# shellcheck shell=bash
# audit log: the directory, the empty log, the format it is written in, and a small writer.
#
# the log lives in a directory owned by the owner. the agent has no access to it at all, so
# from the agent's point of view it is append only through the wrapper and nothing else.
#
# the writer is for the package's own commands. when install.sh, uninstall.sh, or a grant
# rollback applies a plan for real (never in a dry run), every numbered step writes a step
# entry, and a changed grant writes a grant entry. entries written before the log exists wait
# in a pending file and go in as soon as it does.
# reads: PREFIX, PACKAGE, CONFIG_DIR, AUDIT_DIR, OWNER, SERVICE_USER, STAGE_DIR

AUDIT_OPERATION="${AUDIT_OPERATION:-install}"
AUDIT_PENDING="${AUDIT_PENDING:-}"

audit_log_file() {
  printf '%s/audit.jsonl' "$AUDIT_DIR"
}

# the format, as data. one JSON object per line in audit.jsonl.
audit_format_json() {
  cat <<END
{
  "schema_version": 1,
  "file": "$(audit_log_file)",
  "encoding": "JSON lines: one JSON object per line, appended, never rewritten",
  "fields": {
    "time": "universal time with seconds, like 2026-10-10T12:00:00Z",
    "event": "install, step, grant, adopt, uninstall, component, warning, session_start, command, session_end, revoke_started, revoke_finished",
    "user": "the service user, $SERVICE_USER by default",
    "principal": "who acted: owner for the package's own commands, owner-agent, or invite:<name> for a friend's agent",
    "level": "observer, builder, or operator; null when a grant change leaves no grant",
    "session": "a random token shared by every event in one SSH session",
    "command": "for command events: the command exactly as received",
    "exit_status": "for command events: the exit status",
    "source": "for session events: the transport and the remote address SSH reported",
    "operation": "for install, step, grant, adopt, uninstall, and component events: install, uninstall, grant rollback, add NAME, or remove NAME",
    "found": "for adopt events: what the install found already on the machine and kept as it is, as the plan showed it",
    "step": "for step events: the step number in the printed plan",
    "title": "for step events: the step title in the printed plan",
    "kind": "for step events: run, system, owner, or planonly",
    "outcome": "for step events: applied, recorded (under --prefix), skipped, owner, or failed. for install, uninstall, and component events: finished, failed, or refused",
    "component": "for component events: the name of the optional component",
    "directory": "for component events: the folder the component was copied into",
    "paths": "for grant events: the granted paths after the change",
    "previous_level": "for grant events: the level before the change, or null",
    "previous_paths": "for grant events: the paths before the change",
    "reason": "for grant events: install or rollback",
    "message": "for warning events: what the undo of a grant could not do, such as a folder replaced by a link (not followed) or a missing snapshot (earlier lists not restored)"
  },
  "rules": [
    "the directory belongs to the owner, mode 0750; the agent cannot read, edit, or remove entries",
    "entries are appended by a forced-command wrapper on the SSH key; it sees what you send, not every system call",
    "install, uninstall, grant rollback, sirven add, and sirven remove write step and grant entries when they apply for real, never in a dry run",
    "install writes one adopt entry for each thing it found and kept, when it applies for real",
    "the kill switch writes revoke_started first and revoke_finished last"
  ],
  "example": {"time": "2026-10-10T12:00:00Z", "event": "command", "user": "$SERVICE_USER", "principal": "owner-agent", "level": "builder", "session": "k3v9q", "command": "npm test", "exit_status": 0}
}
END
}

plan_audit() {
  local directory log staged
  directory="$(rooted "$AUDIT_DIR")"
  log="$(rooted "$(audit_log_file)")"
  plan_section "audit log"
  layout_directory "$AUDIT_DIR" 0750 "create the audit log directory $AUDIT_DIR"
  plan_tag audit
  staged="$(audit_format_json | stage_file audit-format.json)"
  layout_write_file "write the audit log format" "$CONFIG_DIR/audit-format.json" 0644 "$staged" \
    "the JSON lines format every entry follows"
  plan_step run "create the empty audit log" "[ -f $log ]" "touch $log && chmod 0640 $log"
  plan_tag audit
  plan_undo "remove the audit log $(audit_log_file) and every entry in it" "[ ! -e $log ]" "rm -f $log"
  plan_step system "give the audit log directory to the owner, $OWNER" \
    "[ \"\$(ls -ld $directory | awk '{print \$3}')\" = $(shell_quote "$OWNER") ]" \
    "chown -R $(shell_quote "$OWNER") $directory"
  plan_note "capture comes from a forced-command wrapper on the agent's SSH key: designed, built after alpha."
}

# the time for an entry. SIRVEN_TIME_OVERRIDE pins it for tests, and only on a fake root.
audit_now() {
  if [ -n "${SIRVEN_TIME_OVERRIDE:-}" ] && [ -n "${PREFIX:-}" ]; then
    printf '%s' "$SIRVEN_TIME_OVERRIDE"
    return 0
  fi
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# audit_json_string VALUE: VALUE as a JSON string, quotes included. backslash, quote, newline,
# tab, and carriage return are escaped; other control characters are dropped.
audit_json_string() {
  local value="$1" backslash="\\" quote='"' newline tab carriage
  newline="
"
  tab="$(printf '\t')"
  carriage="$(printf '\r')"
  value=${value//"$backslash"/$backslash$backslash}
  value=${value//"$quote"/$backslash$quote}
  value=${value//"$newline"/${backslash}n}
  value=${value//"$tab"/${backslash}t}
  value=${value//"$carriage"/${backslash}r}
  case "$value" in
    *[[:cntrl:]]*) value="$(printf '%s' "$value" | LC_ALL=C tr -d '\001-\037\177')" ;;
  esac
  printf '"%s"' "$value"
}

# audit_json_array VALUE...: the values as a JSON array of strings.
audit_json_array() {
  local out="" value
  for value in "$@"; do
    out="${out:+$out, }$(audit_json_string "$value")"
  done
  printf '[%s]' "$out"
}

# audit_entry EVENT [KEY=VALUE | json:KEY=JSON]...: one entry, on one line. a plain pair is
# written as a JSON string; a json: pair is written as it is, for numbers, arrays, and null.
audit_entry() {
  local event="$1" pair key value line
  shift
  line="{\"time\": $(audit_json_string "$(audit_now)"), \"event\": $(audit_json_string "$event")"
  line="$line, \"user\": $(audit_json_string "$SERVICE_USER"), \"principal\": \"owner\""
  for pair in "$@"; do
    case "$pair" in
      json:*=*)
        pair="${pair#json:}"
        key="${pair%%=*}"
        value="${pair#*=}"
        line="$line, $(audit_json_string "$key"): $value"
        ;;
      *=*)
        key="${pair%%=*}"
        value="${pair#*=}"
        line="$line, $(audit_json_string "$key"): $(audit_json_string "$value")"
        ;;
      *) die "audit_entry: '$pair' is not KEY=VALUE" ;;
    esac
  done
  printf '%s}' "$line"
}

# audit_write LINE: append to the log, or to the pending file while the log does not exist.
audit_write() {
  local log
  log="${PREFIX}$(audit_log_file)"
  if [ -f "$log" ]; then
    if [ -n "$AUDIT_PENDING" ] && [ -s "$AUDIT_PENDING" ]; then
      cat "$AUDIT_PENDING" >> "$log"
      : > "$AUDIT_PENDING"
    fi
    printf '%s\n' "$1" >> "$log"
  elif [ -n "$AUDIT_PENDING" ]; then
    printf '%s\n' "$1" >> "$AUDIT_PENDING"
  fi
}

# audit_flush: write what is pending. warns when the log never came to exist.
audit_flush() {
  local log count
  [ -n "$AUDIT_PENDING" ] && [ -s "$AUDIT_PENDING" ] || return 0
  log="${PREFIX}$(audit_log_file)"
  if [ -f "$log" ]; then
    cat "$AUDIT_PENDING" >> "$log"
  else
    count="$(grep -c . "$AUDIT_PENDING")"
    warn "$count audit entries were not written: there is no audit log at $log"
  fi
  : > "$AUDIT_PENDING"
}

# audit_step_hook NUMBER KIND TAG TITLE OUTCOME: the plan engine calls this after each step.
audit_step_hook() {
  audit_write "$(audit_entry step "operation=$AUDIT_OPERATION" "json:step=$1" "kind=$2" "title=$4" "outcome=$5")"
}

# _audit_grant_fields RECORD: set AUDIT_GRANT_LEVEL (JSON) and AUDIT_GRANT_PATHS (a JSON array)
# from a grant record. a missing record is no grant: null and an empty array.
_audit_grant_fields() {
  local key value paths=""
  AUDIT_GRANT_LEVEL=null
  AUDIT_GRANT_PATHS="[]"
  [ -f "$1" ] || return 0
  while IFS='=' read -r key value; do
    case "$key" in
      level) AUDIT_GRANT_LEVEL="$(audit_json_string "$value")" ;;
      path) paths="${paths:+$paths, }$(audit_json_string "$value")" ;;
    esac
  done <<END
$(grant_compiler show --record "$1")
END
  AUDIT_GRANT_PATHS="[$paths]"
}

# audit_grant_change BEFORE AFTER REASON: a grant entry when the grant record changed. BEFORE is
# a copy taken before applying; either file may be missing.
audit_grant_change() {
  local before="$1" after="$2" reason="$3" level paths
  if [ ! -f "$before" ] && [ ! -f "$after" ]; then return 0; fi
  if [ -f "$before" ] && [ -f "$after" ] && cmp -s "$before" "$after"; then return 0; fi
  _audit_grant_fields "$after"
  level="$AUDIT_GRANT_LEVEL"
  paths="$AUDIT_GRANT_PATHS"
  _audit_grant_fields "$before"
  audit_write "$(audit_entry grant "operation=$AUDIT_OPERATION" "json:level=$level" "json:paths=$paths" \
    "json:previous_level=$AUDIT_GRANT_LEVEL" "json:previous_paths=$AUDIT_GRANT_PATHS" "reason=$reason")"
}
