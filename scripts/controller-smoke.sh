#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
smoke_root="$(mktemp -d "${TMPDIR:-/tmp}/commitpulse-controller.XXXXXX")"
diagnostics="$smoke_root/quickshell.log"

cleanup() {
  case "$smoke_root" in
    "${TMPDIR:-/tmp}"/commitpulse-controller.*) rm -rf -- "$smoke_root" ;;
  esac
}
trap cleanup EXIT INT TERM

mkdir -p "$smoke_root/home" "$smoke_root/config" "$smoke_root/cache" "$smoke_root/state" "$smoke_root/data" "$smoke_root/test" "$smoke_root/quickshell"
go build -trimpath -o "$smoke_root/commitpulse-data" "$repository_root/cmd/commitpulse-data"
cp "$repository_root/test/controller-shell.qml" "$smoke_root/test/ControllerShell.qml"
cp "$repository_root/quickshell/DataController.qml" "$smoke_root/quickshell/DataController.qml"
cp "$repository_root/quickshell/ContributionState.js" "$smoke_root/quickshell/ContributionState.js"
printf '%s\n' 'import "test" as Test' 'Test.ControllerShell {}' > "$smoke_root/shell.qml"

runtime_environment=(
  "HOME=$smoke_root/home"
  "XDG_CONFIG_HOME=$smoke_root/config"
  "XDG_CACHE_HOME=$smoke_root/cache"
  "XDG_STATE_HOME=$smoke_root/state"
  "XDG_DATA_HOME=$smoke_root/data"
  "COMMITPULSE_TEST_HELPER=$smoke_root/commitpulse-data"
  "COMMITPULSE_TEST_FIXTURE=1"
  "QT_QPA_PLATFORM=offscreen"
  "NO_COLOR=1"
)

if ! timeout --foreground --kill-after=2s 12s env "${runtime_environment[@]}" quickshell --no-color --path "$smoke_root" > "$diagnostics" 2>&1; then
  sed -n '1,160p' "$diagnostics" >&2
  printf 'CommitPulse controller smoke: Quickshell did not exit cleanly.\n' >&2
  exit 1
fi

if ! grep -Fq 'COMMITPULSE_CONTROLLER_READY: asynchronous fixture refreshes completed with maximum active 1' "$diagnostics"; then
  sed -n '1,160p' "$diagnostics" >&2
  printf 'CommitPulse controller smoke: readiness marker was not emitted.\n' >&2
  exit 1
fi
if grep -Eiq 'COMMITPULSE_CONTROLLER_ERROR|module .+ is not installed|is not a type|Cannot assign|ReferenceError|TypeError|Required property|QQmlComponent: Component is not ready|file:.*:.*(Error|error:)' "$diagnostics"; then
  sed -n '1,160p' "$diagnostics" >&2
  printf 'CommitPulse controller smoke: QML/runtime diagnostics reported an error.\n' >&2
  exit 1
fi
if [[ -e "$smoke_root/cache/commitpulse" ]]; then
  printf 'CommitPulse controller smoke: fixture mode unexpectedly created persistent cache state.\n' >&2
  exit 1
fi

printf 'CommitPulse controller smoke: asynchronous fixture lifecycle passed.\n'
