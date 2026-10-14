#!/usr/bin/env bash
# SIR-70 round 4, the 31,000-level case from the re-review. a chain deeper than the walk's bound of 30,000 levels is
# reported by name with a hint, the rest of the undo continues, uninstall fails with the account's state explained, and
# after the owner removes the chain a second uninstall finishes. at 2211d8f the helper was killed for memory first.
# harness-apparmor: unconfined
# (why: the server ba-sing-se's default AppArmor profile rejects this deliberately deep chain (about 62,000 bytes of path, past the
# 30,000-level bound) with ENAMETOOLONG; Omashu has no AppArmor. the depth must not be lowered. no other isolation changes: no host
# folder, no network, same capabilities and caps)
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
mkdir -p /srv/work && echo base > /srv/work/f && chown -R owner:owner /srv/work
cat > /tmp/chain.py <<'PY'
import os, sys
os.chdir(sys.argv[1])
for _ in range(int(sys.argv[2])):
    os.mkdir("d")
    os.chdir("d")
PY
check_exit "install builder applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
check_exit "the agent makes a chain of 31,000 folders" 0 runuser -u agent -- python3 /tmp/chain.py /srv/work 31000

check_exit "uninstall fails loudly" 4 bash /var/lib/sirven/package/uninstall.sh
printf '%s\n' "$(grep -E 'error:|recovery|locked' <<< "$LAST_OUTPUT" | cut -c1-200 | head -6 | sed 's/^/        /')"
check "it names the bound" grep -q 'deeper than 30000 levels' <<< "$LAST_OUTPUT"
check "it says how to recover" grep -q 'recovery:' <<< "$LAST_OUTPUT"
check "it says the account is locked until uninstall finishes" grep -q 'locked and expired until uninstall finishes' <<< "$LAST_OUTPUT"
check "no traceback" bash -c '! grep -q Traceback <<< "$0"' "$LAST_OUTPUT"
check "the rest of the tree was undone: the file beside the chain has no entry of the agent" \
  bash -c '! getfacl -n -p /srv/work/f | grep -Eq "^user:[0-9]+:"'

check_exit "the owner removes the chain with rm -r" 0 rm -rf /srv/work/d
check_exit "a second uninstall finishes" 0 bash /var/lib/sirven/package/uninstall.sh
check "the service user is gone" bash -c '! getent passwd agent'

finish
