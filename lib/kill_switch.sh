# shellcheck shell=bash
# kill switch: revoke --all. cuts the agent off now and keeps the records. on linux it writes its own revoke
# marker, then in one change locks and expires the account and turns its shell off, ends every process of the
# service user, stops the services (and the timers, sockets and path units that start them) that run as it,
# removes its cron and at jobs and its SSH keys, puts every granted folder back exactly
# (lib/access_control_snapshot.sh), marks the grant record revoked, closes the transport, and last checks the
# end state. on macos it is still plan output.
#
# every step is attempted even when an earlier one fails (plan_continue): the agent must not be able to stop
# the removal of its access by making one step fail, so a failure is recorded, the rest run, and the run ends
# with exit 4 listing every failure. the account stays locked throughout. a step that finds its end state
# already in place is skipped, and the check is read again just before the step runs (PLAN_RECHECK), so
# running it again is safe and finishes a run that stopped.
#
# the revoke marker ($STATE_DIR/agent-revoked.json) is written before the first change and kept after the
# run. it is separate from the install's agent-quiesce.json (which remembers the account's earlier state so a
# finished install can give it back): install and release refuse to turn the account on while the revoke
# marker is there, and only install --reinstate removes it. so a revoke that stopped halfway is never undone by
# a plain install.
#
# the agent owns its home folder, so nothing is done to a name inside it by path: the keys are
# removed by lib/kill_switch.py, which opens each folder without following a link and unlinks the
# names, never truncating through them. the audit log gets revoke_started before the first step and
# revoke_finished last, and every step writes its own entry as it is applied (see install.sh).
# a grant record that cannot be read never stops the lock: the failure comes as a step after the keys.
# reads: ROOT_DIR, PREFIX, OPERATING_SYSTEM, SERVICE_USER, OWNER, CONFIG_DIR, STATE_DIR, AUDIT_DIR, TRANSPORT, STAGE_DIR

KILL_SWITCH_REASON="the kill switch on macos is plan output until a run in a macos virtual machine verifies it"
KILL_SWITCH_NOLOGIN="/usr/sbin/nologin"
# some distributions keep it in /sbin only (Alpine)
if [ "$(uname -s)" = Linux ] && [ ! -x /usr/sbin/nologin ] && [ -x /sbin/nologin ]; then KILL_SWITCH_NOLOGIN="/sbin/nologin"; fi
KILL_SWITCH_SWEEPS=6

# the helpers run from the folder this installer runs from (install.sh re-runs itself from the root-owned
# pinned copy when there is one, see lib/trust.sh), so the lock never waits on the pinned copy being there:
# the kill switch must work on a machine where that copy is gone.
kill_switch_helper() {
  printf '%s/lib/%s' "$ROOT_DIR" "$1"
}

# the revoke marker, outside the prefix: a path under STATE_DIR.
kill_switch_revoked_marker() {
  printf '%s/agent-revoked.json' "$STATE_DIR"
}

# kill_switch_write_marker USER MARKER: record that the kill switch has started. never overwrites an earlier one.
kill_switch_write_marker() {
  local user="$1" marker="$2"
  [ ! -e "$marker" ] || return 0
  [ -d "$(dirname "$marker")" ] || mkdir -p -m 0700 "$(dirname "$marker")" || return 1
  ( umask 077 && printf '{"user": "%s", "revoked": "%s"}\n' "$user" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$marker" )
}

# kill_switch_lock USER: lock and expire the account and turn its shell off in one change, then end every
# process of it (by effective and real user), repeating until none is left.
kill_switch_lock() {
  bash "$(kill_switch_helper access_control_snapshot.sh)" revoke-lock "$1" "$KILL_SWITCH_NOLOGIN"
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

# the account is locked, expired, on the nologin shell, and has no process.
kill_switch_locked_down() {
  kill_switch_account_stopped "$1" && kill_switch_shell_is_nologin "$1"
}

# true when systemd runs here and can be asked about units.
kill_switch_systemd_running() {
  [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1
}

# kill_switch_unit_names: every unit systemd knows by name, from the unit files and from the loaded units (a
# template instance such as name@agent.service is only in the second list), one per line.
kill_switch_unit_names() {
  {
    systemctl list-unit-files --no-legend --plain 2>/dev/null
    systemctl list-units --all --no-legend --plain 2>/dev/null
  } | while read -r unit _; do
    case "$unit" in *.service | *.timer | *.socket | *.path) printf '%s\n' "$unit" ;; esac
  done | sort -u
}

# kill_switch_user_units USER: the units that run as USER or start what does, one per line, triggers first: its
# service units (User= is USER, template instances included) and the timer, socket and path units that start
# one of them. read only. a unit of root that starts the agent's work with su or setpriv is invisible here; the
# last check (kill_switch_verify) is what catches the process it starts.
kill_switch_user_units() {
  local user="$1" number names unit found services="" triggers="" property target word
  kill_switch_systemd_running || return 0
  number="$(id -u "$user" 2>/dev/null)" || return 0
  names="$(kill_switch_unit_names)"
  while read -r unit; do
    case "$unit" in *.service) ;; *) continue ;; esac
    found="$(systemctl show --property=User --value "$unit" 2>/dev/null)" || continue
    if [ "$found" = "$user" ] || [ "$found" = "$number" ]; then services="$services$unit
"; fi
  done <<END
$names
END
  while read -r unit; do
    case "$unit" in
      *.timer | *.path) property=Unit ;;
      *.socket) property=Triggers ;;
      *) continue ;;
    esac
    target="$(systemctl show --property="$property" --value "$unit" 2>/dev/null)" || continue
    for word in $target; do
      if printf '%s' "$services" | grep -qxF "$word"; then triggers="$triggers$unit
"; break; fi
    done
  done <<END
$names
END
  printf '%s%s' "$triggers" "$services"
}

# true when the user still has a systemd session or a user manager running.
kill_switch_user_session_open() {
  command -v loginctl >/dev/null 2>&1 || return 1
  case "$(loginctl show-user "$1" --property=State --value 2>/dev/null)" in
    active | online | closing) return 0 ;;
  esac
  return 1
}

kill_switch_user_lingering() {
  command -v loginctl >/dev/null 2>&1 || return 1
  loginctl show-user "$1" --property=Linger --value 2>/dev/null | grep -qx yes
}

# true when no unit that runs as USER is active or enabled, and the user has no lingering or open systemd session.
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
  ! kill_switch_user_lingering "$user" && ! kill_switch_user_session_open "$user"
}

# kill_switch_stop_services USER: stop and disable every unit kill_switch_user_units finds (disabled so a reboot
# does not bring it back; triggers are stopped first so nothing starts the service again), turn off lingering, and
# end the user's systemd session. every failure is printed and counted, none is ignored: the step fails at the end
# and the run goes on.
kill_switch_stop_services() {
  local user="$1" unit failed=0
  kill_switch_systemd_running || return 0
  while read -r unit; do
    [ -n "$unit" ] || continue
    printf 'stopping %s, which belongs to %s\n' "$unit" "$user"
    if ! systemctl stop "$unit"; then
      printf 'error: could not stop %s\n' "$unit" >&2
      failed=1
      continue
    fi
    systemctl disable "$unit" >/dev/null 2>&1 || true
    if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
      printf 'error: %s is stopped but still enabled, so a reboot would start it again\n' "$unit" >&2
      failed=1
    fi
  done <<END
$(kill_switch_user_units "$user")
END
  if command -v loginctl >/dev/null 2>&1; then
    loginctl disable-linger "$user" >/dev/null 2>&1 || true
    loginctl terminate-user "$user" >/dev/null 2>&1 || true
    if kill_switch_user_lingering "$user"; then
      printf 'error: lingering is still on for %s, so its user services start at boot\n' "$user" >&2
      failed=1
    fi
    if kill_switch_user_session_open "$user"; then
      printf 'error: %s still has a systemd session or user manager\n' "$user" >&2
      failed=1
    fi
  fi
  return "$failed"
}

# kill_switch_jobs_present USER: true when USER has a crontab or an at job. read only.
kill_switch_jobs_present() {
  local user="$1"
  if command -v crontab >/dev/null 2>&1 && crontab -l -u "$user" >/dev/null 2>&1; then return 0; fi
  if command -v atq >/dev/null 2>&1 && atq 2>/dev/null | awk -v user="$user" '$NF == user { found = 1 } END { exit !found }'; then return 0; fi
  return 1
}

# kill_switch_remove_jobs USER: remove the crontab and every at job of USER. when the commands are missing, the
# files are left alone and it says so. a job that cannot be removed fails the step.
kill_switch_remove_jobs() {
  local user="$1" failed=0 identifier removed=0 summary=""
  if command -v crontab >/dev/null 2>&1; then
    if crontab -l -u "$user" >/dev/null 2>&1; then
      if crontab -r -u "$user"; then
        summary="removed the crontab of $user"
      else
        printf 'error: could not remove the crontab of %s\n' "$user" >&2
        failed=1
      fi
    fi
  else
    printf 'warning: no crontab command, so a crontab of %s (if any) was left alone\n' "$user" >&2
  fi
  if command -v atq >/dev/null 2>&1 && command -v atrm >/dev/null 2>&1; then
    while read -r identifier; do
      [ -n "$identifier" ] || continue
      if atrm "$identifier"; then removed=$((removed + 1)); else printf 'error: could not remove at job %s\n' "$identifier" >&2; failed=1; fi
    done <<END
$(atq 2>/dev/null | awk -v user="$user" '$NF == user { print $1 }')
END
    [ "$removed" -eq 0 ] || summary="${summary:+$summary, }removed $removed at job(s) of $user"
  else
    printf 'warning: no atq or atrm command, so at jobs of %s (if any) were left alone\n' "$user" >&2
  fi
  if [ -n "$summary" ]; then
    printf '%s\n' "$summary"
    audit_write "$(audit_entry revoke_detail "operation=revoke" "message=$summary")"
  fi
  return "$failed"
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
# kept beside it under a time stamp, never overwritten. when an earlier step failed the record is left where it
# is, so the next run still knows what to take back.
kill_switch_mark_revoked() {
  local record="$1"
  [ -e "$record" ] || [ -L "$record" ] || return 0
  if [ "${PLAN_FAILURES:-0}" -gt 0 ]; then
    printf 'left the grant record in place: an earlier step failed, and the next run needs it to finish\n'
    return 0
  fi
  if [ -e "$record.revoked" ] || [ -L "$record.revoked" ]; then
    mv "$record.revoked" "$record.revoked.$(date -u +%Y%m%d%H%M%S).$$" || return 1
  fi
  mv "$record" "$record.revoked"
}

# kill_switch_fail MESSAGE: a step that fails with the reason.
kill_switch_fail() {
  printf 'error: %s\n' "$1" >&2
  return 1
}

# kill_switch_verify: the last step. looks at the machine, not at the exit statuses: first that no process of the
# agent is left, ending any that came back (a supervisor of the owner's can start the agent's work again, so this
# repeats a bounded number of times, with a pause, and fails loudly if it keeps coming back); then every check
# of a step tagged verify (the lock, the services, the keys, every restored folder) is read again.
kill_switch_verify() {
  local user="$SERVICE_USER" round=0 quiet=0 index=0 bad=""
  id -u "$user" >/dev/null 2>&1 || return 0
  while [ "$round" -lt "$KILL_SWITCH_SWEEPS" ] && [ "$quiet" -lt 2 ]; do
    if pgrep -u "$user" >/dev/null 2>&1 || pgrep -U "$user" >/dev/null 2>&1; then
      printf 'a process of %s is running again; ending it (sweep %s of %s)\n' "$user" "$((round + 1))" "$KILL_SWITCH_SWEEPS"
      kill_switch_lock "$user" || true
      quiet=0
    else
      quiet=$((quiet + 1))
    fi
    round=$((round + 1))
    sleep 1
  done
  if pgrep -u "$user" >/dev/null 2>&1 || pgrep -U "$user" >/dev/null 2>&1; then
    printf 'error: processes of %s keep coming back after %s sweeps. something starts them again (a service of another user, a supervisor, cron): find it with: ps -o pid,ppid,user,args -u %s\n' \
      "$user" "$KILL_SWITCH_SWEEPS" "$user" >&2
    bad="${bad}  a process of $user is running
"
  fi
  while [ "$index" -lt "$PLAN_COUNT" ]; do
    if [ "${PLAN_TAG[index]}" = verify ] && ! _plan_check_passes "${PLAN_CHECK[index]}"; then
      bad="${bad}  not true yet: ${PLAN_TITLE[index]}
"
    fi
    index=$((index + 1))
  done
  if [ -n "$bad" ]; then
    printf 'error: the last check of the machine found what is still open:\n%s' "$bad" >&2
    return 1
  fi
  printf 'checked: no process of %s, the account is locked and expired, no keys, no service, every folder put back\n' "$user"
}

# kill_switch_report_failure: after a failed revoke, say plainly what state the machine is in and what to do.
# unlike an install or a rollback, the account is not given back: locked is the state the kill switch wants.
kill_switch_report_failure() {
  if kill_switch_locked_down "$SERVICE_USER"; then
    printf 'the kill switch did not finish every step, but %s is locked, expired, and has no process: no new login works.\n' "$SERVICE_USER" >&2
  else
    printf 'the kill switch did not finish, and %s is NOT confirmed locked. do it by hand now, as root: usermod --lock --expiredate 1 --shell %s %s; pkill -KILL -u %s\n' \
      "$SERVICE_USER" "$KILL_SWITCH_NOLOGIN" "$SERVICE_USER" "$SERVICE_USER" >&2
  fi
  printf 'fix the causes printed above and run the same command again: sudo bash %s/package/install.sh revoke --all. finished steps are skipped.\n' "$STATE_DIR" >&2
  printf 'the revoke marker stays, so a plain install will not turn the account back on; only install --reinstate does.\n' >&2
}

# kill_switch_account_cut_off USER: true when the kill switch has cut the account off: its revoke marker is there,
# or the account is expired and no install is in the middle of changing it (an install that stopped leaves
# agent-quiesce.json, and its next run gives the account back). the marker is read under the prefix; the account
# only on a real root, where an account is real.
kill_switch_account_cut_off() {
  [ "$OPERATING_SYSTEM" = linux ] || return 1
  [ ! -e "${PREFIX}$(kill_switch_revoked_marker)" ] || return 0
  [ -z "$PREFIX" ] || return 1
  id -u "$1" >/dev/null 2>&1 || return 1
  [ ! -e "$(kill_switch_state_file agent-quiesce.json)" ] || return 1
  [ "$(getent shadow "$1" 2>/dev/null | cut -d: -f8)" = 1 ]
}

kill_switch_state_file() {
  printf '%s%s/%s' "$PREFIX" "$STATE_DIR" "$1"
}

# kill_switch_reinstate USER: turn a cut-off account back on, as install made it: unlocked (the password stays
# off, keys only), no expiry, the shell install gives it. the revoke marker goes last, only when the account is on.
kill_switch_reinstate() {
  if id -u "$1" >/dev/null 2>&1; then
    usermod --unlock --expiredate '' --shell /bin/bash "$1"
  fi
}

# plan_reinstate: install --reinstate on an account the kill switch cut off. the steps come first, so the
# install that follows finds an ordinary account.
plan_reinstate() {
  [ "$REINSTATE" = yes ] || return 0
  plan_section "reinstate"
  if ! kill_switch_account_cut_off "$SERVICE_USER" && [ -z "$PREFIX" ]; then
    plan_note "--reinstate was given, but $SERVICE_USER is not cut off (no revoke marker, and the account is not left expired), so there is nothing to turn back on."
    return 0
  fi
  plan_step system "reinstate $SERVICE_USER, as --reinstate asked: unlock the account, remove the expiry, give back the /bin/bash shell, remove the revoke marker" \
    "! kill_switch_account_cut_off $SERVICE_USER" \
    "kill_switch_reinstate $SERVICE_USER"
  # the marker goes last, and only when the account is on again (a failed step above stops the run before this one)
  plan_step run "remove the revoke marker of $SERVICE_USER, so installs are no longer refused" \
    "[ ! -e $(rooted "$(kill_switch_revoked_marker)") ]" \
    "rm -f $(rooted "$(kill_switch_revoked_marker)") $(rooted "$(kill_switch_state_file_name agent-quiesce.json)")"
  plan_note "the kill switch removed the keys, the services, the cron jobs and the grant of $SERVICE_USER, so none of the old access comes back. add the agent client's public key again."
}

# kill_switch_uid_min: the first user number of an ordinary account here: UID_MIN from /etc/login.defs, else 1000.
kill_switch_uid_min() {
  local value
  value="$(sed -n 's/^UID_MIN[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p' /etc/login.defs 2>/dev/null | head -n 1)"
  printf '%s' "${value:-1000}"
}

# kill_switch_refuse_unsafe_user: the kill switch locks an account and ends its processes, so it refuses the accounts
# that must never be locked by mistake before it plans anything: root, the owner, the user who ran sudo, an account
# below UID_MIN (the system accounts: a database, a web server), and nobody (65534). a real root only.
kill_switch_refuse_unsafe_user() {
  local number minimum
  if [ "$SERVICE_USER" = root ] || [ "$SERVICE_USER" = "$OWNER" ] || [ "$SERVICE_USER" = "${SUDO_USER:-}" ]; then
    DIE_STATUS=2 die "refusing to revoke $SERVICE_USER: it is root, the owner, or the account running this, which the kill switch would lock out. --user names the agent's account. nothing was changed."
  fi
  [ -z "$PREFIX" ] || return 0
  number="$(id -u "$SERVICE_USER" 2>/dev/null)" || return 0
  minimum="$(kill_switch_uid_min)"
  if [ "$number" -lt "$minimum" ] || [ "$number" -eq 65534 ] || [ "$number" -eq 4294967294 ] || [ "$SERVICE_USER" = nobody ]; then
    DIE_STATUS=2 die "refusing to revoke $SERVICE_USER: user number $number is a system account here (ordinary accounts start at $minimum), not an agent account. locking it could stop a service. nothing was changed."
  fi
}

# kill_switch_confirm: a real run asks first, because it ends processes and locks an account. --yes skips it.
# the word must be typed on a terminal; with no terminal and no --yes it refuses rather than guess.
kill_switch_confirm() {
  local answer=""
  [ -z "$PREFIX" ] && [ "$ASSUME_YES" != yes ] || return 0
  if [ ! -r /dev/tty ] || ! { : < /dev/tty; } 2>/dev/null; then
    DIE_STATUS=2 die "the kill switch ends every process of $SERVICE_USER and locks its account, so it asks first, and there is no terminal to ask on. run it again with --yes to go ahead. nothing was changed."
  fi
  printf 'this will end every process of %s, lock and expire its account, remove its keys, services and jobs, and take back every grant.\ntype revoke to go on, anything else stops: ' "$SERVICE_USER" > /dev/tty
  read -r answer < /dev/tty || answer=""
  [ "$answer" = revoke ] || DIE_STATUS=2 die "not confirmed. nothing was changed."
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
  local user="$SERVICE_USER" home record marker revoked
  home="$(rooted "$(service_user_home)")"
  record="$(rooted "$CONFIG_DIR/grants/$user.json")"
  marker="$(rooted "$(kill_switch_state_file_name agent-quiesce.json)")"
  revoked="$(rooted "$(kill_switch_revoked_marker)")"

  # nothing installed and no such account: nothing to cut off, and nothing is created to say so
  if [ -n "$PREFIX" ] || id -u "$user" >/dev/null 2>&1 || [ -e "$(kill_switch_revoked_marker)" ]; then
    plan_step run "record that the kill switch has started for $user, so no install turns the account back on" \
      "[ -s $revoked ]" "kill_switch_write_marker $user $revoked"
    plan_undo "remove the kill switch marker of $user" "[ ! -e $revoked ]" "rm -f $revoked"
    plan_continue
  fi
  plan_step system "lock and expire $user and turn its shell off in one change, then end every process of it" \
    "kill_switch_locked_down $user" \
    "kill_switch_lock $user"
  plan_tag verify
  plan_continue
  plan_step system "stop and disable every service, timer, socket and path unit that runs as $user, and end its systemd session" \
    "kill_switch_services_stopped $user" \
    "kill_switch_stop_services $user"
  plan_tag verify
  plan_continue
  plan_step system "remove the cron and at jobs of $user" \
    "! kill_switch_jobs_present $user" \
    "kill_switch_remove_jobs $user"
  plan_continue
  plan_step system "remove every authorized key of $user, by name, without following a link" \
    "kill_switch_keys_gone $home" \
    "kill_switch_remove_keys $home"
  plan_tag verify
  plan_continue

  plan_section "kill switch: access control lists"
  plan_access_control_revoke
  if [ -n "${KILL_SWITCH_LATE_FAILURE:-}" ]; then
    plan_step run "stop: the grants of $user cannot be listed, so they cannot be removed" "false" \
      "kill_switch_fail $(shell_quote "$KILL_SWITCH_LATE_FAILURE")"
    plan_continue
  fi
  plan_step run "mark the grant record revoked, and keep it" "[ ! -e $record ]" "kill_switch_mark_revoked $record"
  plan_undo "remove the revoked grant records of $user" "[ ! -e $record.revoked ]" \
    "rm -f $record.revoked $record.revoked.[0-9]*"
  plan_continue
  # no check: the plan is read before the first step, when the marker quiesce makes does not exist yet
  plan_step run "forget the earlier state of the account an install saved, so no later step gives it back" "false" "rm -f $marker"
  plan_continue
}

# the file name part only, so the plan can root it
kill_switch_state_file_name() {
  printf '%s/%s' "$STATE_DIR" "$1"
}

plan_kill_switch_transport() {
  local key_file
  plan_section "kill switch: transport"
  case "$TRANSPORT" in
    tailscale)
      key_file="$(rooted "$(tailscale_auth_key_file)")"
      if [ "$OPERATING_SYSTEM" = linux ]; then
        plan_step run "remove the tailscale auth key from disk, if one is left" "[ ! -e $key_file ]" "rm -f $key_file"
        plan_continue
      fi
      plan_owner "remove the agent rule from your tailnet policy" \
        "tailscale admin console: delete the tag:agent rule and any unused auth key for it. the keys and the account above already refuse the agent; this closes the way in."
      ;;
    cloudflare)
      if [ "$OPERATING_SYSTEM" = linux ]; then
        plan_step system "stop the tunnel service" "! cloudflare_service_installed" "cloudflared service uninstall"
        plan_continue
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
  plan_note "every step is attempted even when an earlier one fails; the run then ends with exit 4 and lists each failure. the account stays locked."
  if [ "$OPERATING_SYSTEM" = macos ]; then
    plan_kill_switch_macos
  else
    plan_kill_switch_linux
  fi
  plan_kill_switch_transport
  if [ "$OPERATING_SYSTEM" = linux ]; then
    plan_section "kill switch: check the result"
    plan_step system "look at the machine: no process of $SERVICE_USER, locked and expired, no service, no keys, every folder put back" \
      "false" "kill_switch_verify"
    plan_continue
  fi
  plan_section "kill switch: finish"
  plan_note "kept on purpose: the install record, the audit log, the revoked grant record, the revoke marker, and the home folder of $SERVICE_USER with whatever the agent left in it."
  plan_note "the account stays locked and expired, with its shell turned off. to give the agent access again on purpose, run install.sh with --reinstate; nothing here is reversed automatically."
}
