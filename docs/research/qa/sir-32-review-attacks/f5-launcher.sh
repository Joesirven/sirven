#!/usr/bin/env bash
# round 3 (e): the launcher /usr/local/sbin/sirven.
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
mkdir -p /srv/app && echo f > /srv/app/f
bash install.sh --yes --level observer --transport none --path /srv/app >/dev/null 2>&1
L=/usr/local/sbin/sirven
ls -ln "$L" /usr/local /usr/local/sbin | awk '{print $1,$3,$4,$9}' | head -4; stat -c '%A %U %n' "$L" /usr/local/sbin
check "mode 755, owned by root" bash -c '[ "$(stat -c %a:%u "'$L'")" = 755:0 ]'
check "the agent cannot replace, remove or add beside it" bash -c '! runuser -u agent -- bash -c "echo x > '$L'" 2>/dev/null && ! runuser -u agent -- rm -f '$L' 2>/dev/null && ! runuser -u agent -- touch /usr/local/sbin/other 2>/dev/null && ! runuser -u agent -- ln -sf /tmp/x /usr/local/sbin/sirven2 2>/dev/null'
echo "== hostile environment: BASH_ENV, ENV, a fake bash and python3 first on PATH, LD_PRELOAD, an exported function =="
mkdir -p /work/agentbin; for c in bash python3 id; do printf '#!/bin/sh\ntouch /tmp/ROOT-RAN-FAKE-%s\nexec /usr/bin/%s "$@"\n' $c $c > /work/agentbin/$c; chmod 755 /work/agentbin/$c; done
printf 'touch /tmp/ROOT-RAN-BASH-ENV\n' > /work/be.sh
rm -f /tmp/ROOT-RAN-*
env BASH_ENV=/work/be.sh ENV=/work/be.sh PATH=/work/agentbin:$PATH LD_PRELOAD=/work/none.so BASH_FUNC_id%%='() { touch /tmp/ROOT-RAN-FUNC; }' /usr/local/sbin/sirven revoke --all --dry-run > /tmp/o 2>&1; echo "exit $?"
ls /tmp/ROOT-RAN-* 2>/dev/null | tr '\n' ' '; echo
check "nothing from the hostile environment ran as root through the launcher" bash -c '! ls /tmp/ROOT-RAN-* >/dev/null 2>&1'
echo "== /usr/local/sbin writable by the agent before the install lays the launcher =="
rm -f "$L"; chmod 777 /usr/local/sbin
bash install.sh --yes --level observer --transport none --path /srv/app > /tmp/o2 2>&1; echo "install exit $?"; grep -i "launcher\|usr/local" /tmp/o2 | head -4 | cut -c1-200
ls -l "$L" | cut -c1-60
runuser -u agent -- bash -c "printf '#!/bin/sh\ntouch /tmp/ROOT-RAN-LAUNCHER\n' > $L.tmp && mv -f $L.tmp $L" 2>&1 | head -1
rm -f /tmp/ROOT-RAN-*; /usr/local/sbin/sirven revoke --all --dry-run >/dev/null 2>&1
check "an agent-replaced launcher does not get to run as root" bash -c '[ ! -e /tmp/ROOT-RAN-LAUNCHER ]'
echo "== /usr/local/sbin a symlink to an agent folder =="
chmod 755 /usr/local/sbin
finish
