#!/usr/bin/env bash
# SIR-70 round 3, should fix 1 and 4. (1) a run stops after the account was locked and before it was given back
# (simulated: the helper's quiesce is run by hand, which leaves the marker and the locked, expired account). a
# re-run at the same level must give the account back, not judge the step done. (2) a grant that stopped partway
# (simulated: one file's entry is stripped) must be finished by a re-run, not judged done because the folder
# itself has the entry. at 1ce7450 neither was done.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
mkdir -p /srv/work/sub && echo f > /srv/work/sub/f && echo g > /srv/work/g && chown -R owner:owner /srv/work
helper=/var/lib/sirven/package/lib/access_control_snapshot.sh

check_exit "install builder applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
check_exit "simulate a run that stopped after locking the account" 0 bash $helper quiesce agent /var/lib/sirven/agent-quiesce.json
check "precondition: the account is locked and expired" bash -c '[ "$(getent shadow agent | cut -d: -f2)" = "!*" ] && [ -n "$(getent shadow agent | cut -d: -f8)" ]'
check_exit "a re-run at the same level applies" 0 bash install.sh --yes --level builder --transport none --path /srv/work
check "the account is back as it was: password login off, never expires" \
  bash -c '[ "$(getent shadow agent | cut -d: -f2)" = "*" ] && [ -z "$(getent shadow agent | cut -d: -f8)" ]'
check "the marker is gone" bash -c '[ ! -e /var/lib/sirven/agent-quiesce.json ]'

setfacl -x u:agent /srv/work/sub/f
check "precondition: the file lost the agent's entry" bash -c '! getfacl -p /srv/work/sub/f | grep -q "^user:agent:"'
check_exit "a re-run finishes the partial grant" 0 bash install.sh --yes --level builder --transport none --path /srv/work
check "the file has the agent's entry again" bash -c 'getfacl -p /srv/work/sub/f | grep -q "^user:agent:rw"'
check_exit "another re-run finds everything in place and leaves the agent alone" 0 bash install.sh --yes --level builder --transport none --path /srv/work
check "that re-run skipped the grant steps" grep -q 'skipped 2[0-9] already done' <<< "$LAST_OUTPUT"

check_exit "uninstall applies" 0 bash /var/lib/sirven/package/uninstall.sh

finish
