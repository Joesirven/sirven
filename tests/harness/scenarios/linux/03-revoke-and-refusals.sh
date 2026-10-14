#!/usr/bin/env bash
# the kill switch and the refusals. revoke is plan only today (exit 3); the known_defect lines
# are the acceptance test for SIR-32 and flip to real assertions when it lands.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

mkdir -p /srv/app && echo hello > /srv/app/file.txt
bash install.sh --yes --level observer --transport none --path /srv/app >/dev/null 2>&1

# something running as the agent, so "no processes remain" can fail for the right reason.
setsid runuser -u agent -- sleep 600 >/dev/null 2>&1 &
sleep 0.3
check "precondition: a process of agent is running" pgrep -u agent

check_exit "revoke --all refuses to apply while it is plan only" 3 bash install.sh revoke --all --yes --level observer --transport none --path /srv/app
check "the refusal points to uninstall, the undo that works today" grep -q 'to undo this install today, use ./uninstall.sh' <<< "$LAST_OUTPUT"
check "a refused revoke changed nothing: agent still exists" id -u agent
known_defect "revoke --all applies and exits 0" SIR-32 \
  bash -c 'cd "$0" && bash install.sh revoke --all --yes --level observer --transport none --path /srv/app >/dev/null' "$SRC"
known_defect "after revoke the account is locked" SIR-32 \
  bash -c '[ "$(getent passwd agent | cut -d: -f7)" = /usr/sbin/nologin ] && passwd --status agent | grep -q "^agent L"'
known_defect "after revoke the agent can no longer read the granted folder" SIR-32 \
  bash -c '! runuser -u agent -- cat /srv/app/file.txt 2>/dev/null'
known_defect "after revoke no sessions or processes of agent remain" SIR-32 bash -c '! pgrep -u agent'

# a real apply as an ordinary user is refused before any change.
check_exit "an ordinary user is refused" 3 setpriv --reuid=65534 --regid=65534 --clear-groups bash install.sh --yes --level observer --transport none
check "the refusal names root" grep -q 'needs root' <<< "$LAST_OUTPUT"

finish
