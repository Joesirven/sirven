# shellcheck shell=bash
# access control list plan steps: setfacl on linux, chmod +a on macos.
#
# the commands come from lib/grant_compiler.py, which reads the level file and refuses paths
# the level's policy never grants. this module only turns its plan fragment into steps.
# on linux, each folder the grant changes gets a snapshot step first. lib/access_control_snapshot.sh
# records the folder's access control lists, and that step's undo puts them back exactly. uninstall,
# rollback and the kill switch all restore from the same snapshot.
# reads: ROOT_DIR, PREFIX, PACKAGE, OPERATING_SYSTEM, SERVICE_USER, LEVEL, LEVEL_FILE, LEVEL_SUMMARY,
#        CONFIG_DIR, STAGE_DIR, GRANT_PATHS

ACCESS_CONTROL_MACOS_REASON="macos access control lists are plan output in the alpha cut; apply needs a run in a macos virtual machine"

grant_compiler() {
  python3 "$ROOT_DIR/lib/grant_compiler.py" "$@"
}

# load_level: read what the plan needs from levels/LEVEL.json, through the grant compiler.
# sets LEVEL_FILE, LEVEL_SUMMARY, and LEVEL_WRITE_ALLOWED.
load_level() {
  local key value description
  LEVEL_SUMMARY=""
  LEVEL_WRITE_ALLOWED=false
  LEVEL_FILE="$ROOT_DIR/levels/$LEVEL.json"
  [ -f "$LEVEL_FILE" ] || die "level file $LEVEL_FILE is missing"
  description="$STAGE_DIR/level-description.txt"
  if ! grant_compiler describe --level "$LEVEL_FILE" > "$description"; then
    die "the $LEVEL level file breaks the rules; nothing was changed"
  fi
  while IFS='=' read -r key value; do
    case "$key" in
      summary) LEVEL_SUMMARY="$value" ;;
      write_allowed) LEVEL_WRITE_ALLOWED="$value" ;;
    esac
  done < "$description"
}

access_control_record_file() {
  printf '%s/grants/%s.json' "$CONFIG_DIR" "$SERVICE_USER"
}

# _access_control_run_compiler OUTPUT ARGUMENT...: run the compiler with the shared flags and
# every --path, write its fragment to OUTPUT, and stop the run if it refuses.
_access_control_run_compiler() {
  local output="$1" index=0 status=0
  shift
  set -- "$@" --user "$SERVICE_USER" --os "$OPERATING_SYSTEM" --package "$PACKAGE"
  while [ "$index" -lt "${#GRANT_PATHS[@]}" ]; do
    set -- "$@" --path "${GRANT_PATHS[index]}"
    index=$((index + 1))
  done
  grant_compiler "$@" > "$output" 2> "$output.error" || status=$?
  if [ "$status" -ne 0 ]; then
    cat "$output.error" >&2
    DIE_STATUS=2 die "the grant compiler refused this grant; nothing was changed"
  fi
}

# turn a plan fragment (title, check, command separated by tabs, and with --with-undo the undo
# title, check, and command) into steps.
_access_control_add_fragment() {
  local fragment="$1" kind="$2" reason="$3" tab title check command undo_title undo_check undo_command
  tab="$(printf '\t')"
  while IFS="$tab" read -r title check command undo_title undo_check undo_command; do
    case "$title" in '#'* | '') continue ;; esac
    if [ "$kind" = system ]; then
      plan_step system "$title" "$check" "$command"
    else
      plan_planonly "$title" "$command" "$reason" "$check"
    fi
    if [ -n "$undo_title" ]; then
      plan_undo "$undo_title" "$undo_check" "$undo_command"
    fi
  done < "$fragment"
}

_access_control_kind() {
  if [ "$OPERATING_SYSTEM" = macos ]; then printf 'planonly'; else printf 'system'; fi
}

plan_access_control() {
  local level_copy grant_record fragment
  plan_section "access to paths, level $LEVEL"
  plan_note "$LEVEL: $LEVEL_SUMMARY"
  level_copy="$(rooted "$CONFIG_DIR/levels/$LEVEL.json")"
  plan_step run "install the $LEVEL level as policy" \
    "cmp -s $(shell_quote "$LEVEL_FILE") $level_copy" \
    "cp $(shell_quote "$LEVEL_FILE") $level_copy && chmod 0644 $level_copy" \
    "cp levels/$LEVEL.json $level_copy && chmod 0644 $level_copy"
  plan_undo "remove the $LEVEL policy copy" "[ ! -e $level_copy ]" "rm -f $level_copy"
  if [ "${#GRANT_PATHS[@]}" -eq 0 ]; then
    plan_note "no --path given. the agent can use only its own home until you grant a path."
    return 0
  fi
  if [ "$OPERATING_SYSTEM" = macos ]; then
    plan_note "macos keeps Desktop, Documents, and Downloads behind privacy prompts a service user cannot answer, so those are refused."
  fi

  grant_record="$STAGE_DIR/grant-record.json"
  _access_control_run_compiler "$grant_record" record --level "$LEVEL_FILE"
  layout_write_file "record the grant for $SERVICE_USER" "$(access_control_record_file)" 0644 "$grant_record" \
    "level $LEVEL on the paths below, no expiry, cannot grant further"
  plan_tag grant

  fragment="$STAGE_DIR/grant-fragment.txt"
  _access_control_run_compiler "$fragment" compile --level "$LEVEL_FILE" --prefix "$PREFIX" --with-undo
  _access_control_add_fragment "$fragment" "$(_access_control_kind)" "$ACCESS_CONTROL_MACOS_REASON"
}

# removal steps for the kill switch. uses --path when given, otherwise the grant record.
plan_access_control_revoke() {
  local record fragment
  record="${PREFIX}$(access_control_record_file)"
  fragment="$STAGE_DIR/revoke-fragment.txt"
  if [ "${#GRANT_PATHS[@]}" -gt 0 ]; then
    _access_control_run_compiler "$fragment" revoke --level "$LEVEL_FILE" --prefix "$PREFIX"
  elif [ -f "$record" ]; then
    _access_control_run_compiler "$fragment" revoke --level "$LEVEL_FILE" --prefix "$PREFIX" --record "$record"
  else
    plan_note "no grant record at $record and no --path given, so there are no access control lists to remove."
    return 0
  fi
  _access_control_add_fragment "$fragment" planonly "$KILL_SWITCH_REASON"
}

# plan_access_control_remove_paths: removal steps for the paths in GRANT_PATHS only, as system
# steps on linux. a grant rollback uses this for paths the change being reversed added.
plan_access_control_remove_paths() {
  local fragment="$STAGE_DIR/remove-fragment.txt"
  [ "${#GRANT_PATHS[@]}" -gt 0 ] || return 0
  _access_control_run_compiler "$fragment" revoke --level "$LEVEL_FILE" --prefix "$PREFIX"
  _access_control_add_fragment "$fragment" "$(_access_control_kind)" "$ACCESS_CONTROL_MACOS_REASON"
}
