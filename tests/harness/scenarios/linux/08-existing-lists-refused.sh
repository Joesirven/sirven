#!/usr/bin/env bash
# SIR-70 round 2, must fix 3. a tree that already has named entries for other accounts, or a mask, is
# refused before anything changes: granting would recalculate the mask and widen another account's access.
# the message lists up to ten paths and says how to go on. at 66e31fe the install applied and bob could
# append to a file he could only read.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m bob
mkdir -p /srv/work/d && echo data > /srv/work/f && chmod 644 /srv/work/f
setfacl -m u:bob:rw- /srv/work/f && setfacl -m m::r-- /srv/work/f
setfacl -m u:bob:rwx /srv/work/d && setfacl -m m::r-x /srv/work/d
world_aclraw_attributes /srv > /tmp/before.raw
world_accounts > /tmp/before.accounts
check "precondition: bob cannot append to the file" bash -c '! runuser -u bob -- sh -c "echo x >> /srv/work/f" 2>/dev/null'
check "precondition: bob cannot create a file in the folder" bash -c '! runuser -u bob -- touch /srv/work/d/new 2>/dev/null'

check_exit "install builder on a tree with named entries is refused" 2 bash install.sh --yes --level builder --transport none --path /srv/work
check "the message names the file and why" grep -q '^  /srv/work/f (' <<< "$LAST_OUTPUT"
check "the message names the folder and why" grep -q '^  /srv/work/d (' <<< "$LAST_OUTPUT"
check "the message says nothing was changed" grep -q 'nothing was changed' <<< "$LAST_OUTPUT"
check "the message says how to go on" grep -qi 'remove' <<< "$LAST_OUTPUT"
world_unchanged "no permission list or mode changed" aclraw_attributes /tmp/before.raw /srv
world_unchanged "no account was created" accounts /tmp/before.accounts
check "bob still cannot append to the file" bash -c '! runuser -u bob -- sh -c "echo x >> /srv/work/f" 2>/dev/null'
check "bob still cannot create a file in the folder" bash -c '! runuser -u bob -- touch /srv/work/d/new 2>/dev/null'

# a pass-through parent with a named entry is refused too
mkdir -p /data/proj/app && setfacl -m u:bob:r-x /data/proj
check_exit "install on a folder whose parent has a named entry is refused" 2 bash install.sh --yes --level observer --transport none --path /data/proj/app
check "the message names the parent and why" grep -q '^  /data/proj (' <<< "$LAST_OUTPUT"

# at most ten paths are listed
mkdir -p /srv/many
for number in 1 2 3 4 5 6 7 8 9 10 11 12 13; do touch "/srv/many/file$number"; setfacl -m u:bob:r-- "/srv/many/file$number"; done
check_exit "a tree with thirteen such files is refused" 2 bash install.sh --yes --level observer --transport none --path /srv/many
check "the message lists ten paths and counts the rest" bash -c '[ "$(grep -c "^  /srv/many/" <<< "$0")" = 10 ] && grep -q "3 more" <<< "$0"' "$LAST_OUTPUT"

# the way out the message names works
setfacl -R -b /srv/work /srv/many /data/proj
check_exit "after the lists are removed the install applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work

finish
