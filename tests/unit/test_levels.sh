# shellcheck shell=bash
# levels as data: the three shipped levels keep the hard rules, and broken ones are refused.

compiler() {
  python3 "$REPO_DIR/lib/grant_compiler.py" "$@"
}

describe_value() {
  compiler describe --level "$REPO_DIR/levels/$1.json" | sed -n "s/^$2=//p"
}

# broken_level NAME PYTHON_EDIT: copy observer.json, apply an edit to the parsed level, save it.
broken_level() {
  python3 - "$REPO_DIR/levels/observer.json" "$TEST_TMP/$1.json" "$2" <<'END'
import json, sys
level = json.load(open(sys.argv[1]))
exec(sys.argv[3])
json.dump(level, open(sys.argv[2], "w"))
END
}

test_shipped_levels_validate_together() {
  assert_status 0 compiler validate "$REPO_DIR/levels/observer.json" "$REPO_DIR/levels/builder.json" "$REPO_DIR/levels/operator.json"
  assert_contains "$CAPTURED_STDOUT" "ok observer"
  assert_contains "$CAPTURED_STDOUT" "ok builder"
  assert_contains "$CAPTURED_STDOUT" "ok operator"
}

test_observer_is_read_only() {
  assert_eq false "$(describe_value observer write_allowed)"
  assert_eq true "$(describe_value builder write_allowed)"
  assert_eq true "$(describe_value operator write_allowed)"
}

test_friend_invites_default_to_observer_with_expiry() {
  assert_eq true "$(describe_value observer friend_invite_default_level)"
  assert_eq false "$(describe_value builder friend_invite_default_level)"
  assert_eq false "$(describe_value operator friend_invite_allowed)"
  assert_eq 7 "$(describe_value observer friend_invite_default_days)"
}

test_level_names_match_their_files() {
  local level
  for level in observer builder operator; do
    assert_eq "$level" "$(describe_value "$level" level)"
  done
}

test_writable_observer_is_refused() {
  broken_level observer-writes 'level["write_allowed"] = True'
  assert_status 2 compiler validate "$TEST_TMP/observer-writes.json"
  assert_contains "$CAPTURED_STDERR" "observer must be read only"
}

test_write_rights_without_write_allowed_are_refused() {
  broken_level sneaky 'level["access_control"]["linux"]["grant"] = "rwX"; level["access_control"]["macos"]["files"] += ",write"'
  assert_status 2 compiler validate "$TEST_TMP/sneaky.json"
  assert_contains "$CAPTURED_STDERR" "linux grant includes write"
  assert_contains "$CAPTURED_STDERR" "macos grant includes 'write'"
}

test_a_level_that_grants_grants_is_refused() {
  broken_level widens 'level["widening"]["can_grant"] = True'
  assert_status 2 compiler validate "$TEST_TMP/widens.json"
  assert_contains "$CAPTURED_STDERR" "nothing widens itself"
}

test_invites_without_expiry_are_refused() {
  broken_level forever 'level["expiry"]["friend_invite"]["required"] = False'
  assert_status 2 compiler validate "$TEST_TMP/forever.json"
  assert_contains "$CAPTURED_STDERR" "friend invites always expire"
}

test_default_paths_are_refused() {
  broken_level everything 'level["paths"]["default_grants"] = ["/"]'
  assert_status 2 compiler validate "$TEST_TMP/everything.json"
  assert_contains "$CAPTURED_STDERR" "every path is granted explicitly"
}

test_root_must_stay_denied() {
  broken_level rooted 'level["capabilities"]["denied"].remove("sudo")'
  assert_status 2 compiler validate "$TEST_TMP/rooted.json"
  assert_contains "$CAPTURED_STDERR" "must include 'sudo'"
}

test_agent_cannot_touch_its_audit_log() {
  broken_level reads-log 'level["audit"]["agent_can_write_log"] = True'
  assert_status 2 compiler validate "$TEST_TMP/reads-log.json"
  assert_contains "$CAPTURED_STDERR" "audit.agent_can_write_log must be false"
}

test_two_invite_defaults_are_refused() {
  broken_level builder-default 'level["level"] = "builder"; level["expiry"]["friend_invite"]["default_level"] = True'
  assert_status 2 compiler validate "$TEST_TMP/builder-default.json"
  assert_contains "$CAPTURED_STDERR" "only observer can be the default level for friend invites"
}
