#!/usr/bin/env bash
# attack: the owner runs the kill switch from a copy of the package that sits inside a granted folder, so the agent could edit it first.
# (install defaults the granted folder to the current folder, which is often the repository itself.)
set -uo pipefail
. /src/tests/harness/lib/world.sh
mkdir -p /work && cp -r "$SRC" /work/repo && cd /work/repo || exit 2
bash install.sh --yes --level builder --transport none --path /work/repo >/dev/null 2>&1
echo "granted: $(getfacl -p /work/repo 2>/dev/null | grep user:agent | head -1)"
# the agent edits the library the kill switch sources
runuser -u agent -- bash -c 'printf "\ntouch /tmp/ROOT-RAN-AGENT-CODE\n" >> /work/repo/lib/kill_switch.sh && echo "agent edited lib/kill_switch.sh"'
out="$(bash install.sh revoke --all --yes --transport none 2>&1)"; echo "revoke from the granted copy: exit $?"
ls -l /tmp/ROOT-RAN-AGENT-CODE 2>&1 | head -1
check "the kill switch did not run code the agent edited" bash -c '[ ! -e /tmp/ROOT-RAN-AGENT-CODE ]'
# and the same from the pinned copy, which root owns
rm -f /tmp/ROOT-RAN-AGENT-CODE
ls -ld /var/lib/sirven/package /var/lib/sirven/package/lib | head -2
finish
