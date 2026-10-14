#!/usr/bin/env bash
# e1 again with the payload in the entry script of the agent's copy (the first thing root runs when the gate hands over),
# and the agent's copy left otherwise intact. the owner's install.sh in /work/repo is unedited; only project.json changed.
set -uo pipefail
. /src/tests/harness/lib/world.sh
mkdir -p /work && cp -r "$SRC" /work/repo && cd /work/repo || exit 2
cp install.sh /tmp/install.sh.orig
bash install.sh --yes --level builder --transport none --path /work/repo >/dev/null 2>&1
runuser -u agent -- bash -c '
  mkdir -p /tmp/evil && cp -r /work/repo /tmp/evil/package &&
  sed -i "2i touch /tmp/ROOT-RAN-AGENT-CODE; id -u > /tmp/ROOT-RAN-AGENT-CODE" /tmp/evil/package/install.sh &&
  sed -i "s|\"name\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"name\": \"../../tmp/evil\"|" /work/repo/project.json'
cmp install.sh /tmp/install.sh.orig && echo "the owner's install.sh in /work/repo is unedited"
setsid runuser -u agent -- sleep 600 >/dev/null 2>&1 &
sleep 0.3
out="$(bash install.sh revoke --all --yes --transport none 2>&1)"; st=$?
echo "revoke exit $st"; printf '%s\n' "$out" | head -3
echo "file made by the agent's code: $(ls -l /tmp/ROOT-RAN-AGENT-CODE 2>&1 | cut -c1-60); uid recorded: $(cat /tmp/ROOT-RAN-AGENT-CODE 2>/dev/null)"
check "the agent's code did not run as root" bash -c '[ ! -e /tmp/ROOT-RAN-AGENT-CODE ]'
check "the agent is cut off" bash -c '! pgrep -u agent && passwd --status agent | grep -q "^agent L"'
finish
