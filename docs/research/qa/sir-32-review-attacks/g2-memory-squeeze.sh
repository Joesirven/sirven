#!/usr/bin/env bash
# the gate forks python (the vet) up to three times. if the agent holds nearly all memory of a shared cgroup, does the kill switch refuse, run, or break?
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
mkdir -p /srv/app && echo f > /srv/app/f
bash install.sh --yes --level observer --transport none --path /srv/app >/dev/null 2>&1
setsid runuser -u agent -- python3 -c 'import time; b = bytearray(205*1024*1024); b[::4096] = b"x" * len(b[::4096]); time.sleep(300)' >/dev/null 2>&1 &
sleep 2
echo "memory in use: $(cat /sys/fs/cgroup/memory.current 2>/dev/null) of $(cat /sys/fs/cgroup/memory.max 2>/dev/null)"
/usr/local/sbin/sirven revoke --all --yes --transport none > /tmp/o 2>&1; st=$?
echo "launcher revoke under memory pressure: exit $st"; grep -vE "^preflight" /tmp/o | head -5 | cut -c1-200
echo "agent: $(pgrep -u agent | wc -l) processes; expire=$(getent shadow agent | cut -d: -f8)"
check "the agent was cut off" bash -c '! pgrep -u agent && [ "$(getent shadow agent | cut -d: -f8)" = 1 ]'
finish
