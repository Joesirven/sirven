#!/usr/bin/env bash
# SIR-83, uninstall. on a Linux host with AppArmor enforcing (the server ba-sing-se, under its docker-default profile), the agent cannot
# build a deep chain of folders at all: its mkdir fails with ENAMETOOLONG (Errno 36) once the absolute path reaches about 8,000
# bytes (measured: depth 4,090, path 8,189 bytes). this scenario keeps the default profile (no harness-apparmor header), lets the
# agent build the deepest chain it can (up to 12,000 levels, the bound of scenario 17), and asserts that uninstall removes every
# access list in that chain and the service user. the check of the depth is only made when AppArmor is enforcing; on a host
# without AppArmor (Omashu) the chain is simply deeper and the uninstall is checked the same.
# the question this answers is in docs/PERMISSIONS.md: revoke's descriptor walk opens the same folders the agent made, so the
# default profile does not block it. a tree made while the profile was lifted and revoked under it was checked by hand (see docs).
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
mkdir -p /srv/work && echo base > /srv/work/f && chown -R owner:owner /srv/work

# the profile this container runs under: "docker-default (enforce)" on ba-sing-se, "unconfined" or absent elsewhere
profile="$(cat /proc/self/attr/current 2>/dev/null)"
case "$profile" in
  *enforce*) apparmor=yes ;;
  *) apparmor=no ;;
esac

# levels_with_lists FOLDER: how many levels of the chain under FOLDER carry a permission list attribute, and how deep it is.
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
# chain.py: the agent makes folders until the kernel refuses, at most LIMIT, and prints the depth and the reason it stopped
cat > /tmp/chain.py <<'PY'
import os, sys
os.chdir(sys.argv[1])
depth = 0
try:
    while depth < int(sys.argv[2]):
        os.mkdir("d")
        os.chdir("d")
        depth += 1
    print(depth, "limit")
except OSError as error:
    print(depth, error.errno)
PY
chmod 644 /tmp/levels.py /tmp/chain.py

check_exit "install builder applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
built="$(runuser -u agent -- python3 /tmp/chain.py /srv/work 12000)"
depth="${built% *}"
reason="${built#* }"
printf '        the agent made %s levels, stopped by %s (36 is ENAMETOOLONG; limit is the bound of 12,000)\n' "$depth" "$reason"
check "the agent makes a deep chain as far as the profile lets it" bash -c '[ "$1" -ge 100 ] && { [ "$2" = limit ] || [ "$2" = 36 ]; }' _ "$depth" "$reason"
if [ "$apparmor" = yes ]; then
  check "under AppArmor the chain stops at the kernel's name limit (Errno 36), not at the bound" bash -c '[ "$1" = 36 ] && [ "$2" -lt 12000 ]' _ "$reason" "$depth"
else
  skip "under AppArmor the chain stops at Errno 36" "no AppArmor in this container (profile: ${profile:-none})"
fi
check "the chain is built: every level is a folder with a list of the agent's" bash -c '
  [ "$(python3 /tmp/levels.py /srv/work | cut -d" " -f1)" -ge 100 ]'

check_exit "uninstall applies under the same profile" 0 bash /var/lib/sirven/package/uninstall.sh
check "no level of the chain carries a list attribute afterwards" bash -c '[ "$(python3 /tmp/levels.py /srv/work | cut -d" " -f1)" = 0 ]'
check "the chain is still there (uninstall removes lists, not folders)" bash -c '[ "$(python3 /tmp/levels.py /srv/work | cut -d" " -f2)" -ge 100 ]'
check "no traceback is printed" bash -c '! grep -q Traceback <<< "$0"' "$LAST_OUTPUT"
check "the service user is gone" bash -c '! getent passwd agent'
check "no process of the agent is left" bash -c '! pgrep -u agent'

finish
