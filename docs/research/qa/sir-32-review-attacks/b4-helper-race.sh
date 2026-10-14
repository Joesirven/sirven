#!/usr/bin/env bash
# attack 2: while the agent swaps .ssh and authorized_keys between a real file, links to root's files and a fifo, run
# the key-removal helper over and over. nothing of root's may be read, changed or removed, and the helper must not hang.
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
mkdir -p /srv/app && echo f > /srv/app/f
bash install.sh --yes --level observer --transport none --path /srv/app >/dev/null 2>&1
mkdir -p /root/secret.d; echo "root secret" > /root/secret.d/authorized_keys; echo "root file" > /root/sentinel
sum() { cat /root/secret.d/authorized_keys /root/sentinel | md5sum; }
before="$(sum)"
cat > /tmp/swapper.sh <<'SCRIPT'
cd /home/agent
n=0
while [ -e /tmp/swap-on ]; do
  rm -rf .ssh .ssh.x 2>/dev/null
  case $((n % 5)) in
    0) mkdir .ssh; ln -s /root/sentinel .ssh/authorized_keys ;;
    1) ln -s /root/secret.d .ssh ;;
    2) mkdir .ssh; mkfifo .ssh/authorized_keys ;;
    3) mkdir .ssh; echo "ssh-ed25519 AAAA x" > .ssh/authorized_keys ;;
    4) mkdir .ssh; echo "k" > .ssh/authorized_keys2; ln -s /root/sentinel .ssh/authorized_keys ;;
  esac
  n=$((n+1))
done
SCRIPT
touch /tmp/swap-on
setsid runuser -u agent -- bash /tmp/swapper.sh >/dev/null 2>&1 &
sleep 0.5
hangs=0; fails=0; runs=0
for i in $(seq 1 400); do
  timeout 5 python3 -I "$SRC/lib/kill_switch.py" remove-keys /home/agent >/tmp/h.out 2>&1; st=$?
  runs=$((runs+1))
  [ "$st" = 124 ] && hangs=$((hangs+1))
  [ "$st" != 0 ] && [ "$st" != 124 ] && { fails=$((fails+1)); last="$(cat /tmp/h.out | head -2)"; }
done
rm -f /tmp/swap-on; sleep 0.3; pkill -KILL -u agent
echo "runs=$runs hangs=$hangs nonzero-exits=$fails"; [ -z "${last:-}" ] || echo "last error: $last"
check "root's files were not read through, changed or removed" bash -c '[ "$(cat /root/secret.d/authorized_keys /root/sentinel | md5sum)" = "'"$before"'" ] && [ -f /root/sentinel ] && [ -f /root/secret.d/authorized_keys ]'
check "the helper never hung on a fifo" test "$hangs" = 0
finish
