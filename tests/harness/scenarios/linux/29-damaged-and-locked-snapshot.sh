#!/usr/bin/env bash
# SIR-70 round 6, should fix 3 and 4. (3) a snapshot whose header and tables are fine but whose middle pages are
# overwritten is treated like any other unusable one: the grant's entries are removed, the warning is loud and goes to
# the audit log, uninstall finishes (exit 0), and the file is renamed aside (not deleted) and its new name is printed.
# (4) a snapshot held under a lock by another process is not unusable: undo waits a bounded time, then fails with the
# file untouched and says so; once the lock is gone, the same command finishes and puts the owner's own lists back.
# at fa208c7 the first case ended in "unexpected DatabaseError" and a rerun failed the same way, and the second
# fell back, losing the owner's lists, and deleted the intact snapshot.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
mkdir -p /srv/work && chown owner:owner /srv/work
# 6,000 folders, each with a default list of the owner's own, so the snapshot has many pages
cat > /tmp/lists.py <<'PY'
import os, struct
blob = struct.pack("<I", 2) + b"".join(struct.pack("<HHI", tag, perm, 0xFFFFFFFF) for tag, perm in ((1, 7), (4, 5), (0x20, 5)))
for number in range(6000):
    path = "/srv/work/f%d" % number
    os.makedirs(path, exist_ok=True)
    os.setxattr(path, "system.posix_acl_default", blob)
    os.chown(path, int(os.environ["OWNER_ID"]), int(os.environ["OWNER_ID"]))
PY
make_lists() { OWNER_ID="$(id -u owner)" python3 /tmp/lists.py; }
make_lists
world_aclraw_attributes /srv > /tmp/before.raw
snapshot_file() { ls /var/lib/sirven/access-lists/*.txt 2>/dev/null | while read -r f; do [ "$(stat -c %s "$f")" -gt 100000 ] && echo "$f"; done | head -1; }

# ---- damaged in the middle
check_exit "install builder applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
snap="$(snapshot_file)"
check "precondition: the snapshot is a large file" test -n "$snap"
python3 - "$snap" <<'PY'
import os, sys
path = sys.argv[1]
size = os.path.getsize(path)
with open(path, "r+b") as handle:
    handle.seek(size // 3)
    handle.write(os.urandom(4096 * 6))
PY
check_exit "uninstall applies" 0 bash /var/lib/sirven/package/uninstall.sh
printf '%s\n' "$(grep -E 'warning' <<< "$LAST_OUTPUT" | cut -c1-260 | head -3 | sed 's/^/        /')"
check "no DatabaseError and no traceback" bash -c '! grep -Eq "DatabaseError|Traceback" <<< "$0"' "$LAST_OUTPUT"
check "it warns that the snapshot is damaged" grep -q 'is damaged' <<< "$LAST_OUTPUT"
check "it says where the snapshot was set aside" grep -q 'set aside as /var/lib/sirven/access-lists/.*\.unusable-' <<< "$LAST_OUTPUT"
check "the file is there under that name, not deleted" bash -c 'ls /var/lib/sirven/access-lists/*.unusable-* >/dev/null 2>&1'
check "the audit log has the warning" bash -c 'grep "\"event\": \"warning\"" /var/log/sirven/audit.jsonl | grep -q "damaged"'
check "no entry of the agent is left on any folder" bash -c '! getfacl -R -n -p /srv/work | grep -Eq "^(default:)?user:[0-9]+:"'
check "the service user is gone" bash -c '! getent passwd agent'
rm -rf /var/lib/sirven/access-lists

# ---- locked (the first uninstall lost the owner's lists, as warned, so make them again)
make_lists
check_exit "install builder applies again" 0 bash install.sh --yes --level builder --transport none --path /srv/work
snap="$(snapshot_file)"
before_sum="$(sha256sum "$snap" | cut -d' ' -f1)"
python3 -c "
import sqlite3, sys, time
connection = sqlite3.connect(sys.argv[1], isolation_level=None)
connection.execute('BEGIN EXCLUSIVE')
print('locked', flush=True)
time.sleep(600)" "$snap" > /tmp/lock.out 2>&1 &
holder=$!
sleep 1
check "precondition: the other process holds the lock" grep -q locked /tmp/lock.out
check_exit "uninstall fails (exit 4) while the snapshot is locked" 4 env SIRVEN_SNAPSHOT_WAIT=1 bash /var/lib/sirven/package/uninstall.sh
check "it says the snapshot is in use and was left untouched" grep -q 'in use by another process.*left untouched' <<< "$LAST_OUTPUT"
check "it says how to go on" grep -q 'run the same command again' <<< "$LAST_OUTPUT"
check "the snapshot file is exactly as it was" bash -c '[ "$(sha256sum "$0" | cut -d" " -f1)" = "$1" ]' "$snap" "$before_sum"
check "it was not set aside" bash -c '! ls /var/lib/sirven/access-lists/*.unusable-* >/dev/null 2>&1'
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
check_exit "after the lock is gone the same uninstall finishes" 0 bash /var/lib/sirven/package/uninstall.sh
check "no warning about an unusable snapshot" bash -c '! grep -q "cannot be used\|is damaged" <<< "$0"' "$LAST_OUTPUT"
world_unchanged "the owner's own lists are back exactly: the intact snapshot was used" aclraw_attributes /tmp/before.raw /srv

finish
