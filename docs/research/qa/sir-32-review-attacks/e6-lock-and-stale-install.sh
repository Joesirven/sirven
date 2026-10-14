#!/usr/bin/env bash
# round 2: another run holds the lock (stand-in for an install in progress) while a plain install has already planned and a
# revoke runs; the revoke waits 10 s and goes on. when the lock is free the install applies the plan it made BEFORE the revoke.
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
mkdir -p /srv/app /srv/other && echo f > /srv/app/f && echo g > /srv/other/g
bash install.sh --yes --level observer --transport none --path /srv/app >/dev/null 2>&1
state() { echo "locked=$(getent shadow agent | cut -d: -f2 | cut -c1) expire='$(getent shadow agent | cut -d: -f8)' shell=$(getent passwd agent | cut -d: -f7 | sed 's|.*/||') acl=$(getfacl -p /srv/app 2>/dev/null | grep -c user:agent) other_acl=$(getfacl -p /srv/other 2>/dev/null | grep -c user:agent) record=$(ls /etc/sirven/grants | tr '\n' ',') marker=$([ -e /var/lib/sirven/agent-revoked.json ] && echo y || echo n)"; }
setsid bash -c 'exec 8< /var/lib/sirven; flock 8; sleep 40' >/dev/null 2>&1 &
sleep 1
# a plain install that changes the level and adds a path: its plan is made now, it waits for the lock
( bash install.sh --yes --level builder --transport none --path /srv/app --path /srv/other > /tmp/install.out 2>&1; echo "install exit $?" >> /tmp/install.out ) &
sleep 3
started=$SECONDS
bash install.sh revoke --all --yes --transport none > /tmp/revoke.out 2>&1; echo "revoke exit $? after $((SECONDS-started)) s"
grep -i "going on" /tmp/revoke.out | head -1
echo "after the revoke: $(state)"
wait
echo "after the stale install: $(state)"
tail -5 /tmp/install.out | cut -c1-220
check "the account is still locked and expired after the stale install" bash -c '[ "$(getent shadow agent | cut -d: -f8)" = 1 ]'
check "no access list entry for the agent is back" bash -c '! getfacl -p /srv/app /srv/other 2>/dev/null | grep -q user:agent'
finish
