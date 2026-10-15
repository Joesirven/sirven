#!/usr/bin/env bash
# attack 3: the join logs in and writes its record, then ends in a state that is not Running, so the step fails. the install
# record only gets a line for a step that succeeded. does uninstall still log the node out?
set -uo pipefail
. /src/docs/research/qa/sir-1-33-review-attacks/common.sh
touch /tmp/ts-knob/end-needs-machine-auth
SIRVEN_TAILSCALE_WAIT=1 SIRVEN_TAILSCALE_AUTHKEY="$KEY" install_ts > /tmp/t3.out 2>&1; echo "install exit $?"
tail -6 /tmp/t3.out
echo "node state: $(state); marker: $(ls /var/lib/sirven/tailscale-node.json 2>&1)"
echo "undo line for the join in the install record: $(grep -c 'tailscale_node.sh leave' /var/lib/sirven/install-record.tsv 2>&1)"
bash uninstall.sh --yes > /tmp/t3u.out 2>&1; echo "uninstall exit $?"; tail -5 /tmp/t3u.out
echo "node state after uninstall: $(state); marker: $(ls /var/lib/sirven/tailscale-node.json 2>&1)"
check "uninstall logged out the node a failed join left behind" bash -c '[ "$(cat /tmp/fake-ts/state)" = NeedsLogin ]'
# the same half-joined node, torn down by the kill switch instead
rm -rf "$FAKE_TS_DIR"
SIRVEN_TAILSCALE_WAIT=1 SIRVEN_TAILSCALE_AUTHKEY="$KEY" install_ts > /tmp/t3b.out 2>&1; echo "second install exit $? (node: $(state))"
bash install.sh revoke --all --yes --transport tailscale > /tmp/t3r.out 2>&1; echo "revoke exit $?"
echo "node state after revoke: $(state)"
check "revoke logged out the node a failed join left behind" bash -c '[ "$(cat /tmp/fake-ts/state)" = NeedsLogin ]'
finish
