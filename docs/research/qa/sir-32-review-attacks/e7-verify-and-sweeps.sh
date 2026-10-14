#!/usr/bin/env bash
# round 2: the final check and re-sweep. (a) a supervisor that restarts the agent's work twice, (b) one that never stops.
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
mkdir -p /srv/app && echo f > /srv/app/f
bash install.sh --yes --level builder --transport none --path /srv/app >/dev/null 2>&1
echo "== (a) restarts the agent's work two times, then stops =="
setsid bash -c 'n=0; while [ $n -lt 2 ]; do pgrep -u agent -f supervised >/dev/null || { setpriv --reuid=agent --regid=agent --clear-groups bash -c "exec -a supervised sleep 3000" & n=$((n+1)); }; sleep 1; done' >/dev/null 2>&1 &
sleep 2
bash install.sh revoke --all --yes --transport none > /tmp/a.out 2>&1; st=$?
echo "revoke exit $st; agent processes now: $(pgrep -u agent | wc -l)"; grep -E "running again|keep coming back|checked:|last check" /tmp/a.out | head -6
check "(a) revoke ends with exit 0 and no process of the agent" bash -c '[ "'$st'" = 0 ] && ! pgrep -u agent'
pkill -f 'while \[ \$n' ; pkill -KILL -u agent
echo "== (b) never stops =="
bash install.sh --yes --reinstate --level builder --transport none --path /srv/app >/dev/null 2>&1
setsid bash -c 'while :; do pgrep -u agent -f supervised >/dev/null || setpriv --reuid=agent --regid=agent --clear-groups bash -c "exec -a supervised sleep 3000" & sleep 1; done' >/dev/null 2>&1 &
sleep 2
started=$SECONDS
bash install.sh revoke --all --yes --transport none > /tmp/b.out 2>&1; st=$?
echo "revoke exit $st after $((SECONDS-started)) s"; grep -E "keep coming back|last check|not true yet|a process" /tmp/b.out | head -6
tail -2 /var/log/sirven/audit.jsonl | cut -c1-250
check "(b) revoke fails loudly (exit 4) and the audit log says failed" bash -c '[ "'$st'" = 4 ] && tail -1 /var/log/sirven/audit.jsonl | grep -q "\"outcome\": \"failed\""'
check "(b) the account is still locked and expired" bash -c '[ "$(getent shadow agent | cut -d: -f8)" = 1 ]'
finish
