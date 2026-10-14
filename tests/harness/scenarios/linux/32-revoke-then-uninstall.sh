#!/usr/bin/env bash
# SIR-32. install, run the kill switch against a live agent, then uninstall from the pinned copy, and compare the
# whole machine with how it was before: the revoked grant record, the quiesce marker and the snapshot folder must not
# be left behind. allowed leftovers are named in lib/world.sh (the audit log and the agent's home).
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

mkdir -p /srv/app && echo hello > /srv/app/file.txt
world_files > /tmp/before.files
world_accounts > /tmp/before.accounts
world_acls /srv > /tmp/before.acls

check_exit "install applies" 0 bash install.sh --yes --level observer --transport none --path /srv/app
setsid runuser -u agent -- sleep 600 >/dev/null 2>&1 &
sleep 0.3
check "precondition: a process of agent is running" pgrep -u agent
check_exit "revoke --all applies" 0 bash install.sh revoke --all --yes --transport none
check "after revoke the install record is still there to be read, and lists the revoked grant record's removal" bash -c 'grep -q "agent.json.revoked" /var/lib/sirven/install-record.tsv'
check "after revoke the revoked grant record is kept for the owner to look at" test -f /etc/sirven/grants/agent.json.revoked

check_exit "uninstall from the pinned copy applies" 0 bash /var/lib/sirven/package/uninstall.sh
uninstall="$LAST_OUTPUT"
revoked() { grep -q '"event": "revoke_finished"' /var/log/sirven/audit.jsonl; }
check "uninstall removed the revoked grant record it knew about" bash -c 'grep -q revoke_finished /var/log/sirven/audit.jsonl && ! ls /etc/sirven/grants 2>/dev/null | grep -q .'
check "service user is gone" bash -c 'grep -q revoke_finished /var/log/sirven/audit.jsonl && ! getent passwd agent && ! getent group agent'
check "its home is kept on purpose" bash -c 'grep -q revoke_finished /var/log/sirven/audit.jsonl && [ -d /home/agent ]'
check "audit log is kept on purpose, with the revoke entries in it" bash -c 'grep -q revoke_finished /var/log/sirven/audit.jsonl'
world_unchanged_if 'grep -q revoke_finished /var/log/sirven/audit.jsonl' "files match the machine before the install" files /tmp/before.files
world_unchanged_if 'grep -q revoke_finished /var/log/sirven/audit.jsonl' "accounts match the machine before the install" accounts /tmp/before.accounts
world_unchanged_if 'grep -q revoke_finished /var/log/sirven/audit.jsonl' "access control lists match the machine before the install" acls /tmp/before.acls /srv
check "no leftover folder named for the package" bash -c 'grep -q revoke_finished /var/log/sirven/audit.jsonl && [ ! -e /etc/sirven ] && [ ! -e /var/lib/sirven ]'

finish
