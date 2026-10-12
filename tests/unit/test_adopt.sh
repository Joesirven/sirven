# shellcheck shell=bash
# adopting what is already on the machine: Tailscale, bb, and sirven state from an earlier run.
# the fakes in tests/fixtures/adopt answer only read-only calls and log every call they get.

FAKES="$REPO_DIR/tests/fixtures/adopt"

# install_sh ARGUMENT...: install.sh on linux with the fake Tailscale and bb.
install_sh() {
  SIRVEN_OS_OVERRIDE=linux SIRVEN_TAILSCALE="$FAKES/tailscale" SIRVEN_BB="$FAKES/bb" \
    FAKE_CALLS_LOG="$TEST_TMP/calls.log" "$REPO_DIR/install.sh" "$@" --owner "${TEST_OWNER:-example}"
}

# seed: an earlier install of builder on /srv/app, applied to the fake root ROOT.
seed() {
  ROOT="$TEST_TMP/root"
  assert_status 0 install_sh --prefix "$ROOT" --level builder --path /srv/app --transport tailscale --with-bb
}

# snapshot: every path under ROOT with its type, mode, and checksum, to prove nothing changed.
snapshot() {
  (cd "$ROOT" && find . | LC_ALL=C sort | while IFS= read -r path; do
    if [ -f "$path" ]; then
      printf '%s file %s %s\n' "$path" "$(ls -ld "$path" | awk '{print $1}')" "$(cksum < "$path")"
    else
      printf '%s %s\n' "$path" "$(ls -ld "$path" | awk '{print $1}')"
    fi
  done)
}

# the fakes saw only the read-only calls sirven may make.
assert_only_read_calls() {
  local unexpected
  [ -f "$TEST_TMP/calls.log" ] || return 0
  unexpected="$(grep -v -x -e 'tailscale version' -e 'tailscale status --json' -e 'bb --version' "$TEST_TMP/calls.log" || true)"
  assert_eq "" "$unexpected" "a fake was asked to do more than read"
}

test_a_dry_run_on_an_earlier_install_adopts_and_changes_nothing() {
  local before
  seed
  before="$(snapshot)"
  : > "$TEST_TMP/calls.log"
  assert_status 0 install_sh --dry-run --prefix "$ROOT" --transport tailscale --with-bb
  assert_eq "$before" "$(snapshot)" "a dry run changed the fake root"
  assert_contains "$CAPTURED_STDERR" "adopting the grant in force for agent: level builder on /srv/app."
  assert_contains "$CAPTURED_STDOUT" "adopted: Tailscale 1.76.1, logged in; this machine is already the agent node (tag:agent)"
  assert_contains "$CAPTURED_STDOUT" "adopted: bb 0.42.1"
  assert_contains "$CAPTURED_STDOUT" "adopted: the grant for agent from an earlier run: level builder on /srv/app."
  assert_contains "$CAPTURED_STDOUT" "adopted: the audit log /var/log/sirven/audit.jsonl"
  assert_contains "$CAPTURED_STDOUT" "0 to do"
  assert_not_contains "$CAPTURED_STDOUT" "tailscale up --auth-key"
  assert_not_contains "$CAPTURED_STDOUT" "install bb for agent"
  grep -q 'tailscale status --json' "$TEST_TMP/calls.log" || fail "the fake Tailscale was never asked"
  assert_only_read_calls
}

test_an_apply_keeps_the_grant_the_policy_and_every_audit_entry() {
  local log="$TEST_TMP/root/var/log/sirven/audit.jsonl" old_log grant policy
  seed
  old_log="$TEST_TMP/old-audit.jsonl"
  cp "$log" "$old_log"
  grant="$TEST_TMP/old-grant.json"
  cp "$ROOT/etc/sirven/grants/agent.json" "$grant"
  policy="$TEST_TMP/old-policy.json"
  cp "$ROOT/etc/sirven/levels/builder.json" "$policy"
  : > "$TEST_TMP/calls.log"
  assert_status 0 install_sh --prefix "$ROOT" --transport tailscale --with-bb
  assert_contains "$CAPTURED_STDOUT" "applied 0 steps"
  cmp -s "$grant" "$ROOT/etc/sirven/grants/agent.json" || fail "the grant record was rewritten"
  cmp -s "$policy" "$ROOT/etc/sirven/levels/builder.json" || fail "the policy copy was rewritten"
  [ "$(head -c "$(wc -c < "$old_log")" "$log")" = "$(cat "$old_log")" ] || fail "earlier audit entries were changed"
  assert_contains "$(cat "$log")" '"event": "adopt", "user": "agent", "principal": "owner", "operation": "install", "found": "Tailscale 1.76.1, logged in'
  assert_eq 1 "$(grep -c '"event": "grant"' "$log")" "adopting the same grant is not a grant change"
  assert_only_read_calls
}

test_adopted_things_never_go_in_the_install_record() {
  seed
  assert_not_contains "$(cat "$ROOT/var/lib/sirven/install-record.tsv")" "tailscale up"
  assert_not_contains "$(cat "$ROOT/var/lib/sirven/install-record.tsv")" "bb"
}

test_a_yes_rerun_keeps_the_grant_in_force_instead_of_observer() {
  seed
  assert_status 0 install_sh --dry-run --prefix "$ROOT" --yes --transport tailscale
  assert_contains "$CAPTURED_STDOUT" "level: builder (write allowed: true)"
  assert_contains "$CAPTURED_STDOUT" "paths: /srv/app"
  assert_not_contains "$CAPTURED_STDOUT" "(to do)"
}

test_this_machines_own_tags_decide_not_another_devices() {
  # every fake state has another device tagged tag:agent; a personal machine must not pass.
  SIRVEN_PATH=none FAKE_TAILSCALE_STATE=personal-node assert_status 0 install_sh --dry-run --prefix "$TEST_TMP/root" --level observer --transport none
  assert_contains "$CAPTURED_STDOUT" "adopted: Tailscale 1.76.1, logged in as a device of your tailnet (tags: none). not used by this plan."
  assert_not_contains "$CAPTURED_STDOUT" "agent node"
}

test_a_personal_tailscale_login_is_refused_with_what_to_do() {
  local before
  ROOT="$TEST_TMP/root"
  mkdir -p "$ROOT"
  before="$(snapshot)"
  FAKE_TAILSCALE_STATE=personal-node assert_status 2 install_sh --dry-run --prefix "$ROOT" --level builder --path /srv/app --transport tailscale
  assert_eq "" "$CAPTURED_STDOUT" "a refusal prints no plan"
  assert_contains "$CAPTURED_STDERR" "error: refused: what is already on this machine conflicts with this request. nothing was changed."
  assert_contains "$CAPTURED_STDERR" "this machine is already logged in to Tailscale (tags: none), and it is not the agent node."
  assert_contains "$CAPTURED_STDERR" "run again with --transport none"
  assert_contains "$CAPTURED_STDERR" "tag this machine tag:agent yourself"
  assert_eq "$before" "$(snapshot)"
  FAKE_TAILSCALE_STATE=personal-node assert_status 2 install_sh --prefix "$ROOT" --level builder --path /srv/app --transport tailscale
  assert_eq "$before" "$(snapshot)" "a refused apply changed the fake root"
  assert_only_read_calls
}

test_a_logged_out_tailscale_is_kept_and_the_join_stays() {
  SIRVEN_PATH=none FAKE_TAILSCALE_STATE=logged-out assert_status 0 install_sh --dry-run --prefix "$TEST_TMP/root" --level observer --transport tailscale
  assert_contains "$CAPTURED_STDOUT" "adopted: Tailscale 1.76.1, installed and not logged in. kept as it is, never reinstalled"
  assert_contains "$CAPTURED_STDOUT" "join the tailnet as a tagged device with that key (plan only)"
}

test_a_stopped_agent_node_stays_stopped() {
  SIRVEN_PATH=none FAKE_TAILSCALE_STATE=agent-node-stopped assert_status 0 install_sh --dry-run --prefix "$TEST_TMP/root" --level observer --transport tailscale
  assert_contains "$CAPTURED_STDOUT" "logged in and stopped; this machine is already the agent node (tag:agent). kept as it is: never logged out, re-keyed, re-tagged, or started."
  assert_not_contains "$CAPTURED_STDOUT" "tailscale up --auth-key"
}

test_a_tailscale_that_does_not_answer_is_kept() {
  SIRVEN_PATH=none FAKE_TAILSCALE_STATE=unanswered assert_status 0 install_sh --dry-run --prefix "$TEST_TMP/root" --level observer --transport tailscale
  assert_contains "$CAPTURED_STDOUT" "adopted: Tailscale 1.76.1 is installed, but tailscale status did not answer."
}

test_nothing_found_means_no_adopt_section() {
  assert_status 0 env SIRVEN_OS_OVERRIDE=linux SIRVEN_TAILSCALE=none SIRVEN_BB=none \
    "$REPO_DIR/install.sh" --dry-run --prefix "$TEST_TMP/root" --level observer --transport none --owner example
  assert_not_contains "$CAPTURED_STDOUT" "adopted"
}

test_with_bb_and_no_bb_stays_plan_only() {
  assert_status 0 env SIRVEN_OS_OVERRIDE=linux SIRVEN_BB=none \
    "$REPO_DIR/install.sh" --dry-run --prefix "$TEST_TMP/root" --level observer --transport none --with-bb --owner example
  assert_contains "$CAPTURED_STDOUT" "install bb for agent (plan only)"
}

test_granting_no_path_over_a_grant_in_force_is_refused() {
  seed
  SIRVEN_PATH=none assert_status 2 install_sh --dry-run --prefix "$ROOT" --level builder --transport tailscale
  assert_contains "$CAPTURED_STDERR" "a grant is in force for agent: level builder on /srv/app. this request grants no path"
  assert_contains "$CAPTURED_STDERR" "./install.sh revoke --all --dry-run"
}

test_a_changed_policy_copy_is_refused_not_overwritten() {
  seed
  printf '{}\n' > "$ROOT/etc/sirven/levels/builder.json"
  assert_status 2 install_sh --prefix "$ROOT" --transport tailscale
  assert_contains "$CAPTURED_STDERR" "the installed builder policy /etc/sirven/levels/builder.json differs from this package's levels/builder.json"
  assert_eq "{}" "$(cat "$ROOT/etc/sirven/levels/builder.json")"
}

test_an_unreadable_grant_record_is_refused_not_overwritten() {
  ROOT="$TEST_TMP/root"
  mkdir -p "$ROOT/etc/sirven/grants"
  printf 'not a grant\n' > "$ROOT/etc/sirven/grants/agent.json"
  assert_status 2 install_sh --prefix "$ROOT" --level builder --path /srv/app --transport none
  assert_contains "$CAPTURED_STDERR" "the grant record /etc/sirven/grants/agent.json is there but cannot be read as a grant"
  assert_eq "not a grant" "$(cat "$ROOT/etc/sirven/grants/agent.json")"
}

test_an_audit_log_owned_by_someone_else_is_refused() {
  seed
  TEST_OWNER=someone assert_status 2 install_sh --dry-run --prefix "$ROOT" --transport tailscale
  assert_contains "$CAPTURED_STDERR" "the audit log directory /var/log/sirven belongs to example, and this run would give it to someone."
  assert_contains "$CAPTURED_STDERR" "run again with --owner example"
}

test_asking_for_a_different_grant_changes_it_as_before() {
  seed
  assert_status 0 install_sh --dry-run --prefix "$ROOT" --level observer --path /srv/app --transport tailscale
  assert_contains "$CAPTURED_STDOUT" "note: the grant in force for agent, level builder on /srv/app, changes to the one below, as asked. sirven grant rollback reverses the change."
  assert_not_contains "$CAPTURED_STDOUT" "adopted: the grant"
}

test_a_revoked_grant_is_kept_as_history() {
  seed
  mv "$ROOT/etc/sirven/grants/agent.json" "$ROOT/etc/sirven/grants/agent.json.revoked"
  SIRVEN_PATH=none assert_status 0 install_sh --dry-run --prefix "$ROOT" --level observer --transport tailscale
  assert_contains "$CAPTURED_STDOUT" "adopted: a grant for agent revoked by the kill switch, /etc/sirven/grants/agent.json.revoked. kept as history, never rewritten."
}

test_the_seams_need_a_dry_run_or_a_fake_root() {
  assert_status 64 env SIRVEN_OS_OVERRIDE= SIRVEN_TAILSCALE="$FAKES/tailscale" "$REPO_DIR/install.sh" --level observer --transport none
  assert_contains "$CAPTURED_STDERR" "SIRVEN_TAILSCALE only works with --dry-run or --prefix"
  assert_status 64 env SIRVEN_OS_OVERRIDE= SIRVEN_BB="$FAKES/bb" "$REPO_DIR/install.sh" --level observer --transport none
  assert_contains "$CAPTURED_STDERR" "SIRVEN_BB only works with --dry-run or --prefix"
}
