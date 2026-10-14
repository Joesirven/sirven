#!/usr/bin/env bash
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
mkdir -p /srv/app && echo f > /srv/app/f
mkdir -p /usr/local/sbin; chmod 777 /usr/local/sbin
bash install.sh --yes --level observer --transport none --path /srv/app > /tmp/o2 2>&1; echo "install exit $?"
grep -i "launcher" /tmp/o2 | cut -c1-160 | head -3
L=/usr/local/sbin/sirven; ls -l $L | cut -c1-70
runuser -u agent -- bash -c "printf '#!/bin/sh\ntouch /tmp/ROOT-RAN-LAUNCHER\n' > $L.tmp && chmod +x $L.tmp && mv -f $L.tmp $L; echo agent-mv-rc=\$?"
ls -l $L | cut -c1-70
rm -f /tmp/ROOT-RAN-LAUNCHER; $L revoke --all --dry-run >/dev/null 2>&1
check "an agent-replaced launcher does not run as root" bash -c '[ ! -e /tmp/ROOT-RAN-LAUNCHER ]'
finish
