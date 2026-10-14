#!/usr/bin/env bash
# SIR-70 round 2, must fix 1 for rollback. builder grant, then a second install at observer level, then the
# owner and root change modes, then `sirven grant rollback` back to builder. the changes must stay. at 66e31fe
# rollback put the world-readable bit the owner had removed back (664).
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
useradd -m neighbor
mkdir -p /srv/work && chown owner:owner /srv/work && chmod 755 /srv/work
echo g > /srv/work/g && chown owner:owner /srv/work/g && chmod 644 /srv/work/g
world_aclraw /srv > /tmp/before.raw

check_exit "install builder applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
check_exit "install observer (a level change) applies" 0 bash install.sh --yes --level observer --transport none --path /srv/work
runuser -u owner -- chmod 600 /srv/work/g
chmod 700 /srv
check_exit "rollback applies" 0 bash /var/lib/sirven/package/bin/sirven grant rollback
# while a grant is in force stat shows the mask in the group position (660 here), so the test is the list itself:
# the owner's chmod 600 means group and other have nothing, and the grant must not give that bit back.
check "the owner's chmod 600 stayed after the rollback: group and other still have nothing" \
  bash -c 'getfacl -p --omit-header /srv/work/g | grep -qx "group::---" && getfacl -p --omit-header /srv/work/g | grep -qx "other::---"'
check "another account still cannot read it" bash -c '! runuser -u neighbor -- cat /srv/work/g 2>/dev/null'
check "root's chmod 700 on the parent stayed after the rollback: group and other still have nothing" \
  bash -c 'getfacl -p --omit-header /srv | grep -qx "group::---" && getfacl -p --omit-header /srv | grep -qx "other::---"'
check "the earlier level (builder) is back: the agent can write a new file" runuser -u agent -- sh -c 'echo x > /srv/work/by-agent'

check_exit "uninstall applies" 0 bash /var/lib/sirven/package/uninstall.sh
check "the owner's chmod 600 stayed after uninstall" bash -c '[ "$(stat -c %a /srv/work/g)" = 600 ]'
check "root's chmod 700 stayed after uninstall" bash -c '[ "$(stat -c %a /srv)" = 700 ]'
rm -f /srv/work/by-agent
world_unchanged "no permission list is left anywhere" aclraw /tmp/before.raw /srv

finish
