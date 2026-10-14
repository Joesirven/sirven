# shellcheck shell=bash
# bin/sirven on a fake root: grant inspect reads state, grant rollback reverses the last change.

install_sh() {
  SIRVEN_OS_OVERRIDE=linux "$REPO_DIR/install.sh" "$@" --owner example --transport none
}

sirven() {
  SIRVEN_OS_OVERRIDE=linux "$REPO_DIR/bin/sirven" "$@"
}

two_installs() {
  ROOT="$TEST_TMP/root"
  assert_status 0 install_sh --prefix "$ROOT" --level observer --path /srv/app
  assert_status 0 install_sh --prefix "$ROOT" --level builder --path /srv/app --path /home/example/project
}

test_usage() {
  assert_status 0 sirven --help
  assert_contains "$CAPTURED_STDOUT" "grant rollback"
  assert_status 64 sirven
  assert_status 64 sirven grant
  assert_status 64 sirven grant revoke
  assert_contains "$CAPTURED_STDERR" "designed, not built"
  assert_status 64 sirven grant inspect --dry-run
  assert_status 64 sirven grant inspect --user Root
}

test_inspect_with_nothing_installed() {
  assert_status 0 sirven grant inspect --prefix "$TEST_TMP/root"
  assert_contains "$CAPTURED_STDOUT" "nothing is installed here"
}

test_inspect_shows_the_level_in_force_and_the_grants() {
  two_installs
  assert_status 0 sirven grant inspect --prefix "$ROOT" --user agent
  assert_contains "$CAPTURED_STDOUT" "level in force: builder (write allowed: true)"
  assert_contains "$CAPTURED_STDOUT" "policy: /etc/sirven/levels/builder.json, the same as levels/builder.json"
  assert_contains "$CAPTURED_STDOUT" "    /home/example/project
    /srv/app"
  assert_contains "$CAPTURED_STDOUT" "level builder on 2 path(s), before it level observer on 1 path(s)"
  assert_contains "$CAPTURED_STDOUT" "steps this package can reverse"
  assert_contains "$CAPTURED_STDOUT" "after alpha"
}

test_inspect_notices_a_changed_policy_copy() {
  two_installs
  printf '{}\n' > "$ROOT/etc/sirven/levels/builder.json"
  assert_status 0 sirven grant inspect --prefix "$ROOT"
  assert_contains "$CAPTURED_STDOUT" "different from levels/builder.json"
}

test_inspect_lists_revoked_records() {
  two_installs
  mv "$ROOT/etc/sirven/grants/agent.json" "$ROOT/etc/sirven/grants/agent.json.revoked"
  assert_status 0 sirven grant inspect --prefix "$ROOT"
  assert_contains "$CAPTURED_STDOUT" "no active grants."
  assert_contains "$CAPTURED_STDOUT" "revoked by the kill switch: agent"
}

test_rollback_dry_run_changes_nothing() {
  local before
  two_installs
  before="$(cat "$ROOT/etc/sirven/grants/agent.json" "$ROOT/var/log/sirven/audit.jsonl")"
  assert_status 0 sirven grant rollback --dry-run --prefix "$ROOT"
  assert_contains "$CAPTURED_STDOUT" "now: level builder on 2 path(s)"
  assert_contains "$CAPTURED_STDOUT" "after: level observer on 1 path(s)"
  assert_contains "$CAPTURED_STDOUT" "access_control_snapshot.sh restore"
  assert_contains "$CAPTURED_STDOUT" "$ROOT/home/example/project yes agent"
  assert_contains "$CAPTURED_STDOUT" "grant-access $ROOT/srv/app yes agent rX"
  assert_contains "$CAPTURED_STDOUT" "forced-command wrapper, built after alpha"
  assert_eq "$before" "$(cat "$ROOT/etc/sirven/grants/agent.json" "$ROOT/var/log/sirven/audit.jsonl")"
}

test_rollback_restores_the_earlier_grant_and_a_second_one_undoes_it() {
  two_installs
  assert_status 0 sirven grant rollback --prefix "$ROOT"
  assert_contains "$(cat "$ROOT/etc/sirven/grants/agent.json")" '"level": "observer"'
  assert_not_contains "$(cat "$ROOT/etc/sirven/grants/agent.json")" "/home/example/project"
  assert_contains "$(grep '"event": "grant"' "$ROOT/var/log/sirven/audit.jsonl" | tail -n 1)" \
    '"operation": "grant rollback", "level": "observer", "paths": ["/srv/app"], "previous_level": "builder"'
  assert_status 0 sirven grant rollback --prefix "$ROOT"
  assert_contains "$(cat "$ROOT/etc/sirven/grants/agent.json")" '"level": "builder"'
}

test_rollback_of_the_first_grant_removes_it() {
  ROOT="$TEST_TMP/root"
  assert_status 0 install_sh --prefix "$ROOT" --level builder --path /srv/app
  assert_status 0 sirven grant rollback --prefix "$ROOT"
  assert_contains "$CAPTURED_STDOUT" "after: no grant"
  assert_no_file "$ROOT/etc/sirven/grants/agent.json"
  assert_contains "$(grep '"event": "grant"' "$ROOT/var/log/sirven/audit.jsonl" | tail -n 1)" '"level": null, "paths": []'
}

test_rollback_refuses_when_the_record_drifted() {
  two_installs
  printf '{"schema_version": 1, "level": "operator", "paths": ["/srv/x"], "user": "agent"}\n' > "$ROOT/etc/sirven/grants/agent.json"
  assert_status 2 sirven grant rollback --dry-run --prefix "$ROOT"
  assert_contains "$CAPTURED_STDERR" "no longer matches the last grant change"
}

test_rollback_with_nothing_to_roll_back() {
  assert_status 1 sirven grant rollback --dry-run --prefix "$TEST_TMP/root"
  assert_contains "$CAPTURED_STDERR" "no audit log"
  mkdir -p "$TEST_TMP/root/var/log/sirven"
  : > "$TEST_TMP/root/var/log/sirven/audit.jsonl"
  assert_status 0 sirven grant rollback --dry-run --prefix "$TEST_TMP/root"
  assert_contains "$CAPTURED_STDOUT" "nothing to roll back"
}

test_uninstall_reverses_what_a_rollback_granted() {
  two_installs
  assert_status 0 sirven grant rollback --prefix "$ROOT"
  assert_status 0 "$REPO_DIR/uninstall.sh" --prefix "$ROOT"
  assert_no_file "$ROOT/etc/sirven"
  assert_contains "$CAPTURED_STDOUT" "access_control_snapshot.sh restore"
  assert_contains "$CAPTURED_STDOUT" "$ROOT/srv/app"
}

test_real_rollback_is_refused_without_root() {
  # as root this would really apply to the machine running the tests, so only a non-root run is checked here.
  if [ "$(id -u)" = 0 ]; then
    return 0
  fi
  assert_status 3 "$REPO_DIR/bin/sirven" grant rollback
  assert_real_apply_refusal "$CAPTURED_STDERR"
}

test_runs_through_a_symbolic_link() {
  mkdir -p "$TEST_TMP/bin"
  ln -s "$REPO_DIR/bin/sirven" "$TEST_TMP/bin/sirven"
  assert_status 0 "$TEST_TMP/bin/sirven" grant inspect --prefix "$TEST_TMP/root"
  assert_contains "$CAPTURED_STDOUT" "nothing is installed here"
}
