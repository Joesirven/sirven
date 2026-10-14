#!/usr/bin/env bash
# SIR-32. a revoke that cannot finish says so loudly and says what to do, and leaves the machine in the safe state:
# here the snapshot of a granted folder is held under a lock by another process, so putting the folder's lists back
# fails. the account must already be locked and expired, no process of the agent left, the keys gone; the hint must
# name revoke --all (never the command that gives the account back); the grant record is not marked revoked yet.
# once the lock is gone, the same command finishes.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

mkdir -p /srv/work && echo f > /srv/work/f
bash install.sh --yes --level builder --transport none --path /srv/work >/dev/null 2>&1
echo 'ssh-ed25519 AAAAkey agent-client' > /home/agent/.ssh/authorized_keys && chown agent:agent /home/agent/.ssh/authorized_keys
setsid runuser -u agent -- sleep 600 >/dev/null 2>&1 &
sleep 0.3
check "precondition: a process of agent is running" pgrep -u agent

# hold every snapshot under an exclusive lock, as scenario 29 does
python3 -c "
import glob, sqlite3, time
held = []
for name in sorted(glob.glob('/var/lib/sirven/access-lists/*.txt')):
    connection = sqlite3.connect(name, isolation_level=None)
    connection.execute('BEGIN EXCLUSIVE')
    held.append(connection)
print('locked', len(held), flush=True)
time.sleep(600)" > /tmp/lock.out 2>&1 &
holder=$!
sleep 1
check "precondition: the other process holds the snapshots" grep -q 'locked [1-9]' /tmp/lock.out

check_exit "revoke fails with exit 4 while a snapshot is locked" 4 env SIRVEN_SNAPSHOT_WAIT=1 bash install.sh revoke --all --yes --transport none
out="$LAST_OUTPUT"
check "it says the snapshot is in use" grep -q 'in use by another process' <<< "$out"
check "it says the kill switch did not finish, and the account is locked, expired and without a process" grep -q 'the kill switch did not finish every step, but agent is locked, expired, and has no process' <<< "$out"
check "the hint is to run revoke --all again, from the kept copy" grep -q 'run the same command again: sudo /usr/local/sbin/sirven revoke --all' <<< "$out"
check "the hint does not tell the owner to give the account back" bash -c 'grep -q "run the same command again: sudo /usr/local/sbin/sirven revoke --all" <<< "$0" && ! grep -qi "release\|give the account back" <<< "$0"' "$out"
check "it lists the failed restore and says the others ran" bash -c 'grep -q "steps failed, each listed here, and the others ran" <<< "$0" && grep -q "the other steps still run" <<< "$0"' "$out"
check "the account is locked, expired, and on the nologin shell" bash -c '
  [ "$(getent passwd agent | cut -d: -f7)" = /usr/sbin/nologin ] && passwd --status agent | grep -q "^agent L" &&
  [ "$(getent shadow agent | cut -d: -f8)" = 1 ]'
check "no process of the agent is left" bash -c '! pgrep -u agent'
check "the key file is already gone" bash -c '[ ! -e /home/agent/.ssh/authorized_keys ]'
check "the grant record is not marked revoked yet, so the next run finishes the job" bash -c 'grep -q revoke_started /var/log/sirven/audit.jsonl && [ -f /etc/sirven/grants/agent.json ] && [ ! -e /etc/sirven/grants/agent.json.revoked ]'
check "the audit log says the run failed" bash -c 'tail -1 /var/log/sirven/audit.jsonl | grep -q "\"outcome\": \"failed\""'

kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check_exit "after the lock is gone the same revoke finishes" 0 bash install.sh revoke --all --yes --transport none
check "no entry of the agent is left on the granted folder" bash -c '[ -f /etc/sirven/grants/agent.json.revoked ] && ! getfacl -R -n -p /srv | grep -Eq "^(default:)?user:[0-9]+:"'
check "the account is still locked" bash -c '[ -f /etc/sirven/grants/agent.json.revoked ] && passwd --status agent | grep -q "^agent L"'

finish
