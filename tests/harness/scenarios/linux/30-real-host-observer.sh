#!/usr/bin/env bash
# a real Linux host, as nearly as a container can be one: the container markers are removed, so the
# installer's non-container path is the one exercised. observer level, no transport, one folder. then the
# refusals that are specific to a real host: not root, no --yes and no terminal, and the plan not confirmed.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
. "$(dirname "$0")/../../lib/real_host.sh"
cd "$SRC" || exit 2

useradd -m neighbor
mkdir -p /srv/app && echo hello > /srv/app/file.txt
world_files > /tmp/before.files
world_accounts > /tmp/before.accounts

# refusals first: each must change nothing.
check_exit "a non-root run is refused" 3 setpriv --reuid=65534 --regid=65534 --clear-groups bash install.sh --yes --level observer --transport none --path /srv/app
check "the refusal names root" grep -q 'needs root' <<< "$LAST_OUTPUT"
check_exit "root without --yes and without a terminal is refused" 3 env SIRVEN_INTERACTIVE=no bash install.sh --level observer --transport none --path /srv/app
check "the refusal says to run again with --yes" grep -q 'with --yes' <<< "$LAST_OUTPUT"
check_exit "an answer other than yes is refused" 3 bash -c 'echo no | SIRVEN_INTERACTIVE=yes bash install.sh --level observer --transport none --path /srv/app'
check "the refusal says the plan was not confirmed" grep -q 'not confirmed' <<< "$LAST_OUTPUT"
check "the refusals created no service user" bash -c '! getent passwd agent'
world_unchanged "the machine is unchanged by the refusals" files /tmp/before.files

# the real thing, confirmed on the terminal (stdin stands in for it).
check_exit "typing yes applies the plan" 0 bash -c 'echo yes | SIRVEN_INTERACTIVE=yes bash install.sh --level observer --transport none --path /srv/app'
check "install says it applied 23 steps" grep -q 'applied 23 steps' <<< "$LAST_OUTPUT"
check "the install is not marked as a container run in the output" bash -c '! grep -qi container <<< "$0"' "$LAST_OUTPUT"

check "service user agent exists" id -u agent
check "service user is not an administrator" bash -c '! id -nG agent | tr " " "\n" | grep -qx -e sudo -e wheel -e admin'
check "password login is off" bash -c '[ "$(getent shadow agent | cut -d: -f2)" = "*" ]'
check "authorized_keys is empty, 0600, owned by agent" bash -c '[ "$(stat -c "%a %U %s" /home/agent/.ssh/authorized_keys)" = "600 agent 0" ]'
check "agent can read the granted folder" runuser -u agent -- cat /srv/app/file.txt
check "agent cannot write the granted folder (observer)" bash -c '! runuser -u agent -- touch /srv/app/nope 2>/dev/null'
check "agent cannot read root's home" bash -c '! runuser -u agent -- ls /root 2>/dev/null'
check "install record exists, root only" bash -c '[ "$(stat -c "%a %U" /var/lib/sirven/install-record.tsv)" = "600 root" ]'
check "audit log has an install entry" grep -q '"outcome": *"finished"' /var/log/sirven/audit.jsonl

finish
