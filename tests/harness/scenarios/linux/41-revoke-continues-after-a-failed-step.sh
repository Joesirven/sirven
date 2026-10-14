#!/usr/bin/env bash
# SIR-32, from the review (a3-ssh-is-a-file, M3). one step that cannot finish must not leave a later one undone: the
# agent makes .ssh a regular file, a named pipe and a link; a unit will not stop; the account is locked, the grants are
# restored and the keys are gone in every case. when a step does fail, the run ends with exit 4 listing it, the grant
# record is left so the next run knows what to take back, and the next run finishes.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

mkdir -p /srv/app && echo f > /srv/app/f
bash install.sh --yes --level builder --transport none --path /srv/app >/dev/null 2>&1
fresh() {  # a machine with nothing of the package left, through its own uninstall
  bash /var/lib/sirven/package/uninstall.sh >/dev/null 2>&1
  rm -rf /home/agent /etc/sirven /var/lib/sirven /var/log/sirven /srv/app; userdel agent >/dev/null 2>&1; groupdel agent >/dev/null 2>&1
  mkdir -p /srv/app && echo f > /srv/app/f
}
as_agent() { setpriv --reuid="$(id -u agent)" --regid="$(id -g agent)" --clear-groups "$@"; }
locked() { passwd --status agent | grep -q '^agent L' && [ "$(getent shadow agent | cut -d: -f8)" = 1 ]; }
no_entry() { ! getfacl -R -n -p /srv 2>/dev/null | grep -Eq '^(default:)?user:[0-9]+:'; }

# .ssh as a regular file, as a named pipe, then as a link
for kind in file pipe link; do
  fresh
  bash install.sh --yes --level builder --transport none --path /srv/app >/dev/null 2>&1 || fail "fresh install for $kind failed"
  case "$kind" in
    file) as_agent sh -c 'rm -rf /home/agent/.ssh; echo not-a-folder > /home/agent/.ssh' ;;
    pipe) as_agent sh -c 'rm -rf /home/agent/.ssh; mkfifo /home/agent/.ssh' ;;
    link) as_agent sh -c 'rm -rf /home/agent/.ssh; ln -s /etc /home/agent/.ssh' ;;
  esac
  check_exit ".ssh is a $kind: revoke finishes" 0 bash install.sh revoke --all --yes --transport none
  check ".ssh is a $kind: the name is gone, the account locked, the grants restored, the record renamed" bash -c '
    [ ! -e /home/agent/.ssh ] && [ ! -L /home/agent/.ssh ] && [ -f /etc/sirven/grants/agent.json.revoked ]'
  check ".ssh is a $kind: locked and no entry of the agent on /srv" bash -c "$(declare -f locked no_entry); locked && no_entry"
done

# a unit that will not stop: the other steps still run, the failure is listed, the record stays, the next run finishes
fresh
bash install.sh --yes --level builder --transport none --path /srv/app >/dev/null 2>&1
echo 'ssh-ed25519 AAAAkey agent-client' > /home/agent/.ssh/authorized_keys && chown agent:agent /home/agent/.ssh/authorized_keys
setsid runuser -u agent -- sleep 600 >/dev/null 2>&1 &
sleep 0.3
mkdir -p /run/systemd/system /tmp/stub /tmp/units
cat > /tmp/stub/systemctl <<'SCRIPT'
#!/bin/sh
case "$1" in
  list-unit-files) printf 'sirven-agent.service enabled enabled\n' ;;
  list-units) : ;;
  show) echo agent ;;
  is-active) [ -e "/tmp/units/$3.active" ] ;;
  is-enabled) return 1 ;;
  stop) echo "stub: cannot stop $2" >&2; exit 1 ;;
esac
SCRIPT
chmod +x /tmp/stub/systemctl; touch /tmp/units/sirven-agent.service.active
check_exit "a unit will not stop: revoke ends with exit 4" 4 env PATH="/tmp/stub:$PATH" bash install.sh revoke --all --yes --transport none
out="$LAST_OUTPUT"
check "it lists the failed step and says the others ran" bash -c 'grep -q "steps failed, each listed here, and the others ran" <<< "$0" && grep -q "stop and disable every service" <<< "$0" && grep -q "the other steps still run" <<< "$0"' "$out"
check "yet the account is locked, no process, no key, no entry of the agent on /srv" bash -c "$(declare -f locked no_entry); locked && ! pgrep -u agent && [ ! -e /home/agent/.ssh/authorized_keys ] && no_entry"
check "the grant record was left in place for the next run" bash -c '[ -f /etc/sirven/grants/agent.json ] && [ ! -e /etc/sirven/grants/agent.json.revoked ]'
check "the last check named what is still open" grep -q 'the last check of the machine found what is still open' <<< "$out"
rm -f /tmp/units/sirven-agent.service.active
check_exit "once the unit is down the same command finishes" 0 env PATH="/tmp/stub:$PATH" bash install.sh revoke --all --yes --transport none
check "and the record is renamed now" test -f /etc/sirven/grants/agent.json.revoked

finish
