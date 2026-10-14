#!/usr/bin/env bash
# SIR-32. a service that runs as the agent is stopped and disabled, the systemd session of the agent is ended and
# lingering turned off, and a unit of another user is left alone. the container has no systemd, so systemctl and
# loginctl are stand-ins that keep their state in files; what is asserted is what the kill switch asks them to do.
# a unit that cannot be stopped fails the run loudly with the account already locked, and the same command finishes
# once it can.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

mkdir -p /srv/app && echo f > /srv/app/f
bash install.sh --yes --level observer --transport none --path /srv/app >/dev/null 2>&1

mkdir -p /run/systemd/system /tmp/stub /tmp/units
cat > /tmp/stub/systemctl <<'SCRIPT'
#!/bin/sh
state=/tmp/units
case "$1" in
  list-unit-files) printf 'sirven-agent.service enabled enabled\nother.service enabled enabled\n' ;;
  show) if [ "$4" = sirven-agent.service ]; then echo agent; else echo root; fi ;;
  is-active) [ -e "$state/$3.active" ] ;;
  is-enabled) [ -e "$state/$3.enabled" ] ;;
  stop) if [ -e /tmp/stub-cannot-stop ]; then echo "stub: cannot stop $2" >&2; exit 1; fi
        rm -f "$state/$2.active"; echo "stop $2" >> /tmp/stub.log ;;
  disable) rm -f "$state/$2.enabled"; echo "disable $2" >> /tmp/stub.log ;;
esac
SCRIPT
cat > /tmp/stub/loginctl <<'SCRIPT'
#!/bin/sh
case "$1" in
  show-user) if [ -e /tmp/units/linger ]; then echo yes; else echo no; fi ;;
  disable-linger) rm -f /tmp/units/linger; echo "disable-linger $2" >> /tmp/stub.log ;;
  terminate-user) echo "terminate-user $2" >> /tmp/stub.log ;;
esac
SCRIPT
chmod +x /tmp/stub/systemctl /tmp/stub/loginctl
touch /tmp/units/sirven-agent.service.active /tmp/units/sirven-agent.service.enabled /tmp/units/other.service.active /tmp/units/other.service.enabled /tmp/units/linger
export PATH="/tmp/stub:$PATH"

touch /tmp/stub-cannot-stop
check_exit "revoke fails (exit 4) when a service of the agent cannot be stopped" 4 bash install.sh revoke --all --yes --transport none
check "it says which unit could not be stopped" grep -q 'could not stop sirven-agent.service' <<< "$LAST_OUTPUT"
check "the account is locked and expired by then" bash -c 'passwd --status agent | grep -q "^agent L" && [ "$(getent shadow agent | cut -d: -f8)" = 1 ]'
rm -f /tmp/stub-cannot-stop

check_exit "once it can be stopped the same revoke finishes" 0 bash install.sh revoke --all --yes --transport none
check "the agent's service is neither active nor enabled" bash -c '[ ! -e /tmp/units/sirven-agent.service.active ] && [ ! -e /tmp/units/sirven-agent.service.enabled ]'
check "a unit of another user is left alone" bash -c 'grep -q "stop sirven-agent.service" /tmp/stub.log && [ -e /tmp/units/other.service.active ] && [ -e /tmp/units/other.service.enabled ]'
check "lingering is off and the systemd session of the agent was ended" bash -c '
  [ ! -e /tmp/units/linger ] && grep -qx "disable-linger agent" /tmp/stub.log && grep -qx "terminate-user agent" /tmp/stub.log'
check_exit "a second revoke has nothing left to stop" 0 bash install.sh revoke --all --yes --transport none
check "the second run skipped the service step as already done" bash -c 'grep -A1 "stop and disable every service" <<< "$0" | grep -q "already done"' "$LAST_OUTPUT"

finish
