#!/usr/bin/env bash
# SIR-70 round 3, must fix B. the agent makes a chain of 12,000 folders (cheap with relative paths). undo walks
# it without recursion and without a descriptor per level, even with an open-file limit of 1,024. at 1ce7450 the
# walk was recursive: uninstall exited 4 with a RecursionError traceback and left the account locked, and about
# 1,000 levels were enough under a 1,024 limit.
# harness-apparmor: unconfined
# (why: the server ba-sing-se's default AppArmor profile rejects this deliberately deep chain (about 24,000 bytes of path) with
# ENAMETOOLONG; Omashu has no AppArmor. the depth must not be lowered. no other isolation changes: no host folder, no network,
# same capabilities and caps)
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
mkdir -p /srv/work && echo base > /srv/work/f && chown -R owner:owner /srv/work

# levels_with_lists FOLDER: how many levels of the chain under FOLDER carry a permission list attribute.
cat > /tmp/levels.py <<'PY'
import os, sys
os.chdir(sys.argv[1])
count = depth = 0
while True:
    names = os.listxattr(".", follow_symlinks=False)
    if any(n.startswith("system.posix_acl") for n in names):
        count += 1
    if not os.path.isdir("d") or os.path.islink("d"):
        break
    os.chdir("d")
    depth += 1
print(count, depth)
PY
cat > /tmp/chain.py <<'PY'
import os, sys
os.chdir(sys.argv[1])
for _ in range(int(sys.argv[2])):
    os.mkdir("d")
    os.chdir("d")
open("bottom", "w").write("x")
PY

check_exit "install builder applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
check_exit "the agent makes a chain of 12,000 folders" 0 runuser -u agent -- python3 /tmp/chain.py /srv/work 12000
check "every level carries the grant's lists while it is in force" bash -c '[ "$(python3 /tmp/levels.py /srv/work | cut -d" " -f1)" -ge 12000 ]'

# the usual soft limit of a login shell
check_exit "uninstall applies under an open-file limit of 1,024" 0 bash -c 'ulimit -n 1024; bash /var/lib/sirven/package/uninstall.sh'
check "no traceback is printed" bash -c '! grep -q Traceback <<< "$0"' "$LAST_OUTPUT"
check "no level of the chain carries a list attribute afterwards" bash -c '[ "$(python3 /tmp/levels.py /srv/work | cut -d" " -f1)" = 0 ]'
check "the chain is still 12,000 deep (nothing was skipped or removed)" bash -c '[ "$(python3 /tmp/levels.py /srv/work | cut -d" " -f2)" -ge 12000 ]'
check "the service user is gone" bash -c '! getent passwd agent'

finish
