#!/usr/bin/env bash
# SIR-32. the kill switch is idempotent: run twice, the second run exits 0, skips what is done, and changes nothing
# (files, accounts and access lists are the same as after the first). the revoked grant record is not duplicated and
# not overwritten, and the audit log shows both runs. revoke on a machine with nothing installed is harmless.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

# nothing installed: no account, no record, no log. the kill switch has nothing to do and must say so, not fail.
world_files > /tmp/empty.files
world_accounts > /tmp/empty.accounts
check_exit "revoke --all on a machine with nothing installed exits 0" 0 bash install.sh revoke --all --yes --transport none
world_unchanged_if 'grep -q "^applied [0-9]* steps" <<< "$LAST_OUTPUT"' "and it changed nothing: files" files /tmp/empty.files
world_unchanged_if 'grep -q "^applied [0-9]* steps" <<< "$LAST_OUTPUT"' "and it changed nothing: accounts" accounts /tmp/empty.accounts

mkdir -p /srv/work && echo f > /srv/work/f
bash install.sh --yes --level builder --transport none --path /srv/work >/dev/null 2>&1
setsid runuser -u agent -- sleep 600 >/dev/null 2>&1 &
sleep 0.3
check "precondition: a process of agent is running" pgrep -u agent

check_exit "the first revoke applies" 0 bash install.sh revoke --all --yes --transport none --path /srv/work
check "the first revoke ended the agent" bash -c '! pgrep -u agent'
world_files > /tmp/one.files
world_accounts > /tmp/one.accounts
world_acls /srv > /tmp/one.acls
cp /etc/sirven/grants/agent.json.revoked /tmp/one.revoked

check_exit "the second revoke applies" 0 bash install.sh revoke --all --yes --transport none --path /srv/work
second="$LAST_OUTPUT"
second_ran() { [ "$(grep -c "\"event\": \"revoke_finished\"" /var/log/sirven/audit.jsonl)" = 2 ]; }
check "it skipped the lock and the key removal as already done" bash -c '
  printf "%s\n" "$0" | grep -A1 "lock and expire agent and turn its shell off" | grep -q "already done" &&
  printf "%s\n" "$0" | grep -A1 "remove every authorized key of agent" | grep -q "already done"' "$second"
world_unchanged_if second_ran "the second revoke changed no file, owner or mode" files /tmp/one.files
world_unchanged_if second_ran "the second revoke changed no account" accounts /tmp/one.accounts
world_unchanged_if second_ran "the second revoke changed no access list" acls /tmp/one.acls /srv
check "there is one revoked grant record, the first one, unchanged" bash -c '
  [ "$(ls /etc/sirven/grants | grep -c revoked)" = 1 ] && cmp -s /etc/sirven/grants/agent.json.revoked /tmp/one.revoked'
check "the audit log shows both runs, each started and finished" bash -c '
  [ "$(grep -c "\"event\": \"revoke_started\"" /var/log/sirven/audit.jsonl)" = 2 ] &&
  [ "$(grep -c "\"event\": \"revoke_finished\"" /var/log/sirven/audit.jsonl)" = 2 ] &&
  [ "$(grep -c "\"event\": \"warning\"" /var/log/sirven/audit.jsonl)" = 0 ]'
check "the second run finished and did not warn about a missing snapshot" bash -c 'grep -q "^applied" <<< "$0" && ! grep -qi "could not restore" <<< "$0"' "$second"

finish
