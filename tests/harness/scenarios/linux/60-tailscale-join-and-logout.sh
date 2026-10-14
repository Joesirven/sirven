#!/usr/bin/env bash
# SIR-1, SIR-33. the Tailscale transport on a real install, with a fake tailscale that keeps a login state (the real
# one is scenario 61, which needs a test key and a network). apply without a key is refused before the first change;
# apply with a key joins as tag:agent and records the node; a second apply does nothing; the key is nowhere on the
# disk or in any output; revoke and uninstall log out exactly that node and nothing else, and are safe to repeat.
set -uo pipefail
. "$(dirname "$0")/../../lib/world.sh"
cd "$SRC" || exit 2

export KEY="tskey""-auth-SENTINELkey0123456789-ZZZZ"
export FAKE_TS_DIR=/tmp/fake-ts FAKE_TS_KEY="$KEY" SIRVEN_TAILSCALE_HOSTNAME=harness-node
install -o root -g root -m 755 "$SRC/tests/fixtures/tailscale-node/tailscale" /usr/local/bin/tailscale
install_ts() { bash install.sh --yes --level observer --transport tailscale "$@"; }
state() { cat "$FAKE_TS_DIR/state" 2>/dev/null; }
no_key_on_disk() { local hits; hits="$(grep -rl -F -- "$KEY" /etc /var /root /home /usr/local 2>/dev/null)"; [ -z "$hits" ] || { printf "the key is in: %s\n" "$hits"; return 1; }; }

# 1. no key: refused up front, nothing changed
world_files > /tmp/empty.files
world_accounts > /tmp/empty.accounts
check_exit "apply without an auth key is refused" 2 install_ts
check "the refusal says there is no key and names the two ways to give one" bash -c 'grep -q "there is no Tailscale auth key" <<< "$0" && grep -q "SIRVEN_TAILSCALE_AUTHKEY" <<< "$0" && grep -q "nothing was changed" <<< "$0"' "$LAST_OUTPUT"
world_unchanged_if 'true' "and it changed nothing: files" files /tmp/empty.files
world_unchanged_if 'true' "and it changed nothing: accounts" accounts /tmp/empty.accounts
check "tailscale was never asked to join" bash -c '! grep -q "^tailscale up --auth-key" /tmp/fake-ts/calls.log 2>/dev/null'

# 2. with a key: joined, tagged, recorded
SIRVEN_TAILSCALE_AUTHKEY="$KEY" check_exit "apply with a key joins the tailnet" 0 install_ts
out="$LAST_OUTPUT"
check "the node is up, tagged tag:agent, named after the account" bash -c '[ "$(cat /tmp/fake-ts/state)" = Running ] && grep -q tag:agent /tmp/fake-ts/tags && grep -q -- "--hostname=agent-harness-node" /tmp/fake-ts/up-arguments'
check "no Tailscale SSH, no route or name resolution acceptance, no exit node" bash -c '! grep -q -e "--exit-node" /tmp/fake-ts/up-arguments && grep -q -e "--ssh=false" -e "--accept-dns=false" -e "--accept-routes=false" /tmp/fake-ts/up-arguments'
check "the record is root-only and names the node" bash -c '[ "$(stat -c %a:%U /var/lib/sirven/tailscale-node.json)" = 600:root ] && grep -q "\"node_id\": \"nodeid-" /var/lib/sirven/tailscale-node.json'
check "the key reached tailscale in a private file, not on the command line" bash -c '[ "$(cat /tmp/fake-ts/keyfile-mode)" = "-rw-------" ] && [ ! -e /tmp/fake-ts/key-on-argv ]'
check "the key is nowhere on the disk" no_key_on_disk
check "the key is in no output" bash -c '! grep -qF -- "$KEY" <<< "$0"' "$out"
check "the audit log has no key" bash -c '! grep -qF -- "$KEY" /var/log/sirven/audit.jsonl'
check "the install record can undo the join" grep -q 'tailscale_node.sh leave /var/lib/sirven/tailscale-node.json' /var/lib/sirven/install-record.tsv

# 3. again: nothing more happens, no error, and no key is needed
world_files > /tmp/one.files
check_exit "a second apply without any key exits 0" 0 install_ts
check "and it did not join again" bash -c '[ "$(grep -c "^tailscale up --auth-key" /tmp/fake-ts/calls.log)" = 1 ]'
world_unchanged_if 'true' "and it changed no file" files /tmp/one.files

# 4. revoke logs out the node apply joined, and only it
check_exit "revoke --all applies" 0 bash install.sh revoke --all --yes --transport tailscale
check "the node is logged out and the record is gone" bash -c '[ "$(cat /tmp/fake-ts/state)" = NeedsLogin ] && [ ! -e /var/lib/sirven/tailscale-node.json ]'
check "the revoke plan showed the logout and the audit log recorded the step" bash -c 'grep -q "log this machine out of the tailnet" <<< "$0" && grep -q "log this machine out of the tailnet" /var/log/sirven/audit.jsonl' "$LAST_OUTPUT"
check_exit "a second revoke exits 0" 0 bash install.sh revoke --all --yes --transport tailscale
check "and logged out nothing more" bash -c '[ "$(grep -c "^tailscale logout" /tmp/fake-ts/calls.log)" = 1 ]'
check_exit "uninstall after revoke exits 0" 0 bash uninstall.sh
check "uninstall had no login left to undo, and the key is still nowhere" no_key_on_disk

# 5. a login that is not ours is never logged out: apply, then somebody else logs this machine in
rm -rf /tmp/fake-ts /var/lib/sirven/package
bash uninstall.sh >/dev/null 2>&1
SIRVEN_TAILSCALE_AUTHKEY="$KEY" check_exit "apply again on a clean machine joins" 0 install_ts
printf 'Running\n' > /tmp/fake-ts/state; printf 'node-owner\n' > /tmp/fake-ts/id; printf '\n' > /tmp/fake-ts/tags
check_exit "revoke with another login present exits 0" 0 bash install.sh revoke --all --yes --transport tailscale
check "it left the other login alone and dropped its stale record" bash -c '[ "$(cat /tmp/fake-ts/state)" = Running ] && ! grep -q "^tailscale logout" /tmp/fake-ts/calls.log && [ ! -e /var/lib/sirven/tailscale-node.json ]'

# 6. uninstall alone logs out what install joined
printf 'NeedsLogin\n' > /tmp/fake-ts/state
bash uninstall.sh >/dev/null 2>&1
rm -f /var/lib/sirven/revoked* /etc/sirven/grants/*.revoked 2>/dev/null
SIRVEN_TAILSCALE_AUTHKEY="$KEY" check_exit "install --reinstate after a revoke joins again" 0 install_ts --reinstate
check_exit "uninstall logs the node out" 0 bash uninstall.sh
check "the node is logged out" bash -c '[ "$(cat /tmp/fake-ts/state)" = NeedsLogin ]'

finish
