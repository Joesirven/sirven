#!/usr/bin/env bash
# SIR-32, from the review (a4-uid-boundary, M4). the kill switch locks an account and ends its processes, so it must
# not be pointed at an account that runs a service: root, the owner, anything below UID_MIN (read from login.defs),
# nobody. refused with exit 2, and nothing about the account changes. an ordinary account is still revoked.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -r -s /bin/bash svcdb       # 100 to 999, as a database or web service would have
useradd -u 700 -s /bin/bash svc700
useradd -m -u 1500 -s /bin/bash person
unchanged_after() {  # USER: the shadow line and the shell, before and after a refused revoke
  local user="$1" before after
  before="$(getent shadow "$user"; getent passwd "$user")"
  setsid setpriv --reuid="$(id -u "$user")" --regid="$(id -g "$user")" --clear-groups sleep 600 >/dev/null 2>&1 &
  sleep 0.3
  bash install.sh revoke --all --yes --transport none --user "$user" --owner root > /tmp/out.txt 2>&1
  REFUSED_STATUS=$?
  after="$(getent shadow "$user"; getent passwd "$user")"
  [ "$before" = "$after" ] && pgrep -u "$user" >/dev/null
}
for user in svcdb svc700 nobody www-data daemon; do
  check "$user (user number $(id -u "$user")): refused, account and processes untouched" bash -c "$(declare -f unchanged_after); unchanged_after $user && [ \"\$REFUSED_STATUS\" = 2 ]"
  check "$user: the message says it is a system account" grep -q 'is a system account here' /tmp/out.txt
  pkill -KILL -u "$user" 2>/dev/null
done
check_exit "root is refused" 2 bash install.sh revoke --all --yes --transport none --user root
check_exit "the owner is refused" 2 bash install.sh revoke --all --yes --transport none --user person --owner person
sed -i 's/^UID_MIN.*/UID_MIN 2000/' /etc/login.defs
check_exit "an account below a raised UID_MIN is refused (person, 1500, UID_MIN 2000)" 2 bash install.sh revoke --all --yes --transport none --user person --owner root
check "the message names the number the machine uses" grep -q 'ordinary accounts start at 2000' <<< "$LAST_OUTPUT"
sed -i 's/^UID_MIN.*/UID_MIN 1000/' /etc/login.defs
setsid setpriv --reuid="$(id -u person)" --regid="$(id -g person)" --clear-groups sleep 600 >/dev/null 2>&1 &
sleep 0.3
check_exit "an ordinary account (1500) is revoked" 0 bash install.sh revoke --all --yes --transport none --user person --owner root
check "and it is locked, expired and without processes" bash -c 'passwd --status person | grep -q "^person L" && [ "$(getent shadow person | cut -d: -f8)" = 1 ] && ! pgrep -u person'

finish
