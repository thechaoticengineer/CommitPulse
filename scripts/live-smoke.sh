#!/usr/bin/env bash

set -u
set -o pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass() {
  printf 'CommitPulse live smoke: PASS.\n'
  exit 0
}

skip() {
  printf 'CommitPulse live smoke: SKIP (%s).\n' "$1"
  exit 0
}

fail() {
  printf 'CommitPulse live smoke: FAIL.\n'
  exit 1
}

if ! command -v gh > /dev/null 2>&1; then
  skip "GitHub CLI unavailable"
fi
if ! timeout --foreground --kill-after=2s 15s env MISE_QUIET=1 GH_PROMPT_DISABLED=1 gh auth status --active > /dev/null 2>&1; then
  skip "GitHub authentication unavailable"
fi

umask 077
smoke_root="$(mktemp -d "${TMPDIR:-/tmp}/commitpulse-live-smoke.XXXXXX" 2> /dev/null)" || fail
cleanup() {
  case "$smoke_root" in
    "${TMPDIR:-/tmp}"/commitpulse-live-smoke.*) rm -rf -- "$smoke_root" > /dev/null 2>&1 ;;
  esac
}
trap cleanup EXIT INT TERM

if ! (cd "$repository_root" && go build -trimpath -o "$smoke_root/commitpulse-data" ./cmd/commitpulse-data) > "$smoke_root/build.log" 2>&1; then
  fail
fi

helper_status=0
env XDG_CACHE_HOME="$smoke_root/cache" MISE_QUIET=1 GH_PROMPT_DISABLED=1 \
  timeout --foreground --kill-after=2s 25s "$smoke_root/commitpulse-data" -max-attempts 1 \
  > "$smoke_root/output.json" 2> "$smoke_root/helper.log" || helper_status=$?

if [[ "$helper_status" -eq 124 || "$helper_status" -eq 137 ]]; then
  skip "network unavailable"
fi

validation_status=0
node "$repository_root/scripts/validate-helper-output.mjs" --live "$smoke_root/output.json" \
  > "$smoke_root/validation.log" 2>&1 || validation_status=$?
case "$validation_status" in
  0) pass ;;
  10) skip "authenticated API unavailable" ;;
  *) fail ;;
esac
