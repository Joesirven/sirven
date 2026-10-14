#!/usr/bin/env bash
# SIR-32, from the review (S5). two runs of the installer must not overlap. another run holds the lock on the state
# directory: install, uninstall and grant rollback refuse (exit 75) after the wait; the kill switch waits a short time and
# goes on anyway, because the emergency command must never be blocked by a hung install, and finishes.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

mkdir -p /srv/app && echo f > /srv/app/f
bash install.sh --yes --level builder --transport none --path /srv/app >/dev/null 2>&1
setsid runuser -u agent -- sleep 600 >/dev/null 2>&1 &
sleep 0.3

# another run: holds the lock on the state directory
setsid bash -c 'exec 8< /var/lib/sirven; flock 8; echo held; sleep 120' > /tmp/holder.out 2>&1 &
holder=$!
sleep 1
check "precondition: another run holds the lock" grep -q held /tmp/holder.out
account_before="$(getent shadow agent)"

check_exit "install refuses while another run holds the lock (exit 75)" 75 env SIRVEN_LOCK_WAIT=1 bash install.sh --yes --level builder --transport none --path /srv/app
check "it says another run holds the lock and nothing was changed" bash -c 'grep -q "another run of this installer holds the lock" <<< "$0" && grep -q "nothing was changed" <<< "$0"' "$LAST_OUTPUT"
check_exit "uninstall refuses too (exit 75)" 75 env SIRVEN_LOCK_WAIT=1 bash /var/lib/sirven/package/uninstall.sh
check_exit "grant rollback refuses too (exit 75)" 75 env SIRVEN_LOCK_WAIT=1 bash /var/lib/sirven/package/bin/sirven grant rollback
check "the refusals changed nothing: the account and its process are as they were" bash -c '[ "$(getent shadow agent)" = "$0" ] && pgrep -u agent >/dev/null' "$account_before"

check_exit "the kill switch goes on after a short wait and finishes (exit 0)" 0 env SIRVEN_LOCK_WAIT=1 bash install.sh revoke --all --yes --transport none
check "it warned that it did not wait" grep -q 'going on, because this command must not wait' <<< "$LAST_OUTPUT"
check "and the agent is cut off" bash -c 'passwd --status agent | grep -q "^agent L" && ! pgrep -u agent && [ -f /etc/sirven/grants/agent.json.revoked ]'
kill "$holder" 2>/dev/null; pkill -f 'sleep 120'
check_exit "with the lock free, uninstall applies" 0 bash /var/lib/sirven/package/uninstall.sh

finish
