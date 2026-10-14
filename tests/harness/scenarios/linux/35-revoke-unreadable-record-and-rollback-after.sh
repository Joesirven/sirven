#!/usr/bin/env bash
# SIR-32. (1) an unreadable grant record must not stop the lock: the account is locked and expired, the agent's
# processes are gone and its keys removed, and only then does the run fail, naming the cause and what to do. moved
# aside and with --path naming the folder, the same command finishes and the lists come off. (2) after a revoke,
# sirven grant rollback must not hand the access back.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

mkdir -p /srv/work && echo f > /srv/work/f
bash install.sh --yes --level builder --transport none --path /srv/work >/dev/null 2>&1
echo 'ssh-ed25519 AAAAkey agent-client' > /home/agent/.ssh/authorized_keys && chown agent:agent /home/agent/.ssh/authorized_keys
setsid runuser -u agent -- sleep 600 >/dev/null 2>&1 &
sleep 0.3
check "precondition: a process of agent is running" pgrep -u agent
echo 'not json' > /etc/sirven/grants/agent.json

check_exit "revoke with an unreadable grant record fails (exit 4)" 4 bash install.sh revoke --all --yes --transport none
out="$LAST_OUTPUT"
check "it names the record and says it cannot be read" grep -q 'grant record .*agent.json cannot be read' <<< "$out"
check "it says what to do: move it aside, name the folders, run revoke --all again" grep -q 'name the granted folders with --path, and run revoke --all again' <<< "$out"
check "yet the account is locked, expired, and on the nologin shell" bash -c '
  [ "$(getent passwd agent | cut -d: -f7)" = /usr/sbin/nologin ] && passwd --status agent | grep -q "^agent L" &&
  [ "$(getent shadow agent | cut -d: -f8)" = 1 ]'
check "the agent's process is gone" bash -c '! pgrep -u agent'
check "and its key file is gone" bash -c '[ ! -e /home/agent/.ssh/authorized_keys ]'
check "the unreadable record is left exactly where it was" bash -c 'grep -q revoke_started /var/log/sirven/audit.jsonl && [ "$(cat /etc/sirven/grants/agent.json)" = "not json" ]'

mv /etc/sirven/grants/agent.json /root/agent.json.damaged
check_exit "moved aside, revoke --all --path finishes" 0 bash install.sh revoke --all --yes --transport none --path /srv/work
check "the lists are off the granted folder and its parent" bash -c 'grep -q revoke_finished /var/log/sirven/audit.jsonl && ! getfacl -R -n -p /srv | grep -Eq "^(default:)?user:[0-9]+:"'

# (2) rollback after revoke
check "after a finished revoke, grant rollback is refused (exit 2) because the record no longer matches" bash -c '
  grep -q revoke_finished /var/log/sirven/audit.jsonl || exit 1
  out="$(bash /var/lib/sirven/package/bin/sirven grant rollback 2>&1)"; status=$?
  [ "$status" = 2 ] && grep -q "no longer matches the last grant change" <<< "$out"'
check "no access was handed back: no entry of the agent on the granted folder" bash -c 'grep -q revoke_finished /var/log/sirven/audit.jsonl && ! getfacl -R -n -p /srv | grep -Eq "^(default:)?user:[0-9]+:"'
check "the account is still locked and expired" bash -c 'grep -q revoke_finished /var/log/sirven/audit.jsonl && passwd --status agent | grep -q "^agent L" && [ "$(getent shadow agent | cut -d: -f8)" = 1 ]'

finish
