#!/usr/bin/env bash
# SIR-32 round 3 (review S-F). the launcher /usr/local/sbin/sirven is the one invocation the documents give for every root
# command. install lays it down: root-owned, mode 755, running the kept copy. it works for the kill switch, the uninstaller and
# the other sirven commands; the agent cannot change it; code the agent edited in a granted copy is never reached through it;
# uninstall removes it (scenario 02 compares the whole machine afterwards).
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"

mkdir -p /work && cp -r "$SRC" /work/repo && cd /work/repo || exit 2
check_exit "first install from a copy only root can write applies" 0 bash install.sh --yes --level builder --transport none --path /work/repo
check "the launcher is there, root-owned, mode 755" bash -c '[ "$(stat -c "%a %u %g" /usr/local/sbin/sirven)" = "755 0 0" ]'
check "the plan tells the owner to use it, and to delete the folder the package was unpacked in" bash -c 'grep -q "sudo /usr/local/sbin/sirven revoke --all" <<< "$0" && grep -q "the folder you unpacked this package in is code the agent can change" <<< "$0"' "$LAST_OUTPUT"
check "the agent cannot change the launcher or its folder" bash -c '! runuser -u agent -- sh -c "echo x >> /usr/local/sbin/sirven" 2>/dev/null && ! runuser -u agent -- sh -c "rm -f /usr/local/sbin/sirven" 2>/dev/null'
check "the launcher sets its own search path and runs only the kept copy" bash -c 'grep -q "^PATH=/usr/sbin:/usr/bin:/sbin:/bin" /usr/local/sbin/sirven && grep -q "kept=/var/lib/sirven/package" /usr/local/sbin/sirven'
check_exit "a second install leaves the launcher alone" 0 bash install.sh --yes --level builder --transport none --path /work/repo
check "grant inspect through the launcher shows the level in force" bash -c '/usr/local/sbin/sirven grant inspect | grep -q "builder"'

# the agent edits the granted copy; through the launcher none of it runs
runuser -u agent -- bash -c 'printf "\ntouch /tmp/ROOT-RAN-AGENT-CODE\n" >> /work/repo/lib/kill_switch.sh; printf "\ntouch /tmp/ROOT-RAN-AGENT-CODE\n" >> /work/repo/install.sh'
setsid runuser -u agent -- sleep 600 >/dev/null 2>&1 &
sleep 0.3
check_exit "the plan through the launcher" 0 /usr/local/sbin/sirven revoke --all --dry-run --transport none
check_exit "revoke through the launcher applies" 0 /usr/local/sbin/sirven revoke --all --yes --transport none
check "the agent is cut off, and none of its edits ran" bash -c '! pgrep -u agent && passwd --status agent | grep -q "^agent L" && [ ! -e /tmp/ROOT-RAN-AGENT-CODE ]'
check_exit "reinstate through the launcher applies" 0 /usr/local/sbin/sirven install --yes --reinstate --level observer --transport none
check_exit "uninstall through the launcher applies" 0 /usr/local/sbin/sirven uninstall
check "uninstall removed the launcher" bash -c '[ ! -e /usr/local/sbin/sirven ]'
check_exit "the launcher is gone, so there is nothing to run: a clear error" 127 /usr/local/sbin/sirven revoke --all
finish
