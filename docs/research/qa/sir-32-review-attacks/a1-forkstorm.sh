#!/usr/bin/env bash
# attack 1: an exponential fork storm as the agent, capped at 60 processes for the agent's real user (root is exempt, as on a real host).
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
mkdir -p /srv/app && echo f > /srv/app/f
bash install.sh --yes --level builder --transport none --path /srv/app >/dev/null 2>&1
setsid runuser -u agent -- bash -c 'ulimit -u 60; f(){ f | f & }; f' >/dev/null 2>&1 &
sleep 1
echo "agent processes before: $(pgrep -u agent | wc -l)"
started=$SECONDS
bash install.sh revoke --all --yes --transport none > /tmp/rev.out 2>&1; st=$?
echo "revoke exit $st after $((SECONDS-started)) s"
tail -12 /tmp/rev.out
echo "agent processes after: $(pgrep -u agent | wc -l) (real uid: $(pgrep -U agent | wc -l))"
echo "shadow: $(getent shadow agent | cut -d: -f2 | cut -c1-2) expire=$(getent shadow agent | cut -d: -f8) shell=$(getent passwd agent | cut -d: -f7)"
echo "marker: $(ls /var/lib/sirven/agent-quiesce.json 2>&1)"
echo "record: $(ls /etc/sirven/grants 2>&1 | tr '\n' ' ')"
echo "acl on /srv/app: $(getfacl -p /srv/app 2>/dev/null | grep -c 'user:agent')"
check "storm: revoke finished with exit 0" test "$st" = 0
check "storm: no agent process left" bash -c '! pgrep -u agent'
finish
