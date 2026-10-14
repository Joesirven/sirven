#!/usr/bin/env bash
# attack 1: the key file is trusted without a look at who owns it or who can write it. a file anyone can write is a way to
# make the machine join a tailnet of someone else's choosing; a file anyone can read is a leak of the key.
set -uo pipefail
. /src/docs/research/qa/sir-1-33-review-attacks/common.sh
mkdir -p /etc/sirven; chmod 755 /etc/sirven
printf '%s\n' "$KEY" > /etc/sirven/tailscale-auth-key
chown nobody:nogroup /etc/sirven/tailscale-auth-key; chmod 0666 /etc/sirven/tailscale-auth-key
ls -l /etc/sirven/tailscale-auth-key
install_ts > /tmp/t1.out 2>&1; echo "install exit $? (0 means a nobody-owned, world-writable key file was used)"
echo "node state: $(state)"; tail -4 /tmp/t1.out
check "a key file owned by nobody and writable by everyone is refused" bash -c '[ "$(cat /tmp/fake-ts/state 2>/dev/null)" != Running ]'
finish
