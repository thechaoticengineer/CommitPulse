#!/usr/bin/env bash

set -Eeuo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

fail() {
  printf 'CommitPulse panel lifecycle smoke: %s\n' "$*" >&2
  exit 1
}

for command_name in quickshell hyprctl jq; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done
[[ -n ${WAYLAND_DISPLAY:-} && -n ${XDG_RUNTIME_DIR:-} && -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]] ||
  fail "an active Wayland socket is required"

/usr/lib/qt6/bin/qmlformat "$repository_root/test/panel-lifecycle-shell.qml" >/dev/null
/usr/lib/qt6/bin/qmlformat "$repository_root/quickshell/Widget.qml" >/dev/null
/usr/lib/qt6/bin/qmlformat "$repository_root/quickshell/Popup.qml" >/dev/null

smoke_root="$(mktemp -d "${TMPDIR:-/tmp}/commitpulse-panel-lifecycle.XXXXXX")"
runtime_pid=""
cleanup() {
  if [[ -n $runtime_pid ]] && kill -0 "$runtime_pid" 2>/dev/null; then
    kill "$runtime_pid" 2>/dev/null || true
    wait "$runtime_pid" 2>/dev/null || true
  fi
  case "$smoke_root" in
    "${TMPDIR:-/tmp}"/commitpulse-panel-lifecycle.*) rm -rf -- "$smoke_root" ;;
  esac
}
trap cleanup EXIT INT TERM

umask 077
runtime_config="$smoke_root/config-root"
runtime_plugin="$runtime_config/quickshell"
runtime_test="$runtime_config/test"
runtime_dir="$smoke_root/runtime"
diagnostics="$smoke_root/quickshell.log"
mkdir -p "$smoke_root/home" "$smoke_root/config" "$smoke_root/cache" "$smoke_root/state" \
  "$smoke_root/data" "$runtime_dir" "$runtime_plugin" "$runtime_test"
chmod 700 "$smoke_root/home" "$smoke_root/config" "$smoke_root/cache" "$smoke_root/state" \
  "$smoke_root/data" "$runtime_dir"
cp -a -- "$repository_root/quickshell/." "$runtime_plugin/"
cp -- "$repository_root/test/panel-lifecycle-shell.qml" "$runtime_test/PanelLifecycleRoot.qml"
printf '%s\n' 'import "test" as Test' 'Test.PanelLifecycleRoot {}' > "$runtime_config/shell.qml"
for import_parent in "$runtime_config" "$runtime_plugin" "$runtime_test"; do
  ln -s /usr/share/omarchy/shell/Commons "$import_parent/Commons"
  ln -s /usr/share/omarchy/shell/Ui "$import_parent/Ui"
done
ln -s "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" "$runtime_dir/$WAYLAND_DISPLAY"

runtime_environment=(
  "HOME=$smoke_root/home"
  "XDG_CONFIG_HOME=$smoke_root/config"
  "XDG_CACHE_HOME=$smoke_root/cache"
  "XDG_STATE_HOME=$smoke_root/state"
  "XDG_DATA_HOME=$smoke_root/data"
  "XDG_RUNTIME_DIR=$runtime_dir"
  "OMARCHY_PATH=/usr/share/omarchy"
  "QML2_IMPORT_PATH=$runtime_config:/usr/share/omarchy/shell:/usr/lib/qt6/qml"
  "QML_IMPORT_PATH=$runtime_config:/usr/share/omarchy/shell:/usr/lib/qt6/qml"
  "COMMITPULSE_TEST_HELPER=/usr/bin/false"
  "NO_COLOR=1"
)

env "${runtime_environment[@]}" quickshell --no-color --path "$runtime_config" >"$diagnostics" 2>&1 &
runtime_pid=$!

ipc() {
  env "${runtime_environment[@]}" quickshell ipc --pid "$runtime_pid" call "$@"
}

state=""
for _ in {1..200}; do
  kill -0 "$runtime_pid" 2>/dev/null || break
  if state="$(ipc commitpulse.lifecycle state 2>/dev/null)" &&
    jq -e '.loaderReady and .realPanel and .anchorValid and (.completedRuns >= 1) and (.dataRunning | not) and (.hasTotals | not)' <<<"$state" >/dev/null 2>&1; then
    break
  fi
  sleep 0.05
done
kill -0 "$runtime_pid" 2>/dev/null || {
  sed -n '1,120p' "$diagnostics" >&2
  fail "Quickshell exited before the panel became ready"
}
jq -e '.loaderReady and .realPanel and .anchorValid and (.completedRuns >= 1) and (.dataRunning | not) and (.hasTotals | not)' <<<"$state" >/dev/null || {
  sed -n '1,120p' "$diagnostics" >&2
  fail "real panel Loader, anchor, or unavailable-data precondition was not ready"
}

surface_snapshot() {
  hyprctl layers -j | jq -c --argjson pid "$runtime_pid" '
    [to_entries[] as $monitor
      | $monitor.value.levels | to_entries[] | .value[]
      | select(.pid == $pid and .namespace == "omarchy-keyboard-panel")
      | {monitor: $monitor.key, x, y, w, h, alpha}]
  '
}

assert_open_surface() {
  local phase="$1" snapshot="" monitors
  for _ in {1..100}; do
    state="$(ipc commitpulse.lifecycle state 2>/dev/null || true)"
    snapshot="$(surface_snapshot)"
    if jq -e '.opened and .controllerOpen and .loaderReady and .realPanel and .anchorValid and (.hasTotals | not)' <<<"$state" >/dev/null 2>&1 &&
      jq -e 'length == 1 and .[0].w > 0 and .[0].h > 0 and .[0].alpha > 0 and .[0].x >= 0 and .[0].y >= 0' <<<"$snapshot" >/dev/null; then
      break
    fi
    sleep 0.05
  done
  monitors="$(hyprctl monitors -j)"
  jq -e --argjson monitors "$monitors" '
    (length == 1)
    and (.[0] as $surface
      | any($monitors[]; .name == $surface.monitor
        and $surface.x >= .x and $surface.y >= .y
        and $surface.x + $surface.w <= .x + .width
        and $surface.y + $surface.h <= .y + .height))
  ' <<<"$snapshot" >/dev/null || fail "$phase surface was absent, zero-sized, or off-screen"
  printf '%s surface: %s\n' "$phase" "$snapshot"
}

assert_closed_surface() {
  local snapshot=""
  for _ in {1..100}; do
    state="$(ipc commitpulse.lifecycle state 2>/dev/null || true)"
    snapshot="$(surface_snapshot)"
    if jq -e '(.opened | not) and (.controllerOpen | not)' <<<"$state" >/dev/null 2>&1 &&
      jq -e 'length == 0' <<<"$snapshot" >/dev/null; then
      return 0
    fi
    sleep 0.05
  done
  fail "supported close action did not unmap the panel surface"
}

# Invoke WidgetButton.triggerPress(Qt.LeftButton), the same exported action the
# production MouseArea uses, then close through the production panel IPC.
assert_closed_surface
ipc commitpulse.lifecycle press >/dev/null
assert_open_surface "first unavailable-data open"
ipc dev.commitpulse close >/dev/null
assert_closed_surface
ipc commitpulse.lifecycle press >/dev/null
assert_open_surface "reopen"
ipc dev.commitpulse close >/dev/null
assert_closed_surface
ipc commitpulse.lifecycle quit >/dev/null
wait "$runtime_pid"
runtime_pid=""

if grep -Eiq 'module .+ is not installed|is not a type|Cannot assign|ReferenceError|TypeError|Required property|QQmlComponent: Component is not ready|No such file or directory|Unable to assign|QWaylandWindow.*(error|failed)|file:.*:.*(Error|error:)' "$diagnostics"; then
  sed -n '1,120p' "$diagnostics" >&2
  fail "relevant QML, component, property, anchor, or Wayland diagnostics were reported"
fi

if [[ -n ${COMMITPULSE_EVIDENCE_DIR:-} ]]; then
  [[ -d $COMMITPULSE_EVIDENCE_DIR && ! -L $COMMITPULSE_EVIDENCE_DIR ]] ||
    fail "COMMITPULSE_EVIDENCE_DIR must be an existing regular directory"
  cp -- "$diagnostics" "$COMMITPULSE_EVIDENCE_DIR/panel-lifecycle-quickshell.log"
fi

printf 'CommitPulse panel lifecycle smoke: PASS.\n'
