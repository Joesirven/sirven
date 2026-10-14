#!/usr/bin/env bash
# SIR-1, SIR-33. the Tailscale transport against the REAL tailscale, in a disposable machine. scenario 61 does the same with a
# fake. this one needs a network and, for the join itself, a test key: an auth key of a TEST tailnet (never Jose's own), tagged
# tag:agent, pre-approved, reusable, ephemeral. without the key the steps that join say "skipped: needs a Tailscale test key"
# and the rest still runs against the real tailscale: apply without a key is refused, and a wrong key fails cleanly with
# nothing recorded and the key nowhere in the output.
# to run the joining steps for real, once a test key is in a dotenv file (a line SIRVEN_TAILSCALE_AUTHKEY=...), as one command:
#   SIRVEN_HARNESS_SECRETS_FILE=/path/to/that.env bash tests/harness/run-linux.sh 62
# (or export SIRVEN_TAILSCALE_AUTHKEY in the shell). the key goes into the container by name or by file, never on a command line.
# harness-tailscale: yes
# harness-memory: 512m
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

ENV_KEY="${SIRVEN_TAILSCALE_AUTHKEY:-}"
# docker --env-file keeps the quotes a dotenv writer may put around a value, and a key with quotes is not a key
ENV_KEY="${ENV_KEY#[\"\']}"; ENV_KEY="${ENV_KEY%[\"\']}"
# the harness passes the key line of a dotenv file and nothing else from it: a canary variable in that file must not be here
check "no variable of the secrets file but the key reached this container" bash -c '[ -z "${SIRVEN_HARNESS_CANARY:-}" ]'
BAD_KEY="tskey""-auth-kINVALIDinvalid-INVALIDINVALIDINVALIDINVALIDINVALID"
unset SIRVEN_TAILSCALE_AUTHKEY TAILSCALE_AUTHKEY
export BAD_KEY
install_ts() { bash install.sh --yes --level observer --transport tailscale "$@"; }
node_status() { tailscale status --json 2>/dev/null | python3 -I -c '
import json, sys
s = json.load(sys.stdin)
me = s.get("Self") or {}
print("%s|%s|%s" % (s.get("BackendState"), ",".join(me.get("Tags") or []), me.get("HostName") or ""))'; }
export -f node_status

# our own tailscaled, no tun device and no privileges: userspace networking, state in a file of this container
mkdir -p /var/lib/tailscale /var/run/tailscale
tailscaled --tun=userspace-networking --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock >/tmp/tailscaled.log 2>&1 &
for _ in 1 2 3 4 5 6 7 8 9 10; do tailscale status --json >/dev/null 2>&1 && break; sleep 1; done
check "tailscaled answers and this machine is logged out" bash -c '[ "$(tailscale status --json | python3 -I -c "import json,sys; print(json.load(sys.stdin)[\"BackendState\"])")" = NeedsLogin ]'

# whatever happens, a node this scenario made does not outlive it (an ephemeral key drops it anyway)
leave_tailnet() { if [ "$(node_status | cut -d'|' -f2)" = "tag:agent" ]; then tailscale logout >/dev/null 2>&1; fi; }
trap leave_tailnet EXIT

world_files > /tmp/empty.files
check_exit "apply without an auth key is refused" 2 install_ts
check "and it names the key and changes nothing" bash -c 'grep -q "there is no Tailscale auth key" <<< "$0" && grep -q "nothing was changed" <<< "$0"' "$LAST_OUTPUT"
world_unchanged_if 'true' "files unchanged" files /tmp/empty.files

# a wrong key reaches the real control server and is turned away: no node, no record, and the key is in no output
SIRVEN_TAILSCALE_AUTHKEY="$BAD_KEY" check_exit "apply with a wrong key fails" 4 install_ts
bad_out="$LAST_OUTPUT"
check "it says tailscale up failed, and why the machine is not joined" bash -c 'grep -q "tailscale up failed" <<< "$0"' "$bad_out"
check "the wrong key is in no output" bash -c '! grep -qF -- "$BAD_KEY" <<< "$0"' "$bad_out"
check "nothing is recorded and the machine is still logged out" bash -c '[ ! -e /var/lib/sirven/tailscale-node.json ] && [ "$(tailscale status --json | python3 -I -c "import json,sys; print(json.load(sys.stdin)[\"BackendState\"])")" = NeedsLogin ]'
check "no copy of the key is left on the disk" bash -c '! grep -rlF -- "$BAD_KEY" /etc /var /root /home /usr/local 2>/dev/null | grep -q .'

if [ -z "$ENV_KEY" ]; then
  skip "apply joins the test tailnet as tag:agent" "needs a Tailscale test key (SIRVEN_TAILSCALE_AUTHKEY in the environment, or in the dotenv file named by SIRVEN_HARNESS_SECRETS_FILE; see the top of this scenario)"
  skip "status reports connected, a second apply does nothing, revoke logs the node out" "needs a Tailscale test key"
  finish
  exit $?
fi

export KEY="$ENV_KEY"
SIRVEN_TAILSCALE_AUTHKEY="$KEY" check_exit "apply with the test key joins the test tailnet" 0 install_ts
out="$LAST_OUTPUT"
check "status reports connected, tagged tag:agent, named after the account" bash -c 'IFS="|" read -r backend tags name <<< "$(node_status)"; [ "$backend" = Running ] && [ "$tags" = tag:agent ] && case "$name" in agent-harness-*) true ;; *) false ;; esac'
check "the node has a tailnet address" bash -c 'tailscale ip -4 | grep -q "^100\."'
check "the record names the node" bash -c '[ "$(stat -c %a:%U /var/lib/sirven/tailscale-node.json)" = 600:root ] && grep -q "\"tag\": \"tag:agent\"" /var/lib/sirven/tailscale-node.json'
check "the key is in no output, no file, and not on the command line of any process" bash -c '
  ! grep -qF -- "$KEY" <<< "$0" && ! grep -rlF -- "$KEY" /etc /var /root /home /usr/local 2>/dev/null | grep -q . &&
  ! ps -eo args | grep -qF -- "$KEY"' "$out"
check "the audit log has no key" bash -c '! grep -qF -- "$KEY" /var/log/sirven/audit.jsonl'

SIRVEN_TAILSCALE_AUTHKEY="$KEY" check_exit "a second apply exits 0" 0 install_ts
check "and the node is still up and tagged" bash -c 'IFS="|" read -r backend tags name <<< "$(node_status)"; [ "$backend" = Running ] && [ "$tags" = tag:agent ]'

check_exit "revoke --all logs the node out" 0 bash install.sh revoke --all --yes --transport tailscale
check "status reports logged out and the record is gone" bash -c '[ "$(node_status | cut -d"|" -f1)" = NeedsLogin ] && [ ! -e /var/lib/sirven/tailscale-node.json ]'
check_exit "a second revoke exits 0" 0 bash install.sh revoke --all --yes --transport tailscale
# the tailnet side (that the node left the test tailnet) needs an administrator credential this scenario does not hold: with an
# ephemeral key the node is dropped when it logs out, otherwise it stays listed as expired until the tailnet owner deletes it.

finish
