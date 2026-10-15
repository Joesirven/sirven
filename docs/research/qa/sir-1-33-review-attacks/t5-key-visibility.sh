#!/usr/bin/env bash
# attack 5: where the key is visible while the join runs: tailscale's own argv and environment, the files beside the private copy,
# and the environment of the other installer steps (which run as root and never as the service account).
set -uo pipefail
. /src/docs/research/qa/sir-1-33-review-attacks/common.sh
SIRVEN_TAILSCALE_AUTHKEY="$KEY" install_ts > /tmp/t5.out 2>&1; echo "install exit $?"
echo "--- what tailscale up saw:"; cat /tmp/ts-up-view
check "tailscale's argv holds no key" bash -c '! grep -q "^argv:.*ATTACKkey" /tmp/ts-up-view'
check "tailscale's environment holds no key" bash -c 'grep -q "^environ-has-key: 0" /tmp/ts-up-view'
check "the private copy is gone and the folder holds no other copy" bash -c '! ls /var/lib/sirven/.tailscale-key.* 2>/dev/null | grep -q .'
check "no file anywhere holds the key" bash -c '! grep -rlF -- "$KEY" /etc /var /root /home /usr /tmp/fake-ts /tmp/t5.out 2>/dev/null | grep -q .'
finish
