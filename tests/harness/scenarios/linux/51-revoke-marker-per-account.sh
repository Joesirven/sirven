#!/usr/bin/env bash
# SIR-32 round 3 (review e5, e6). the kill switch's marker is per account: revoking agent does not block install --user bob,
# reinstating one account leaves the other's marker, and deleting a marker as root does not make install think nothing happened
# (the account is still left expired). and a plain install that made its plan before a revoke and gets the lock after it is
# refused instead of applying the old plan.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

mkdir -p /srv/app && echo f > /srv/app/f
check_exit "install applies for agent" 0 bash install.sh --yes --level observer --transport none --path /srv/app
useradd -m bob
check_exit "revoke --all applies for agent" 0 bash install.sh revoke --all --yes --transport none
check "agent has its own marker, and there is no marker for bob" bash -c '[ -s /var/lib/sirven/agent-revoked-agent.json ] && [ ! -e /var/lib/sirven/agent-revoked-bob.json ] && [ ! -e /var/lib/sirven/agent-revoked.json ]'
check_exit "install for another account (bob) is not blocked by agent's marker" 0 bash install.sh --yes --user bob --level observer --transport none --path /srv/app
check_exit "install for agent is refused" 2 bash install.sh --yes --level observer --transport none --path /srv/app
rm -f /var/lib/sirven/agent-revoked-agent.json
check_exit "install for agent with the marker deleted by root is still refused (the account is left expired)" 2 bash install.sh --yes --level observer --transport none --path /srv/app
check "the refusal says the account was cut off by the kill switch" grep -q 'was cut off by the kill switch' <<< "$LAST_OUTPUT"
echo '{"user": "agent"}' > /var/lib/sirven/agent-revoked-agent.json
check_exit "--reinstate for agent applies" 0 bash install.sh --yes --reinstate --level observer --transport none --path /srv/app
check "agent's marker is gone and bob is untouched" bash -c '[ ! -e /var/lib/sirven/agent-revoked-agent.json ] && getent shadow bob >/dev/null && [ -z "$(getent shadow bob | cut -d: -f8)" ]'
check "the step that gives an account back refuses for a revoked account only" bash -c '
  echo "{\"locked\": false, \"expire\": \"\"}" > /var/lib/sirven/agent-quiesce.json
  echo "{}" > /var/lib/sirven/agent-revoked-bob.json
  bash /var/lib/sirven/package/lib/access_control_snapshot.sh release agent /var/lib/sirven/agent-quiesce.json &&
  ! bash /var/lib/sirven/package/lib/access_control_snapshot.sh release bob /var/lib/sirven/agent-quiesce.json'
rm -f /var/lib/sirven/agent-revoked-bob.json /var/lib/sirven/agent-quiesce.json

# a plain install that planned before a revoke and gets the lock after it
check_exit "revoke --all applies again (agent)" 0 bash install.sh revoke --all --yes --transport none
check_exit "--reinstate and install again, so there is something to revoke" 0 bash install.sh --yes --reinstate --level observer --transport none --path /srv/app
setsid bash -c 'exec 8< /var/lib/sirven; flock 8; sleep 25' >/dev/null 2>&1 &
sleep 1
( bash install.sh --yes --level builder --transport none --path /srv/app > /tmp/install.out 2>&1; echo "install exit $?" >> /tmp/install.out ) &
sleep 3
SIRVEN_LOCK_WAIT=2 bash install.sh revoke --all --yes --transport none > /tmp/revoke.out 2>&1
check "the revoke went on after its short wait" bash -c 'grep -q "going on, because this command must not wait" /tmp/revoke.out && passwd --status agent | grep -q "^agent L"'
wait
check "the stale install that got the lock afterwards was refused" bash -c 'grep -q "install exit 2" /tmp/install.out && grep -q "cut agent off while this run waited for the lock" /tmp/install.out'
check "the account is still locked and expired, and no list entry for the agent is back" bash -c '[ "$(getent shadow agent | cut -d: -f8)" = 1 ] && ! getfacl -p /srv/app 2>/dev/null | grep -q user:agent'
finish
