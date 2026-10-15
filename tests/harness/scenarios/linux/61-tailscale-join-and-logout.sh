#!/usr/bin/env bash
# SIR-1, SIR-33. the Tailscale transport on a real install, with a fake tailscale that keeps a login state (the real
# one is scenario 62, which needs a test key and a network). apply without a key is refused before the first change;
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

# stand-ins for mkdir, chown and install (the commands the steps before the join run) that record the NAMES, never the values, of the
# variables in the environment they were started with, then run the real command. for the runs that follow only (a disposable machine).
CHILD_ENV_LOG=/tmp/child-environment-names
shim_children_on() {
  local name
  : > "$CHILD_ENV_LOG"
  for name in mkdir chown install; do
    mv "/usr/bin/$name" "/usr/bin/$name.real"
    printf '#!/bin/sh\nprintf "%%s: %%s\\n" "%s" "$(env | /usr/bin/sed "s/=.*//" | /usr/bin/tr "\\n" " ")" >> %s\nexec /usr/bin/%s.real "$@"\n' "$name" "$CHILD_ENV_LOG" "$name" > "/usr/bin/$name"
    chmod 755 "/usr/bin/$name"
  done
}
shim_children_off() {
  local name
  for name in mkdir chown install; do mv -f "/usr/bin/$name.real" "/usr/bin/$name"; done
}

# 1. no key: refused up front, nothing changed
world_files > /tmp/empty.files
world_accounts > /tmp/empty.accounts
check_exit "apply without an auth key is refused" 2 install_ts
check "the refusal says there is no key and names the two ways to give one" bash -c 'grep -q "there is no Tailscale auth key" <<< "$0" && grep -q "SIRVEN_TAILSCALE_AUTHKEY" <<< "$0" && grep -q "nothing was changed" <<< "$0"' "$LAST_OUTPUT"
world_unchanged_if 'true' "and it changed nothing: files" files /tmp/empty.files
world_unchanged_if 'true' "and it changed nothing: accounts" accounts /tmp/empty.accounts
check "tailscale was never asked to join" bash -c '! grep -q "^tailscale up --auth-key" /tmp/fake-ts/calls.log 2>/dev/null'

# 1b. a key file with an access entry for another account is refused before the first change, whatever the mask shows. the mask
# decides what the group bits of ls show: at r-- they show the entry, at --- they show nothing at all, and both are refused.
KEY_FILE=/etc/sirven/tailscale-auth-key
mkdir -p /etc/sirven
printf '%s\n' "$KEY" > "$KEY_FILE"; chown root:root "$KEY_FILE"; chmod 600 "$KEY_FILE"
setfacl -m u:nobody:r "$KEY_FILE"
check "the entry shows in the group bits (the mask is r--)" bash -c '[ "$(ls -ldn "$0" | cut -c1-11)" = "-rw-r-----+" ]' "$KEY_FILE"
check_exit "apply with a root-owned 0600 key file that has an entry for another account is refused" 2 install_ts
check "the refusal names the access control list, and nothing was changed" bash -c 'grep -q "extended access control list" <<< "$0" && grep -q "nothing was changed" <<< "$0"' "$LAST_OUTPUT"
check "the key is not in the refusal" bash -c '! grep -qF -- "$KEY" <<< "$0"' "$LAST_OUTPUT"
setfacl -m m::--- "$KEY_FILE"
check "with the mask at --- the group bits show nothing: the case the mode bits alone let through" bash -c '[ "$(ls -ldn "$0" | cut -c1-11)" = "-rw-------+" ]' "$KEY_FILE"
check_exit "the same file is refused with the mask hiding the entry" 2 install_ts
check "and it names the access control list" bash -c 'grep -q "extended access control list" <<< "$0"' "$LAST_OUTPUT"
check "tailscale was never asked to join" bash -c '! grep -q "^tailscale up --auth-key" /tmp/fake-ts/calls.log 2>/dev/null'
# 1c. a key file with a second name (a hard link) is refused too: the other name may sit where others can read it
setfacl -b "$KEY_FILE"
mkdir -p /var/other-name && ln "$KEY_FILE" /var/other-name/copy
check_exit "apply with a root-owned 0600 key file that has a second name is refused" 2 install_ts
check "the refusal says the file has more than one name, and nothing was changed" bash -c 'grep -q "more than one name" <<< "$0" && grep -q "nothing was changed" <<< "$0"' "$LAST_OUTPUT"
check "the key is not in the refusal" bash -c '! grep -qF -- "$KEY" <<< "$0"' "$LAST_OUTPUT"
rm -rf /var/other-name
rm -rf /etc/sirven
world_unchanged_if 'true' "and it changed nothing: files" files /tmp/empty.files
world_unchanged_if 'true' "and it changed nothing: accounts" accounts /tmp/empty.accounts

# 2. with a key: joined, tagged, recorded. a saved key file is there too, so the step after the join (it removes that file) runs. root
# finds rm in the system folders first, so for this step only (a disposable machine) the real rm is moved aside and a stand-in takes
# its place: it records the names (never the values) of the variables in the environment it was started with, then runs the real one.
mkdir -p /etc/sirven
printf '%s\n' "$KEY" > "$KEY_FILE"; chown root:root "$KEY_FILE"; chmod 600 "$KEY_FILE"
mv /usr/bin/rm /usr/bin/rm.real
printf '#!/bin/sh\ncase "$*" in *tailscale-auth-key*) env | /usr/bin/sed "s/=.*//" > /tmp/rm-environment-names ;; esac\nexec /usr/bin/rm.real "$@"\n' > /usr/bin/rm
chmod 755 /usr/bin/rm
shim_children_on
SIRVEN_TAILSCALE_AUTHKEY="$KEY" TAILSCALE_AUTHKEY="$KEY" check_exit "apply with a key joins the tailnet" 0 install_ts
out="$LAST_OUTPUT"
mv -f /usr/bin/rm.real /usr/bin/rm
shim_children_off
check "steps before the join did start children (so the next check proves something)" bash -c '[ "$(grep -c "^mkdir:" "$0")" -gt 0 ] && [ "$(grep -c "^chown:" "$0")" -gt 0 ]' "$CHILD_ENV_LOG"
check "and none of them was started with either key variable in its environment" bash -c '! grep -q "AUTHKEY" "$0"' "$CHILD_ENV_LOG"
check "the step after the join started its child with neither key variable in the environment" bash -c '[ -s /tmp/rm-environment-names ] && ! grep -q "TAILSCALE_AUTHKEY" /tmp/rm-environment-names'
check "and the saved key file was removed by that step" bash -c '[ ! -e "$0" ]' "$KEY_FILE"
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
# the machine is the agent node now, so the join is skipped: a key in the environment must still reach no child
shim_children_on
SIRVEN_TAILSCALE_AUTHKEY="$KEY" TAILSCALE_AUTHKEY="$KEY" check_exit "a second apply with a key in the environment (no join runs) exits 0" 0 install_ts
shim_children_off
check "no join ran, and the steps that did run started children" bash -c '[ "$(grep -c "^tailscale up --auth-key" /tmp/fake-ts/calls.log)" = 1 ] && [ -s "$0" ]' "$CHILD_ENV_LOG"
check "none of them was started with either key variable in its environment" bash -c '! grep -q "AUTHKEY" "$0"' "$CHILD_ENV_LOG"
check "and it did not join again" bash -c '[ "$(grep -c "^tailscale up --auth-key" /tmp/fake-ts/calls.log)" = 1 ]'
world_unchanged_if 'true' "and it changed no file" files /tmp/one.files

# 4. revoke logs out the node apply joined, and only it
check_exit "revoke --all applies" 0 bash install.sh revoke --all --yes --transport tailscale
check "the node is logged out and the record is gone" bash -c '[ "$(cat /tmp/fake-ts/state)" = NeedsLogin ] && [ ! -e /var/lib/sirven/tailscale-node.json ]'
check "the revoke plan showed the logout and the audit log recorded the step" bash -c 'grep -q "log this machine out of the tailnet" <<< "$0" && grep -q "log this machine out of the tailnet" /var/log/sirven/audit.jsonl' "$LAST_OUTPUT"
check_exit "a second revoke exits 0" 0 bash install.sh revoke --all --yes --transport tailscale
check "and logged out nothing more" bash -c '[ "$(grep -c "^tailscale logout" /tmp/fake-ts/calls.log)" = 1 ]'
check_exit "uninstall after revoke exits 0" 0 bash uninstall.sh --yes
check "uninstall had no login left to undo, and the key is still nowhere" no_key_on_disk

# 5. a login that is not ours is never logged out: apply, then somebody else logs this machine in
rm -rf /tmp/fake-ts /var/lib/sirven/package
bash uninstall.sh --yes >/dev/null 2>&1
SIRVEN_TAILSCALE_AUTHKEY="$KEY" check_exit "apply again on a clean machine joins" 0 install_ts
printf 'Running\n' > /tmp/fake-ts/state; printf 'node-owner\n' > /tmp/fake-ts/id; printf '\n' > /tmp/fake-ts/tags
check_exit "revoke with another login present exits 0" 0 bash install.sh revoke --all --yes --transport tailscale
check "it left the other login alone and dropped its stale record" bash -c '[ "$(cat /tmp/fake-ts/state)" = Running ] && ! grep -q "^tailscale logout" /tmp/fake-ts/calls.log && [ ! -e /var/lib/sirven/tailscale-node.json ]'

# 6. uninstall alone logs out what install joined
printf 'NeedsLogin\n' > /tmp/fake-ts/state
bash uninstall.sh --yes >/dev/null 2>&1
rm -f /var/lib/sirven/revoked* /etc/sirven/grants/*.revoked 2>/dev/null
SIRVEN_TAILSCALE_AUTHKEY="$KEY" check_exit "install --reinstate after a revoke joins again" 0 install_ts --reinstate
check_exit "uninstall logs the node out" 0 bash uninstall.sh --yes
check "the node is logged out" bash -c '[ "$(cat /tmp/fake-ts/state)" = NeedsLogin ]'

finish
