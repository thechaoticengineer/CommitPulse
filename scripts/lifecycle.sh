#!/usr/bin/env bash

# Shared implementation for the user-local CommitPulse installer and
# uninstaller. This file is sourced by the repository-root entry points.

readonly COMMITPULSE_PLUGIN_ID="dev.commitpulse"
readonly COMMITPULSE_SECTION="right"

commitpulse_fail() {
  printf 'CommitPulse: %s\n' "$*" >&2
  return 1
}

commitpulse_usage() {
  local command_name="$1"
  cat <<EOF
Usage: ./$command_name

Installs or removes the user-local $COMMITPULSE_PLUGIN_ID Omarchy plugin.
No command-line options are accepted.
EOF
}

commitpulse_require_command() {
  command -v "$1" >/dev/null 2>&1 || commitpulse_fail "required command not found: $1"
}

commitpulse_reject_arguments() {
  local command_name="$1"
  shift
  if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    commitpulse_usage "$command_name"
    return 2
  fi
  (( $# == 0 )) || commitpulse_fail "$command_name does not accept arguments"
}

commitpulse_resolve_user_root() {
  local candidate temporary_root
  candidate="${COMMITPULSE_TEST_ROOT:-${HOME:-}}"
  [[ -n $candidate ]] || commitpulse_fail "HOME is not set"
  [[ $candidate == /* && $candidate != *$'\n'* ]] ||
    commitpulse_fail "the user root must be an absolute path without newlines"
  [[ -d $candidate && ! -L $candidate ]] ||
    commitpulse_fail "the user root must be an existing, non-symlinked directory: $candidate"

  COMMITPULSE_USER_ROOT="$(realpath -e -- "$candidate")"
  [[ $COMMITPULSE_USER_ROOT == "$candidate" && $COMMITPULSE_USER_ROOT != "/" ]] ||
    commitpulse_fail "the user root must be canonical and may not be /: $candidate"
  [[ -O $COMMITPULSE_USER_ROOT ]] ||
    commitpulse_fail "the user root is not owned by the current user: $COMMITPULSE_USER_ROOT"

  if [[ -n ${COMMITPULSE_TEST_ROOT:-} ]]; then
    temporary_root="$(realpath -e -- "${TMPDIR:-/tmp}")"
    case "$COMMITPULSE_USER_ROOT/" in
      "$temporary_root"/*) ;;
      *) commitpulse_fail "COMMITPULSE_TEST_ROOT must be beneath ${TMPDIR:-/tmp}" ;;
    esac
  fi

  COMMITPULSE_CONFIG_DIR="$COMMITPULSE_USER_ROOT/.config/omarchy"
  COMMITPULSE_PLUGINS_DIR="$COMMITPULSE_CONFIG_DIR/plugins"
  COMMITPULSE_DESTINATION="$COMMITPULSE_PLUGINS_DIR/$COMMITPULSE_PLUGIN_ID"
  COMMITPULSE_SHELL_JSON="$COMMITPULSE_CONFIG_DIR/shell.json"

  case "$COMMITPULSE_DESTINATION" in
    "$COMMITPULSE_USER_ROOT/.config/omarchy/plugins/$COMMITPULSE_PLUGIN_ID") ;;
    *) commitpulse_fail "resolved plugin destination is outside the user plugin root" ;;
  esac
  case "$COMMITPULSE_DESTINATION" in
    /usr/share/omarchy/*) commitpulse_fail "refusing to use packaged Omarchy paths" ;;
  esac
}

commitpulse_assert_safe_component_chain() {
  local path="$1" current="" component
  IFS='/' read -r -a components <<< "${path#/}"
  for component in "${components[@]}"; do
    [[ -n $component ]] || continue
    current="$current/$component"
    if [[ -L $current ]]; then
      commitpulse_fail "symlinked destination components are not allowed: $current"
      return 1
    fi
    if [[ -e $current && ! -d $current ]]; then
      commitpulse_fail "destination component is not a directory: $current"
      return 1
    fi
  done
}

commitpulse_prepare_user_directories() {
  commitpulse_assert_safe_component_chain "$COMMITPULSE_PLUGINS_DIR"
  mkdir -p -- "$COMMITPULSE_PLUGINS_DIR"
  commitpulse_assert_safe_component_chain "$COMMITPULSE_PLUGINS_DIR"
  [[ $(realpath -e -- "$COMMITPULSE_PLUGINS_DIR") == "$COMMITPULSE_PLUGINS_DIR" ]] ||
    commitpulse_fail "plugin root did not resolve to the intended path"
}

commitpulse_assert_regular_tree() {
  local tree="$1" link
  [[ -d $tree && ! -L $tree ]] || commitpulse_fail "plugin tree is not a regular directory: $tree"
  link="$(find "$tree" -type l -print -quit)"
  [[ -z $link ]] || commitpulse_fail "symlinks are not allowed in plugin contents: $link"
}

commitpulse_assert_manifest_identity() {
  local tree="$1"
  [[ -f $tree/manifest.json && ! -L $tree/manifest.json ]] ||
    commitpulse_fail "plugin manifest is missing or unsafe: $tree/manifest.json"
  jq -e --arg id "$COMMITPULSE_PLUGIN_ID" '
    .schemaVersion == 1
    and .id == $id
    and (.kinds | type == "array" and index("bar-widget") != null)
    and .entryPoints.barWidget == "quickshell/BarWidget.qml"
  ' "$tree/manifest.json" >/dev/null ||
    commitpulse_fail "unexpected plugin manifest identity at $tree"
}

commitpulse_assert_existing_destination() {
  if [[ -L $COMMITPULSE_DESTINATION ]]; then
    commitpulse_fail "refusing to replace a symlinked plugin destination"
    return 1
  fi
  if [[ -e $COMMITPULSE_DESTINATION ]]; then
    commitpulse_assert_regular_tree "$COMMITPULSE_DESTINATION"
    commitpulse_assert_manifest_identity "$COMMITPULSE_DESTINATION"
  fi
}

commitpulse_new_backup_path() {
  local base="$1" candidate timestamp suffix=0
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  candidate="$base.$timestamp"
  while [[ -e $candidate || -L $candidate ]]; do
    suffix=$((suffix + 1))
    candidate="$base.$timestamp-$suffix"
  done
  printf '%s\n' "$candidate"
}

commitpulse_run_omarchy() {
  HOME="$COMMITPULSE_USER_ROOT" omarchy "$@"
}

commitpulse_scrub_owned_state() {
  jq --arg id "$COMMITPULSE_PLUGIN_ID" '
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
        (.disabledPlugins | index($id)) as $contained
        | .disabledPlugins |= map(select(. != $id))
        | if $contained != null and .disabledPlugins == [] then del(.disabledPlugins) else . end
      else . end
    | if (.cloneSourceRestores? | type) == "array" then
        (.cloneSourceRestores | index($id)) as $contained
        | .cloneSourceRestores |= map(select(. != $id))
        | if $contained != null and .cloneSourceRestores == [] then del(.cloneSourceRestores) else . end
      else . end
  ' "$1"
}

commitpulse_validate_shell_json() {
  local shell_json="$1"
  [[ -f $shell_json && ! -L $shell_json ]] ||
    commitpulse_fail "shell configuration is not a regular file: $shell_json"
  jq -e '
    type == "object"
    and (.bar | type == "object")
    and (.bar.layout | type == "object")
    and (.bar.layout.left | type == "array")
    and (.bar.layout.center | type == "array")
    and (.bar.layout.right | type == "array")
    and ((.plugins? // []) | type == "array")
    and ((.disabledPlugins? // []) | type == "array")
    and ((.cloneSourceRestores? // []) | type == "array")
  ' "$shell_json" >/dev/null ||
    commitpulse_fail "shell.json is malformed or has an unsupported layout shape"
}

commitpulse_write_json_if_changed() {
  local source="$1" generated="$2" temporary
  if jq -e -s '.[0] == .[1]' "$source" "$generated" >/dev/null; then
    return 0
  fi
  temporary="$(mktemp "$COMMITPULSE_CONFIG_DIR/.shell.json.commitpulse.XXXXXX")"
  cp -- "$generated" "$temporary"
  chmod --reference="$source" "$temporary"
  mv -f -- "$temporary" "$source"
}

commitpulse_dedupe_owned_bar_state() {
  local source="$1" generated="$2"
  jq --arg id "$COMMITPULSE_PLUGIN_ID" '
    def entry_id:
      if type == "object" then (.id // "")
      elif type == "string" then .
      else ""
      end;
    reduce ["left", "center", "right"][] as $section (
      { doc: ., seen: false };
      . as $outer
      | reduce ($outer.doc.bar.layout[$section][]) as $entry (
          { state: $outer, entries: [] };
          if (($entry | entry_id) == $id) then
            if .state.seen then .
            else .state.seen = true | .entries += [$entry]
            end
          else .entries += [$entry]
          end
        )
      | .state.doc.bar.layout[$section] = .entries
      | .state
    )
    | .doc
    | if .bar.id? == $id then del(.bar.id) else . end
    | if (.plugins? | type) == "array" then
        .plugins |= map(select((if type == "object" then (.id // "") else "" end) != $id))
      else . end
  ' "$source" > "$generated"
  commitpulse_write_json_if_changed "$source" "$generated"
}

commitpulse_snapshot_shell() {
  COMMITPULSE_SHELL_EXISTED=0
  COMMITPULSE_SHELL_BACKUP=""
  if [[ -e $COMMITPULSE_SHELL_JSON || -L $COMMITPULSE_SHELL_JSON ]]; then
    commitpulse_validate_shell_json "$COMMITPULSE_SHELL_JSON"
    COMMITPULSE_SHELL_EXISTED=1
    COMMITPULSE_SHELL_BACKUP="$(commitpulse_new_backup_path "$COMMITPULSE_SHELL_JSON.commitpulse-backup")"
    cp -p -- "$COMMITPULSE_SHELL_JSON" "$COMMITPULSE_SHELL_BACKUP"
  fi
}

commitpulse_restore_shell() {
  local temporary
  if (( COMMITPULSE_SHELL_EXISTED )); then
    temporary="$(mktemp "$COMMITPULSE_CONFIG_DIR/.shell.json.commitpulse-restore.XXXXXX")"
    cp -p -- "$COMMITPULSE_SHELL_BACKUP" "$temporary"
    mv -f -- "$temporary" "$COMMITPULSE_SHELL_JSON"
  else
    if [[ -L $COMMITPULSE_SHELL_JSON || ( -e $COMMITPULSE_SHELL_JSON && ! -f $COMMITPULSE_SHELL_JSON ) ]]; then
      commitpulse_fail "cannot safely restore the original absent shell.json"
      return 1
    fi
    rm -f -- "$COMMITPULSE_SHELL_JSON"
  fi
}

commitpulse_capture_unrelated_state() {
  local output="$1"
  if (( COMMITPULSE_SHELL_EXISTED )); then
    commitpulse_scrub_owned_state "$COMMITPULSE_SHELL_BACKUP" > "$output"
  else
    : > "$output"
  fi
}

commitpulse_assert_unrelated_state_preserved() {
  local baseline="$1" current
  (( COMMITPULSE_SHELL_EXISTED )) || return 0
  commitpulse_validate_shell_json "$COMMITPULSE_SHELL_JSON"
  current="$(mktemp "${TMPDIR:-/tmp}/commitpulse-shell-current.XXXXXX")"
  commitpulse_scrub_owned_state "$COMMITPULSE_SHELL_JSON" > "$current"
  if ! jq -e -s '.[0] == .[1]' "$baseline" "$current" >/dev/null; then
    rm -f -- "$current"
    commitpulse_fail "Omarchy changed unrelated shell.json state"
    return 1
  fi
  rm -f -- "$current"
}

commitpulse_plugin_list_once() {
  commitpulse_run_omarchy shell shell listPlugins
}

commitpulse_plugin_list() {
  local attempt output
  for attempt in {1..100}; do
    if output="$(commitpulse_plugin_list_once 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    fi
    [[ $output == *"not responding"* || $output == *"not running"* || $output == *"not ready"* ]] || {
      printf '%s\n' "$output" >&2
      return 1
    }
    sleep 0.1
  done
  printf '%s\n' "$output" >&2
  return 1
}

commitpulse_shell_has_owned_state() {
  local scrubbed
  [[ -e $COMMITPULSE_SHELL_JSON ]] || return 1
  commitpulse_validate_shell_json "$COMMITPULSE_SHELL_JSON"
  scrubbed="$(mktemp "${TMPDIR:-/tmp}/commitpulse-shell-scrubbed.XXXXXX")"
  commitpulse_scrub_owned_state "$COMMITPULSE_SHELL_JSON" > "$scrubbed"
  if jq -e -s '.[0] != .[1]' "$COMMITPULSE_SHELL_JSON" "$scrubbed" >/dev/null; then
    rm -f -- "$scrubbed"
    return 0
  fi
  rm -f -- "$scrubbed"
  return 1
}

commitpulse_rescan() {
  local attempt output
  for attempt in {1..100}; do
    if output="$(commitpulse_run_omarchy shell shell rescanPlugins 2>&1)"; then
      return 0
    fi
    [[ $output == *"not responding"* || $output == *"not running"* || $output == *"not ready"* ]] || {
      printf '%s\n' "$output" >&2
      return 1
    }
    sleep 0.1
  done
  printf '%s\n' "$output" >&2
  return 1
}

commitpulse_wait_for_catalog_state() {
  local expected="$1" attempt plugins match
  for attempt in {1..100}; do
    if plugins="$(commitpulse_plugin_list_once 2>/dev/null)" &&
      jq -e 'type == "array"' <<< "$plugins" >/dev/null 2>&1; then
      match="$(jq -r --arg id "$COMMITPULSE_PLUGIN_ID" '
        any(.[]; .id == $id)
      ' <<< "$plugins")"
      [[ $match == "$expected" ]] && return 0
    fi
    sleep 0.1
  done
  commitpulse_fail "Omarchy plugin catalog did not reach the expected state"
}

commitpulse_enable() {
  local attempt output
  for attempt in {1..100}; do
    if output="$(commitpulse_run_omarchy plugin enable "$COMMITPULSE_PLUGIN_ID" --section "$COMMITPULSE_SECTION" 2>&1)"; then
      return 0
    fi
    [[ $output == *"not known"* || $output == *"not ready"* ||
      $output == *"not responding"* || $output == *"not running"* ]] || {
      printf '%s\n' "$output" >&2
      return 1
    }
    sleep 0.1
  done
  printf '%s\n' "$output" >&2
  return 1
}

commitpulse_assert_installed_state() {
  local plugins
  commitpulse_assert_regular_tree "$COMMITPULSE_DESTINATION"
  commitpulse_assert_manifest_identity "$COMMITPULSE_DESTINATION"
  [[ -x $COMMITPULSE_DESTINATION/bin/commitpulse-data ]] ||
    commitpulse_fail "installed helper is not executable"
  commitpulse_validate_shell_json "$COMMITPULSE_SHELL_JSON"
  jq -e --arg id "$COMMITPULSE_PLUGIN_ID" '
    def entry_id:
      if type == "object" then (.id // "")
      elif type == "string" then .
      else ""
      end;
    ([.bar.layout.right[] | select(entry_id == $id)] | length) == 1
    and ([.bar.layout.left[], .bar.layout.center[]] | map(select(entry_id == $id)) | length) == 0
    and ([.plugins[]? | select(type == "object" and (.id // "") == $id)] | length) == 0
    and ([.disabledPlugins[]? | select(. == $id)] | length) == 0
    and ([.cloneSourceRestores[]? | select(. == $id)] | length) == 0
    and (.bar.id? != $id)
  ' "$COMMITPULSE_SHELL_JSON" >/dev/null ||
    commitpulse_fail "CommitPulse is not enabled exactly once in the right bar section"
  plugins="$(commitpulse_plugin_list)"
  jq -e --arg id "$COMMITPULSE_PLUGIN_ID" '
    type == "array"
    and ([.[] | select(.id == $id)] | length) == 1
    and any(.[]; .id == $id and .enabled == true and (.kinds | index("bar-widget") != null))
  ' <<< "$plugins" >/dev/null ||
    commitpulse_fail "Omarchy does not report CommitPulse as an enabled bar widget"
}

commitpulse_assert_uninstalled_state() {
  local plugins
  [[ ! -e $COMMITPULSE_DESTINATION && ! -L $COMMITPULSE_DESTINATION ]] ||
    commitpulse_fail "CommitPulse plugin directory is still installed"
  if [[ -e $COMMITPULSE_SHELL_JSON ]]; then
    commitpulse_validate_shell_json "$COMMITPULSE_SHELL_JSON"
    jq -e --arg id "$COMMITPULSE_PLUGIN_ID" '
      def entry_id:
        if type == "object" then (.id // "")
        elif type == "string" then .
        else ""
        end;
      ([.bar.layout.left[], .bar.layout.center[], .bar.layout.right[]] | map(select(entry_id == $id)) | length) == 0
      and ([.plugins[]? | select(type == "object" and (.id // "") == $id)] | length) == 0
      and ([.disabledPlugins[]? | select(. == $id)] | length) == 0
      and ([.cloneSourceRestores[]? | select(. == $id)] | length) == 0
      and (.bar.id? != $id)
    ' "$COMMITPULSE_SHELL_JSON" >/dev/null ||
      commitpulse_fail "CommitPulse shell state remains after uninstall"
  fi
  plugins="$(commitpulse_plugin_list)"
  jq -e --arg id "$COMMITPULSE_PLUGIN_ID" '
    type == "array" and ([.[] | select(.id == $id)] | length) == 0
  ' <<< "$plugins" >/dev/null ||
    commitpulse_fail "Omarchy still discovers CommitPulse after uninstall"
}

commitpulse_build_stage() {
  local repository_root="$1" stage="$2"
  for source in manifest.json LICENSE quickshell; do
    [[ -e $repository_root/$source && ! -L $repository_root/$source ]] ||
      commitpulse_fail "required plugin source is missing or symlinked: $source"
  done
  [[ -z $(find "$repository_root/quickshell" -type l -print -quit) ]] ||
    commitpulse_fail "symlinks are not allowed in quickshell sources"

  mkdir -p -- "$stage/bin"
  cp -a -- "$repository_root/manifest.json" "$repository_root/LICENSE" "$stage/"
  cp -a -- "$repository_root/quickshell" "$stage/"
  (
    cd -- "$repository_root"
    go build -trimpath -o "$stage/bin/commitpulse-data" ./cmd/commitpulse-data
  )
  chmod 0755 "$stage/bin/commitpulse-data"
  commitpulse_assert_regular_tree "$stage"
  commitpulse_assert_manifest_identity "$stage"
  "$stage/bin/commitpulse-data" -version >/dev/null
  commitpulse_run_omarchy plugin validate "$stage"
}

commitpulse_restore_plugin() {
  local restore_stage
  if [[ -n ${COMMITPULSE_PLUGIN_BACKUP:-} ]]; then
    restore_stage="$(mktemp -d "$COMMITPULSE_PLUGINS_DIR/.dev.commitpulse.restore.XXXXXX")"
    cp -a -- "$COMMITPULSE_PLUGIN_BACKUP/." "$restore_stage/"
    chmod --reference="$COMMITPULSE_PLUGIN_BACKUP" "$restore_stage"
    if [[ -e $COMMITPULSE_DESTINATION ]]; then
      rm -rf -- "$COMMITPULSE_DESTINATION"
    fi
    mv -- "$restore_stage" "$COMMITPULSE_DESTINATION"
  elif [[ -e $COMMITPULSE_DESTINATION ]]; then
    rm -rf -- "$COMMITPULSE_DESTINATION"
  fi
}

commitpulse_rollback() {
  commitpulse_restore_plugin || true
  commitpulse_restore_shell || true
  commitpulse_rescan || true
}

commitpulse_cleanup_temporary() {
  if [[ -n ${COMMITPULSE_TRANSFER_STAGE:-} && -d $COMMITPULSE_TRANSFER_STAGE ]]; then
    case "$COMMITPULSE_TRANSFER_STAGE" in
      "$COMMITPULSE_PLUGINS_DIR"/.dev.commitpulse.stage.*)
        rm -rf -- "$COMMITPULSE_TRANSFER_STAGE"
        ;;
    esac
  fi
  if [[ -n ${COMMITPULSE_PREPARATION_ROOT:-} && -d $COMMITPULSE_PREPARATION_ROOT ]]; then
    case "$COMMITPULSE_PREPARATION_ROOT" in
      "${TMPDIR:-/tmp}"/commitpulse-install.*|"${TMPDIR:-/tmp}"/commitpulse-uninstall.*)
        rm -rf -- "$COMMITPULSE_PREPARATION_ROOT"
        ;;
    esac
  fi
}

commitpulse_exit_handler() {
  local status="$1"
  if (( status != 0 && ${COMMITPULSE_MUTATED:-0} )); then
    commitpulse_rollback
  fi
  commitpulse_cleanup_temporary
  exit "$status"
}

commitpulse_install() {
  local repository_root="$1" preparation_root stage transfer_stage baseline generated
  shift
  if ! commitpulse_reject_arguments install.sh "$@"; then
    [[ ${1:-} == "-h" || ${1:-} == "--help" ]] && return 0
    return 1
  fi
  umask 077
  for command_name in go jq omarchy realpath find mktemp; do
    commitpulse_require_command "$command_name"
  done
  commitpulse_resolve_user_root

  preparation_root="$(mktemp -d "${TMPDIR:-/tmp}/commitpulse-install.XXXXXX")"
  COMMITPULSE_PREPARATION_ROOT="$preparation_root"
  COMMITPULSE_TRANSFER_STAGE=""
  stage="$preparation_root/$COMMITPULSE_PLUGIN_ID"
  baseline="$preparation_root/unrelated-shell.json"
  generated="$preparation_root/shell-next.json"
  trap 'commitpulse_exit_handler $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  commitpulse_build_stage "$repository_root" "$stage"
  commitpulse_assert_safe_component_chain "$COMMITPULSE_PLUGINS_DIR"
  commitpulse_assert_existing_destination
  commitpulse_snapshot_shell
  commitpulse_capture_unrelated_state "$baseline"
  commitpulse_prepare_user_directories

  transfer_stage="$(mktemp -d "$COMMITPULSE_PLUGINS_DIR/.dev.commitpulse.stage.XXXXXX")"
  COMMITPULSE_TRANSFER_STAGE="$transfer_stage"
  cp -a -- "$stage/." "$transfer_stage/"
  commitpulse_assert_regular_tree "$transfer_stage"
  commitpulse_assert_manifest_identity "$transfer_stage"
  commitpulse_run_omarchy plugin validate "$transfer_stage"

  COMMITPULSE_PLUGIN_BACKUP=""
  COMMITPULSE_MUTATED=1
  if [[ -e $COMMITPULSE_DESTINATION ]]; then
    COMMITPULSE_PLUGIN_BACKUP="$(commitpulse_new_backup_path "$COMMITPULSE_PLUGINS_DIR/.$COMMITPULSE_PLUGIN_ID.backup")"
    mv -- "$COMMITPULSE_DESTINATION" "$COMMITPULSE_PLUGIN_BACKUP"
  fi
  mv -- "$transfer_stage" "$COMMITPULSE_DESTINATION"
  COMMITPULSE_TRANSFER_STAGE=""

  if (( COMMITPULSE_SHELL_EXISTED )); then
    commitpulse_dedupe_owned_bar_state "$COMMITPULSE_SHELL_JSON" "$generated"
  fi
  commitpulse_rescan
  commitpulse_enable
  commitpulse_assert_installed_state
  commitpulse_assert_unrelated_state_preserved "$baseline"
  COMMITPULSE_MUTATED=0
  trap - EXIT INT TERM
  commitpulse_cleanup_temporary

  printf 'CommitPulse installed at %s\n' "$COMMITPULSE_DESTINATION"
  [[ -z $COMMITPULSE_PLUGIN_BACKUP ]] || printf 'Previous plugin backup: %s\n' "$COMMITPULSE_PLUGIN_BACKUP"
  [[ -z $COMMITPULSE_SHELL_BACKUP ]] || printf 'Shell configuration backup: %s\n' "$COMMITPULSE_SHELL_BACKUP"
}

commitpulse_uninstall() {
  local repository_root="$1" preparation_root baseline generated plugins
  shift
  if ! commitpulse_reject_arguments uninstall.sh "$@"; then
    [[ ${1:-} == "-h" || ${1:-} == "--help" ]] && return 0
    return 1
  fi
  : "$repository_root"
  umask 077
  for command_name in jq omarchy realpath find mktemp; do
    commitpulse_require_command "$command_name"
  done
  commitpulse_resolve_user_root
  commitpulse_assert_safe_component_chain "$COMMITPULSE_PLUGINS_DIR"
  if [[ ! -e $COMMITPULSE_DESTINATION && ! -L $COMMITPULSE_DESTINATION ]] &&
    ! commitpulse_shell_has_owned_state; then
    printf 'CommitPulse is already uninstalled.\n'
    return 0
  fi
  commitpulse_assert_existing_destination

  preparation_root="$(mktemp -d "${TMPDIR:-/tmp}/commitpulse-uninstall.XXXXXX")"
  COMMITPULSE_PREPARATION_ROOT="$preparation_root"
  COMMITPULSE_TRANSFER_STAGE=""
  baseline="$preparation_root/unrelated-shell.json"
  generated="$preparation_root/shell-next.json"
  trap 'commitpulse_exit_handler $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  commitpulse_snapshot_shell
  commitpulse_capture_unrelated_state "$baseline"
  commitpulse_rescan
  if [[ -e $COMMITPULSE_DESTINATION ]]; then
    commitpulse_run_omarchy plugin validate "$COMMITPULSE_DESTINATION"
    commitpulse_wait_for_catalog_state true
  fi
  plugins="$(commitpulse_plugin_list)"
  jq -e 'type == "array"' <<< "$plugins" >/dev/null ||
    commitpulse_fail "Omarchy returned an invalid plugin catalog"

  COMMITPULSE_PLUGIN_BACKUP=""
  COMMITPULSE_MUTATED=1
  if jq -e --arg id "$COMMITPULSE_PLUGIN_ID" 'any(.[]; .id == $id)' <<< "$plugins" >/dev/null; then
    commitpulse_run_omarchy plugin disable "$COMMITPULSE_PLUGIN_ID" >/dev/null
  fi
  if [[ -e $COMMITPULSE_DESTINATION ]]; then
    COMMITPULSE_PLUGIN_BACKUP="$(commitpulse_new_backup_path "$COMMITPULSE_PLUGINS_DIR/.$COMMITPULSE_PLUGIN_ID.backup")"
    mv -- "$COMMITPULSE_DESTINATION" "$COMMITPULSE_PLUGIN_BACKUP"
  fi
  if [[ -e $COMMITPULSE_SHELL_JSON ]]; then
    commitpulse_scrub_owned_state "$COMMITPULSE_SHELL_JSON" > "$generated"
    commitpulse_write_json_if_changed "$COMMITPULSE_SHELL_JSON" "$generated"
  fi
  commitpulse_rescan
  commitpulse_wait_for_catalog_state false
  commitpulse_assert_uninstalled_state
  commitpulse_assert_unrelated_state_preserved "$baseline"
  COMMITPULSE_MUTATED=0
  trap - EXIT INT TERM
  commitpulse_cleanup_temporary

  printf 'CommitPulse uninstalled.\n'
  [[ -z $COMMITPULSE_PLUGIN_BACKUP ]] || printf 'Removed plugin backup: %s\n' "$COMMITPULSE_PLUGIN_BACKUP"
  [[ -z $COMMITPULSE_SHELL_BACKUP ]] || printf 'Shell configuration backup: %s\n' "$COMMITPULSE_SHELL_BACKUP"
}
