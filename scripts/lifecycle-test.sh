#!/usr/bin/env bash

# End-to-end lifecycle coverage for install.sh and uninstall.sh.  This harness
# never uses the caller's HOME: every command receives a disposable home and
# XDG roots below one temporary directory.  It delegates manifest checking to
# Omarchy's installed validator and stubs only the shell IPC command boundary.

set -Eeuo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
original_path="$PATH"
real_validator="$(command -v omarchy-plugin-validate || true)"
real_go="$(command -v go)"
real_date="$(command -v date)"

[[ -n $real_validator ]] || {
  printf 'CommitPulse lifecycle test: installed omarchy-plugin-validate is required.\n' >&2
  exit 1
}

lifecycle_root="$(mktemp -d "${TMPDIR:-/tmp}/commitpulse-lifecycle.XXXXXX")"
stub_dir="$lifecycle_root/omarchy stubs"
mkdir -p -- "$stub_dir"

cleanup() {
  case "$lifecycle_root" in
    "${TMPDIR:-/tmp}"/commitpulse-lifecycle.*) rm -rf -- "$lifecycle_root" ;;
  esac
}
trap cleanup EXIT INT TERM

fail() {
  printf 'CommitPulse lifecycle test: %s\n' "$*" >&2
  exit 1
}

expect_failure() {
  if "$@"; then
    fail "expected command to fail: $*"
  fi
}

assert_file() {
  [[ -f $1 && ! -L $1 ]] || fail "expected regular file: $1"
}

assert_directory() {
  [[ -d $1 && ! -L $1 ]] || fail "expected regular directory: $1"
}

assert_no_symlinks() {
  local tree="$1" link
  link="$(find "$tree" -type l -print -quit)"
  [[ -z $link ]] || fail "unexpected symlink in installed tree: $link"
}

assert_no_transfer_stages() {
  local plugins="$1" stage
  [[ -d $plugins ]] || return 0
  stage="$(find "$plugins" -mindepth 1 -maxdepth 1 -name '.dev.commitpulse.stage.*' -print -quit)"
  [[ -z $stage ]] || fail "partial transfer stage remains: $stage"
}

scrub_owned_state() {
  jq --arg id dev.commitpulse '
    def entry_id:
      if type == "object" then (.id // "")
      elif type == "string" then .
      else ""
      end;
    if (.bar? | type) == "object" and .bar.id? == $id then del(.bar.id) else . end
    | if (.bar?.layout? | type) == "object" then
        reduce ["left", "center", "right"][] as $section (.;
          if (.bar.layout[$section] | type) == "array" then
            .bar.layout[$section] |= map(select((entry_id) != $id))
          else . end)
      else . end
    | if (.plugins? | type) == "array" then
        .plugins |= map(select((if type == "object" then (.id // "") else "" end) != $id))
      else . end
    | if (.disabledPlugins? | type) == "array" then
        .disabledPlugins |= map(select(. != $id))
      else . end
    | if (.cloneSourceRestores? | type) == "array" then
        .cloneSourceRestores |= map(select(. != $id))
      else . end
  ' "$1"
}

assert_unrelated_state() {
  local baseline="$1" shell_json="$2"
  jq -e -s '.[0] == .[1]' "$baseline" <(scrub_owned_state "$shell_json") >/dev/null ||
    fail "unrelated shell.json state changed: $shell_json"
}

commitpulse_entry_count() {
  local shell_json="$1"
  jq --arg id dev.commitpulse '
    def entry_id:
      if type == "object" then (.id // "")
      elif type == "string" then .
      else ""
      end;
    [.bar.layout.left[], .bar.layout.center[], .bar.layout.right[]
      | select(entry_id == $id)] | length
  ' "$shell_json"
}

write_fixture_shell() {
  local home="$1" shell_json="$home/.config/omarchy/shell.json"
  mkdir -p -- "$home/.config/omarchy/plugins" "$home/cache directory" "$home/runtime directory"
  jq -n '
    {
      version: 1,
      idle: {screensaver: 123, lock: 456, fictionalIdleExtension: {mode: "fictional"}},
      bar: {
        id: "omarchy.bar",
        position: "top",
        transparent: false,
        centerAnchor: "fictional.clock",
        layout: {
          left: [
            {id: "fictional.menu", settings: {label: "Fictional menu", nested: [1, 2]}},
            {id: "fictional.workspaces", icons: {active: "A", inactive: "I"}}
          ],
          center: [
            {id: "fictional.clock", format: "HH:mm", calendar: {weekStartsMonday: true}},
            {id: "fictional.status", state: {level: "green", labels: ["one", "two"]}}
          ],
          right: [
            {id: "fictional.network", display: {showSignal: true, label: "Fictional Wi-Fi"}},
            {id: "fictional.audio", volume: {step: 5, device: "fictional-output"}}
          ]
        }
      },
      plugins: [{id: "fictional.panel", settings: {collapsed: false, labels: ["alpha", "beta"]}}],
      disabledPlugins: ["fictional.disabled"],
      cloneSourceRestores: ["fictional.clone"],
      unknownFutureSetting: {preserve: ["fictional", {deep: true}]}
    }
  ' > "$shell_json"
}

new_case() {
  local name="$1" case_root home
  case_root="$(mktemp -d "$lifecycle_root/$name.XXXXXX")"
  home="$case_root/home with spaces"
  mkdir -p -- "$home"
  write_fixture_shell "$home"
  printf '%s\n' "$home"
}

run_lifecycle() {
  local home="$1" action="$2" injected_failure="${3:-}"
  env \
    HOME="$home" \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_CACHE_HOME="$home/cache directory" \
    XDG_RUNTIME_DIR="$home/runtime directory" \
    TMPDIR="$lifecycle_root" \
    COMMITPULSE_TEST_ROOT="$home" \
    COMMITPULSE_TEST_FAIL="$injected_failure" \
    COMMITPULSE_REAL_VALIDATE="$real_validator" \
    COMMITPULSE_REAL_GO="$real_go" \
    COMMITPULSE_REAL_DATE="$real_date" \
    PATH="$stub_dir:$original_path" \
    bash "$repository_root/$action.sh"
}

assert_complete_install() {
  local home="$1" destination="$home/.config/omarchy/plugins/dev.commitpulse"
  assert_directory "$destination"
  assert_file "$destination/manifest.json"
  assert_file "$destination/LICENSE"
  assert_file "$destination/quickshell/BarWidget.qml"
  assert_file "$destination/quickshell/DataController.qml"
  assert_file "$destination/quickshell/Panel.qml"
  assert_file "$destination/bin/commitpulse-data"
  [[ -x $destination/bin/commitpulse-data ]] || fail "installed helper is not executable"
  cmp -- "$repository_root/manifest.json" "$destination/manifest.json" || fail "installed manifest differs from source"
  cmp -- "$repository_root/LICENSE" "$destination/LICENSE" || fail "installed license differs from source"
  diff -r --no-dereference "$repository_root/quickshell" "$destination/quickshell" >/dev/null ||
    fail "installed QML tree is incomplete or differs from source"
  assert_no_symlinks "$destination"
  "$real_validator" "$destination"
}

assert_helper_fixture() {
  local home="$1" destination="$home/.config/omarchy/plugins/dev.commitpulse" output="$home/helper-fixture.json" fixture_cache="$home/fixture-only cache"
  env PATH=/nonexistent XDG_CACHE_HOME="$fixture_cache" \
    "$destination/bin/commitpulse-data" -fixture > "$output"
  [[ ! -e $fixture_cache ]] || fail "fixture mode created cache state"
  node "$repository_root/scripts/validate-helper-output.mjs" --fixture "$output" >/dev/null
}

assert_installed_layout() {
  local shell_json="$1/.config/omarchy/shell.json"
  [[ $(commitpulse_entry_count "$shell_json") == 1 ]] ||
    fail "CommitPulse is duplicated or placed outside the requested section"
  jq -e --arg id dev.commitpulse '
    [.bar.layout.right[] | select((if type == "object" then (.id // "") else . end) == $id)] | length == 1
  ' "$shell_json" >/dev/null || fail "CommitPulse is not enabled in right"
}

assert_uninstalled() {
  local home="$1" destination="$home/.config/omarchy/plugins/dev.commitpulse" shell_json="$home/.config/omarchy/shell.json"
  [[ ! -e $destination && ! -L $destination ]] || fail "plugin destination remains after uninstall"
  [[ $(commitpulse_entry_count "$shell_json") == 0 ]] || fail "CommitPulse layout remains after uninstall"
}

create_stubs() {
  apply_stub() {
    local path="$1"
    shift
    printf '%s\n' "$@" > "$path"
    chmod 0755 "$path"
  }

  apply_stub "$stub_dir/date" '#!/usr/bin/env bash' 'if [[ ${1:-} == "-u" && ${2:-} == "+%Y%m%dT%H%M%SZ" ]]; then printf "%s\\n" "20960101T000000Z"; else exec "$COMMITPULSE_REAL_DATE" "$@"; fi'
  apply_stub "$stub_dir/go" '#!/usr/bin/env bash' 'if [[ ${COMMITPULSE_TEST_FAIL:-} == build && ${1:-} == build ]]; then echo "fictional build failure" >&2; exit 77; fi' 'exec "$COMMITPULSE_REAL_GO" "$@"'
  apply_stub "$stub_dir/omarchy" '#!/usr/bin/env bash' 'set -Eeuo pipefail' 'fail() { printf "omarchy stub: %s\\n" "$*" >&2; exit 1; }' 'home=${COMMITPULSE_TEST_ROOT:?}' 'shell_json="$home/.config/omarchy/shell.json"' 'destination="$home/.config/omarchy/plugins/dev.commitpulse"' 'id=dev.commitpulse' 'case "${1:-}:${2:-}:${3:-}" in' '  plugin:validate:*) [[ ${COMMITPULSE_TEST_FAIL:-} != validate ]] || fail "fictional validation failure"; shift 2; exec "$COMMITPULSE_REAL_VALIDATE" "$@" ;;' '  shell:shell:rescanPlugins) [[ ${COMMITPULSE_TEST_FAIL:-} != rescan ]] || fail "fictional rescan failure"; printf "ok\\n" ;;' '  shell:shell:listPlugins)' '    if [[ -d $destination && ! -L $destination ]]; then' '      enabled=$(jq -c --arg id "$id" "[.bar.layout.left[], .bar.layout.center[], .bar.layout.right[] | if type == \\"object\\" then (.id // \\"\\") else . end] | index(\$id) != null" "$shell_json")' '      jq -cn --arg id "$id" --argjson enabled "$enabled" "[{id: \$id, kinds: [\"bar-widget\"], enabled: \$enabled}]"' '    else printf "[]\\n"; fi ;;' '  plugin:enable:dev.commitpulse)' '    [[ ${4:-} == --section && ${5:-} == right && $# == 5 ]] || fail "unexpected enable arguments"' '    [[ ${COMMITPULSE_TEST_FAIL:-} != enable ]] || fail "fictional enable failure"' '    jq --arg id "$id" "def entry_id: if type == \\"object\\" then (.id // \\"\\") elif type == \\"string\\" then . else \\"\\" end; if any(.bar.layout.left[], .bar.layout.center[], .bar.layout.right[]; entry_id == \$id) then . else .bar.layout.right += [{id: \$id}] end" "$shell_json" > "$shell_json.stub"' '    mv "$shell_json.stub" "$shell_json"' '    printf "Enabled %s\\n" "$id" ;;' '  plugin:disable:dev.commitpulse)' '    [[ $# == 3 ]] || fail "unexpected disable arguments"' '    jq --arg id "$id" "def entry_id: if type == \\"object\\" then (.id // \\"\\") elif type == \\"string\\" then . else \\"\\" end; .bar.layout.left |= map(select(entry_id != \$id)) | .bar.layout.center |= map(select(entry_id != \$id)) | .bar.layout.right |= map(select(entry_id != \$id))" "$shell_json" > "$shell_json.stub"' '    mv "$shell_json.stub" "$shell_json"' '    printf "Disabled %s\\n" "$id" ;;' '  *) fail "unexpected exact Omarchy API: $*" ;;' 'esac'
}

create_test_stubs() {
  local filter_dir="$lifecycle_root/jq filters"
  write_test_stub() {
    local path="$1"
    shift
    printf '%s\n' "$@" > "$path"
    chmod 0755 "$path"
  }
  mkdir -p -- "$filter_dir"

  write_test_stub "$filter_dir/list-enabled.jq" '[.bar.layout.left[], .bar.layout.center[], .bar.layout.right[] | if type == "object" then (.id // "") else . end] | index($id) != null'
  write_test_stub "$filter_dir/enable.jq" 'def entry_id: if type == "object" then (.id // "") elif type == "string" then . else "" end; if any(.bar.layout.left[], .bar.layout.center[], .bar.layout.right[]; entry_id == $id) then . else .bar.layout.right += [{id: $id}] end'
  write_test_stub "$filter_dir/disable.jq" 'def entry_id: if type == "object" then (.id // "") elif type == "string" then . else "" end; .bar.layout.left |= map(select(entry_id != $id)) | .bar.layout.center |= map(select(entry_id != $id)) | .bar.layout.right |= map(select(entry_id != $id))'

  write_test_stub "$stub_dir/date" '#!/usr/bin/env bash' 'if [[ ${1:-} == "-u" && ${2:-} == "+%Y%m%dT%H%M%SZ" ]]; then printf "%s\n" "20960101T000000Z"; else exec "$COMMITPULSE_REAL_DATE" "$@"; fi'
  write_test_stub "$stub_dir/go" '#!/usr/bin/env bash' 'if [[ ${COMMITPULSE_TEST_FAIL:-} == build && ${1:-} == build ]]; then echo "fictional build failure" >&2; exit 77; fi' 'exec "$COMMITPULSE_REAL_GO" "$@"'
  write_test_stub "$stub_dir/omarchy" '#!/usr/bin/env bash' 'set -Eeuo pipefail' 'fail() { printf "omarchy stub: %s\n" "$*" >&2; exit 1; }' 'home=${COMMITPULSE_TEST_ROOT:?}' 'shell_json="$home/.config/omarchy/shell.json"' 'destination="$home/.config/omarchy/plugins/dev.commitpulse"' 'id=dev.commitpulse' 'case "${1:-}:${2:-}:${3:-}" in' '  plugin:validate:*) [[ ${COMMITPULSE_TEST_FAIL:-} != validate ]] || fail "fictional validation failure"; shift 2; exec "$COMMITPULSE_REAL_VALIDATE" "$@" ;;' '  shell:shell:rescanPlugins) [[ ${COMMITPULSE_TEST_FAIL:-} != rescan ]] || fail "fictional rescan failure"; printf "ok\n" ;;' '  shell:shell:listPlugins)' '    if [[ -d $destination && ! -L $destination ]]; then' "      jq -cn --arg id \"\$id\" '[{id: \$id, kinds: [\"bar-widget\"], enabled: true}]'" '    else printf "[]\n"; fi ;;' '  plugin:enable:dev.commitpulse)' '    [[ ${4:-} == --section && ${5:-} == right && $# == 5 ]] || fail "unexpected enable arguments"' '    [[ ${COMMITPULSE_TEST_FAIL:-} != enable ]] || fail "fictional enable failure"' '    jq --arg id "$id" -f "$COMMITPULSE_STUB_ENABLE_FILTER" "$shell_json" > "$shell_json.stub"' '    mv "$shell_json.stub" "$shell_json"' '    printf "Enabled %s\n" "$id" ;;' '  plugin:disable:dev.commitpulse)' '    [[ $# == 3 ]] || fail "unexpected disable arguments"' '    jq --arg id "$id" -f "$COMMITPULSE_STUB_DISABLE_FILTER" "$shell_json" > "$shell_json.stub"' '    mv "$shell_json.stub" "$shell_json"' '    printf "Disabled %s\n" "$id" ;;' '  *) fail "unexpected exact Omarchy API: $*" ;;' 'esac'

  export COMMITPULSE_STUB_LIST_FILTER="$filter_dir/list-enabled.jq"
  export COMMITPULSE_STUB_ENABLE_FILTER="$filter_dir/enable.jq"
  export COMMITPULSE_STUB_DISABLE_FILTER="$filter_dir/disable.jq"
}

create_test_stubs

# Fresh install, repeat installation, collision-safe upgrade backup, and both
# uninstall paths all run against a HOME whose path contains spaces.
home="$(new_case lifecycle)"
shell_json="$home/.config/omarchy/shell.json"
plugins="$home/.config/omarchy/plugins"
baseline="$home/unrelated-baseline.json"
scrub_owned_state "$shell_json" > "$baseline"

run_lifecycle "$home" install
assert_complete_install "$home"
assert_helper_fixture "$home"
assert_installed_layout "$home"
assert_unrelated_state "$baseline" "$shell_json"

# The staged installer must preserve an existing configured instance while
# replacing its tree.  A fixed test clock forces the suffix branch in backup
# allocation, so collision handling is deterministic.
printf 'fictional previous build\n' > "$plugins/dev.commitpulse/old-version-marker"
jq --arg id dev.commitpulse '
  .bar.layout.right |= map(if (.id // "") == $id then . + {fictionalSetting: {mode: "previous"}} else . end)
' "$shell_json" > "$shell_json.next"
mv "$shell_json.next" "$shell_json"
mkdir -p -- "$plugins/.dev.commitpulse.backup.20960101T000000Z"
printf 'fictional collision\n' > "$plugins/.dev.commitpulse.backup.20960101T000000Z/sentinel"
printf 'fictional shell collision\n' > "$shell_json.commitpulse-backup.20960101T000000Z"

run_lifecycle "$home" install
assert_complete_install "$home"
assert_installed_layout "$home"
assert_file "$plugins/.dev.commitpulse.backup.20960101T000000Z-1/old-version-marker"
assert_file "$shell_json.commitpulse-backup.20960101T000000Z-1"
assert_unrelated_state "$baseline" "$shell_json"

run_lifecycle "$home" install
assert_installed_layout "$home"
assert_unrelated_state "$baseline" "$shell_json"

run_lifecycle "$home" uninstall
assert_uninstalled "$home"
assert_unrelated_state "$baseline" "$shell_json"
run_lifecycle "$home" uninstall
assert_uninstalled "$home"
assert_unrelated_state "$baseline" "$shell_json"

# Invalid configuration is rejected before any destination is created.
malformed_home="$(new_case malformed)"
malformed_shell="$malformed_home/.config/omarchy/shell.json"
printf '{ fictional malformed shell configuration\n' > "$malformed_shell"
cp -- "$malformed_shell" "$malformed_home/original-shell.json"
expect_failure run_lifecycle "$malformed_home" install
cmp -- "$malformed_home/original-shell.json" "$malformed_shell" || fail "malformed shell changed"
[[ ! -e "$malformed_home/.config/omarchy/plugins/dev.commitpulse" ]] || fail "malformed install wrote destination"
assert_no_transfer_stages "$malformed_home/.config/omarchy/plugins"

# Build and manifest validation failures occur before the old installation is
# changed.  The validator branch is the real installed Omarchy validator behind
# the exact `omarchy plugin validate <folder>` command surface.
build_home="$(new_case build-failure)"
build_shell="$build_home/.config/omarchy/shell.json"
cp -- "$build_shell" "$build_home/original-shell.json"
expect_failure run_lifecycle "$build_home" install build
cmp -- "$build_home/original-shell.json" "$build_shell" || fail "failed build changed shell"
[[ ! -e "$build_home/.config/omarchy/plugins/dev.commitpulse" ]] || fail "failed build wrote destination"

validation_home="$(new_case validation-failure)"
validation_shell="$validation_home/.config/omarchy/shell.json"
cp -- "$validation_shell" "$validation_home/original-shell.json"
expect_failure run_lifecycle "$validation_home" install validate
cmp -- "$validation_home/original-shell.json" "$validation_shell" || fail "failed validation changed shell"
[[ ! -e "$validation_home/.config/omarchy/plugins/dev.commitpulse" ]] || fail "failed validation wrote destination"
assert_no_transfer_stages "$validation_home/.config/omarchy/plugins"

# An IPC rescan or enable failure happens after the atomic directory swap.  In
# both cases the original complete tree and exact shell document are restored.
for activation_failure in rescan enable; do
  rollback_home="$(new_case "rollback-$activation_failure")"
  rollback_shell="$rollback_home/.config/omarchy/shell.json"
  run_lifecycle "$rollback_home" install
  rollback_destination="$rollback_home/.config/omarchy/plugins/dev.commitpulse"
  printf 'fictional rollback sentinel\n' > "$rollback_destination/original-tree-marker"
  cp -a -- "$rollback_destination" "$rollback_home/original-tree"
  cp -- "$rollback_shell" "$rollback_home/original-shell.json"
  expect_failure run_lifecycle "$rollback_home" install "$activation_failure"
  cmp -- "$rollback_home/original-shell.json" "$rollback_shell" || fail "$activation_failure rollback changed shell"
  assert_file "$rollback_destination/original-tree-marker"
  diff -r --no-dereference "$rollback_home/original-tree" "$rollback_destination" >/dev/null ||
    fail "$activation_failure rollback did not restore plugin tree"
  assert_no_transfer_stages "$rollback_home/.config/omarchy/plugins"
done

# A symlinked target is rejected without following or replacing it.
symlink_home="$(new_case symlink)"
symlink_plugins="$symlink_home/.config/omarchy/plugins"
mkdir -p -- "$symlink_home/safe fictional target"
ln -s -- "$symlink_home/safe fictional target" "$symlink_plugins/dev.commitpulse"
expect_failure run_lifecycle "$symlink_home" install
[[ -L "$symlink_plugins/dev.commitpulse" ]] || fail "symlink rejection changed destination"
assert_no_transfer_stages "$symlink_plugins"

git diff --check
tracked_runtime="$(git ls-files -- 'bin/**' '**/commitpulse-data' '**/.commitpulse-*.tmp' '**/cache.lock' '*.log')"
[[ -z $tracked_runtime ]] || fail "tracked runtime artifact detected: $tracked_runtime"

printf 'CommitPulse lifecycle test: PASS.\n'
