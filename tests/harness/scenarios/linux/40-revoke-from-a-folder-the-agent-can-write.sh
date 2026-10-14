#!/usr/bin/env bash
# SIR-32, from the review (d1-writable-source). root must not run code the agent could have changed.
#   (1) a copy of the package sits inside a folder granted to the agent; the agent edits the library the kill switch
#       reads and the gate that guards it; the owner runs revoke from that copy. the kept copy runs instead.
#   (2) with no kept copy, a folder that someone other than root and the owner can write is refused: install, revoke.
#       by mode (everyone), by owner, by an access list entry.
#   (3) install over a kept copy from a folder others can write runs the kept copy; from a folder only root can
#       write it is an upgrade and proceeds.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"

mkdir -p /work && cp -r "$SRC" /work/repo && cd /work/repo || exit 2
check_exit "first install from a copy only root can write applies" 0 bash install.sh --yes --level builder --transport none --path /work/repo
check "precondition: the agent can write inside the granted copy" runuser -u agent -- test -w /work/repo/lib/kill_switch.sh
check "the agent edits the kill switch library and two others" runuser -u agent -- bash -c '
  printf "\ntouch /tmp/ROOT-RAN-AGENT-CODE\n" >> /work/repo/lib/kill_switch.sh &&
  printf "\ntouch /tmp/ROOT-RAN-AGENT-CODE\n" >> /work/repo/lib/plan.sh &&
  printf "\ntouch /tmp/ROOT-RAN-AGENT-CODE\n" >> /work/repo/lib/common.sh'
setsid runuser -u agent -- sleep 600 >/dev/null 2>&1 &
sleep 0.3
check_exit "(1) revoke started from the granted copy applies" 0 bash install.sh revoke --all --yes --transport none
check "(1) it ran the kept copy and said so" grep -q 'running the kept copy /var/lib/sirven/package instead of /work/repo' <<< "$LAST_OUTPUT"
check "(1) the agent's code did not run as root" bash -c '[ -f /etc/sirven/grants/agent.json.revoked ] && [ ! -e /tmp/ROOT-RAN-AGENT-CODE ]'
check "(1) the agent is cut off" bash -c '! pgrep -u agent && passwd --status agent | grep -q "^agent L"'
check_exit "(1) uninstall started from the granted copy runs the kept copy too" 0 bash /work/repo/uninstall.sh
check "(1) and the agent's code did not run" bash -c '! getent passwd agent && [ ! -e /tmp/ROOT-RAN-AGENT-CODE ]'

# (2) no kept copy now
rm -rf /work/bad && cp -r "$SRC" /work/bad && chmod o+w /work/bad/lib && cd /work/bad || exit 2
check_exit "(2) install from a folder everyone can write is refused" 2 bash install.sh --yes --level observer --transport none
check "(2) it names the folder and says why" grep -q '/work/bad/lib: writable by everyone' <<< "$LAST_OUTPUT"
check "(2) the refusal does not point at the launcher path" bash -c '! grep -q "usr/local/sbin/sirven" <<< "$0"' "$LAST_OUTPUT"
check "(2) nothing was created" bash -c '! getent passwd agent && [ ! -e /var/lib/sirven ]'
chmod o-w /work/bad/lib
useradd -m intruder
chown intruder /work/bad/lib/common.sh
check_exit "(2) install from a copy with a file owned by another account is refused" 2 bash install.sh --yes --level observer --transport none
check "(2) it names the file and the owner" grep -q 'common.sh: owned by intruder' <<< "$LAST_OUTPUT"
chown root /work/bad/lib/common.sh
setfacl -m u:intruder:rw /work/bad/lib/audit.sh
check_exit "(2) install from a copy with an access list entry for another account is refused" 2 bash install.sh --yes --level observer --transport none
check "(2) it names the file and the entry" grep -q 'audit.sh: an access list entry gives intruder write' <<< "$LAST_OUTPUT"
setfacl -b /work/bad/lib/audit.sh
useradd -m agent
check_exit "(2) revoke with no kept copy from a folder the agent can write is refused" 2 env PATH="$PATH" bash -c 'cd /work/bad && chmod g+w lib && setfacl -m u:agent:rwx lib && bash install.sh revoke --all --yes --transport none'
check "(2) it names the way out and changed nothing" bash -c 'grep -q "there is no kept copy to run instead" <<< "$0" && [ "$(getent shadow agent | cut -d: -f8)" = "" ]' "$LAST_OUTPUT"
userdel -r agent >/dev/null 2>&1; userdel -r intruder >/dev/null 2>&1; setfacl -b /work/bad/lib

# (3) a kept copy exists
rm -rf /work/good && cp -r "$SRC" /work/good && cd /work/good || exit 2
check_exit "install from a copy only root can write applies" 0 bash install.sh --yes --level observer --transport none
rm -rf /work/newer && cp -r "$SRC" /work/newer && chmod o+w /work/newer/lib && cd /work/newer || exit 2
check_exit "(3) install over a kept copy from a folder others can write applies" 0 bash install.sh --yes --level observer --transport none
check "(3) ... by running the kept copy" grep -q 'running the kept copy /var/lib/sirven/package instead of /work/newer' <<< "$LAST_OUTPUT"
chmod o-w /work/newer/lib
check_exit "(3) install over a kept copy from a folder only root can write is an upgrade and applies" 0 bash install.sh --yes --level observer --transport none
check "(3) ... from where it was started" bash -c '! grep -q "running the kept copy" <<< "$0"' "$LAST_OUTPUT"

finish
