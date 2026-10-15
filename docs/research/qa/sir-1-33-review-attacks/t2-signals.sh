#!/usr/bin/env bash
# attack 2: the private copy of the key is removed on a normal end, an error, and on SIGTERM, SIGINT and SIGHUP; SIGKILL cannot be caught.
set -uo pipefail
. /src/docs/research/qa/sir-1-33-review-attacks/common.sh
mkdir -p /var/lib/sirven; chmod 700 /var/lib/sirven
echo "state dir: $(stat -c '%a:%U' /var/lib/sirven)"
touch /tmp/ts-knob/slow
for sig in TERM INT HUP; do
  rm -rf "$FAKE_TS_DIR" /tmp/ts-up-view /var/lib/sirven/tailscale-node.json
  # timeout sends the signal to the script (a foreground child, so it has the default disposition for INT)
  SIRVEN_TAILSCALE_AUTHKEY="$KEY" timeout --foreground -s "$sig" 2 bash lib/tailscale_node.sh join /var/lib/sirven/tailscale-node.json agent /nonexistent >/tmp/t2.out 2>&1
  echo "$sig: script ended with exit $?"
  sleep 1
  left="$(ls /var/lib/sirven/.tailscale-key.* 2>/dev/null | tr '\n' ' ')"
  echo "$sig: private copy left on disk after the script was signalled: [${left}]"
  check "$sig: no copy of the key is left after the script is signalled" test -z "$left"
  pkill -f 'sleep 30' 2>/dev/null
  rm -f /var/lib/sirven/.tailscale-key.*
done
# SIGKILL cannot be caught, by anyone: the copy stays, root-only, in a root-only folder
rm -rf "$FAKE_TS_DIR"
SIRVEN_TAILSCALE_AUTHKEY="$KEY" setsid bash lib/tailscale_node.sh join /var/lib/sirven/tailscale-node.json agent /nonexistent >/tmp/t2.out 2>&1 &
pid=$!; sleep 2; kill -KILL "$pid"; sleep 1; pkill -f 'sleep 30' 2>/dev/null
echo "KILL: private copy left on disk: $(ls -l /var/lib/sirven/.tailscale-key.* 2>/dev/null | awk '{print $1, $3, $9}' | tr '\n' ' ')"
echo "a later join on the same machine: does it clean up the stale copy? (run a normal join)"
rm -f /tmp/ts-knob/slow; rm -rf "$FAKE_TS_DIR"
SIRVEN_TAILSCALE_AUTHKEY="$KEY" bash lib/tailscale_node.sh join /var/lib/sirven/tailscale-node.json agent /nonexistent >/dev/null 2>&1
echo "after a later normal join: $(ls /var/lib/sirven/.tailscale-key.* 2>/dev/null | tr '\n' ' ')"
bash lib/tailscale_node.sh leave /var/lib/sirven/tailscale-node.json >/dev/null 2>&1
echo "after leave: $(ls /var/lib/sirven/.tailscale-key.* 2>/dev/null | tr '\n' ' ')"
check "a later normal join swept the copy a killed join left" bash -c '! ls /var/lib/sirven/.tailscale-key.* 2>/dev/null | grep -q .'
# and a killed join followed by leave alone, with no record at all
printf 'stale\n' > /var/lib/sirven/.tailscale-key.999
bash lib/tailscale_node.sh leave /var/lib/sirven/tailscale-node.json >/dev/null 2>&1
check "leave with no record at all swept a stale copy" bash -c '! ls /var/lib/sirven/.tailscale-key.* 2>/dev/null | grep -q .'
finish
