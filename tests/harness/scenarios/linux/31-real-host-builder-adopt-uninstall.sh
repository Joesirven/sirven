#!/usr/bin/env bash
# a real Linux host (container markers removed, see lib/real_host.sh): builder level with a path owned by
# a person, a re-run on the configured machine (adopts what is there and does nothing twice, with and
# without repeating the flags), then uninstall, and the whole machine is as it was: files, accounts,
# groups, and access control lists.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
. "$(dirname "$0")/../../lib/real_host.sh"
cd "$SRC" || exit 2

useradd -m owner
mkdir -p /srv/work && chown owner:owner /srv/work && chmod 755 /srv/work
echo before > /srv/work/old.txt && chown owner:owner /srv/work/old.txt
world_files > /tmp/before.files
world_accounts > /tmp/before.accounts
world_etc_content > /tmp/before.etc
world_acls /srv > /tmp/before.acls
world_aclraw_attributes /srv > /tmp/before.raw

check_exit "install builder on /srv/work applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
check "the agent can write in the granted folder" runuser -u agent -- sh -c 'echo from-agent > /srv/work/from-agent'
check "the folder owner can read what the agent wrote" runuser -u owner -- cat /srv/work/from-agent
check "the agent cannot read root's home" bash -c '! runuser -u agent -- ls /root 2>/dev/null'
check "the agent cannot write outside the grant" bash -c '! runuser -u agent -- touch /srv/outside 2>/dev/null'
cp /var/lib/sirven/install-record.tsv /tmp/record.first
cp /etc/sirven/grants/agent.json /tmp/grant.first
{ getent passwd agent; getent shadow agent; } > /tmp/agent.first

check_exit "re-run with the same flags applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
# one step runs on every re-run by design: the one that gives the agent's account back after the grant (it has
# no "already done" check). its effect is the same each time, which the shadow comparison below shows.
check "re-run did nothing twice: 25 steps skipped, only the give-back-the-account step ran" grep -q 'applied 1 steps, skipped 25 already done' <<< "$LAST_OUTPUT"
check "install record is byte for byte the same" cmp /tmp/record.first /var/lib/sirven/install-record.tsv
check "grant record is byte for byte the same" cmp /tmp/grant.first /etc/sirven/grants/agent.json
check "the service user is the same account, password field and expiry included" bash -c '[ "$({ getent passwd agent; getent shadow agent; })" = "$(cat /tmp/agent.first)" ]'

check_exit "re-run with no flags adopts the grant in force" 0 bash install.sh --yes --transport none
check "adopting changed nothing: 25 steps skipped, only the give-back-the-account step ran" grep -q 'applied 1 steps, skipped 25 already done' <<< "$LAST_OUTPUT"
check "install record is still the same" cmp /tmp/record.first /var/lib/sirven/install-record.tsv

check_exit "uninstall applies" 0 bash /var/lib/sirven/package/uninstall.sh --yes
check "service user and group are gone" bash -c '! getent passwd agent && ! getent group agent'
rm -f /srv/work/from-agent
world_unchanged "files match the machine before the install" files /tmp/before.files
world_unchanged "the content of every file in /etc matches the machine before the install" etc_content /tmp/before.etc
world_unchanged "accounts and groups match the machine before the install" accounts /tmp/before.accounts
world_unchanged "access control lists match the machine before the install" acls /tmp/before.acls /srv
world_unchanged "raw attributes, owners and modes match the machine before the install" aclraw_attributes /tmp/before.raw /srv

finish
