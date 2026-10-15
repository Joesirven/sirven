# shellcheck shell=bash
# the Tailscale transport: lib/tailscale_node.sh joins this machine as the tagged agent node and logs the same
# node out again, and the plan, the kill switch and uninstall use it. the fake tailscale keeps a login state of its
# own in FAKE_TS_DIR and answers 'up' only for the one key a test hands it. a key this long and odd is a sentinel:
# it must appear nowhere but in the environment of the test.

FAKE="$REPO_DIR/tests/fixtures/tailscale-node/tailscale"
SENTINEL_KEY="tskey""-auth-SENTINELkey0123456789-ZZZZ"
NODE="$REPO_DIR/lib/tailscale_node.sh"

# setup: a state directory for the record, and the fake's own folder.
# the script ignores the SIRVEN_TAILSCALE seam when it runs as root (root runs only the vetted tailscale), so as root these
# tests could not use the fake: they end here, and scenario 61 covers the same ground as root, in a container.
setup_node() {
  if [ "$(id -u)" -eq 0 ]; then
    printf 'skipped: these tests need a normal user, because root ignores the SIRVEN_TAILSCALE seam\n'
    exit 0
  fi
  STATE="$TEST_TMP/state"
  mkdir -p "$STATE"
  MARKER="$STATE/tailscale-node.json"
  FAKE_TS_DIR="$TEST_TMP/fake"
  export FAKE_TS_DIR
  SIRVEN_TAILSCALE="$FAKE"
  export SIRVEN_TAILSCALE
  SIRVEN_TAILSCALE_HOSTNAME="Example_Host.local"
  export SIRVEN_TAILSCALE_HOSTNAME
  SIRVEN_TAILSCALE_WAIT=5
  export SIRVEN_TAILSCALE_WAIT
  unset SIRVEN_TAILSCALE_AUTHKEY TAILSCALE_AUTHKEY FAKE_TS_NO_ID FAKE_TS_ECHO_KEY FAKE_TS_UNTAGGED FAKE_TS_OLD FAKE_TS_LOGOUT_FAILS FAKE_TS_STOPPED
  FAKE_TS_KEY="$SENTINEL_KEY"
  export FAKE_TS_KEY
}

join() {
  bash "$NODE" join "$MARKER" agent "$TEST_TMP/no-key-file"
}

leave() {
  bash "$NODE" leave "$MARKER"
}

calls() {
  cat "$FAKE_TS_DIR/calls.log" 2>/dev/null || true
}

# a login the fake already has, as a state, an id, and the tags between the quotes of a JSON list.
fake_login() {
  mkdir -p "$FAKE_TS_DIR"
  printf '%s\n' "$1" > "$FAKE_TS_DIR/state"
  printf '%s\n' "$2" > "$FAKE_TS_DIR/id"
  printf '%s\n' "$3" > "$FAKE_TS_DIR/tags"
  printf 'someone-elses-machine\n' > "$FAKE_TS_DIR/name"
}

# nothing anywhere under the folders, or in the last output, holds the key.
assert_key_nowhere() {
  if grep -rl -F -- "$SENTINEL_KEY" "$@" >/dev/null 2>&1; then fail "the auth key was written under: $*"; fi
  assert_not_contains "$CAPTURED_STDOUT" "$SENTINEL_KEY" "standard output"
  assert_not_contains "$CAPTURED_STDERR" "$SENTINEL_KEY" "standard error"
}

test_join_logs_in_tagged_and_records_the_node() {
  setup_node
  SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 0 join
  assert_contains "$CAPTURED_STDOUT" "joined the tailnet as agent-example-host-local"
  assert_eq "Running" "$(cat "$FAKE_TS_DIR/state")"
  assert_contains "$(cat "$FAKE_TS_DIR/tags")" "tag:agent"
  assert_contains "$(cat "$FAKE_TS_DIR/up-arguments")" "--advertise-tags=tag:agent"
  assert_contains "$(cat "$FAKE_TS_DIR/up-arguments")" "--hostname=agent-example-host-local"
  assert_contains "$(cat "$FAKE_TS_DIR/up-arguments")" "--ssh=false"
  assert_contains "$(cat "$FAKE_TS_DIR/up-arguments")" "--accept-dns=false"
  assert_contains "$(cat "$FAKE_TS_DIR/up-arguments")" "--accept-routes=false"
  assert_not_contains "$(cat "$FAKE_TS_DIR/up-arguments")" "--exit-node"
  assert_not_contains "$(cat "$FAKE_TS_DIR/up-arguments")" "tskey"
  assert_file_exists "$MARKER"
  # shellcheck disable=SC2012 # ls -ln is the portable way to read a mode string on macos and linux, as the other tests do
  assert_eq "-rw-------" "$(ls -ln "$MARKER" | cut -c1-10)" "the record's mode"
  assert_contains "$(cat "$MARKER")" '"node_id": "nodeid-'
  assert_contains "$(cat "$MARKER")" '"tag": "tag:agent"'
  # the key reached tailscale through a private file that is gone again, never on the command line
  assert_eq "-rw-------" "$(cat "$FAKE_TS_DIR/keyfile-mode")" "mode of the private key copy"
  assert_no_file "$FAKE_TS_DIR/key-on-argv"
  assert_eq "1" "$(find "$STATE" -mindepth 1 | wc -l | tr -d ' ')" "only the record is in the state folder"
  assert_key_nowhere "$STATE" "$FAKE_TS_DIR"
}

test_joining_again_does_nothing_and_does_not_fail() {
  setup_node
  SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 0 join
  SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 0 join
  assert_contains "$CAPTURED_STDOUT" "already logged in to Tailscale as tag:agent"
  assert_eq "1" "$(calls | grep -c '^tailscale up --auth-key')" "tailscale up runs once"
}

test_the_key_can_come_from_either_variable_or_the_key_file() {
  setup_node
  TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 0 join
  assert_file_exists "$MARKER"
  rm -rf "$FAKE_TS_DIR" "$MARKER"
  printf '%s\n' "$SENTINEL_KEY" > "$TEST_TMP/key-file"
  chmod 600 "$TEST_TMP/key-file"
  assert_status 0 bash "$NODE" join "$MARKER" agent "$TEST_TMP/key-file"
  assert_file_exists "$MARKER"
  assert_key_nowhere "$STATE" "$FAKE_TS_DIR"
}

test_join_without_a_key_is_refused_before_tailscale_runs() {
  setup_node
  assert_status 2 join
  assert_contains "$CAPTURED_STDERR" "refused: there is no Tailscale auth key"
  assert_contains "$CAPTURED_STDERR" "SIRVEN_TAILSCALE_AUTHKEY"
  assert_contains "$CAPTURED_STDERR" "nothing was changed"
  assert_not_contains "$(calls)" "tailscale up --auth-key"
  assert_no_file "$MARKER"
}

test_join_without_tailscale_says_how_to_install_it() {
  setup_node
  SIRVEN_TAILSCALE=none SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 2 join
  assert_contains "$CAPTURED_STDERR" "tailscale is not installed on this machine"
  assert_contains "$CAPTURED_STDERR" "https://tailscale.com/download"
  assert_no_file "$MARKER"
}

test_join_with_a_tailscale_too_old_to_read_a_key_file_is_refused() {
  setup_node
  FAKE_TS_OLD=yes SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 2 join
  assert_contains "$CAPTURED_STDERR" "cannot read an auth key from a file"
  assert_not_contains "$(calls)" "tailscale up --auth-key"
}

test_join_when_tailscaled_does_not_answer_is_refused() {
  setup_node
  FAKE_TS_STOPPED=yes SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 2 join
  assert_contains "$CAPTURED_STDERR" "tailscaled does not answer"
  assert_no_file "$MARKER"
}

test_join_never_touches_a_login_it_did_not_make() {
  setup_node
  fake_login Running node-owner ""
  SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 2 join
  assert_contains "$CAPTURED_STDERR" "already logged in to Tailscale without tag:agent"
  assert_not_contains "$(calls)" "up --auth-key"
  assert_not_contains "$(calls)" "logout"
  assert_no_file "$MARKER"
}

test_an_agent_node_found_as_it_is_gets_no_join_and_no_record() {
  setup_node
  fake_login Running node-existing '"tag:agent"'
  SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 0 join
  assert_contains "$CAPTURED_STDOUT" "already logged in to Tailscale as tag:agent"
  assert_not_contains "$(calls)" "up --auth-key"
  assert_no_file "$MARKER"
}

test_a_failed_join_never_prints_the_key_and_records_nothing() {
  setup_node
  FAKE_TS_ECHO_KEY=yes FAKE_TS_KEY="another-key" SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 1 join
  assert_contains "$CAPTURED_STDERR" "backend error: invalid key"
  assert_contains "$CAPTURED_STDERR" "[key hidden]"
  assert_contains "$CAPTURED_STDERR" "tailscale up failed"
  assert_no_file "$MARKER"
  assert_eq "" "$(ls -A "$STATE")" "nothing is left in the state folder"
  assert_key_nowhere "$STATE" "$FAKE_TS_DIR"
}

test_a_join_without_the_tag_is_logged_out_again() {
  setup_node
  FAKE_TS_UNTAGGED=yes SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 1 join
  assert_contains "$CAPTURED_STDERR" "joined without tag:agent"
  assert_contains "$CAPTURED_STDERR" "logged it out again"
  assert_eq "NeedsLogin" "$(cat "$FAKE_TS_DIR/state")"
  assert_no_file "$MARKER"
}

test_a_join_with_no_node_number_to_record_is_logged_out_again() {
  setup_node
  FAKE_TS_NO_ID=yes SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 1 join
  assert_contains "$CAPTURED_STDERR" "did not report a node number to record"
  assert_eq "NeedsLogin" "$(cat "$FAKE_TS_DIR/state")"
  assert_no_file "$MARKER"
}

test_a_key_with_odd_characters_is_refused_and_not_run() {
  setup_node
  SIRVEN_TAILSCALE_AUTHKEY='--ssh=true' assert_status 2 join
  assert_contains "$CAPTURED_STDERR" "characters a Tailscale key never has"
  assert_not_contains "$(calls)" "up --auth-key"
}

# a key file that is not a plain file owned by the account running this with nothing for anyone else is not used. (owned by
# root is the rule as root; the tests run as a normal user, so "owned by whoever runs it". scenario 61 and the attack scripts
# cover a file owned by another account, which needs root to make.)
test_a_key_file_others_can_read_or_write_is_refused() {
  setup_node
  local mode
  printf '%s\n' "$SENTINEL_KEY" > "$TEST_TMP/key-file"
  for mode in 644 640 660 666 604 602; do
    chmod "$mode" "$TEST_TMP/key-file"
    assert_status 2 bash "$NODE" join "$MARKER" agent "$TEST_TMP/key-file"
    assert_contains "$CAPTURED_STDERR" "is not used: its mode is"
    assert_contains "$CAPTURED_STDERR" "nothing was changed"
    assert_status 2 bash "$NODE" key-file-check "$TEST_TMP/key-file"
  done
  assert_not_contains "$(calls)" "up --auth-key"
  assert_no_file "$MARKER"
  chmod 400 "$TEST_TMP/key-file"
  assert_status 0 bash "$NODE" key-file-check "$TEST_TMP/key-file"
  chmod 600 "$TEST_TMP/key-file"
  assert_status 0 bash "$NODE" key-file-check "$TEST_TMP/key-file"
  assert_status 0 bash "$NODE" join "$MARKER" agent "$TEST_TMP/key-file"
}

test_a_key_file_that_is_a_link_or_a_folder_is_refused_and_a_missing_one_is_just_missing() {
  setup_node
  printf '%s\n' "$SENTINEL_KEY" > "$TEST_TMP/real-key"
  chmod 600 "$TEST_TMP/real-key"
  ln -s "$TEST_TMP/real-key" "$TEST_TMP/key-link"
  assert_status 2 bash "$NODE" join "$MARKER" agent "$TEST_TMP/key-link"
  assert_contains "$CAPTURED_STDERR" "not a plain file"
  mkdir "$TEST_TMP/key-dir"
  assert_status 2 bash "$NODE" key-file-check "$TEST_TMP/key-dir"
  assert_status 1 bash "$NODE" key-file-check "$TEST_TMP/nothing-here"
  : > "$TEST_TMP/empty-key"
  chmod 600 "$TEST_TMP/empty-key"
  assert_status 1 bash "$NODE" key-file-check "$TEST_TMP/empty-key"
  assert_not_contains "$(calls)" "up --auth-key"
}

test_the_environment_key_is_not_held_back_by_a_bad_key_file() {
  setup_node
  printf 'not-the-key\n' > "$TEST_TMP/key-file"
  chmod 666 "$TEST_TMP/key-file"
  SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 0 bash "$NODE" join "$MARKER" agent "$TEST_TMP/key-file"
}

test_tailscale_key_available_applies_the_same_check_to_the_key_file() {
  setup_node
  local root="$TEST_TMP/root" file
  # shellcheck source=install.sh
  . "$REPO_DIR/install.sh"
  PREFIX="$root" CONFIG_DIR=/etc/sirven
  file="$root$(tailscale_auth_key_file)"
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$SENTINEL_KEY" > "$file"
  chmod 600 "$file"
  assert_status 0 tailscale_key_available
  chmod 644 "$file"
  assert_status 1 tailscale_key_available
  chmod 666 "$file"
  assert_status 1 tailscale_key_available
  rm "$file"
  assert_status 1 tailscale_key_available
  SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 0 tailscale_key_available
}

test_check_makes_the_refusals_of_the_join_and_changes_nothing() {
  setup_node
  # all fine: no refusal, tailscale never asked to log in, nothing written
  SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 0 bash "$NODE" check agent "$TEST_TMP/no-key-file"
  assert_not_contains "$(calls)" "up --auth-key"
  assert_no_file "$MARKER"
  assert_eq "" "$(ls -A "$STATE")" "nothing in the state folder"
  assert_not_contains "$CAPTURED_STDOUT" "joined"
  # each refusal the join makes late is made here
  FAKE_TS_OLD=yes SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 2 bash "$NODE" check agent "$TEST_TMP/no-key-file"
  assert_contains "$CAPTURED_STDERR" "cannot read an auth key from a file"
  SIRVEN_TAILSCALE_AUTHKEY="$(printf '%s\r' "$SENTINEL_KEY")" assert_status 2 bash "$NODE" check agent "$TEST_TMP/no-key-file"
  assert_contains "$CAPTURED_STDERR" "characters a Tailscale key never has"
  assert_status 2 bash "$NODE" check agent "$TEST_TMP/no-key-file"
  assert_contains "$CAPTURED_STDERR" "there is no Tailscale auth key"
  SIRVEN_TAILSCALE=none SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 2 bash "$NODE" check agent "$TEST_TMP/no-key-file"
  FAKE_TS_STOPPED=yes SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 2 bash "$NODE" check agent "$TEST_TMP/no-key-file"
  fake_login Running node-owner ""
  SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 2 bash "$NODE" check agent "$TEST_TMP/no-key-file"
  assert_contains "$CAPTURED_STDERR" "already logged in to Tailscale without tag:agent"
  assert_not_contains "$(calls)" "up --auth-key"
  assert_not_contains "$(calls)" "logout"
  # a key file saved with Windows line ends is refused by the check, too
  printf '%s\r\n' "$SENTINEL_KEY" > "$TEST_TMP/key-file"
  chmod 600 "$TEST_TMP/key-file"
  rm -rf "$FAKE_TS_DIR"
  assert_status 2 bash "$NODE" check agent "$TEST_TMP/key-file"
  assert_contains "$CAPTURED_STDERR" "characters a Tailscale key never has"
}

test_a_copy_of_the_key_left_by_a_killed_join_is_swept_by_the_next_join_and_by_leave() {
  setup_node
  printf 'stale\n' > "$STATE/.tailscale-key.4242"
  printf 'stale\n' > "$STATE/.tailscale-key.4243"
  SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 0 join
  assert_no_file "$STATE/.tailscale-key.4242"
  assert_no_file "$STATE/.tailscale-key.4243"
  printf 'stale\n' > "$STATE/.tailscale-key.4244"
  assert_status 0 leave
  assert_no_file "$STATE/.tailscale-key.4244"
  # leave with no record at all sweeps too
  printf 'stale\n' > "$STATE/.tailscale-key.4245"
  assert_status 0 leave
  assert_no_file "$STATE/.tailscale-key.4245"
}

test_leave_logs_out_the_node_that_join_made_and_removes_the_record() {
  setup_node
  SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 0 join
  assert_status 0 leave
  assert_contains "$CAPTURED_STDOUT" "logged this machine (node nodeid-"
  assert_eq "NeedsLogin" "$(cat "$FAKE_TS_DIR/state")"
  assert_no_file "$MARKER"
  assert_status 0 leave
  assert_contains "$CAPTURED_STDOUT" "nothing to log out"
  assert_eq "1" "$(calls | grep -c '^tailscale logout')" "logout runs once"
}

test_leave_without_a_record_logs_nothing_out() {
  setup_node
  fake_login Running node-existing '"tag:agent"'
  assert_status 0 leave
  assert_contains "$CAPTURED_STDOUT" "nothing to log out"
  assert_eq "Running" "$(cat "$FAKE_TS_DIR/state")"
  assert_not_contains "$(calls)" "logout"
}

test_leave_leaves_a_login_that_is_no_longer_the_recorded_node() {
  setup_node
  SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 0 join
  fake_login Running node-owner '"tag:other"'
  assert_status 0 leave
  assert_contains "$CAPTURED_STDOUT" "something sirven did not join"
  assert_eq "Running" "$(cat "$FAKE_TS_DIR/state")"
  assert_not_contains "$(calls)" "logout"
  assert_no_file "$MARKER"
}

test_leave_keeps_the_record_when_logout_does_not_work() {
  setup_node
  SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 0 join
  FAKE_TS_LOGOUT_FAILS=yes assert_status 1 leave
  assert_contains "$CAPTURED_STDERR" "tailscale logout did not end the login"
  assert_file_exists "$MARKER"
  assert_status 0 leave
  assert_no_file "$MARKER"
}

test_leave_keeps_the_record_when_tailscaled_does_not_answer() {
  setup_node
  SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 0 join
  FAKE_TS_STOPPED=yes assert_status 1 leave
  assert_contains "$CAPTURED_STDERR" "tailscaled does not answer"
  assert_file_exists "$MARKER"
}

test_leave_works_when_tailscale_is_gone() {
  setup_node
  SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 0 join
  SIRVEN_TAILSCALE=none assert_status 0 leave
  assert_contains "$CAPTURED_STDOUT" "tailscale is not installed on this machine"
  assert_no_file "$MARKER"
}

test_leave_does_not_trust_a_record_that_is_a_link() {
  setup_node
  printf '{"node_id": "x"}\n' > "$TEST_TMP/elsewhere"
  ln -s "$TEST_TMP/elsewhere" "$MARKER"
  fake_login Running x '"tag:agent"'
  assert_status 1 leave
  assert_contains "$CAPTURED_STDERR" "is not a plain file"
  assert_not_contains "$(calls)" "logout"
}

# ---- the plan, on a fake root

install_sh() {
  SIRVEN_OS_OVERRIDE=linux SIRVEN_TAILSCALE=none SIRVEN_BB=none "$REPO_DIR/install.sh" "$@" --owner example
}

test_the_join_step_is_recorded_not_run_on_a_fake_root_and_never_holds_the_key() {
  local root="$TEST_TMP/root"
  SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 0 install_sh --prefix "$root" --level observer --transport tailscale
  assert_contains "$(cat "$root/var/lib/sirven/simulated-system-commands.log")" "tailscale_node.sh join"
  assert_contains "$(cat "$root/var/lib/sirven/install-record.tsv")" "tailscale_node.sh leave"
  assert_no_file "$root/var/lib/sirven/tailscale-node.json"
  assert_key_nowhere "$root"
  # a second run finds the join recorded and does nothing more
  assert_status 0 install_sh --prefix "$root" --level observer --transport tailscale
  assert_contains "$CAPTURED_STDOUT" "applied 0 steps"
}

test_the_install_record_undoes_the_join_before_the_pinned_copy_goes() {
  local root="$TEST_TMP/root" join_line copy_line
  assert_status 0 install_sh --prefix "$root" --level observer --transport tailscale
  assert_status 0 env SIRVEN_OS_OVERRIDE=linux "$REPO_DIR/uninstall.sh" --dry-run --prefix "$root"
  assert_contains "$CAPTURED_STDOUT" "log this machine out of the tailnet, if this installer joined it"
  join_line="$(printf '%s\n' "$CAPTURED_STDOUT" | grep -n 'log this machine out of the tailnet' | cut -d: -f1)"
  copy_line="$(printf '%s\n' "$CAPTURED_STDOUT" | grep -n 'remove the pinned copy of this package' | cut -d: -f1)"
  [ "$join_line" -lt "$copy_line" ] || fail "the logout (line $join_line) must come before the pinned copy goes (line $copy_line)"
  assert_contains "$(cat "$root/var/lib/sirven/install-record.tsv")" "bash $root/var/lib/sirven/package/lib/tailscale_node.sh leave $root/var/lib/sirven/tailscale-node.json"
}

test_the_pinned_copy_holds_the_script_the_undo_calls() {
  local root="$TEST_TMP/root"
  assert_status 0 install_sh --prefix "$root" --level observer --transport tailscale
  assert_file_exists "$root/var/lib/sirven/package/lib/tailscale_node.sh"
}

test_revoke_adds_the_logout_only_when_this_installer_joined() {
  local root="$TEST_TMP/root"
  assert_status 0 install_sh --prefix "$root" --level observer --transport tailscale
  assert_status 0 install_sh revoke --all --dry-run --prefix "$root" --transport tailscale
  assert_not_contains "$CAPTURED_STDOUT" "log this machine out of the tailnet"
  printf '{"node_id": "node-1"}\n' > "$root/var/lib/sirven/tailscale-node.json"
  assert_status 0 install_sh revoke --all --dry-run --prefix "$root" --transport tailscale
  assert_contains "$CAPTURED_STDOUT" "log this machine out of the tailnet: the node this installer joined, and only it (to do"
  assert_contains "$CAPTURED_STDOUT" "the node recorded in /var/lib/sirven/tailscale-node.json"
  # a revoke that names no transport still logs out a node this installer joined
  assert_status 0 install_sh revoke --all --dry-run --prefix "$root" --transport none
  assert_contains "$CAPTURED_STDOUT" "log this machine out of the tailnet: the node this installer joined, and only it"
}

test_an_apply_without_a_key_is_refused_before_any_change() {
  setup_node
  # install.sh is sourced so the refusal is read in a real-apply state without root or a container
  # shellcheck source=install.sh
  . "$REPO_DIR/install.sh"
  COMMAND=install TRANSPORT=tailscale DRY_RUN=no PREFIX="" OPERATING_SYSTEM=linux ADOPT_TAILSCALE=logged_out CONFIG_DIR=/nonexistent/sirven SERVICE_USER=agent
  unset SIRVEN_TAILSCALE_AUTHKEY TAILSCALE_AUTHKEY
  assert_status 2 tailscale_refuse_before_apply
  assert_contains "$CAPTURED_STDERR" "refused: there is no Tailscale auth key to join the tailnet with. nothing was changed."
  assert_contains "$CAPTURED_STDERR" "--transport none"
  ADOPT_TAILSCALE=unanswered assert_status 2 tailscale_refuse_before_apply
  assert_contains "$CAPTURED_STDERR" "tailscaled does not answer"
  # a key, an adopted agent node, a dry run, a fake root, or another transport: no refusal
  SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 0 tailscale_refuse_before_apply
  ADOPT_TAILSCALE=agent_node assert_status 0 tailscale_refuse_before_apply
  DRY_RUN=yes assert_status 0 tailscale_refuse_before_apply
  PREFIX=/tmp/fake assert_status 0 tailscale_refuse_before_apply
  TRANSPORT=none assert_status 0 tailscale_refuse_before_apply
}

test_an_apply_that_the_join_would_refuse_late_is_refused_before_any_change() {
  setup_node
  # shellcheck source=install.sh
  . "$REPO_DIR/install.sh"
  COMMAND=install TRANSPORT=tailscale DRY_RUN=no PREFIX="" OPERATING_SYSTEM=linux ADOPT_TAILSCALE=logged_out SERVICE_USER=agent
  CONFIG_DIR="$TEST_TMP/etc-sirven"
  mkdir -p "$CONFIG_DIR"
  # a tailscale too old to read a key file, and a key with a stray carriage return: refused up front, with "nothing was changed" true
  FAKE_TS_OLD=yes SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" assert_status 2 tailscale_refuse_before_apply
  assert_contains "$CAPTURED_STDERR" "cannot read an auth key from a file"
  assert_contains "$CAPTURED_STDERR" "nothing was changed"
  SIRVEN_TAILSCALE_AUTHKEY="$(printf '%s\r' "$SENTINEL_KEY")" assert_status 2 tailscale_refuse_before_apply
  assert_contains "$CAPTURED_STDERR" "characters a Tailscale key never has"
  # a key file that others can write is named as the reason, not reported as "no key"
  printf '%s\n' "$SENTINEL_KEY" > "$CONFIG_DIR/tailscale-auth-key"
  chmod 666 "$CONFIG_DIR/tailscale-auth-key"
  assert_status 2 tailscale_refuse_before_apply
  assert_contains "$CAPTURED_STDERR" "its mode is"
  assert_contains "$CAPTURED_STDERR" "cannot be trusted"
  assert_not_contains "$CAPTURED_STDERR" "there is no Tailscale auth key"
  chmod 600 "$CONFIG_DIR/tailscale-auth-key"
  assert_status 0 tailscale_refuse_before_apply
  assert_not_contains "$(calls)" "up --auth-key"
}

# ---- uninstall, with a join the install record does not know about

test_uninstall_logs_out_a_node_a_failed_join_left_behind() {
  local root="$TEST_TMP/root" record="$TEST_TMP/root/var/lib/sirven/install-record.tsv"
  assert_status 0 install_sh --prefix "$root" --level observer --transport tailscale
  # the join logged in but never reached Running: the join's record file is there, the install record has no line for it
  grep -v 'tailscale_node.sh leave' "$record" > "$TEST_TMP/record.without" || true
  cp "$TEST_TMP/record.without" "$record"
  printf '{"node_id": "node-1"}\n' > "$root/var/lib/sirven/tailscale-node.json"
  assert_status 0 env SIRVEN_OS_OVERRIDE=linux "$REPO_DIR/uninstall.sh" --dry-run --prefix "$root"
  assert_contains "$CAPTURED_STDOUT" "log this machine out of the tailnet: the node a join left behind, and only it (to do"
  assert_contains "$CAPTURED_STDOUT" "only when this machine's login is still the node recorded in /var/lib/sirven/tailscale-node.json"
  # the logout comes before the pinned copy goes
  local join_line copy_line
  join_line="$(printf '%s\n' "$CAPTURED_STDOUT" | grep -n 'log this machine out of the tailnet' | cut -d: -f1)"
  copy_line="$(printf '%s\n' "$CAPTURED_STDOUT" | grep -n 'remove the pinned copy of this package' | cut -d: -f1)"
  [ "$join_line" -lt "$copy_line" ] || fail "the logout (line $join_line) must come before the pinned copy goes (line $copy_line)"
}

test_uninstall_also_acts_on_a_stale_key_copy_and_adds_nothing_without_a_join() {
  local root="$TEST_TMP/root" record="$TEST_TMP/root/var/lib/sirven/install-record.tsv"
  assert_status 0 install_sh --prefix "$root" --level observer --transport tailscale
  grep -v 'tailscale_node.sh leave' "$record" > "$TEST_TMP/record.without" || true
  cp "$TEST_TMP/record.without" "$record"
  assert_status 0 env SIRVEN_OS_OVERRIDE=linux "$REPO_DIR/uninstall.sh" --dry-run --prefix "$root"
  assert_not_contains "$CAPTURED_STDOUT" "a join left behind"
  printf 'stale\n' > "$root/var/lib/sirven/.tailscale-key.77"
  assert_status 0 env SIRVEN_OS_OVERRIDE=linux "$REPO_DIR/uninstall.sh" --dry-run --prefix "$root"
  assert_contains "$CAPTURED_STDOUT" "a join left behind"
}

test_uninstall_does_not_log_out_twice_when_the_install_record_already_does() {
  local root="$TEST_TMP/root"
  assert_status 0 install_sh --prefix "$root" --level observer --transport tailscale
  printf '{"node_id": "node-1"}\n' > "$root/var/lib/sirven/tailscale-node.json"
  assert_status 0 env SIRVEN_OS_OVERRIDE=linux "$REPO_DIR/uninstall.sh" --dry-run --prefix "$root"
  assert_contains "$CAPTURED_STDOUT" "log this machine out of the tailnet, if this installer joined it"
  assert_not_contains "$CAPTURED_STDOUT" "a join left behind"
}

# ---- the key does not outlive the join step in the installer's environment

# a step that runs after the join starts a child process; one that is given the saved key file's name to remove is such a
# step. a stand-in for rm records the environment it was started with (the names of the variables only, never a value).
test_a_step_after_the_join_starts_a_child_that_does_not_inherit_the_key() {
  local root="$TEST_TMP/root" bin="$TEST_TMP/bin" real_rm
  real_rm="$(command -v rm)"
  mkdir -p "$bin" "$root/etc/sirven"
  cat > "$bin/rm" <<SHIM
#!/bin/sh
case "\$*" in
  *tailscale-auth-key*) env | sed 's/=.*//' > "$TEST_TMP/rm-environment-names" ;;
esac
exec "$real_rm" "\$@"
SHIM
  chmod 755 "$bin/rm"
  printf '%s\n' "$SENTINEL_KEY" > "$root/etc/sirven/tailscale-auth-key"
  chmod 600 "$root/etc/sirven/tailscale-auth-key"
  PATH="$bin:$PATH" SIRVEN_TAILSCALE_AUTHKEY="$SENTINEL_KEY" TAILSCALE_AUTHKEY="$SENTINEL_KEY" \
    assert_status 0 install_sh --prefix "$root" --level observer --transport tailscale
  assert_contains "$CAPTURED_STDOUT" "remove the used auth key from disk"
  assert_file_exists "$TEST_TMP/rm-environment-names"
  assert_not_contains "$(cat "$TEST_TMP/rm-environment-names")" "TAILSCALE_AUTHKEY" "the environment of the step after the join"
  assert_no_file "$root/etc/sirven/tailscale-auth-key"
  assert_key_nowhere "$root" "$TEST_TMP/rm-environment-names"
}

# ---- a key file with an access entry for another account

# add an access entry for another account to FILE. returns 1 when this machine has no way to make one.
give_another_account_access() {
  case "$(uname -s)" in
    Darwin) chmod +a "group:everyone allow read" "$1" ;;
    # the mask is set to '---' on purpose: it is what keeps the entry out of the group bits that ls shows
    *) command -v setfacl >/dev/null 2>&1 && setfacl -m u:65534:r "$1" && setfacl -m m::--- "$1" ;;
  esac
}

# the owner, group and other bits as ls prints them: nine characters, with no '+' or '@' after them
mode_bits_of() {
  # shellcheck disable=SC2012 # ls -ln is the portable way to read a mode string on macos and linux, as the other tests do
  ls -ldn "$1" | cut -c1-10
}

test_a_key_file_with_an_access_entry_for_another_account_is_refused() {
  setup_node
  printf '%s\n' "$SENTINEL_KEY" > "$TEST_TMP/key-file"
  chmod 600 "$TEST_TMP/key-file"
  assert_status 0 bash "$NODE" key-file-check "$TEST_TMP/key-file"
  if ! give_another_account_access "$TEST_TMP/key-file"; then
    printf 'skipped: this machine has no way to make an access control list entry (no setfacl)\n'
    return 0
  fi
  # a file that already has extended attributes (macos shows '@' and hides the '+') is no way round it either
  if [ "$(uname -s)" = Darwin ]; then xattr -w sirven.test value "$TEST_TMP/key-file"; fi
  assert_eq "-rw-------" "$(mode_bits_of "$TEST_TMP/key-file")" "the mode bits alone look right"
  assert_status 2 bash "$NODE" key-file-check "$TEST_TMP/key-file"
  assert_contains "$CAPTURED_STDERR" "extended access control list"
  assert_status 2 bash "$NODE" join "$MARKER" agent "$TEST_TMP/key-file"
  assert_contains "$CAPTURED_STDERR" "extended access control list"
  assert_contains "$CAPTURED_STDERR" "nothing was changed"
  assert_status 2 bash "$NODE" check agent "$TEST_TMP/key-file"
  assert_not_contains "$(calls)" "up --auth-key"
  assert_no_file "$MARKER"
  # the key is not echoed in the refusal
  assert_key_nowhere "$STATE" "$FAKE_TS_DIR"
  # taken away again, the same file is used
  case "$(uname -s)" in Darwin) chmod -N "$TEST_TMP/key-file" ;; *) setfacl -b "$TEST_TMP/key-file" ;; esac
  assert_status 0 bash "$NODE" key-file-check "$TEST_TMP/key-file"
  assert_status 0 bash "$NODE" join "$MARKER" agent "$TEST_TMP/key-file"
}

# on Linux the group bits of a file with an access control list show the mask. a mask of '---' hides a named entry from the
# mode bits completely, and the file has to be refused anyway, whatever the mask is.
test_a_key_file_with_an_access_entry_hidden_by_the_mask_is_refused_whatever_the_mask_is() {
  setup_node
  local mask
  command -v setfacl >/dev/null 2>&1 || { printf 'skipped: this test needs setfacl (Linux)\n'; return 0; }
  printf '%s\n' "$SENTINEL_KEY" > "$TEST_TMP/key-file"
  chmod 600 "$TEST_TMP/key-file"
  setfacl -m u:65534:r "$TEST_TMP/key-file" 2>/dev/null || { printf 'skipped: this file system keeps no access control lists\n'; return 0; }
  for mask in 'r--' 'rw-' '---'; do
    setfacl -m "m::$mask" "$TEST_TMP/key-file"
    assert_status 2 bash "$NODE" key-file-check "$TEST_TMP/key-file"
    assert_status 2 bash "$NODE" join "$MARKER" agent "$TEST_TMP/key-file"
    assert_not_contains "$(calls)" "up --auth-key"
  done
  # with the mask at '---' the mode bits show nothing for the group: this is the case a mode check alone lets through
  assert_eq "-rw-------" "$(mode_bits_of "$TEST_TMP/key-file")" "mode bits with the mask at ---"
  assert_contains "$CAPTURED_STDERR" "extended access control list"
  # a named group entry counts the same
  setfacl -b "$TEST_TMP/key-file"
  setfacl -m g:65534:r "$TEST_TMP/key-file"
  assert_status 2 bash "$NODE" key-file-check "$TEST_TMP/key-file"
  setfacl -b "$TEST_TMP/key-file"
  assert_status 0 bash "$NODE" key-file-check "$TEST_TMP/key-file"
}
