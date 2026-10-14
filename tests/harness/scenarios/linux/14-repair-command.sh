#!/usr/bin/env bash
# SIR-70 round 2, must fix 5, the one-off repair. an install made before snapshots existed has no snapshot
# and an undo command that removes only one entry. `access_control_snapshot.sh repair` removes what the grant
# added (the agent's and the owner's entries, the default list, the mask) from a folder and from a parent, from
# a checkout of this package, with no snapshot. it must leave modes alone and say so.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
mkdir -p /srv/work/sub && echo f > /srv/work/sub/f && echo g > /srv/work/g && chown -R owner:owner /srv/work
world_aclraw_attributes /srv > /tmp/before.raw

check_exit "install builder on /srv/work applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
rm -rf /var/lib/sirven/access-lists
runuser -u owner -- chmod 600 /srv/work/g
check_exit "repair the granted folder" 0 bash lib/access_control_snapshot.sh repair /srv/work yes agent
check_exit "repair the pass-through parent" 0 bash lib/access_control_snapshot.sh repair /srv no agent
check "the owner's chmod 600 stayed" bash -c '[ "$(stat -c %a /srv/work/g)" = 600 ]'
check "no entry of the agent is left" bash -c '! getfacl -R -n -p /srv 2>/dev/null | grep -Eq "^(default:)?user:[0-9]+:"'
check_exit "repair run twice changes nothing" 0 bash lib/access_control_snapshot.sh repair /srv/work yes agent
chmod 644 /srv/work/g
check_exit "uninstall still applies afterwards" 0 bash /var/lib/sirven/package/uninstall.sh
world_unchanged "every list, owner, and mode is back exactly" aclraw_attributes /tmp/before.raw /srv

finish
