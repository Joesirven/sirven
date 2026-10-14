#!/usr/bin/env bash
# SIR-70 round 4, must fix D. a subtree moved while the walk is deep must not be skipped in silence. 60 levels, 20
# files beside level 12, in level 11. while the walk lists level 60 (a hook, so the timing is exact), level 12 is moved
# out of the tree and level 1 is renamed: level 11 can no longer be reached by identity or by name. the run must fail
# and say so, and a second run after the tree is put back must remove every entry. at 2211d8f it exited 0 and left
# the agent's entry on all 20 files.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
mkdir -p /srv/work
level=/srv/work
for number in $(seq 1 60); do level="$level/d$number"; mkdir "$level"; [ "$number" = 11 ] && eleven="$level"; done
for number in $(seq 1 20); do echo "f$number" > "$eleven/f$number"; done
chown -R owner:owner /srv/work

check_exit "install builder applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
check "precondition: the 20 files hold the agent's entry" bash -c '[ "$(getfacl -n -p '"$eleven"'/f* | grep -Ec "^user:[0-9]+:")" = 20 ]'

# the run that loses level 11
python3 -I "$SRC/tests/harness/lib/lost_subtree.py" "$SRC/lib/access_control_snapshot.py" > /tmp/lost.out 2>&1
printf '%s\n' "$(sed 's/^/        /' /tmp/lost.out | head -12)"
check "the hook fired while the walk was deep" grep -q 'fired=1' /tmp/lost.out
check "the run failed (status 1), not exit 0" grep -q '^status=1 ' /tmp/lost.out
check "it said the folder was lost and the names not visited" grep -q 'moved, replaced or removed while it was being read' /tmp/lost.out
check "it printed a recovery line" grep -q '^recovery:' /tmp/lost.out

# the tree is put back by the driver; a second run finishes the job
check_exit "a second repair after the tree is back applies" 0 bash "$SRC/lib/access_control_snapshot.sh" repair /srv/work yes agent
check "no file holds an entry of the agent any more" bash -c '[ "$(getfacl -n -p '"$eleven"'/f* | grep -Ec "^user:[0-9]+:")" = 0 ]'

finish
