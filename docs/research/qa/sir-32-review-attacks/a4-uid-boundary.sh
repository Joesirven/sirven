#!/usr/bin/env bash
# attack 4: which accounts does the refusal list protect? 500 is the old Linux boundary; Debian and Fedora use 1000.
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
useradd -r -s /bin/bash svcdb      # a system account: uid in the 100-999 range, as a database or web service would have
useradd -u 700 -s /bin/bash svc700
grep -E '^(UID_MIN|SYS_UID_MAX|SYS_UID_MIN)' /etc/login.defs
for u in svcdb svc700 nobody www-data _apt daemon; do
  id "$u" >/dev/null 2>&1 || { echo "$u: no such account"; continue; }
  setsid runuser -u "$u" -s /bin/bash -- sleep 600 >/dev/null 2>&1 &
  sleep 0.3
  out="$(bash install.sh revoke --all --yes --transport none --user "$u" --owner root 2>&1)"; st=$?
  echo "$u (uid $(id -u "$u")): revoke exit $st; locked=$(getent shadow "$u" | cut -d: -f2 | cut -c1-1) expire='$(getent shadow "$u" | cut -d: -f8)' shell=$(getent passwd "$u" | cut -d: -f7) processes=$(pgrep -u "$u" | wc -l)"
  pkill -KILL -u "$u" 2>/dev/null
done
