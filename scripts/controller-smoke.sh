#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v quickshell > /dev/null 2>&1; then
  printf 'CommitPulse controller smoke: SKIP; quickshell is unavailable.\n'
  exit 0
fi
if ! command -v flock > /dev/null 2>&1; then
  printf 'CommitPulse controller smoke: SKIP; flock is unavailable.\n'
  exit 0
fi

smoke_root="$(mktemp -d "${TMPDIR:-/tmp}/commitpulse-controller.XXXXXX")"
diagnostics="$smoke_root/quickshell.log"

cleanup() {
  case "$smoke_root" in
    "${TMPDIR:-/tmp}"/commitpulse-controller.*) rm -rf -- "$smoke_root" ;;
  esac
}
trap cleanup EXIT INT TERM

umask 077
stage_root="$smoke_root/staged_plugin"
scenario_state="$smoke_root/scenario-state"
mkdir -p "$smoke_root/home" "$smoke_root/config" "$smoke_root/cache" "$smoke_root/state" "$smoke_root/data" "$smoke_root/runtime" "$scenario_state" "$stage_root/bin" "$stage_root/test" "$stage_root/quickshell"
chmod 700 "$smoke_root/home" "$smoke_root/config" "$smoke_root/cache" "$smoke_root/state" "$smoke_root/data" "$smoke_root/runtime" "$scenario_state"
go build -trimpath -o "$stage_root/bin/commitpulse-data" "$repository_root/cmd/commitpulse-data"
cp "$repository_root/manifest.json" "$stage_root/manifest.json"
cp "$repository_root/test/controller-shell.qml" "$stage_root/test/ControllerShell.qml"
cp "$repository_root/test/scenario-helper.sh" "$smoke_root/scenario-helper"
cp "$repository_root/quickshell/DataController.qml" "$stage_root/quickshell/DataController.qml"
cp "$repository_root/quickshell/ContributionState.js" "$stage_root/quickshell/ContributionState.js"
chmod 700 "$smoke_root/scenario-helper"
printf '%s\n' 'import "staged_plugin/test" as Test' 'Test.ControllerShell {}' > "$smoke_root/shell.qml"

runtime_environment=(
  "HOME=$smoke_root/home"
  "XDG_CONFIG_HOME=$smoke_root/config"
  "XDG_CACHE_HOME=$smoke_root/cache"
  "XDG_STATE_HOME=$smoke_root/state"
  "XDG_DATA_HOME=$smoke_root/data"
  "XDG_RUNTIME_DIR=$smoke_root/runtime"
  "COMMITPULSE_TEST_HELPER=$smoke_root/scenario-helper"
  "COMMITPULSE_SCENARIO_STATE=$scenario_state"
  "QT_QPA_PLATFORM=offscreen"
  "NO_COLOR=1"
)

if ! timeout --foreground --kill-after=2s 12s env "${runtime_environment[@]}" quickshell --no-color --path "$smoke_root" > "$diagnostics" 2>&1; then
  sed -n '1,160p' "$diagnostics" >&2
  printf 'CommitPulse controller smoke: Quickshell did not exit cleanly.\n' >&2
  exit 1
fi

if ! grep -Fq 'COMMITPULSE_CONTROLLER_READY: fresh stale auth malformed manual startup maximum active 1' "$diagnostics"; then
  sed -n '1,160p' "$diagnostics" >&2
  printf 'CommitPulse controller smoke: readiness marker was not emitted.\n' >&2
  exit 1
fi
if grep -Eiq 'COMMITPULSE_CONTROLLER_ERROR|module .+ is not installed|is not a type|Cannot assign|ReferenceError|TypeError|Required property|QQmlComponent: Component is not ready|file:.*:.*(Error|error:)' "$diagnostics"; then
  sed -n '1,160p' "$diagnostics" >&2
  printf 'CommitPulse controller smoke: QML/runtime diagnostics reported an error.\n' >&2
  exit 1
fi
if [[ "$(< "$scenario_state/invocation-count")" != "4" || "$(< "$scenario_state/maximum-active")" != "1" || "$(< "$scenario_state/active-count")" != "0" ]]; then
  printf 'CommitPulse controller smoke: fixture invocation or concurrency record was invalid.\n' >&2
  exit 1
fi
if [[ -e "$smoke_root/cache/commitpulse" ]]; then
  printf 'CommitPulse controller smoke: scenario mode unexpectedly created helper cache state.\n' >&2
  exit 1
fi

printf 'CommitPulse controller smoke: fresh/stale/auth/malformed lifecycle passed.\n'
