#!/usr/bin/env bash
# SIR-70 round 3, should fix 5. `repair` works after an old uninstall already removed the account (simulated: the
# snapshot is deleted and the account removed by hand, leaving the grant's entries on the folders). it lists what it
# will remove, --dry-run changes nothing, and the real run leaves the lists as they were before the install.
# at 1ce7450 repair exited 1 "the account agent is gone".
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
mkdir -p /srv/work/sub && echo f > /srv/work/sub/f && chown -R owner:owner /srv/work
world_aclraw_attributes /srv > /tmp/before.raw
check_exit "install builder applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
runuser -u owner -- sh -c 'echo made-under-grant > /srv/work/new'
rm -rf /var/lib/sirven/access-lists
pkill -KILL -u agent; userdel agent
check "precondition: the account is gone" bash -c '! getent passwd agent'
check "precondition: the grant's entries are still on the folder" bash -c 'getfacl -p /srv/work | grep -q "^default:"'

helper=/src/lib/access_control_snapshot.sh
check_exit "dry run lists what it would remove" 0 bash $helper repair /srv/work yes agent --dry-run
check "it says it would change the folder" grep -q 'would change /srv/work' <<< "$LAST_OUTPUT"
check "a dry run changed nothing" bash -c 'getfacl -p /srv/work | grep -q "^default:"'
check_exit "repair the granted folder" 0 bash $helper repair /srv/work yes agent
check "it printed what it changed" grep -q 'changed /srv/work' <<< "$LAST_OUTPUT"
check_exit "repair the pass-through parent" 0 bash $helper repair /srv no agent
rm -f /srv/work/new
world_unchanged "every list, owner, and mode is back exactly" aclraw_attributes /tmp/before.raw /srv

finish
