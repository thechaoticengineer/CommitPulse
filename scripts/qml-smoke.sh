#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
interactive=0

usage() {
  cat <<'EOF'
Usage: scripts/qml-smoke.sh [--interactive]

Runs model and static QML checks, then loads the repository-local CommitPulse
demo through Quickshell when an active Wayland socket is available. --interactive
leaves the isolated demo visible until Quickshell is closed or interrupted.
EOF
}

for argument in "$@"; do
  case "$argument" in
    --interactive) interactive=1 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$argument" >&2; usage >&2; exit 2 ;;
  esac
done

static_check() {
  (cd "$repository_root" && npm test)
  /usr/lib/qt6/bin/qmlformat "$repository_root/demo/shell.qml" > /dev/null
  /usr/lib/qt6/bin/qmlformat "$repository_root/quickshell/BarWidget.qml" > /dev/null
  /usr/lib/qt6/bin/qmlformat "$repository_root/quickshell/DataController.qml" > /dev/null
  /usr/lib/qt6/bin/qmlformat "$repository_root/quickshell/Panel.qml" > /dev/null
  /usr/lib/qt6/bin/qmlformat "$repository_root/test/controller-shell.qml" > /dev/null
}

static_check

if ! command -v quickshell > /dev/null; then
  printf 'CommitPulse smoke: runtime skipped; quickshell is unavailable. Static validation passed.\n'
  exit 0
fi

if ! command -v flock > /dev/null; then
  printf 'CommitPulse smoke: runtime skipped; flock is unavailable. Static validation passed.\n'
  exit 0
fi

if [[ -z "${WAYLAND_DISPLAY:-}" || -z "${XDG_RUNTIME_DIR:-}" || ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]]; then
  printf 'CommitPulse smoke: runtime skipped; an active Wayland socket (WAYLAND_DISPLAY and XDG_RUNTIME_DIR) is required. Static validation passed.\n'
  exit 0
fi

smoke_root="$(mktemp -d "${TMPDIR:-/tmp}/commitpulse-smoke.XXXXXX")"
diagnostics="$smoke_root/quickshell.log"
cleanup() {
  case "$smoke_root" in
    "${TMPDIR:-/tmp}"/commitpulse-smoke.*) rm -rf -- "$smoke_root" ;;
  esac
}
trap cleanup EXIT INT TERM

umask 077
stage_root="$smoke_root/staged_plugin"
runtime_demo="$stage_root/demo"
runtime_quickshell="$stage_root/quickshell"
runtime_bin="$stage_root/bin"
scenario_state="$smoke_root/scenario-state"
runtime_dir="$smoke_root/runtime"
mkdir -p "$smoke_root/home" "$smoke_root/config" "$smoke_root/cache" "$smoke_root/state" "$smoke_root/data" "$scenario_state" "$runtime_dir" "$runtime_demo" "$runtime_quickshell" "$runtime_bin"
chmod 700 "$smoke_root/home" "$smoke_root/config" "$smoke_root/cache" "$smoke_root/state" "$smoke_root/data" "$scenario_state" "$runtime_dir"

# Quickshell's configuration scanner resolves qs.Commons and qs.Ui relative
# to each loaded QML file. Stage only this repository's three QML/JS inputs,
# then make those resolution points explicit links to the packaged, read-only
# Omarchy APIs. The real user plugin directory is never considered.
cp "$repository_root/demo/shell.qml" "$runtime_demo/DemoRoot.qml"
cp "$repository_root/quickshell/BarWidget.qml" "$runtime_quickshell/BarWidget.qml"
cp "$repository_root/quickshell/DataController.qml" "$runtime_quickshell/DataController.qml"
cp "$repository_root/quickshell/Panel.qml" "$runtime_quickshell/Panel.qml"
cp "$repository_root/quickshell/ContributionFixture.js" "$runtime_quickshell/ContributionFixture.js"
cp "$repository_root/quickshell/ContributionState.js" "$runtime_quickshell/ContributionState.js"
cp "$repository_root/manifest.json" "$stage_root/manifest.json"
cp "$repository_root/test/scenario-helper.sh" "$smoke_root/scenario-helper"
chmod 700 "$smoke_root/scenario-helper"
printf '%s\n' 'import "staged_plugin/demo" as Demo' 'Demo.DemoRoot {}' > "$smoke_root/shell.qml"
for import_parent in "$runtime_demo" "$runtime_quickshell"; do
  ln -s /usr/share/omarchy/shell/Commons "$import_parent/Commons"
  ln -s /usr/share/omarchy/shell/Ui "$import_parent/Ui"
done
ln -s /usr/share/omarchy/shell/Commons "$smoke_root/Commons"
ln -s /usr/share/omarchy/shell/Ui "$smoke_root/Ui"

# Expose only the active compositor socket through the otherwise private XDG
# runtime tree. No live plugin or shell configuration is consulted.
ln -s "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" "$runtime_dir/$WAYLAND_DISPLAY"

runtime_environment=(
  "HOME=$smoke_root/home"
  "XDG_CONFIG_HOME=$smoke_root/config"
  "XDG_CACHE_HOME=$smoke_root/cache"
  "XDG_STATE_HOME=$smoke_root/state"
  "XDG_DATA_HOME=$smoke_root/data"
  "XDG_RUNTIME_DIR=$runtime_dir"
  "OMARCHY_PATH=/usr/share/omarchy"
  "QML2_IMPORT_PATH=$smoke_root:/usr/share/omarchy/shell:/usr/lib/qt6/qml"
  "QML_IMPORT_PATH=$smoke_root:/usr/share/omarchy/shell:/usr/lib/qt6/qml"
  "NO_COLOR=1"
  "COMMITPULSE_TEST_HELPER=$smoke_root/scenario-helper"
  "COMMITPULSE_SCENARIO_STATE=$scenario_state"
)

go build -trimpath -o "$runtime_bin/commitpulse-data" "$repository_root/cmd/commitpulse-data"

if [[ "$interactive" -eq 1 ]]; then
  runtime_environment+=("COMMITPULSE_SMOKE_INTERACTIVE=1")
  printf 'CommitPulse demo: isolated Quickshell preview is running; close it or press Ctrl-C when finished.\n'
  if ! env "${runtime_environment[@]}" quickshell --no-color --path "$smoke_root" > "$diagnostics" 2>&1; then
    cat "$diagnostics" >&2
    exit 1
  fi
else
  if ! timeout --foreground --kill-after=2s 15s env "${runtime_environment[@]}" quickshell --no-color --path "$smoke_root" > "$diagnostics" 2>&1; then
    cat "$diagnostics" >&2
    printf 'CommitPulse smoke: Quickshell did not exit cleanly.\n' >&2
    exit 1
  fi
fi

if ! grep -Fq 'COMMITPULSE_SMOKE_READY: fresh stale auth malformed manual maximum active 1' "$diagnostics"; then
  sed -n '1,200p' "$diagnostics" >&2
  printf 'CommitPulse smoke: expected readiness marker was not emitted.\n' >&2
  exit 1
fi

if grep -Eiq 'COMMITPULSE_SMOKE_ERROR|module .+ is not installed|is not a type|Cannot assign|ReferenceError|TypeError|Required property|QQmlComponent: Component is not ready|file:.*:.*(Error|error:)' "$diagnostics"; then
  printf 'CommitPulse smoke: QML/import/component diagnostics reported an error.\n' >&2
  exit 1
fi

if [[ "$(< "$scenario_state/invocation-count")" != "4" || "$(< "$scenario_state/maximum-active")" != "1" || "$(< "$scenario_state/active-count")" != "0" ]]; then
  printf 'CommitPulse smoke: fixture invocation or concurrency record was invalid.\n' >&2
  exit 1
fi
if [[ -e "$smoke_root/cache/commitpulse" ]]; then
  printf 'CommitPulse smoke: scenario mode unexpectedly created helper cache state.\n' >&2
  exit 1
fi

printf 'CommitPulse smoke: isolated live-state runtime passed.\n'
