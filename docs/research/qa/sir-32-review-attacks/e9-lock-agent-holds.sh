#!/usr/bin/env bash
# round 2: a state directory left at mode 0755 (made by hand, by an older version, or by another tool) lets the agent open it
# and hold the installer lock. what do install, uninstall and revoke do?
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
mkdir -p /srv/app && echo f > /srv/app/f
mkdir -m 755 /var/lib/sirven
bash install.sh --yes --level observer --transport none --path /srv/app >/dev/null 2>&1
echo "state directory mode after install: $(stat -c %a /var/lib/sirven)"
setsid runuser -u agent -- flock /var/lib/sirven sleep 300 >/dev/null 2>&1 &
sleep 1
echo "agent holds the lock: $(pgrep -u agent -a | head -2 | tr '\n' ';')"
out="$(SIRVEN_LOCK_WAIT=3 bash install.sh --yes --level observer --transport none --path /srv/app 2>&1)"; echo "install while the agent holds the lock: exit $?"
started=$SECONDS
bash install.sh revoke --all --yes --transport none > /tmp/rev.out 2>&1; echo "revoke exit $? after $((SECONDS-started)) s"
grep -i "going on" /tmp/rev.out | head -1
check "the agent is cut off and its lock holder is gone" bash -c '! pgrep -u agent && passwd --status agent | grep -q "^agent L"'
finish
