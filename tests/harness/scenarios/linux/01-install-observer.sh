#!/usr/bin/env bash
# the smallest real install: observer level, one folder, no transport. checks the effects, not
# the plan: the account, the permission lists, the install record, the audit log, and a re-run.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m neighbor
mkdir -p /srv/app && echo hello > /srv/app/file.txt

check_exit "install observer on /srv/app applies" 0 bash install.sh --yes --level observer --transport none --path /srv/app
check "install says it applied 26 steps (24 and the two that stop and give back the agent's account)" grep -q 'applied 26 steps' <<< "$LAST_OUTPUT"

check "service user agent exists" id -u agent
check "service user is not an administrator" bash -c '! id -nG agent | tr " " "\n" | grep -qx -e sudo -e wheel -e admin'
check "password login is off" bash -c '[ "$(getent shadow agent | cut -d: -f2)" = "*" ]'
check "ssh folder is 0700 and owned by agent" bash -c '[ "$(stat -c "%a %U" /home/agent/.ssh)" = "700 agent" ]'
check "authorized_keys is empty, 0600, owned by agent" bash -c '[ "$(stat -c "%a %U %s" /home/agent/.ssh/authorized_keys)" = "600 agent 0" ]'
check "agent can read the granted folder" runuser -u agent -- cat /srv/app/file.txt
check "agent cannot write the granted folder (observer)" bash -c '! runuser -u agent -- touch /srv/app/nope 2>/dev/null'
check "agent cannot read root's home" bash -c '! runuser -u agent -- ls /root 2>/dev/null'
check "default permission list makes new files readable by agent" bash -c 'touch /srv/app/later && runuser -u agent -- cat /srv/app/later'
# finding of 2026-10-13: the default list used to copy the folder's own group and other entries (755 gave
# r-x), so a file made under umask 077 was readable by everyone. the default list now gives group and other
# nothing. stat cannot show 600 while the agent has a named entry: the mask shows the agent's read in the
# group position (a 700 folder shows 640 for the same reason). so the test is what the access is, not the mode.
check "a new file made under umask 077 in the granted 755 folder gives other nothing" \
  bash -c 'umask 077; touch /srv/app/private; [ "$(stat -c %a /srv/app/private | cut -c3)" = 0 ]'
check "its group and other entries are empty" \
  bash -c 'getfacl --omit-header /srv/app/private | grep -qx "group::---" && getfacl --omit-header /srv/app/private | grep -qx "other::---"'
check "another account cannot read it" bash -c '! runuser -u neighbor -- cat /srv/app/private 2>/dev/null'
check "the agent can read it" runuser -u agent -- cat /srv/app/private
check "after the install the account is back as it was: password login off, never expires" \
  bash -c '[ "$(getent shadow agent | cut -d: -f2)" = "*" ] && [ -z "$(getent shadow agent | cut -d: -f8)" ]'
check "grant record exists" test -s /etc/sirven/grants/agent.json
check "install record exists, root only" bash -c '[ "$(stat -c "%a %U" /var/lib/sirven/install-record.tsv)" = "600 root" ]'
check "pinned copy exists" test -f /var/lib/sirven/package/PINNED-COPY
check "audit log has an install entry" grep -q '"outcome": *"finished"' /var/log/sirven/audit.jsonl

check_exit "re-run is idempotent" 0 bash install.sh --yes --level observer --transport none --path /srv/app
check "re-run skipped the finished steps" grep -q 'skipped 25 already done' <<< "$LAST_OUTPUT"

finish
