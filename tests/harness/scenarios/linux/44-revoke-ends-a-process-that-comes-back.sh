#!/usr/bin/env bash
# SIR-32, from the review (b2-residuals, S1). something of the owner's starts the agent's work again after the first
# sweep (here a root supervisor loop, as a unit with Restart=always that runs setpriv or su would). the last step ends it
# again a bounded number of times. when the supervisor stops, revoke finishes and says it ended a process again; when it
# never stops, revoke ends with exit 4 and says the processes keep coming back and how to find what starts them. the
# end state is checked on the machine, so "finished" is never printed while the agent runs.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

mkdir -p /srv/app && echo f > /srv/app/f
bash install.sh --yes --level builder --transport none --path /srv/app >/dev/null 2>&1

# a supervisor that restarts the agent's work every second, at most N times (N=2 here), then gives up
cat > /tmp/supervisor.sh <<'SCRIPT'
#!/bin/bash
limit="$1"; n=0
while [ "$n" -lt "$limit" ]; do
  pgrep -u agent -f supervised >/dev/null || { setpriv --reuid=agent --regid=agent --clear-groups bash -c 'exec -a supervised sleep 3000' & n=$((n+1)); }
  sleep 1
done
SCRIPT
chmod +x /tmp/supervisor.sh
setsid /tmp/supervisor.sh 3 >/dev/null 2>&1 &
sleep 2
check "precondition: the supervisor started the agent's work" pgrep -u agent -f supervised
check_exit "revoke finishes when the supervisor gives up after a few restarts" 0 bash install.sh revoke --all --yes --transport none
check "it said it ended a process that came back" grep -q 'is running again; ending it' <<< "$LAST_OUTPUT"
check "and the end state is clean, checked after the run" bash -c 'sleep 2; ! pgrep -u agent && ! pgrep -U agent'
check "the last check of the machine printed its result" grep -q '^checked: no process of agent' <<< "$LAST_OUTPUT"

# a supervisor that never stops
bash /var/lib/sirven/package/uninstall.sh >/dev/null 2>&1
rm -rf /etc/sirven /var/lib/sirven /var/log/sirven /home/agent /srv/app; userdel agent >/dev/null 2>&1; groupdel agent >/dev/null 2>&1
mkdir -p /srv/app && echo f > /srv/app/f
bash install.sh --yes --level builder --transport none --path /srv/app >/dev/null 2>&1
setsid /tmp/supervisor.sh 100000 >/dev/null 2>&1 &
supervisor=$!
sleep 2
check_exit "revoke ends with exit 4 when something keeps starting the agent's work" 4 bash install.sh revoke --all --yes --transport none
out="$LAST_OUTPUT"
check "it says the processes keep coming back and how to find what starts them" bash -c 'grep -q "keep coming back" <<< "$0" && grep -q "ps -o pid,ppid,user,args -u agent" <<< "$0"' "$out"
check "the audit log says the run failed, not finished" bash -c 'tail -1 /var/log/sirven/audit.jsonl | grep -q "\"outcome\": \"failed\""'
check "the account is still locked, expired, on nologin" bash -c 'passwd --status agent | grep -q "^agent L" && [ "$(getent shadow agent | cut -d: -f8)" = 1 ]'
kill "$supervisor" 2>/dev/null; pkill -f supervisor.sh; pkill -KILL -u agent
check_exit "once the supervisor is gone the same command finishes" 0 bash install.sh revoke --all --yes --transport none

finish
