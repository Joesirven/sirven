#!/usr/bin/env bash
# round 3 (a): can the agent make the vet of the kept copy FAIL so the gate falls back to a start folder it influences?
# 1 a grant that covers the kept copy (the owner grants /var/lib/sirven/package): the agent really can write it
# 2 the agent edits the kept copy through that grant, then the owner runs the launcher (starts from the kept copy)
# 3 the same edit, the owner starts from a clean root-only folder, and from a folder the agent edited
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
mkdir -p /srv/app && echo f > /srv/app/f
bash install.sh --yes --level builder --transport none --path /srv/app >/dev/null 2>&1
echo "== 1: a second install grants the kept copy itself to the agent =="
out="$(bash /var/lib/sirven/package/install.sh --yes --level builder --transport none --path /srv/app --path /var/lib/sirven/package 2>&1)"; echo "exit $?"; printf '%s\n' "$out" | grep -iE "refus|error|conflict" | head -3 | cut -c1-200
getfacl -p /var/lib/sirven/package 2>/dev/null | grep agent | head -2
if runuser -u agent -- test -w /var/lib/sirven/package/lib/kill_switch.sh; then
  echo "the agent can write the kept copy now"
  runuser -u agent -- bash -c 'printf "\ntouch /tmp/ROOT-RAN-KEPT-EDIT\n" >> /var/lib/sirven/package/lib/kill_switch.sh'
else echo "the agent cannot write the kept copy: the grant did not reach it"; fi
echo "== 2: owner runs the launcher =="
rm -f /tmp/ROOT-RAN-KEPT-EDIT
setsid runuser -u agent -- sleep 600 >/dev/null 2>&1 &
sleep 0.3
/usr/local/sbin/sirven revoke --all --yes --transport none > /tmp/o2 2>&1; st=$?
echo "launcher revoke: exit $st"; head -4 /tmp/o2 | cut -c1-200
check "the agent's edit of the kept copy did not run as root" bash -c '[ ! -e /tmp/ROOT-RAN-KEPT-EDIT ]'
echo "agent cut off: $(pgrep -u agent | wc -l) processes; shadow expire=$(getent shadow agent | cut -d: -f8)"
echo "== 3: from a clean root-only folder =="
rm -rf /work/clean && mkdir -p /work && cp -r /src /work/clean && chown -R root:root /work/clean && cd /work/clean
bash install.sh revoke --all --yes --transport none > /tmp/o3 2>&1; st=$?
echo "clean folder revoke: exit $st"; head -3 /tmp/o3 | cut -c1-220
rm -rf /work/edited && cp -r /src /work/edited && chown -R root:root /work/edited && chmod -R a+w /work/edited/lib && cd /work/edited
bash install.sh revoke --all --yes --transport none > /tmp/o4 2>&1; st=$?
echo "agent-writable folder revoke: exit $st"; head -3 /tmp/o4 | cut -c1-220
finish
