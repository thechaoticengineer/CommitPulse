#!/usr/bin/env bash

set -euo pipefail

# Deterministic executable used only by isolated QML integration smokes. Every
# envelope and timestamp is fictional. Coordination files are required to live
# below the disposable smoke tree supplied by the caller.
state_root="${COMMITPULSE_SCENARIO_STATE:?COMMITPULSE_SCENARIO_STATE is required}"
delay="${COMMITPULSE_SCENARIO_DELAY:-0.12}"
startup_gate="${COMMITPULSE_SCENARIO_GATE:-}"

case "$state_root" in
  /*) ;;
  *) exit 64 ;;
esac

umask 077
mkdir -p -- "$state_root"

counter_file="$state_root/invocation-count"
active_file="$state_root/active-count"
maximum_file="$state_root/maximum-active"
lock_file="$state_root/scenario.lock"

read_counter() {
  local file="$1"
  local value=0
  if [[ -f "$file" ]]; then
    IFS= read -r value < "$file" || value=0
  fi
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    value=0
  fi
  printf '%s' "$value"
}

exec 9> "$lock_file"
flock 9
invocation="$(read_counter "$counter_file")"
invocation=$((invocation + 1))
active="$(read_counter "$active_file")"
active=$((active + 1))
maximum="$(read_counter "$maximum_file")"
if ((active > maximum)); then
  maximum="$active"
fi
printf '%s\n' "$invocation" > "$counter_file"
printf '%s\n' "$active" > "$active_file"
printf '%s\n' "$maximum" > "$maximum_file"
flock -u 9

release_slot() {
  flock 9
  active="$(read_counter "$active_file")"
  if ((active > 0)); then
    active=$((active - 1))
  fi
  printf '%s\n' "$active" > "$active_file"
  flock -u 9
}
trap release_slot EXIT INT TERM

# The visual smoke supplies this optional gate for its first request. The helper
# stays observably active until QML has rendered and reported the loading state;
# only a file inside the disposable scenario tree may release it.
if [[ "$invocation" == "1" && -n "$startup_gate" ]]; then
  case "$startup_gate" in
    "$state_root"/*) ;;
    *) exit 64 ;;
  esac

  for ((attempt = 0; attempt < 1000; attempt++)); do
    [[ -e "$startup_gate" ]] && break
    sleep 0.01
  done
  [[ -e "$startup_gate" ]] || exit 70
fi

sleep "$delay"

case "$invocation" in
  1)
    printf '%s\n' '{"schemaVersion":1,"state":"fresh","effectiveTimezone":"UTC","periods":[{"name":"today","total":7},{"name":"week","total":17},{"name":"month","total":40},{"name":"year","total":140}],"attemptedAt":"2096-01-14T12:00:00Z","lastUpdated":"2096-01-14T12:00:00Z","visibility":{"privateContributions":"unknown"}}'
    ;;
  2)
    printf '%s\n' '{"schemaVersion":1,"state":"stale","effectiveTimezone":"UTC","periods":[{"name":"today","total":7},{"name":"week","total":17},{"name":"month","total":40},{"name":"year","total":140}],"attemptedAt":"2096-01-14T12:15:00Z","lastUpdated":"2096-01-14T12:00:00Z","visibility":{"privateContributions":"unknown"},"error":{"kind":"offline","message":"Contribution data is unavailable offline."}}'
    exit 7
    ;;
  3)
    printf '%s\n' '{"schemaVersion":1,"state":"unavailable","effectiveTimezone":"UTC","attemptedAt":"2096-01-14T12:30:00Z","visibility":{"privateContributions":"unknown"},"error":{"kind":"authentication","message":"GitHub CLI authentication is required."}}'
    exit 4
    ;;
  4)
    printf '%s\n' '{fictional malformed output'
    exit 1
    ;;
  *)
    printf '%s\n' '{"schemaVersion":1,"state":"fresh","effectiveTimezone":"UTC","periods":[{"name":"today","total":8},{"name":"week","total":18},{"name":"month","total":41},{"name":"year","total":141}],"attemptedAt":"2096-01-14T12:45:00Z","lastUpdated":"2096-01-14T12:45:00Z","visibility":{"privateContributions":"unknown"}}'
    ;;
esac
