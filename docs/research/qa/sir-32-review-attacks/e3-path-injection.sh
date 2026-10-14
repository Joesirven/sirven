#!/usr/bin/env bash
# round 2: the owner's PATH holds a folder the agent can write (root's PATH, sudo -E, a login shell). the gate runs id, uname,
# sed, tr, head and python3 before it checks anything. start from the kept copy, the documented safe path.
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
bash install.sh --yes --level observer --transport none >/dev/null 2>&1
mkdir -p /work/agentbin && chown agent /work/agentbin
runuser -u agent -- bash -c 'for c in id uname sed python3; do printf "#!/bin/sh\ntouch /tmp/ROOT-RAN-FAKE-$c\nexec /usr/bin/$c \"\$@\"\n" > /work/agentbin/$c; chmod +x /work/agentbin/$c; done'
rm -f /tmp/ROOT-RAN-FAKE-*
env PATH="/work/agentbin:$PATH" bash /var/lib/sirven/package/install.sh revoke --all --yes --transport none >/tmp/out 2>&1; echo "exit $?"
echo "fake commands that ran as root: $(ls /tmp/ROOT-RAN-FAKE-* 2>/dev/null | sed 's|.*FAKE-||' | tr '\n' ' ')"
check "no command from the agent's folder ran as root" bash -c '! ls /tmp/ROOT-RAN-FAKE-* >/dev/null 2>&1'
finish
