#!/usr/bin/env bash
# attack 4: logout does nothing (tailnet unreachable, say). revoke and uninstall must say so, exit nonzero, keep the record, and a
# second run after the cause is fixed must finish the job. in uninstall, the pinned copy the undo line needs must still be there.
set -uo pipefail
. /src/docs/research/qa/sir-1-33-review-attacks/common.sh
SIRVEN_TAILSCALE_AUTHKEY="$KEY" install_ts >/dev/null 2>&1; echo "joined: $(state)"
export FAKE_TS_LOGOUT_FAILS=yes
bash install.sh revoke --all --yes --transport tailscale > /tmp/t4r.out 2>&1; echo "revoke exit $?"; grep -iE "error|failed|logout" /tmp/t4r.out | head -6
echo "record kept: $(ls /var/lib/sirven/tailscale-node.json 2>&1)"
bash uninstall.sh --yes > /tmp/t4u.out 2>&1; echo "uninstall exit $?"; grep -iE "error|failed|logout|left" /tmp/t4u.out | head -8
echo "after the failed uninstall: marker $(ls /var/lib/sirven/tailscale-node.json 2>&1); pinned copy $(ls /var/lib/sirven/package/lib/tailscale_node.sh 2>&1); install record $(ls /var/lib/sirven/install-record.tsv 2>&1); state $(state)"
unset FAKE_TS_LOGOUT_FAILS
bash uninstall.sh --yes > /tmp/t4u2.out 2>&1; echo "second uninstall exit $?"; tail -4 /tmp/t4u2.out
echo "final state: $(state); marker $(ls /var/lib/sirven/tailscale-node.json 2>&1)"
check "the second run finished the logout" bash -c '[ "$(cat /tmp/fake-ts/state)" = NeedsLogin ]'
finish
