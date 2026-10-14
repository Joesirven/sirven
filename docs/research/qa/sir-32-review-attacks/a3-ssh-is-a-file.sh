#!/usr/bin/env bash
# attack 3: the agent replaces .ssh with a regular file (and, in a second run, home/.ssh with a fifo) before the kill switch runs.
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
mkdir -p /srv/app && echo f > /srv/app/f
bash install.sh --yes --level builder --transport none --path /srv/app >/dev/null 2>&1
runuser -u agent -- bash -c 'rm -rf ~/.ssh; echo not-a-folder > ~/.ssh'
bash install.sh revoke --all --yes --transport none > /tmp/rev.out 2>&1; st=$?
echo "revoke exit $st"; tail -10 /tmp/rev.out
echo "acl on /srv/app: $(getfacl -p /srv/app 2>/dev/null | grep 'user:agent')"
echo "grant record: $(ls /etc/sirven/grants | tr '\n' ' ')"
check "ssh is a file: revoke finishes" test "$st" = 0
check "ssh is a file: the grant on /srv/app is undone" bash -c '! getfacl -p /srv/app 2>/dev/null | grep -q "user:agent"'
finish
