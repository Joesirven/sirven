#!/usr/bin/env bash
# SIR-70 round 2, must fix 6. the folder is owned by a user number with no account name (a deleted account,
# a mounted volume). install must apply and use the number. at 66e31fe setfacl was given the name UNKNOWN
# and the install stopped at step 22 with a half grant.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

mkdir -p /srv/work && echo old > /srv/work/old.txt && chown -R 4242:4242 /srv/work
check "precondition: user 4242 has no account name" bash -c '! getent passwd 4242'
world_aclraw_attributes /srv > /tmp/before.raw

check_exit "install builder on a folder owned by 4242 applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
check "the agent can write a new file" runuser -u agent -- sh -c 'echo from-agent > /srv/work/from-agent'
check "the folder's owner (4242) can read what the agent wrote" setpriv --reuid=4242 --regid=4242 --clear-groups cat /srv/work/from-agent
check "new files inherit the owner entry by number" bash -c 'getfacl -n -p --omit-header /srv/work | grep -qx "default:user:4242:rwx"'
check "no entry is written for the name UNKNOWN" bash -c '! getfacl -p /srv/work 2>&1 | grep -q UNKNOWN'

check_exit "uninstall applies" 0 bash /var/lib/sirven/package/uninstall.sh
rm -f /srv/work/from-agent
world_unchanged "every list, owner, and mode is back exactly" aclraw_attributes /tmp/before.raw /srv

finish
