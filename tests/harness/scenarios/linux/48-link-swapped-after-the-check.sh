#!/usr/bin/env bash
# SIR-32 round 3 (review e11). the owner starts install.sh through a symbolic link that lives in a folder another account
# (swapper) controls and that points at a root-only copy; swapper flips the link to its own copy in a loop. the script resolves
# its folder to a physical path once and reads every library through it, so a link changed after the check changes nothing:
# swapper's library never runs as root, in any of the runs.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"

useradd -m swapper
rm -rf /opt/pkg && cp -r "$SRC" /opt/pkg && chown -R root:root /opt/pkg
cp -r /opt/pkg /home/swapper/evil && chown -R swapper /home/swapper/evil
printf '\ntouch /tmp/ROOT-RAN-SWAPPER-CODE\n' >> /home/swapper/evil/lib/common.sh
ln -s /opt/pkg /home/swapper/link && chown -h swapper /home/swapper/link
cat > /tmp/swap.sh <<'SCRIPT'
cd /home/swapper
while [ -e /tmp/swap-on ]; do
  ln -sfn /home/swapper/evil l.tmp && mv -T l.tmp link
  ln -sfn /opt/pkg l.tmp && mv -T l.tmp link
done
SCRIPT
mkdir -p /srv/app; echo f > /srv/app/f
touch /tmp/swap-on
setsid runuser -u swapper -- bash /tmp/swap.sh >/dev/null 2>&1 &
sleep 0.5
check "precondition: the link flips between two folders" bash -c 'a="$(readlink /home/swapper/link)"; for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do b="$(readlink /home/swapper/link)"; [ "$a" != "$b" ] && exit 0; done; exit 1'
ran=0; refused=0; ok=0
for i in $(seq 1 15); do
  rm -f /tmp/ROOT-RAN-SWAPPER-CODE
  bash /home/swapper/link/install.sh --yes --level observer --transport none --path /srv/app > /tmp/out 2>&1; st=$?
  [ -e /tmp/ROOT-RAN-SWAPPER-CODE ] && ran=$((ran+1))
  case "$st" in 0) ok=$((ok+1)) ;; 2) refused=$((refused+1)) ;; esac
done
rm -f /tmp/swap-on
echo "15 installs through the link: swapper's library ran as root in $ran; exit 0 in $ok, refused (2) in $refused"
check "swapper's code never ran as root" test "$ran" = 0
check "every run ended in 0 (the root-only copy) or 2 (refused), never a crash" test $((ok + refused)) = 15
finish
