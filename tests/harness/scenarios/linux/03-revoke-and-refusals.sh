#!/usr/bin/env bash
# the kill switch applies, and the refusals. revoke --all with a live agent process: the account is locked,
# expired and on the nologin shell, nothing of the agent's runs, the agent can no longer read the granted folder,
# and the access control lists are back exactly as before the install (SIR-32). then a real apply as an
# ordinary user is refused before any change.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

# the folder and the file are private to root, so the agent reads them only through its access list entry.
mkdir -p /srv/app && echo hello > /srv/app/file.txt && chmod 700 /srv/app && chmod 600 /srv/app/file.txt
world_acls /srv > /tmp/before.acls
bash install.sh --yes --level observer --transport none --path /srv/app >/dev/null 2>&1

agent_reads() { setpriv --reuid="$(id -u agent)" --regid="$(id -g agent)" --clear-groups cat /srv/app/file.txt; }
check "precondition: the agent reads the granted folder through its list entry" agent_reads

# something running as the agent, so "no processes remain" can fail for the right reason.
setsid runuser -u agent -- sleep 600 >/dev/null 2>&1 &
# and one a setuid program of the agent's would leave: real user agent, effective user root, which pgrep -u never sees
setsid setpriv --ruid="$(id -u agent)" --euid=0 sleep 601 >/dev/null 2>&1 &
sleep 0.3
check "precondition: a process of agent is running" pgrep -u agent
check "precondition: a process with the agent as real user and root as effective user is running" bash -c 'pgrep -U agent -f "sleep 601" && ! pgrep -u agent -f "sleep 601"'

check_exit "revoke --all applies" 0 bash install.sh revoke --all --yes --level observer --transport none --path /srv/app
check "the account is locked, expired, and on the nologin shell" bash -c '
  [ "$(getent passwd agent | cut -d: -f7)" = /usr/sbin/nologin ] &&
  passwd --status agent | grep -q "^agent L" &&
  [ "$(getent shadow agent | cut -d: -f8)" = 1 ]'
check "after revoke no sessions or processes of agent remain, by effective or real user" bash -c '! pgrep -u agent && ! pgrep -U agent'
check "after revoke the agent can no longer read the granted folder" bash -c '! setpriv --reuid="$(id -u agent)" --regid="$(id -g agent)" --clear-groups cat /srv/app/file.txt'
check "no list entry of the agent is left" bash -c '! getfacl -R -n -p /srv | grep -Eq "^(default:)?user:[0-9]+:"'
world_unchanged "access control lists match the machine before the install" acls /tmp/before.acls /srv
check "the install record, the audit log and the revoked grant record are kept" bash -c '
  [ -s /var/lib/sirven/install-record.tsv ] && [ -s /var/log/sirven/audit.jsonl ] &&
  [ -f /etc/sirven/grants/agent.json.revoked ] && [ ! -e /etc/sirven/grants/agent.json ]'
check "the earlier state marker is gone, so no later step unlocks the account" bash -c '[ -f /etc/sirven/grants/agent.json.revoked ] && [ ! -e /var/lib/sirven/agent-quiesce.json ]'

root_before="$(getent shadow root | cut -d: -f2,8)"
check_exit "revoke refuses root" 2 bash install.sh revoke --all --yes --transport none --user root
check_exit "revoke refuses a system account" 2 bash install.sh revoke --all --yes --transport none --user daemon
check "root's account is exactly as it was" bash -c '[ -f /etc/sirven/grants/agent.json.revoked ] && [ "$(getent shadow root | cut -d: -f2,8)" = "$0" ]' "$root_before"

# a real apply as an ordinary user is refused before any change.
check_exit "an ordinary user is refused" 3 setpriv --reuid=65534 --regid=65534 --clear-groups bash install.sh --yes --level observer --transport none
check "the refusal names root" grep -q 'needs root' <<< "$LAST_OUTPUT"

finish
