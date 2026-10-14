#!/usr/bin/env bash
# round 3 (d): the /usr/local ownership vet. controls first, then the case the vet cannot see: /usr/local/bin is a symbolic link
# to a root-only folder, and /usr/local (which holds the link, and is NOT on the vetted path of the link's target) is writable by the agent.
set -uo pipefail
. /src/tests/harness/lib/world.sh
cd "$SRC" || exit 2
useradd -m agent
mkdir -p /opt/tools /home/agent/evil /usr/local/sbin
printf '#!/bin/sh\necho "tailscale 1.80.0"\n' > /opt/tools/tailscale; chmod 755 /opt/tools/tailscale
printf '#!/bin/sh\ntouch /tmp/FAKE-TAILSCALE-RAN\necho "tailscale 1.80.0"\n' > /home/agent/evil/tailscale; chmod 755 /home/agent/evil/tailscale; chown -R agent /home/agent/evil
run() { rm -f /tmp/FAKE-TAILSCALE-RAN; bash install.sh --dry-run --level observer --transport tailscale > /tmp/out 2>&1; echo $?; }
echo "== control 1: /usr/local 1777 (sticky, like /tmp), bin a real root-only folder =="
rm -rf /usr/local/bin; mkdir /usr/local/bin; cp /opt/tools/tailscale /usr/local/bin/; chown -R root:root /usr/local/bin; chmod 1777 /usr/local
echo "dry run exit $(run); on the path: $(grep -c 'not on root' /tmp/out) warnings"
echo "== control 2: /usr/local mode 777 (not sticky): the agent could rename bin away =="
chmod 777 /usr/local; echo "dry run exit $(run); warning: $(grep -m1 'not on root' /tmp/out | cut -c1-120)"
echo "== the case: bin is a link to /opt/tools, /usr/local is 777 =="
rm -rf /usr/local/bin; ln -s /opt/tools /usr/local/bin; chmod 777 /usr/local
echo "dry run exit $(run); warning: $(grep -c 'not on root' /tmp/out) (0 means /usr/local/bin was accepted)"
cat > /tmp/swap.sh <<'SCRIPT'
cd /usr/local
while [ -e /tmp/swap-on ]; do
  ln -sfn /home/agent/evil b.tmp && mv -T b.tmp bin
  ln -sfn /opt/tools b.tmp && mv -T b.tmp bin
done
SCRIPT
touch /tmp/swap-on; setsid runuser -u agent -- bash /tmp/swap.sh >/dev/null 2>&1 &
sleep 0.5
ran=0; n=20
for i in $(seq 1 $n); do rm -f /tmp/FAKE-TAILSCALE-RAN; bash install.sh --dry-run --level observer --transport tailscale > /tmp/out 2>&1; [ -e /tmp/FAKE-TAILSCALE-RAN ] && ran=$((ran+1)); done
rm -f /tmp/swap-on
echo "$n dry runs as root while the agent flips the link: the agent's tailscale ran as root in $ran"
check "the agent's tool never ran as root" test "$ran" = 0
finish
