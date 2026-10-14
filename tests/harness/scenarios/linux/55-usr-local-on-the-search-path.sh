#!/usr/bin/env bash
# SIR-32 round 3 (parent decision). root's search path is the system folders only, plus /usr/local/sbin and /usr/local/bin when root
# alone controls each (the folder, every folder above it, and what is in it), so tools such as tailscale, cloudflared and bb that
# live there are found. a /usr/local/bin the agent can write to is left out, and the run says so.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

# a fake tailscale that leaves a mark: the plan asks for its version when the transport is tailscale
fake() {  # DIRECTORY OWNER
  printf '#!/bin/sh\ntouch /tmp/FAKE-TAILSCALE-RAN\necho "tailscale 1.80.0"\n' > "$1/tailscale"
  chmod 755 "$1/tailscale"; chown "$2" "$1/tailscale"
}
run() { rm -f /tmp/FAKE-TAILSCALE-RAN; bash install.sh --dry-run --level observer --transport tailscale > /tmp/out 2>&1; echo $?; }
mkdir -p /usr/local/bin /usr/local/sbin
useradd -m agent

# 1. root alone controls /usr/local: the tool there is found and run
chown root:root /usr/local /usr/local/bin /usr/local/sbin; chmod 755 /usr/local /usr/local/bin /usr/local/sbin
fake /usr/local/bin root
check "(1) a dry run as root finds and runs a tool in /usr/local/bin that only root controls" bash -c "$(declare -f run); [ \"\$(run)\" = 0 ] && [ -e /tmp/FAKE-TAILSCALE-RAN ]"
check "(1) and says nothing about leaving a folder out" bash -c '! grep -q "is not on root" /tmp/out'

# 2. the agent can write /usr/local/bin: it is not added, the fake never runs, and the run says why
chown agent /usr/local/bin
check "(2) a /usr/local/bin the agent owns is left off root's path: the tool in it does not run" bash -c "$(declare -f run); run >/dev/null; [ ! -e /tmp/FAKE-TAILSCALE-RAN ]"
check "(2) the run says the folder is not on root's search path" grep -q '/usr/local/bin is not on root.s search path' /tmp/out
chown root /usr/local/bin
chmod 777 /usr/local/bin
check "(2) a world-writable /usr/local/bin is left off too" bash -c "$(declare -f run); run >/dev/null; [ ! -e /tmp/FAKE-TAILSCALE-RAN ] && grep -q '/usr/local/bin is not on root.s search path' /tmp/out"
chmod 755 /usr/local/bin

# 3. a root-owned folder holding a file the agent owns: the file could be replaced, so the folder is left off
chown agent /usr/local/bin/tailscale
check "(3) a root-owned /usr/local/bin that holds a file owned by the agent is left off" bash -c "$(declare -f run); run >/dev/null; [ ! -e /tmp/FAKE-TAILSCALE-RAN ] && grep -q '/usr/local/bin is not on root.s search path' /tmp/out"
chown root /usr/local/bin/tailscale

# 4. a folder above it the agent can write: the folder is left off
chown agent /usr/local
check "(4) a folder above it that the agent owns leaves /usr/local/bin off" bash -c "$(declare -f run); run >/dev/null; [ ! -e /tmp/FAKE-TAILSCALE-RAN ]"
chown root /usr/local

# 5. a system folder always wins: a tool of the same name in /usr/local/bin does not shadow one in /usr/bin
printf '#!/bin/sh\ntouch /tmp/FAKE-SHADOW-RAN\nexec /usr/bin/id.real "$@"\n' > /usr/local/bin/id; chmod 755 /usr/local/bin/id
rm -f /tmp/FAKE-SHADOW-RAN
check_exit "(5) a tool in /usr/local/bin with the name of a system tool does not shadow it" 0 bash install.sh --dry-run --level observer --transport none
check "(5) it did not run" bash -c '[ ! -e /tmp/FAKE-SHADOW-RAN ]'
finish
