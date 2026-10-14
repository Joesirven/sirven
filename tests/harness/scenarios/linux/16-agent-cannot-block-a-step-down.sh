#!/usr/bin/env bash
# SIR-70 round 3, must fix A. the refusal is exact: it fires only when granting would switch on bits the mask
# now switches off for another account, and never for a path the agent owns. so (1) an entry that already fits
# inside the mask does not block a grant, (2) the agent putting a named entry on its own file cannot block a level
# change or a rollback, (3) an owner's chmod 600 does not block a re-grant and the group stays shut out, (4) the one
# case that is still refused: bob's read would be switched back on.
# at 1ce7450 every named entry for another account blocked the grant, wherever it was and whoever made it.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
useradd -m neighbor
useradd -m bob
mkdir -p /srv/work && echo base > /srv/work/f && chown -R owner:owner /srv/work && chmod 755 /srv/work && chmod 644 /srv/work/f
setfacl -m u:bob:r-- /srv/work/f
check "precondition: bob can read the file and cannot write it" bash -c 'runuser -u bob -- cat /srv/work/f >/dev/null && ! runuser -u bob -- sh -c "echo x >> /srv/work/f" 2>/dev/null'

check_exit "install builder over an entry that fits inside the mask applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
check "during the grant bob can still only read the file" bash -c 'runuser -u bob -- cat /srv/work/f >/dev/null && ! runuser -u bob -- sh -c "echo x >> /srv/work/f" 2>/dev/null'

# the agent makes a file and gives another account an entry the mask switches off
check "the agent makes its own file with a wide entry and a narrow mask" \
  runuser -u agent -- sh -c 'echo mine > /srv/work/mine && setfacl -m u:neighbor:rw- /srv/work/mine && setfacl -m m::r-- /srv/work/mine'
check_exit "install observer (a step down) is not blocked" 0 bash install.sh --yes --level observer --transport none --path /srv/work
check "the agent cannot write any more" bash -c '! runuser -u agent -- sh -c "echo x > /srv/work/by-agent" 2>/dev/null'
check_exit "install builder (a step up) is not blocked either" 0 bash install.sh --yes --level builder --transport none --path /srv/work
check_exit "rollback of that step up is not blocked" 0 bash /var/lib/sirven/package/bin/sirven grant rollback
check "the rollback took effect: the agent cannot write" bash -c '! runuser -u agent -- sh -c "echo x > /srv/work/by-agent" 2>/dev/null'

# the owner's chmod 600 on a file with no entry for another account, then a re-grant: nobody gains anything
echo plain > /srv/work/g && chown owner:owner /srv/work/g && chmod 644 /srv/work/g
check_exit "re-grant so the new file has the agent's entry" 0 bash install.sh --yes --level builder --transport none --path /srv/work
runuser -u owner -- chmod 600 /srv/work/g
check_exit "a re-grant after the owner's chmod 600 applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
check "neighbor still cannot read the owner's private file" bash -c '! runuser -u neighbor -- cat /srv/work/g 2>/dev/null'
check "the group entry is shut" bash -c 'getfacl -p --omit-header /srv/work/g | grep -qx "group::---"'

# the one case that is refused: bob's entry r-- on a file whose mask the owner then narrowed to nothing. a re-grant
# would raise the mask and give bob the read the owner switched off.
runuser -u owner -- chmod 600 /srv/work/f
check_exit "a re-grant that would switch bob's read back on is refused" 2 bash install.sh --yes --level builder --transport none --path /srv/work
check "the message names the file and the entry" grep -q '^  /srv/work/f (.*bob' <<< "$LAST_OUTPUT"
check "bob still cannot read it" bash -c '! runuser -u bob -- cat /srv/work/f 2>/dev/null'

check_exit "uninstall applies" 0 bash /var/lib/sirven/package/uninstall.sh
check "the owner's chmod 600 stayed" bash -c '[ "$(stat -c %a /srv/work/f)" = 600 ] && [ "$(stat -c %a /srv/work/g)" = 600 ]'

finish
