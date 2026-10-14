# shellcheck shell=bash
# kill switch: revoke --all. cuts the agent off now and keeps the records. on linux it ends every
# process of the service user and locks and expires its account, takes away its SSH keys, stops the
# services that run as it, puts every granted folder back exactly (lib/access_control_snapshot.sh),
# marks the grant record revoked, and closes the transport. on macos it is still plan output.
#
# the order matters: lock first so nothing new starts and end what is running, then stop the services that
# would start it again (a unit with Restart=always would bring a process back while the grants are undone),
# then take the keys, then undo the grants while nothing of the agent's can change a folder. a step that finds its end
# state already in place is skipped, so running it again is safe and finishes a run that stopped.
#
# the agent owns its home folder, so nothing is done to a name inside it by path: the keys are
# removed by lib/kill_switch.py, which opens each folder without following a link and unlinks the
# names, never truncating through them. the audit log gets revoke_started before the first step and
# revoke_finished last, and every step writes its own entry as it is applied (see install.sh).
# a grant record that cannot be read never stops the lock: the failure comes as a step after the keys.
# reads: ROOT_DIR, PREFIX, OPERATING_SYSTEM, SERVICE_USER, CONFIG_DIR, STATE_DIR, AUDIT_DIR, TRANSPORT, STAGE_DIR

KILL_SWITCH_REASON="the kill switch on macos is plan output until a run in a macos virtual machine verifies it"
KILL_SWITCH_NOLOGIN="/usr/sbin/nologin"

# the helpers run from the folder this installer runs from, so the lock never waits on the pinned copy
# being there: the kill switch must work on a machine where that copy is gone.
kill_switch_helper() {
  printf '%s/lib/%s' "$ROOT_DIR" "$1"
}

# kill_switch_quiesce USER MARKER: end every process of USER and lock and expire its account.
kill_switch_quiesce() {
  bash "$(kill_switch_helper access_control_snapshot.sh)" quiesce "$1" "$2"
}

kill_switch_marker() {
  printf '%s/agent-quiesce.json' "$STATE_DIR"
}

# kill_switch_account_stopped USER: true when the account is gone, or locked, expired, and has no process.
# read only.
kill_switch_account_stopped() {
  local user="$1" shadow
  id -u "$user" >/dev/null 2>&1 || return 0
  shadow="$(getent shadow "$user" 2>/dev/null)" || return 1
  [ "$(printf '%s' "$shadow" | cut -d: -f8)" = 1 ] || return 1
  case "$(printf '%s' "$shadow" | cut -d: -f2)" in '!'*) ;; *) return 1 ;; esac
  ! pgrep -u "$user" >/dev/null 2>&1 && ! pgrep -U "$user" >/dev/null 2>&1
}

kill_switch_shell_is_nologin() {
  id -u "$1" >/dev/null 2>&1 || return 0
  [ "$(getent passwd "$1" | cut -d: -f7)" = "$KILL_SWITCH_NOLOGIN" ]
}

# true when systemd runs here and can be asked about units.
kill_switch_systemd_running() {
  [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1
}

# kill_switch_user_units USER: the service units that run as USER, one per line. read only.
kill_switch_user_units() {
  local user="$1" unit number found
  kill_switch_systemd_running || return 0
  number="$(id -u "$user" 2>/dev/null)" || return 0
  systemctl list-unit-files --type=service --no-legend --plain 2>/dev/null | while read -r unit _; do
    [ -n "$unit" ] || continue
    found="$(systemctl show --property=User --value "$unit" 2>/dev/null)" || continue
    if [ "$found" = "$user" ] || [ "$found" = "$number" ]; then printf '%s\n' "$unit"; fi
  done
}

# true when no service unit that runs as USER is active or enabled, and the user has no lingering session.
kill_switch_services_stopped() {
  local user="$1" unit
  kill_switch_systemd_running || return 0
  while read -r unit; do
    [ -n "$unit" ] || continue
    if systemctl is-active --quiet "$unit" 2>/dev/null || systemctl is-enabled --quiet "$unit" 2>/dev/null; then
      return 1
    fi
  done <<END
$(kill_switch_user_units "$user")
END
  ! { command -v loginctl >/dev/null 2>&1 && loginctl show-user "$user" --property=Linger --value 2>/dev/null | grep -qx yes; }
}

# kill_switch_stop_services USER: stop and disable every service unit that runs as USER (disabled so a
# reboot does not bring it back), turn off lingering, and end the user's systemd session. a unit that
# cannot be stopped fails the step.
kill_switch_stop_services() {
  local user="$1" unit
  kill_switch_systemd_running || return 0
  while read -r unit; do
    [ -n "$unit" ] || continue
    printf 'stopping %s, which runs as %s\n' "$unit" "$user"
    systemctl stop "$unit" || { printf 'error: could not stop %s\n' "$unit" >&2; return 1; }
    systemctl disable "$unit" >/dev/null 2>&1 || true
  done <<END
$(kill_switch_user_units "$user")
END
  if command -v loginctl >/dev/null 2>&1; then
    loginctl disable-linger "$user" >/dev/null 2>&1 || true
    loginctl terminate-user "$user" >/dev/null 2>&1 || true
  fi
}

# kill_switch_home_folders HOME: the folder the plan names, and the one the account really has when
# that differs (a real root only).
kill_switch_home_folders() {
  local planned="$1" real
  printf '%s\n' "$planned"
  [ -z "$PREFIX" ] || return 0
  real="$(getent passwd "$SERVICE_USER" 2>/dev/null | cut -d: -f6)" || true
  if [ -n "$real" ] && [ "$real" != "$planned" ]; then printf '%s\n' "$real"; fi
}

kill_switch_keys_gone() {
  local home
  while read -r home; do
    python3 -I "$(kill_switch_helper kill_switch.py)" keys-gone "$home" || return 1
  done <<END
$(kill_switch_home_folders "$1")
END
}

kill_switch_remove_keys() {
  local home
  while read -r home; do
    python3 -I "$(kill_switch_helper kill_switch.py)" remove-keys "$home" || return 1
  done <<END
$(kill_switch_home_folders "$1")
END
}

# kill_switch_mark_revoked RECORD: rename the grant record to RECORD.revoked. an earlier revoked record is
# kept beside it under a time stamp, never overwritten.
kill_switch_mark_revoked() {
  local record="$1"
  [ -e "$record" ] || [ -L "$record" ] || return 0
  if [ -e "$record.revoked" ] || [ -L "$record.revoked" ]; then
    mv "$record.revoked" "$record.revoked.$(date -u +%Y%m%d%H%M%S).$$" || return 1
  fi
  mv "$record" "$record.revoked"
}

# kill_switch_fail MESSAGE: a step that stops the run with the reason.
kill_switch_fail() {
  printf 'error: %s\n' "$1" >&2
  return 1
}

# kill_switch_report_failure: after a failed revoke, say plainly what state the machine is in and what to do.
# unlike an install or a rollback, the account is not given back: locked is the state the kill switch wants.
kill_switch_report_failure() {
  printf 'the kill switch stopped before it finished. %s is locked and expired from the first step on, so no new login works.\n' "$SERVICE_USER" >&2
  printf 'fix the cause printed above and run the same command again: ./install.sh revoke --all. finished steps are skipped.\n' >&2
  printf 'if the agent must be stopped right now, as root: usermod --lock --expiredate 1 --shell %s %s; pkill -KILL -u %s\n' \
    "$KILL_SWITCH_NOLOGIN" "$SERVICE_USER" "$SERVICE_USER" >&2
}

# kill_switch_refuse_unsafe_user: the kill switch locks an account and ends its processes, so it refuses the accounts
# that must never be locked by mistake (root, the owner, a system account) before it plans anything.
kill_switch_refuse_unsafe_user() {
  local number
  if [ "$SERVICE_USER" = root ] || [ "$SERVICE_USER" = "$OWNER" ]; then
    DIE_STATUS=2 die "refusing to revoke $SERVICE_USER: it is root or the owner account, which the kill switch would lock out. --user names the agent's account. nothing was changed."
  fi
  [ -z "$PREFIX" ] || return 0
  number="$(id -u "$SERVICE_USER" 2>/dev/null)" || return 0
  if [ "$number" -lt 500 ]; then
    DIE_STATUS=2 die "refusing to revoke $SERVICE_USER: user number $number is a system account, not an agent account. nothing was changed."
  fi
}

plan_kill_switch_macos() {
  local user="$SERVICE_USER" keys record
  keys="$(rooted "$(service_user_home)/.ssh/authorized_keys")"
  record="$(rooted "$CONFIG_DIR/grants/$user.json")"
  plan_planonly "remove every authorized key for $user" "rm -f $keys ${keys}2" "$KILL_SWITCH_REASON" "[ ! -e $keys ]"
  plan_planonly "lock $user so no new session starts" \
"dscl . -create /Users/$user UserShell /usr/bin/false
pwpolicy -u $user -disableuser" \
    "$KILL_SWITCH_REASON" \
    "dscl . -read /Users/$user UserShell 2>/dev/null | grep -q /usr/bin/false"
  plan_planonly "end every running session and process of $user" "pkill -KILL -u $user" "$KILL_SWITCH_REASON" \
    "! pgrep -u $user >/dev/null 2>&1"
  plan_section "kill switch: access control lists"
  plan_access_control_revoke
  plan_planonly "mark the grant record revoked" "mv $record $record.revoked" "$KILL_SWITCH_REASON" "[ ! -e $record ]"
}

plan_kill_switch_linux() {
  local user="$SERVICE_USER" home record marker
  home="$(rooted "$(service_user_home)")"
  record="$(rooted "$CONFIG_DIR/grants/$user.json")"
  marker="$(rooted "$(kill_switch_marker)")"

  plan_step system "end every process of $user and lock and expire its account, so nothing new starts" \
    "kill_switch_account_stopped $user" \
    "kill_switch_quiesce $user $marker"
  plan_step system "stop and disable every service that runs as $user, and end its systemd session" \
    "kill_switch_services_stopped $user" \
    "kill_switch_stop_services $user"
  plan_step system "set the shell of $user to $KILL_SWITCH_NOLOGIN" \
    "kill_switch_shell_is_nologin $user" \
    "usermod --shell $KILL_SWITCH_NOLOGIN $user"
  plan_step system "remove every authorized key of $user, by name, without following a link" \
    "kill_switch_keys_gone $home" \
    "kill_switch_remove_keys $home"

  plan_section "kill switch: access control lists"
  plan_access_control_revoke
  if [ -n "${KILL_SWITCH_LATE_FAILURE:-}" ]; then
    plan_step run "stop: the grants of $user cannot be listed, so they cannot be removed" "false" \
      "kill_switch_fail $(shell_quote "$KILL_SWITCH_LATE_FAILURE")"
  fi
  plan_step run "mark the grant record revoked, and keep it" "[ ! -e $record ]" "kill_switch_mark_revoked $record"
  plan_undo "remove the revoked grant records of $user" "[ ! -e $record.revoked ]" \
    "rm -f $record.revoked $record.revoked.[0-9]*"
  # no check: the plan is read before the first step, when the marker quiesce makes does not exist yet
  plan_step run "forget the earlier state of the account, so no later step gives it back" "false" "rm -f $marker"
}

plan_kill_switch_transport() {
  local key_file
  plan_section "kill switch: transport"
  case "$TRANSPORT" in
    tailscale)
      key_file="$(rooted "$(tailscale_auth_key_file)")"
      if [ "$OPERATING_SYSTEM" = linux ]; then
        plan_step run "remove the tailscale auth key from disk, if one is left" "[ ! -e $key_file ]" "rm -f $key_file"
      fi
      plan_owner "remove the agent rule from your tailnet policy" \
        "tailscale admin console: delete the tag:agent rule and any unused auth key for it. the keys and the account above already refuse the agent; this closes the way in."
      ;;
    cloudflare)
      if [ "$OPERATING_SYSTEM" = linux ]; then
        plan_step system "stop the tunnel service" "! cloudflare_service_installed" "cloudflared service uninstall"
      else
        plan_planonly "stop the tunnel service" "cloudflared service uninstall" "$KILL_SWITCH_REASON" \
          "! cloudflare_service_installed"
      fi
      plan_owner "revoke the service token" \
        "cloudflare dashboard, access, service auth: revoke the agent client's service token."
      ;;
    *)
      plan_note "no transport selected, nothing to cut beyond the keys above."
      ;;
  esac
}

plan_kill_switch() {
  KILL_SWITCH_LATE_FAILURE=""
  plan_section "kill switch: revoke --all"
  plan_note "audit log: revoke_started is written before the first step and revoke_finished last, with the outcome. every step writes its own entry too."
  if [ "$OPERATING_SYSTEM" = macos ]; then
    plan_kill_switch_macos
  else
    plan_kill_switch_linux
  fi
  plan_kill_switch_transport
  plan_section "kill switch: finish"
  plan_note "kept on purpose: the install record, the audit log, the revoked grant record, and the home folder of $SERVICE_USER with whatever the agent left in it."
  plan_note "the account stays locked and expired, with its shell turned off. to give the agent access again, unlock the account yourself and install again; nothing here is reversed automatically."
}
