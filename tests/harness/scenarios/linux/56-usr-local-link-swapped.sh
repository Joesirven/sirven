#!/usr/bin/env bash
# SIR-32 final round (review S-R3-1, f4). /usr/local/bin is a symbolic link to a root-only folder, and /usr/local (which holds the link
# and is not on the vetted path of the link's target) is writable by the agent. the gate used to vet the target and put the LINK on
# root's search path; the agent flipped the link to its own folder after the check, and its tailscale ran as root (13 of 20). the gate now
# resolves the folder to its physical path, vets that, and puts that path on the search path, so a flipped link changes nothing.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

useradd -m agent
mkdir -p /opt/tools /home/agent/evil /usr/local/sbin
printf '#!/bin/sh\ntouch /tmp/ROOT-TOOL-RAN\necho "tailscale 1.80.0"\n' > /opt/tools/tailscale; chmod 755 /opt/tools/tailscale
printf '#!/bin/sh\ntouch /tmp/FAKE-TAILSCALE-RAN\necho "tailscale 1.80.0"\n' > /home/agent/evil/tailscale; chmod 755 /home/agent/evil/tailscale; chown -R agent /home/agent/evil
run() { rm -f /tmp/FAKE-TAILSCALE-RAN /tmp/ROOT-TOOL-RAN; bash install.sh --dry-run --level observer --transport tailscale > /tmp/out 2>&1; echo $?; }
rm -rf /usr/local/bin; ln -s /opt/tools /usr/local/bin; chmod 777 /usr/local
check "precondition: /usr/local/bin is a link to a root-only folder, and the agent can write /usr/local" bash -c '[ -L /usr/local/bin ] && runuser -u agent -- test -w /usr/local'
check "a dry run finds the root-only tool through the link (it is vetted and used by its physical path)" bash -c "$(declare -f run); [ \"\$(run)\" = 0 ] && [ -e /tmp/ROOT-TOOL-RAN ] && [ ! -e /tmp/FAKE-TAILSCALE-RAN ]"

cat > /tmp/swap.sh <<'SCRIPT'
cd /usr/local
while [ -e /tmp/swap-on ]; do
  ln -sfn /home/agent/evil b.tmp && mv -T b.tmp bin
  ln -sfn /opt/tools b.tmp && mv -T b.tmp bin
done
SCRIPT
touch /tmp/swap-on
setsid runuser -u agent -- bash /tmp/swap.sh >/dev/null 2>&1 &
sleep 0.5
check "precondition: the link flips between the two folders" bash -c 'a="$(readlink /usr/local/bin)"; for _ in $(seq 1 40); do b="$(readlink /usr/local/bin)"; [ "$a" != "$b" ] && exit 0; done; exit 1'
fake=0; real=0; n=20
for i in $(seq 1 $n); do
  rm -f /tmp/FAKE-TAILSCALE-RAN /tmp/ROOT-TOOL-RAN
  bash install.sh --dry-run --level observer --transport tailscale > /tmp/out 2>&1
  [ -e /tmp/FAKE-TAILSCALE-RAN ] && fake=$((fake+1))
  [ -e /tmp/ROOT-TOOL-RAN ] && real=$((real+1))
done
rm -f /tmp/swap-on
echo "$n dry runs as root while the agent flips the link: the agent's tailscale ran in $fake, the root-only one in $real"
check "the agent's tool never ran as root" test "$fake" = 0
check "the root-only tool did run (the folder was vetted and used, not just left off)" test "$real" -gt 0
finish
