#!/usr/bin/env bash
# SIR-32. a revoked account stays off until the owner deliberately turns it back on. install on an account the kill
# switch cut off (expired, nologin shell) refuses, in a dry run too, and changes nothing. with --reinstate it unlocks
# the account, removes the expiry, gives back the shell, writes an audit entry, and goes on: the agent can log in again
# with a key the owner adds. the kill switch itself never takes --reinstate.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

mkdir -p /srv/app && echo hello > /srv/app/file.txt
bash install.sh --yes --level observer --transport none --path /srv/app >/dev/null 2>&1
check_exit "revoke --all applies" 0 bash install.sh revoke --all --yes --transport none
cut_off() { [ "$(getent passwd agent | cut -d: -f7)" = /usr/sbin/nologin ] && [ "$(getent shadow agent | cut -d: -f8)" = 1 ]; }
check "precondition: the account is cut off" cut_off
world_accounts > /tmp/cut.accounts
world_files > /tmp/cut.files

check_exit "install without --reinstate refuses (exit 2)" 2 bash install.sh --yes --level observer --transport none --path /srv/app
out="$LAST_OUTPUT"
check "it says the kill switch cut the account off, and how to bring it back on purpose" bash -c 'grep -q "was cut off by the kill switch" <<< "$0" && grep -q -- "--reinstate" <<< "$0" && grep -q "nothing was changed" <<< "$0"' "$out"
check_exit "a dry run refuses too (exit 2)" 2 bash install.sh --dry-run --level observer --transport none --path /srv/app
world_unchanged_if cut_off "the refusals changed no account" accounts /tmp/cut.accounts
world_unchanged_if cut_off "the refusals changed no file" files /tmp/cut.files
check_exit "--reinstate on the kill switch is a usage error (exit 64)" 64 bash install.sh revoke --all --reinstate --yes --transport none
check "and the account is still cut off" cut_off

check_exit "install --reinstate --dry-run shows the step" 0 bash install.sh --dry-run --reinstate --level observer --transport none --path /srv/app
check "the plan names the reinstate step" grep -q 'reinstate agent, as --reinstate asked' <<< "$LAST_OUTPUT"
check_exit "install --reinstate applies" 0 bash install.sh --yes --reinstate --level observer --transport none --path /srv/app
check "the account is on again: no expiry, shell /bin/bash, password off (keys only)" bash -c '
  [ "$(getent passwd agent | cut -d: -f7)" = /bin/bash ] && [ -z "$(getent shadow agent | cut -d: -f8)" ] &&
  [ "$(getent shadow agent | cut -d: -f2)" = "*" ]'
check "the audit log has a reinstate entry" bash -c 'grep "\"event\": \"reinstate\"" /var/log/sirven/audit.jsonl | grep -q "cut off by the kill switch"'
check "the earlier revoked grant record is kept beside the new grant record" bash -c '[ -f /etc/sirven/grants/agent.json ] && [ -f /etc/sirven/grants/agent.json.revoked ]'
check "the agent reads its granted folder again" bash -c 'setpriv --reuid="$(id -u agent)" --regid="$(id -g agent)" --clear-groups cat /srv/app/file.txt'

# the agent logs in again with a key the owner adds
mkdir -p /tmp/k && ssh-keygen -q -t ed25519 -N '' -f /tmp/k/id
cp /tmp/k/id.pub /home/agent/.ssh/authorized_keys && chown agent:agent /home/agent/.ssh/authorized_keys && chmod 600 /home/agent/.ssh/authorized_keys
ssh-keygen -A >/dev/null 2>&1
mkdir -p /run/sshd
/usr/sbin/sshd -p 2222 -o ListenAddress=127.0.0.1 -o PidFile=/tmp/sshd.pid
sleep 1
check "a key login works again" bash -c '[ "$(ssh -p 2222 -i /tmp/k/id -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR agent@127.0.0.1 id -un)" = agent ]'
check_exit "a second install --reinstate has nothing to turn on and applies" 0 bash install.sh --yes --reinstate --level observer --transport none --path /srv/app

finish
