#!/usr/bin/env bash
# SIR-70 round 4, must fix C. memory used by undo and by the install-time check must not grow with the depth times
# the length of the names. the agent builds 3,000 levels of 255-character folder names (a path of 768,000 bytes) and,
# in a second tree, hundreds of thousands of long-named files; the walk keeps no path per open folder and no listing
# for a folder it let go. peak memory of the largest process must stay under 60 MB (measured: 24 and 18) in the
# check and in uninstall. at 2211d8f the first tree took about 1 GB and was killed in a 256 MB container.
# harness-apparmor: unconfined
# (why: the server ba-sing-se's default AppArmor profile rejects this deliberately deep first tree (about 768,000 bytes of path)
# with ENAMETOOLONG; Omashu has no AppArmor. the depth must not be lowered. no other isolation changes: no host folder, no network,
# same capabilities and caps)
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
mkdir -p /srv/work /srv/files && echo base > /srv/work/f && chown -R owner:owner /srv/work /srv/files
cat > /tmp/chain.py <<'PY'
import os, sys
os.chdir(sys.argv[1])
name = "x" * int(sys.argv[3])
for _ in range(int(sys.argv[2])):
    os.mkdir(name)
    os.chdir(name)
open("bottom", "w").write("x")
PY
cat > /tmp/files.py <<'PY'
import os, sys
os.chdir(sys.argv[1])
levels, per, length = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
for level in range(levels):
    os.mkdir("d")
    os.chdir("d")
    for number in range(per):
        open(("%d_" % number).ljust(length, "n"), "w").close()
PY
peak() { python3 "$SRC/tests/harness/lib/peak.py" "$@"; }
peak_of() { sed -n 's/^peak-memory-mb \([0-9]*\) .*/\1/p' <<< "$1"; }
under() { [ -n "$2" ] && [ "$2" -lt "$1" ]; }

check_exit "install builder applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work --path /srv/files
check_exit "the agent makes 3,000 levels of 255-character folder names" 0 runuser -u agent -- python3 /tmp/chain.py /srv/work 3000 255
check_exit "the agent makes 300 levels with 800 long-named files each" 0 runuser -u agent -- python3 /tmp/files.py /srv/files 300 800 245

check_exit "the install-time check passes" 0 peak python3 -I "$SRC/lib/access_control_snapshot.py" check agent --tree /srv/work --tree /srv/files --alone /srv
printf "        check: %s\n" "$LAST_OUTPUT"
check "the check stays under 60 MB" under 60 "$(peak_of "$LAST_OUTPUT")"
check_exit "a step down at the folder with the deep tree applies" 0 bash install.sh --yes --level observer --transport none --path /srv/work --path /srv/files

check_exit "uninstall of the deep tree applies" 0 bash -c 'python3 "$0/tests/harness/lib/peak.py" bash /var/lib/sirven/package/uninstall.sh' "$SRC"
printf "        uninstall: %s\n" "$(grep peak-memory <<< "$LAST_OUTPUT")"
check "uninstall stays under 60 MB" under 60 "$(peak_of "$LAST_OUTPUT")"
check "no traceback and no memory error" bash -c '! grep -Eqi "Traceback|MemoryError|Killed" <<< "$0"' "$LAST_OUTPUT"

finish
