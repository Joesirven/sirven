#!/usr/bin/env bash
# round 2: the owner starts install.sh through a symbolic link that lives in a folder another account (swapper) controls.
# the gate resolves the link and approves the root-only target; the libraries are read afterwards through the same link name.
# swapper retargets the link to its own copy. install-only: this is the "runs from a trusted folder as an upgrade" path.
set -uo pipefail
. /src/tests/harness/lib/world.sh
useradd -m swapper
mkdir -p /opt && rm -rf /opt/pkg && cp -r "$SRC" /opt/pkg && chown -R root:root /opt/pkg
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
ran=0; refused=0; ok=0
for i in $(seq 1 25); do
  rm -f /tmp/ROOT-RAN-SWAPPER-CODE
  out="$(bash /home/swapper/link/install.sh --yes --level observer --transport none --path /srv/app 2>&1)"; st=$?
  [ -e /tmp/ROOT-RAN-SWAPPER-CODE ] && ran=$((ran+1))
  case "$st" in 0) ok=$((ok+1)) ;; 2) refused=$((refused+1)) ;; esac
done
rm -f /tmp/swap-on
echo "25 installs through the link: swapper's library ran as root in $ran of them; exit 0 in $ok, refused (2) in $refused"
check "the swapper's code never ran as root" test "$ran" = 0
finish
