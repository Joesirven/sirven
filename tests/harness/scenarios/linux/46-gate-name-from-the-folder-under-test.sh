#!/usr/bin/env bash
# SIR-32 round 3 (review e1b, e1c). the gate must not take the location of the kept copy, or the checker that judges it, from the
# folder under test. the agent changes one field of project.json in the granted folder so the kept copy would be a folder of its
# own (with an entry script that touches a file, and a checker that always says yes). the owner's install.sh is unedited.
# the kept copy is a constant, so the agent's folder is never run; and the package name itself is refused unless plain.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"

mkdir -p /work && cp -r "$SRC" /work/repo && cd /work/repo || exit 2
cp install.sh /tmp/install.sh.orig
check_exit "first install from a copy only root can write applies" 0 bash install.sh --yes --level builder --transport none --path /work/repo
check "the agent builds its own 'kept copy' with a payload and a checker that always says yes, and redirects project.json to it" runuser -u agent -- bash -c '
  mkdir -p /tmp/evil && cp -r /work/repo /tmp/evil/package &&
  sed -i "2i touch /tmp/ROOT-RAN-AGENT-CODE; id -u > /tmp/ROOT-RAN-AGENT-CODE" /tmp/evil/package/install.sh &&
  printf "import sys\nsys.exit(0)\n" > /tmp/evil/package/lib/trust.py &&
  sed -i "s|\"name\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"name\": \"../../tmp/evil\"|" /work/repo/project.json'
check "precondition: the owner's install.sh is byte for byte unedited" cmp install.sh /tmp/install.sh.orig
check "precondition: project.json now names the agent's folder" grep -q '../../tmp/evil' project.json
setsid runuser -u agent -- sleep 600 >/dev/null 2>&1 &
sleep 0.3
check_exit "revoke started from the granted copy applies" 0 bash install.sh revoke --all --yes --transport none
check "it ran the constant kept copy, not the agent's" grep -q 'running the kept copy /var/lib/sirven/package instead of /work/repo' <<< "$LAST_OUTPUT"
check "the agent's code did not run as root" bash -c '[ ! -e /tmp/ROOT-RAN-AGENT-CODE ] && [ -f /etc/sirven/grants/agent.json.revoked ]'
check "the agent is cut off" bash -c '! pgrep -u agent && passwd --status agent | grep -q "^agent L"'

# a package name that is not plain is refused by the package itself, before anything is changed
rm -rf /work/badname && cp -r "$SRC" /work/badname && cd /work/badname || exit 2
sed -i 's|"name"[[:space:]]*:[[:space:]]*"[^"]*"|"name": "../../tmp/evil"|' project.json
check_exit "a package name with slashes and dots is refused" 1 bash install.sh --dry-run --level observer --transport none
check "it says the name is not plain" grep -q "is not a plain lowercase name" <<< "$LAST_OUTPUT"
finish
