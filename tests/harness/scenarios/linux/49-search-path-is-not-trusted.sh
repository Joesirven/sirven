#!/usr/bin/env bash
# SIR-32 round 3 (review e3). the owner's PATH holds a folder the agent can write (sudo -E, a kept PATH, a root shell with a
# user folder on its path). as root every entry script resets PATH first and names the tools the gate uses by absolute path, so
# a fake id, uname, sed, tr, head, python3, dirname or readlink in that folder never runs, from the kept copy or from the first
# install. both are tried.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

plant() {
  mkdir -p /work/agentbin && chown agent /work/agentbin
  runuser -u agent -- bash -c 'for c in id uname sed tr head python3 dirname readlink cp mv rm cmp date; do printf "#!/bin/sh\ntouch /tmp/ROOT-RAN-FAKE-$c\nexec /usr/bin/$c \"\$@\"\n" > /work/agentbin/$c; chmod +x /work/agentbin/$c; done'
}
check_exit "first install applies" 0 bash install.sh --yes --level observer --transport none
plant
rm -f /tmp/ROOT-RAN-FAKE-*
check_exit "revoke from the kept copy with the agent's folder first on PATH applies" 0 env PATH="/work/agentbin:$PATH" bash /var/lib/sirven/package/install.sh revoke --all --yes --transport none
check "no command from the agent's folder ran as root (kept copy)" bash -c '! ls /tmp/ROOT-RAN-FAKE-* >/dev/null 2>&1'

bash /var/lib/sirven/package/uninstall.sh >/dev/null 2>&1
rm -rf /home/agent /etc/sirven /var/lib/sirven /var/log/sirven; userdel agent >/dev/null 2>&1; groupdel agent >/dev/null 2>&1
useradd -m agent
plant
rm -f /tmp/ROOT-RAN-FAKE-*
check_exit "the first install with the agent's folder first on PATH applies" 0 env PATH="/work/agentbin:$PATH" bash install.sh --yes --level observer --transport none
check "no command from the agent's folder ran as root (first install)" bash -c '! ls /tmp/ROOT-RAN-FAKE-* >/dev/null 2>&1'
rm -f /tmp/ROOT-RAN-FAKE-*
check_exit "the launcher with the agent's folder first on PATH applies" 0 env PATH="/work/agentbin:$PATH" /usr/local/sbin/sirven revoke --all --dry-run --transport none
check "no command from the agent's folder ran as root (launcher)" bash -c '! ls /tmp/ROOT-RAN-FAKE-* >/dev/null 2>&1'
finish
