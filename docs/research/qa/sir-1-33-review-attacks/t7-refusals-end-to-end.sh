#!/usr/bin/env bash
# attack 7: the refusals, through install.sh and not only through the script: a login without the tag, tailscaled down, a tailscale
# too old to read a key from a file. what has already changed when each one stops, and is a login that is not ours ever touched?
set -uo pipefail
. /src/docs/research/qa/sir-1-33-review-attacks/common.sh
world_files > /tmp/empty.files

echo "== A. tailscaled does not answer"
FAKE_TS_STOPPED=yes SIRVEN_TAILSCALE_AUTHKEY="$KEY" install_ts > /tmp/a.out 2>&1; echo "install exit $?"; grep -E "refused|error" /tmp/a.out | head -3
world_unchanged_if 'true' "A: tailscaled down changed nothing" files /tmp/empty.files

echo "== B. already logged in WITHOUT tag:agent, by the owner"
mkdir -p $FAKE_TS_DIR; printf 'Running\n' > $FAKE_TS_DIR/state; printf 'node-owner\n' > $FAKE_TS_DIR/id; : > $FAKE_TS_DIR/tags; printf 'owners-laptop\n' > $FAKE_TS_DIR/name
SIRVEN_TAILSCALE_AUTHKEY="$KEY" install_ts > /tmp/b.out 2>&1; echo "install exit $?"; grep -E "refused|error|without" /tmp/b.out | head -3
echo "calls: $(grep -c '^tailscale up --auth-key' $FAKE_TS_DIR/calls.log) up, $(grep -c '^tailscale logout' $FAKE_TS_DIR/calls.log) logout"
check "B: the owner's login was never re-tagged or re-keyed" bash -c '! grep -q "^tailscale up --auth-key" /tmp/fake-ts/calls.log && [ "$(cat /tmp/fake-ts/id)" = node-owner ] && [ ! -s /tmp/fake-ts/tags ]'
bash install.sh revoke --all --yes --transport tailscale >/dev/null 2>&1; bash uninstall.sh --yes >/dev/null 2>&1
check "B: revoke and uninstall never logged the owner's login out" bash -c '! grep -q "^tailscale logout" /tmp/fake-ts/calls.log && [ "$(cat /tmp/fake-ts/state)" = Running ]'

echo "== C. the owner's own tag:agent login, no record of ours"
rm -rf $FAKE_TS_DIR /var/lib/sirven /etc/sirven; mkdir -p $FAKE_TS_DIR; printf 'Running\n' > $FAKE_TS_DIR/state; printf 'node-owner\n' > $FAKE_TS_DIR/id; printf '"tag:agent"\n' > $FAKE_TS_DIR/tags; printf 'owners-agent-box\n' > $FAKE_TS_DIR/name
install_ts > /tmp/c.out 2>&1; echo "install (no key given) exit $?"
bash install.sh revoke --all --yes --transport tailscale >/dev/null 2>&1; bash uninstall.sh --yes >/dev/null 2>&1
check "C: an adopted tag:agent node is never logged out by us" bash -c '! grep -q "^tailscale logout" /tmp/fake-ts/calls.log && [ "$(cat /tmp/fake-ts/state)" = Running ]'

echo "== D. tailscale too old to read a key file"
rm -rf $FAKE_TS_DIR /var/lib/sirven /etc/sirven /usr/local/sbin/sirven; world_files > /tmp/empty2.files
FAKE_TS_OLD=yes SIRVEN_TAILSCALE_AUTHKEY="$KEY" install_ts > /tmp/d.out 2>&1; echo "install exit $?"; grep -E "refused|error" /tmp/d.out | head -3
echo "files changed before the refusal: $(world_files | diff /tmp/empty2.files - | grep -c '^>')"
world_unchanged_if 'true' "D: a tailscale too old to read a key file is refused before any change" files /tmp/empty2.files
echo "== E. second node of the tailnet carries tag:agent too (the fake always lists one as a peer): a join and leave read only our own entry"
rm -rf $FAKE_TS_DIR /var/lib/sirven /etc/sirven
SIRVEN_TAILSCALE_AUTHKEY="$KEY" install_ts >/dev/null 2>&1; bash install.sh revoke --all --yes --transport tailscale >/dev/null 2>&1
check "E: one logout, of our own node" bash -c '[ "$(grep -c "^tailscale logout" /tmp/fake-ts/calls.log)" = 1 ] && [ "$(cat /tmp/fake-ts/state)" = NeedsLogin ]'
finish
