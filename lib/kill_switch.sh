# shellcheck shell=bash
# kill switch: revoke --all. removes every key, locks the service user, ends every session,
# removes every access control list entry, cuts transport access, and writes audit entries
# first and last. in the alpha cut this is plan output; apply comes in alpha + 1.
#
# the order matters: lock first so nothing new starts, then end what is running.
# reads: PREFIX, OPERATING_SYSTEM, SERVICE_USER, CONFIG_DIR, AUDIT_DIR, TRANSPORT

KILL_SWITCH_REASON="the kill switch is plan output in the alpha cut; apply comes in alpha + 1"

# kill_switch_audit_line EVENT: the line appended to the audit log, with the time filled in at run time.
kill_switch_audit_line() {
  # shellcheck disable=SC2016 # the date runs when the step is applied, not now
  printf 'printf %s "$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)" >> %s' \
    "'{\"time\": \"%s\", \"event\": \"$1\", \"user\": \"$SERVICE_USER\", \"principal\": \"owner\"}\\n'" \
    "$(rooted "$(audit_log_file)")"
}

plan_kill_switch() {
  local user="$SERVICE_USER" keys record
  keys="$(rooted "$(service_user_home)/.ssh/authorized_keys")"
  record="$(rooted "$CONFIG_DIR/grants/$user.json")"

  plan_section "kill switch: revoke --all"
  plan_planonly "write revoke_started to the audit log" "$(kill_switch_audit_line revoke_started)" "$KILL_SWITCH_REASON"
  plan_tag always
  plan_planonly "remove every authorized key for $user" ": > $keys" "$KILL_SWITCH_REASON" "[ ! -s $keys ]"
  case "$OPERATING_SYSTEM" in
    macos)
      plan_planonly "lock $user so no new session starts" \
"dscl . -create /Users/$user UserShell /usr/bin/false
pwpolicy -u $user -disableuser" \
        "$KILL_SWITCH_REASON" \
        "dscl . -read /Users/$user UserShell 2>/dev/null | grep -q /usr/bin/false"
      ;;
    *)
      plan_planonly "lock $user so no new session starts" \
        "usermod --lock --expiredate 1 --shell /usr/sbin/nologin $user" \
        "$KILL_SWITCH_REASON" \
        "[ \"\$(getent passwd $user | cut -d: -f7)\" = /usr/sbin/nologin ] && passwd --status $user 2>/dev/null | grep -q '^$user L'"
      ;;
  esac
  plan_planonly "end every running session and process of $user" "pkill -KILL -u $user" "$KILL_SWITCH_REASON" \
    "! pgrep -u $user >/dev/null 2>&1"

  plan_section "kill switch: access control lists"
  plan_access_control_revoke
  plan_planonly "mark the grant record revoked" "mv $record $record.revoked" "$KILL_SWITCH_REASON" "[ ! -e $record ]"

  plan_section "kill switch: transport"
  case "$TRANSPORT" in
    tailscale)
      plan_owner "remove the agent rule from your tailnet policy" \
        "tailscale admin console: delete the tag:agent rule and any unused auth key for it."
      ;;
    cloudflare)
      plan_planonly "stop the tunnel service" "cloudflared service uninstall" "$KILL_SWITCH_REASON" \
        "! cloudflare_service_installed"
      plan_owner "revoke the service token" \
        "cloudflare dashboard, access, service auth: revoke the agent client's service token."
      ;;
    *)
      plan_note "no transport selected, nothing to cut beyond the keys above."
      ;;
  esac

  plan_section "kill switch: finish"
  plan_planonly "write revoke_finished to the audit log" "$(kill_switch_audit_line revoke_finished)" "$KILL_SWITCH_REASON"
  plan_tag always
  plan_note "undo is a fresh install. nothing here is reversed automatically."
}
