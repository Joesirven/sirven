#!/usr/bin/env bash
# SIR-70 round 4, the two should-fix items. (1) repair with the account already gone removes the default list an older
# undo left (a list with a mask and no entry: the older grant copied the folder's own group and other bits into it),
# and `sirven grant repair --path` works when the grant record is gone too. (2) a path that had a named entry and a mask
# before the grant gets its recorded mask back, not the wider one the grant raised it to.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m bob
useradd -m owner
# (1) what an older undo left: no agent account, no record; a default list with a mask, and masks on files
mkdir -p /srv/app/sub && echo f > /srv/app/f && echo g > /srv/app/sub/g && chown -R owner:owner /srv/app
world_aclraw_attributes /srv > /tmp/before.raw
setfacl -d -m u::rwx,g::r-x,o::r-x,m::r-x /srv/app /srv/app/sub
setfacl -m m::r-x /srv/app/f /srv/app/sub/g /srv/app
check "precondition: the leftovers are there" bash -c 'getfacl -p /srv/app | grep -q "^default:mask::r-x" && getfacl -p /srv/app/f | grep -q "^mask::r-x"'
check "precondition: there is no account agent" bash -c '! getent passwd agent'
check_exit "repair dry run lists what it would remove" 0 bash bin/sirven grant repair --path /srv/app --dry-run
check "it names the folder" grep -q 'would change /srv/app' <<< "$LAST_OUTPUT"
check "the dry run changed nothing" bash -c 'getfacl -p /srv/app | grep -q "^default:mask::r-x"'
check_exit "repair applies" 0 bash bin/sirven grant repair --path /srv/app
world_unchanged "the default list and the masks are gone: every list, owner, and mode is as it was" aclraw_attributes /tmp/before.raw /srv

# (2) the recorded mask comes back
mkdir -p /srv/work && echo base > /srv/work/f && chown -R owner:owner /srv/work && chmod 644 /srv/work/f
setfacl -m u:bob:r-- /srv/work/f
world_aclraw_attributes /srv/work > /tmp/work.before
check "precondition: the mask is r--" bash -c 'getfacl -p /srv/work/f | grep -q "^mask::r--"'
check_exit "install builder applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
check "during the grant the mask is wider (rw-)" bash -c 'getfacl -p /srv/work/f | grep -q "^mask::rw-"'
check_exit "uninstall applies" 0 bash /var/lib/sirven/package/uninstall.sh
check "the mask is r-- again" bash -c 'getfacl -p /srv/work/f | grep -q "^mask::r--"'
check "bob still has his entry, read only" bash -c 'getfacl -p /srv/work/f | grep -q "^user:bob:r--" && runuser -u bob -- cat /srv/work/f >/dev/null && ! runuser -u bob -- sh -c "echo x >> /srv/work/f" 2>/dev/null'
world_unchanged "the file is exactly as it was: list, owner, mode" aclraw_attributes /tmp/work.before /srv/work

finish
