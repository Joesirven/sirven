#!/usr/bin/env bash
# SIR-32 round 3, self-review. the kept copy is checked too. when somebody has loosened it (here the state directory is 0777, so the
# agent could replace the kept copy), root does not run it. the emergency command must not be refused for that alone, so it runs
# from the folder it was started from if that folder passes the same check, with a warning; if neither passes it refuses and
# changes nothing. the agent's replacement of the kept copy must never run.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"

mkdir -p /srv/app && echo f > /srv/app/f
cd "$SRC" || exit 2
check_exit "install applies" 0 bash install.sh --yes --level observer --transport none --path /srv/app
setsid runuser -u agent -- sleep 600 >/dev/null 2>&1 &
sleep 0.3
chmod 0777 /var/lib/sirven
runuser -u agent -- sh -c 'printf "\ntouch /tmp/ROOT-RAN-KEPT-REPLACEMENT\n" >> /var/lib/sirven/package/install.sh' 2>/dev/null
check "precondition: the loosened state directory lets the agent into the kept copy's folder" runuser -u agent -- test -x /var/lib/sirven
cd /var/lib/sirven/package || exit 2
check_exit "revoke started from a trusted folder runs there, with a warning, when the kept copy is not trusted" 0 bash "$SRC/install.sh" revoke --all --yes --transport none
check "it warned that the kept copy was not used" grep -q 'the kept copy /var/lib/sirven/package can be changed by any account other than root, so it was not used' <<< "$LAST_OUTPUT"
check "the agent is cut off and nothing the agent wrote ran" bash -c '! pgrep -u agent && passwd --status agent | grep -q "^agent L" && [ ! -e /tmp/ROOT-RAN-KEPT-REPLACEMENT ]'
# neither passes
cp -r "$SRC" /work-bad 2>/dev/null || cp -r "$SRC" /work-bad
chmod o+w /work-bad/lib
check_exit "when the started-from folder is not trusted either, it refuses" 2 bash /work-bad/install.sh revoke --all --yes --transport none
check "it says both can be changed, and changed nothing" bash -c 'grep -q "and so can /work-bad" <<< "$0" && grep -q "nothing was changed" <<< "$0"' "$LAST_OUTPUT"
finish
