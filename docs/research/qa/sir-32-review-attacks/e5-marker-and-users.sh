#!/usr/bin/env bash
# round 2: the revoke marker. who can write it, does it follow one user, what does it do to other accounts.
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
mkdir -p /srv/app && echo f > /srv/app/f
bash install.sh --yes --level observer --transport none --path /srv/app >/dev/null 2>&1
ls -ld /var/lib/sirven /var/lib/sirven/package /etc/sirven /etc/sirven/grants /var/log/sirven | awk '{print $1,$3,$4,$9}'
check "the agent cannot create the marker" bash -c '! runuser -u agent -- touch /var/lib/sirven/agent-revoked-agent.json 2>/dev/null'
check "the agent cannot list the state directory" bash -c '! runuser -u agent -- ls /var/lib/sirven >/dev/null 2>&1'
check "the agent cannot hold the lock (open the state directory)" bash -c '! runuser -u agent -- flock /var/lib/sirven true 2>/dev/null'
useradd -m bob
bash install.sh revoke --all --yes --transport none >/dev/null 2>&1; echo "revoke agent exit $?"
echo "marker: $(cat /var/lib/sirven/agent-revoked-agent.json 2>&1)"
out="$(bash install.sh --yes --user bob --level observer --transport none --path /srv/app 2>&1)"; echo "install --user bob after revoking agent: exit $?"; printf '%s\n' "$out" | head -4
out="$(bash install.sh --yes --level observer --transport none --path /srv/app 2>&1)"; echo "install for agent without --reinstate: exit $?"
if [ -e /var/lib/sirven/agent-revoked-agent.json ]; then echo "marker still there"; fi
# delete the marker as root (forging 'no revoke happened') and see whether the expired account is still refused
rm -f /var/lib/sirven/agent-revoked-agent.json
out="$(bash install.sh --yes --level observer --transport none --path /srv/app 2>&1)"; echo "install for agent, marker deleted by root: exit $?"; printf '%s\n' "$out" | grep -i "cut off" | head -2
echo "state: expire='$(getent shadow agent | cut -d: -f8)' shell=$(getent passwd agent | cut -d: -f7)"
finish
