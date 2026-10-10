# shellcheck shell=bash
# audit log bootstrap: the directory, the empty log, and the format it is written in.
#
# the log lives in a directory owned by the owner. the agent has no access to it at all, so
# from the agent's point of view it is append only through the wrapper and nothing else.
# reads: PREFIX, PACKAGE, CONFIG_DIR, AUDIT_DIR, OWNER, SERVICE_USER

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
    "event": "install, grant, session_start, command, session_end, revoke_started, revoke_finished",
    "user": "the service user, $SERVICE_USER by default",
    "principal": "who acted: owner-agent, or invite:<name> for a friend's agent",
    "level": "observer, builder, or operator",
    "session": "a random token shared by every event in one SSH session",
    "command": "for command events: the command exactly as received",
    "exit_status": "for command events: the exit status",
    "source": "for session events: the transport and the remote address SSH reported"
  },
  "rules": [
    "the directory belongs to the owner, mode 0750; the agent cannot read, edit, or remove entries",
    "entries are appended by a forced-command wrapper on the SSH key; it sees what you send, not every system call",
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
  staged="$(audit_format_json | stage_file audit-format.json)"
  layout_write_file "write the audit log format" "$CONFIG_DIR/audit-format.json" 0644 "$staged" \
    "the JSON lines format every entry follows"
  plan_step run "create the empty audit log" "[ -f $log ]" "touch $log && chmod 0640 $log"
  plan_step system "give the audit log directory to the owner, $OWNER" \
    "[ \"\$(ls -ld $directory | awk '{print \$3}')\" = $(shell_quote "$OWNER") ]" \
    "chown -R $(shell_quote "$OWNER") $directory"
  plan_note "capture comes from a forced-command wrapper on the agent's SSH key: designed, built after alpha."
}
