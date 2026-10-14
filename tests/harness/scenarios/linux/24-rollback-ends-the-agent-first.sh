#!/usr/bin/env bash
# SIR-70 round 4, must fix D, the other half. a rollback removes access while the agent may still be running, so it
# ends the agent's processes and locks its account first (as uninstall does), and gives the account back at the end,
# also when the rollback goes back to no grant at all. at 2211d8f the dry run of a rollback to no grant had no such
# step, and with a re-grant it came after the restores.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m owner
mkdir -p /srv/work && echo f > /srv/work/f && chown -R owner:owner /srv/work
first_line() { grep -n "$1" <<< "$2" | head -1 | cut -d: -f1; }

check_exit "install builder applies (previous level: none)" 0 bash install.sh --yes --level builder --transport none --path /srv/work
check_exit "rollback dry run" 0 bash /var/lib/sirven/package/bin/sirven grant rollback --dry-run
dry="$LAST_OUTPUT"
check "the plan has a step that ends the agent's processes" grep -q 'end every process of agent and lock its account while the access is removed' <<< "$dry"
check "it comes before the first restore" bash -c '[ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]' _ "$(first_line 'end every process of agent' "$dry")" "$(first_line 'put back the access control lists' "$dry")"
check "the plan gives the account back at the end" grep -q 'give agent its account back' <<< "$dry"

setsid runuser -u agent -- sleep 600 >/dev/null 2>&1 &
sleep 0.3
check "precondition: a process of agent is running" pgrep -u agent
check_exit "rollback to no grant applies" 0 bash /var/lib/sirven/package/bin/sirven grant rollback
check "the agent's processes were ended" bash -c '! pgrep -u agent'
check "the account is back as it was: password login off, never expires" \
  bash -c '[ "$(getent shadow agent | cut -d: -f2)" = "*" ] && [ -z "$(getent shadow agent | cut -d: -f8)" ]'
check "the marker is gone" bash -c '[ ! -e /var/lib/sirven/agent-quiesce.json ]'
check "no entry of the agent is left" bash -c '! getfacl -R -n -p /srv/work | grep -Eq "^(default:)?user:[0-9]+:"'

# with a re-grant (observer then builder, rolled back to observer) the step still comes first
check_exit "install observer" 0 bash install.sh --yes --level observer --transport none --path /srv/work
check_exit "install builder" 0 bash install.sh --yes --level builder --transport none --path /srv/work
check_exit "rollback dry run, with a re-grant" 0 bash /var/lib/sirven/package/bin/sirven grant rollback --dry-run
check "the step that ends the agent comes before the first restore" bash -c '[ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]' _ "$(first_line 'end every process of agent' "$LAST_OUTPUT")" "$(first_line 'put back the access control lists' "$LAST_OUTPUT")"

finish
