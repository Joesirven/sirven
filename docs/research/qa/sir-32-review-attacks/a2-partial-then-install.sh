#!/usr/bin/env bash
# attack 2: a revoke that stops at the services step (a unit that will not stop), then the owner runs a plain install.
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
mkdir -p /srv/app && echo f > /srv/app/f
bash install.sh --yes --level observer --transport none --path /srv/app >/dev/null 2>&1
mkdir -p /run/systemd/system /tmp/stub /tmp/units
cat > /usr/sbin/systemctl <<'SCRIPT'
#!/bin/sh
case "$1" in
  list-unit-files) printf 'sirven-agent.service enabled enabled\n' ;;
  show) echo agent ;;
  is-active) [ -e "/tmp/units/$3.active" ] ;;
  is-enabled) return 1 ;;
  stop) echo "stub: cannot stop $2" >&2; exit 1 ;;
esac
SCRIPT
chmod +x /usr/sbin/systemctl; touch /tmp/units/sirven-agent.service.active
mkdir -p /tmp/k && ssh-keygen -q -t ed25519 -N '' -f /tmp/k/id; cp /tmp/k/id.pub /home/agent/.ssh/authorized_keys; chown agent:agent /home/agent/.ssh/authorized_keys
state() { echo "  passwd=$(getent shadow agent | cut -d: -f2 | cut -c1-2) expire='$(getent shadow agent | cut -d: -f8)' shell=$(getent passwd agent | cut -d: -f7) keys=$(ls /home/agent/.ssh | tr '\n' ' ') marker=$([ -e /var/lib/sirven/agent-quiesce.json ] && echo yes || echo no)"; }
bash install.sh revoke --all --yes --transport none > /tmp/rev.out 2>&1; echo "revoke exit $?"
echo "after the stopped revoke:"; state
out="$(bash install.sh --yes --level observer --transport none --path /srv/app 2>&1)"; st=$?
echo "plain install exit $st"; printf '%s\n' "$out" | tail -8
echo "after the plain install:"; state
check "a plain install after a stopped revoke leaves the account locked" bash -c '[ "$(getent shadow agent | cut -d: -f8)" = 1 ] && getent shadow agent | cut -d: -f2 | grep -q "^!"'
finish
