#!/usr/bin/env bash
# SIR-32. the kill switch against a live agent: a real sshd (the package's default configuration, which reads both
# authorized_keys and authorized_keys2), a key login that works, and a session that is open when revoke --all runs.
# afterwards the session is gone, no process of the agent remains, both key files are gone, a key login is refused,
# and a key put back by hand is refused too (the account is expired and locked, so the lock stands without the keys).
# revoke is run with no --transport flag, so the default transport is tailscale and the machine has no tailscale:
# the kill switch must not ask for tools it does not use.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

mkdir -p /srv/app && echo hello > /srv/app/file.txt
bash install.sh --yes --level observer --transport none --path /srv/app >/dev/null 2>&1

# the owner's agent client key, in both files the default sshd configuration reads.
mkdir -p /tmp/k && ssh-keygen -q -t ed25519 -N '' -f /tmp/k/id
cp /tmp/k/id.pub /home/agent/.ssh/authorized_keys
cp /tmp/k/id.pub /home/agent/.ssh/authorized_keys2
chown agent:agent /home/agent/.ssh/authorized_keys /home/agent/.ssh/authorized_keys2
ssh-keygen -A >/dev/null 2>&1
mkdir -p /run/sshd
check "precondition: the default sshd configuration reads authorized_keys2 too" \
  bash -c 'sshd -T | grep -i "^authorizedkeysfile" | grep -q authorized_keys2'
/usr/sbin/sshd -p 2222 -o ListenAddress=127.0.0.1 -o PidFile=/tmp/sshd.pid
sleep 1
# the agent client: the key, no password, no prompts
cat > /tmp/agent-ssh <<'SCRIPT'
#!/bin/sh
exec ssh -p 2222 -i /tmp/k/id -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no   -o UserKnownHostsFile=/dev/null -o LogLevel="${AGENT_SSH_LOG:-ERROR}" agent@127.0.0.1 "$@"
SCRIPT
chmod +x /tmp/agent-ssh
check "precondition: a key login works" bash -c '[ "$(/tmp/agent-ssh id -un)" = agent ]'

# a session left open, running a command of its own
setsid /tmp/agent-ssh 'sleep 600' >/dev/null 2>&1 &
client=$!
sleep 1
check "precondition: the session runs a process of agent" pgrep -u agent -f 'sleep 600'

check_exit "revoke --all applies with no transport flag" 0 bash install.sh revoke --all --yes
check "the live session's process is gone" bash -c '! pgrep -u agent && ! pgrep -U agent'
check "the open ssh session ended" bash -c '
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$0" 2>/dev/null || exit 0; sleep 0.5; done; exit 1' "$client"
check "both key files are gone" bash -c '[ ! -e /home/agent/.ssh/authorized_keys ] && [ ! -e /home/agent/.ssh/authorized_keys2 ]'
check "the keys are gone but the ssh folder and the home folder are kept" bash -c '[ ! -e /home/agent/.ssh/authorized_keys ] && [ -d /home/agent/.ssh ] && [ -d /home/agent ]'
check "a key login is refused" bash -c '! /tmp/agent-ssh true'

# the keys back by hand: the lock alone must hold
cp /tmp/k/id.pub /home/agent/.ssh/authorized_keys
chown agent:agent /home/agent/.ssh/authorized_keys
check "a key put back by hand still cannot log in, and sshd says the account expired" bash -c '
  out="$(AGENT_SSH_LOG=INFO /tmp/agent-ssh true 2>&1)" && exit 1
  printf "%s\n" "$out" | grep -qi "expired" || { printf "%s\n" "$out" >&2; exit 1; }'

# the audit log tells the story in order: revoke_started, the steps, revoke_finished
log=/var/log/sirven/audit.jsonl
check "revoke_started is in the audit log and comes before every revoke step" bash -c '
  first="$(grep -n "\"event\": \"revoke_started\"" '"$log"' | head -1 | cut -d: -f1)"
  step="$(grep -n "\"operation\": \"revoke\", \"step\"" '"$log"' | head -1 | cut -d: -f1)"
  [ -n "$first" ] && [ -n "$step" ] && [ "$first" -lt "$step" ]'
check "revoke_finished is the last entry and says finished" bash -c '
  tail -1 '"$log"' | grep -q "\"event\": \"revoke_finished\"" && tail -1 '"$log"' | grep -q "\"outcome\": \"finished\""'
check "every revoke step has an audit entry" bash -c '
  [ "$(grep -c "\"operation\": \"revoke\", \"step\"" '"$log"')" -ge 8 ]'

finish
