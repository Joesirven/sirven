#!/usr/bin/env bash
# a folder that a person owns, not root, granted at builder level, with a 755 mode and a umask of 077.
# the agent writes into it; the owner reads what the agent wrote; another account reads neither the
# owner's private file nor, for the agent's own files, anything but what the grant gives. then uninstall
# puts the access control lists back exactly, which the owner's files created under the grant keep out of.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
useradd -m neighbor
mkdir -p /srv/work && chown owner:owner /srv/work && chmod 755 /srv/work
echo before > /srv/work/old.txt && chown owner:owner /srv/work/old.txt
world_acls /srv > /tmp/before.acls

check_exit "install builder on /srv/work applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
check "the agent can write a new file in the folder" runuser -u agent -- sh -c 'echo from-agent > /srv/work/from-agent'
check "the folder owner can read what the agent wrote" runuser -u owner -- cat /srv/work/from-agent
check "the owner's file made under umask 077 is private to the owner and the agent" \
  runuser -u owner -- sh -c 'umask 077; echo private > /srv/work/private'
check "another account cannot read the owner's private file" bash -c '! runuser -u neighbor -- cat /srv/work/private 2>/dev/null'
check "the agent can read the owner's private file" runuser -u agent -- cat /srv/work/private
check "the owner's private file gives other nothing" bash -c '[ "$(stat -c %a /srv/work/private | cut -c3)" = 0 ]'

check_exit "uninstall applies" 0 bash /var/lib/sirven/package/uninstall.sh
# the files the owner and the agent made under the grant are left, as all user data is; the lists on them are gone.
check "a file the agent made under the grant has no named entry after uninstall" \
  bash -c '! getfacl --omit-header /srv/work/from-agent 2>/dev/null | grep -q "^user:agent:"'
# the diff is taken without those two new files, so it shows the folder's own lists only.
rm -f /srv/work/from-agent /srv/work/private
world_unchanged "access control lists match the machine before the install" acls /tmp/before.acls /srv

finish
