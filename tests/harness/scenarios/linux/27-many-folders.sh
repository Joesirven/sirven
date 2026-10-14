#!/usr/bin/env bash
# SIR-70 round 5, must fix E. memory must not grow with the number of folders. the agent makes 300,000 empty folders
# (about 8 s of work). the snapshot keeps only paths that held a list (none of these did), is written as the walk goes
# and is looked up on disk, never loaded. a rollback to a lower level (which records again at its re-grant) and then
# uninstall each stay far under 100 MB and the snapshot stays small. at b9e1b21 recording peaked at 239 MB with a 72 MB
# snapshot and restoring at 335 MB.
# harness-memory: 3g
# (the kernel's own cache of 300,000 folders with inherited lists is what needs 3 GB; the helper needs 15 MB)
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
mkdir -p /srv/work && echo base > /srv/work/f && chown -R owner:owner /srv/work
cat > /tmp/folders.py <<'PY'
import os, sys
os.chdir(sys.argv[1])
for outer in range(300):
    os.mkdir("o%d" % outer)
    for inner in range(1000):
        os.mkdir("o%d/i%d" % (outer, inner))
PY
peak_of() { sed -n 's/^peak-memory-mb \([0-9]*\) .*/\1/p' <<< "$1"; }
under() { [ -n "$2" ] && [ "$2" -lt "$1" ]; }

check_exit "install observer applies" 0 bash install.sh --yes --level observer --transport none --path /srv/work
check_exit "install builder applies (the level a rollback will leave)" 0 bash install.sh --yes --level builder --transport none --path /srv/work
check_exit "the agent makes 300,000 empty folders" 0 runuser -u agent -- python3 /tmp/folders.py /srv/work
check "300,300 folders are there" bash -c '[ "$(find /srv/work -type d | wc -l)" -ge 300300 ]'

check_exit "rollback to the lower level applies" 0 python3 "$SRC/tests/harness/lib/peak.py" bash /var/lib/sirven/package/bin/sirven grant rollback
printf '        rollback: %s\n' "$(grep peak-memory <<< "$LAST_OUTPUT")"
check "rollback stays under 100 MB" under 100 "$(peak_of "$LAST_OUTPUT")"
check "the snapshot it wrote is small (under 2 MB)" bash -c 'total=0; for f in /var/lib/sirven/access-lists/*; do total=$((total + $(stat -c %s "$f"))); done; echo "        snapshots: $total bytes"; [ "$total" -lt 2000000 ]'
check "the agent cannot write any more (observer)" bash -c '! runuser -u agent -- sh -c "echo x > /srv/work/by-agent" 2>/dev/null'

check_exit "uninstall applies" 0 python3 "$SRC/tests/harness/lib/peak.py" bash /var/lib/sirven/package/uninstall.sh
printf '        uninstall: %s\n' "$(grep peak-memory <<< "$LAST_OUTPUT")"
check "uninstall stays under 100 MB" under 100 "$(peak_of "$LAST_OUTPUT")"
check "no folder holds a list attribute afterwards" bash -c '[ "$(getfacl -R -p -s /srv/work 2>/dev/null | grep -c "^# file")" = 0 ]'

finish
