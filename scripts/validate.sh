#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validation_root="$(mktemp -d "${TMPDIR:-/tmp}/commitpulse-validation.XXXXXX")"

cleanup() {
  case "$validation_root" in
    "${TMPDIR:-/tmp}"/commitpulse-validation.*) rm -rf -- "$validation_root" ;;
  esac
}
trap cleanup EXIT INT TERM

cd "$repository_root"

unformatted="$(gofmt -l cmd internal)"
if [[ -n "$unformatted" ]]; then
  printf 'Go formatting check failed:\n%s\n' "$unformatted" >&2
  exit 1
fi

go vet ./...
go test ./...

goos="$(go env GOOS)"
goarch="$(go env GOARCH)"
cgo_enabled="$(go env CGO_ENABLED)"
case "$goos/$goarch/$cgo_enabled" in
  linux/amd64/1|linux/arm64/1|linux/ppc64le/1|linux/s390x/1|linux/loong64/1)
    go test -race ./...
    ;;
  *)
    printf 'CommitPulse validation: race tests skipped; unsupported Go race target %s/%s with CGO_ENABLED=%s.\n' "$goos" "$goarch" "$cgo_enabled"
    ;;
esac

go build -trimpath -o "$validation_root/commitpulse-data" ./cmd/commitpulse-data
env PATH=/nonexistent XDG_CACHE_HOME="$validation_root/cache" \
  "$validation_root/commitpulse-data" -fixture > "$validation_root/fixture.json"
if [[ -e "$validation_root/cache" ]]; then
  printf 'Fixture mode unexpectedly created cache state.\n' >&2
  exit 1
fi
node scripts/validate-helper-output.mjs --fixture "$validation_root/fixture.json"

bash -n test/scenario-helper.sh scripts/controller-smoke.sh scripts/qml-smoke.sh scripts/live-smoke.sh scripts/validate.sh
npm run smoke:controller
npm run smoke

tracked_runtime="$(git ls-files -- '.env' '.env.*' '.commitpulse/**' 'bin/**' 'dist/**' '**/commitpulse-data' '**/success-v1.json' '**/retry-v1.json' '**/cache.lock' '**/.commitpulse-*.tmp' '**/invocation-count' '**/active-count' '**/maximum-active' '*.log')"
if [[ -n "$tracked_runtime" ]]; then
  printf 'Tracked runtime or generated artifacts found:\n%s\n' "$tracked_runtime" >&2
  exit 1
fi
git diff --check

printf 'CommitPulse validation: PASS.\n'
