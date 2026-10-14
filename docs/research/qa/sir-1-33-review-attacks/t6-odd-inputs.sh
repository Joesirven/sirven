#!/usr/bin/env bash
# attack 6: odd host names, a key file with a carriage return, a key file that is a link, and a key that is rejected after other steps ran.
set -uo pipefail
. /src/docs/research/qa/sir-1-33-review-attacks/common.sh
mkdir -p /var/lib/sirven; chmod 700 /var/lib/sirven
for h in '-evil' 'Dröp Table;x' 'a..b' "$(printf 'x%.0s' $(seq 1 100))" '../../etc'; do
  rm -rf "$FAKE_TS_DIR" /var/lib/sirven/tailscale-node.json
  SIRVEN_TAILSCALE_HOSTNAME="$h" SIRVEN_TAILSCALE_AUTHKEY="$KEY" bash lib/tailscale_node.sh join /var/lib/sirven/tailscale-node.json agent /nope >/dev/null 2>&1
  echo "host name seed [$h] -> exit $?, node name: $(cat $FAKE_TS_DIR/name 2>/dev/null)"
done
rm -rf "$FAKE_TS_DIR" /var/lib/sirven/tailscale-node.json
mkdir -p /etc/sirven; printf '%s\r\n' "$KEY" > /etc/sirven/tailscale-auth-key; chown root:root /etc/sirven/tailscale-auth-key; chmod 600 /etc/sirven/tailscale-auth-key
world_files > /tmp/empty.files
install_ts > /tmp/t6.out 2>&1; echo "install with a CRLF key file: exit $? (the refusal comes after how many changes?)"; tail -3 /tmp/t6.out
world_unchanged_if 'true' "a malformed key file changed nothing (the promise of 'refused before the first change')" files /tmp/empty.files
finish
