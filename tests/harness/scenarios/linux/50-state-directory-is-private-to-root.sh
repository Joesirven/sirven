#!/usr/bin/env bash
# SIR-32 round 3 (review e9). a state directory that already exists with mode 0755 (made by hand, by an older version) used to
# keep that mode, so the agent could open it and hold the installer lock, stalling install, uninstall and rollback. the install
# now forces mode 0700 and root as owner whether or not it made the directory. the agent can then do nothing with it. a lock the
# agent could still hold would cost the kill switch ten seconds and no more, which is also checked.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

mkdir -p /srv/app && echo f > /srv/app/f
mkdir -m 755 /var/lib/sirven
check "precondition: the state directory exists with mode 755" bash -c '[ "$(stat -c %a /var/lib/sirven)" = 755 ]'
check_exit "install applies" 0 bash install.sh --yes --level observer --transport none --path /srv/app
check "the state directory is mode 700 and owned by root now" bash -c '[ "$(stat -c "%a %u" /var/lib/sirven)" = "700 0" ]'
check "the agent cannot open it to hold the lock" bash -c '! runuser -u agent -- flock /var/lib/sirven true 2>/dev/null'
check "the agent cannot list it or create a marker in it" bash -c '! runuser -u agent -- ls /var/lib/sirven >/dev/null 2>&1 && ! runuser -u agent -- touch /var/lib/sirven/agent-revoked-agent.json 2>/dev/null'
check_exit "a second install leaves it as it is" 0 bash install.sh --yes --level observer --transport none --path /srv/app
check "and it is still mode 700, owned by root" bash -c '[ "$(stat -c "%a %u" /var/lib/sirven)" = "700 0" ]'
# loosen it by hand: the next run puts it right
chmod 755 /var/lib/sirven
check_exit "a run after somebody loosened the mode applies" 0 bash install.sh --yes --level observer --transport none --path /srv/app
check "and the mode is 700 again" bash -c '[ "$(stat -c "%a %u" /var/lib/sirven)" = "700 0" ]'
finish
