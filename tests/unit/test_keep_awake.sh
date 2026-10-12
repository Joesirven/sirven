# shellcheck shell=bash
# sirven awake on a real Mac: a real power assertion, checked against what pmset lists for the
# holder process, never against counts that other programs' assertions would change. each test
# keeps its state in TEST_TMP. skipped on linux, and when the program is not built (make keep-awake).

keep_awake_ready() {
  # set these first, so no path through here can reach the user's real keep-awake state.
  export SIRVEN_KEEP_AWAKE_DIR="$TEST_TMP/keep-awake"
  export SIRVEN_KEEP_AWAKE_GRACE=0.3
  [ "$(uname -s)" = Darwin ] || return 1
  [ -x "${SIRVEN_KEEP_AWAKE_BIN:-}" ] && return 0
  for SIRVEN_KEEP_AWAKE_BIN in "$REPO_DIR/macos/keep-awake/.build/release/sirven-keep-awake" \
    "$REPO_DIR/macos/keep-awake/.build/debug/sirven-keep-awake"; do
    if [ -x "$SIRVEN_KEEP_AWAKE_BIN" ]; then
      export SIRVEN_KEEP_AWAKE_BIN
      return 0
    fi
  done
  echo "skipped: the keep-awake program is not built; run make keep-awake"
  return 1
}

awake() {
  "$REPO_DIR/bin/sirven" awake "$@"
}

status_field() {
  awake status --json | python3 -c 'import json, sys; value = json.load(sys.stdin).get(sys.argv[1]); print("" if value is None else json.dumps(value) if isinstance(value, (list, dict, bool)) else value)' "$1"
}

# true when pmset lists sirven's assertion under process $1.
pmset_lists_sirven_for() {
  pmset -g assertions | grep -F "pid $1(" | grep -q -F "sirven keep-awake: your agent has work in flight"
}

# wait up to five seconds for a command to succeed.
eventually() {
  local tries=0
  until "$@"; do
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || return 1
    sleep 0.1
  done
}

holding_is() {
  [ "$(status_field holding)" = "$1" ]
}

holder_gone() {
  [ "$(status_field holderRunning)" = false ]
}

stop_owner() {
  kill "$1" 2>/dev/null
  wait "$1" 2>/dev/null
  return 0
}

test_keep_awake_is_for_macos_only() {
  assert_status 1 env SIRVEN_OS_OVERRIDE=linux "$REPO_DIR/bin/sirven" awake status
  assert_contains "$CAPTURED_STDERR" "macos only"
}

test_keep_awake_help_and_about_carry_the_credit() {
  keep_awake_ready || return 0
  assert_status 0 awake --help
  assert_contains "$CAPTURED_STDOUT" "Inspired by Sleepless by itskoosh (MIT)."
  assert_status 0 awake about
  assert_contains "$CAPTURED_STDOUT" "Inspired by Sleepless by itskoosh (MIT)."
  assert_status 64 awake begin
  assert_status 64 awake begin "bad name" --reason x
  assert_status 64 awake begin fine-name --owner $$
  assert_contains "$CAPTURED_STDERR" "a reason is needed"
  assert_status 64 awake begin fine-name --reason "no owner"
  assert_contains "$CAPTURED_STDERR" "begin needs --owner"
  assert_eq "" "$(ls "$SIRVEN_KEEP_AWAKE_DIR/work" 2>/dev/null)" "a refused begin records nothing"
}

test_keep_awake_asserts_while_work_is_in_flight_and_releases_on_end() {
  local owner holder
  keep_awake_ready || return 0
  sleep 60 &
  owner=$!
  assert_status 0 awake begin inbox --reason "summarize the inbox" --owner "$owner"
  assert_contains "$CAPTURED_STDOUT" "holding the Mac awake for inbox: summarize the inbox (until it ends, or owner process $owner exits)"
  holder="$(status_field holderProcess)"
  assert_eq true "$(status_field holding)" "holding after begin"
  pmset_lists_sirven_for "$holder" || fail "pmset does not list sirven's assertion for holder process $holder"

  assert_status 0 awake status
  assert_contains "$CAPTURED_STDOUT" "holding: yes, since"
  assert_contains "$CAPTURED_STDOUT" "by process $holder"
  assert_contains "$CAPTURED_STDOUT" "system confirms: process $holder holds PreventUserIdleSystemSleep"
  assert_contains "$CAPTURED_STDOUT" "inbox  since"
  assert_contains "$CAPTURED_STDOUT" "summarize the inbox"
  assert_contains "$CAPTURED_STDOUT" "release now: sirven awake release"

  assert_status 0 awake end inbox
  eventually holder_gone || fail "the holder did not stop after the queue drained"
  pmset_lists_sirven_for "$holder" && fail "pmset still lists sirven's assertion after the queue drained"
  assert_contains "$(cat "$SIRVEN_KEEP_AWAKE_DIR/events.jsonl")" '"why":"the work queue drained"'
  stop_owner "$owner"
}

test_keep_awake_overlapping_work_holds_until_the_last_ends() {
  local first second holder
  keep_awake_ready || return 0
  sleep 60 &
  first=$!
  sleep 60 &
  second=$!
  assert_status 0 awake begin inbox --reason "summarize the inbox" --owner "$first"
  assert_status 0 awake begin barber --reason "book a haircut" --owner "$second"
  holder="$(status_field holderProcess)"
  assert_contains "$(pmset -g assertions | grep -F "pid $holder(")" "sirven keep-awake"
  assert_status 0 awake end inbox
  sleep 0.8
  assert_eq true "$(status_field holding)" "one task is still in flight"
  assert_eq "$holder" "$(status_field holderProcess)" "the same holder"
  assert_status 0 awake end barber
  eventually holder_gone || fail "the holder did not stop after the last task ended"
  stop_owner "$first"
  stop_owner "$second"
}

test_keep_awake_lets_go_when_the_owner_process_exits() {
  local owner holder
  keep_awake_ready || return 0
  sleep 60 &
  owner=$!
  assert_status 0 awake begin crawl --reason "read the reviews" --owner "$owner"
  holder="$(status_field holderProcess)"
  stop_owner "$owner"
  eventually holder_gone || fail "the holder kept holding after the owner exited"
  pmset_lists_sirven_for "$holder" && fail "the assertion outlived the owner"
  assert_contains "$(cat "$SIRVEN_KEEP_AWAKE_DIR/events.jsonl")" "is no longer running"
}

test_keep_awake_release_lets_the_mac_sleep_and_keeps_the_work_listed() {
  local owner holder
  keep_awake_ready || return 0
  sleep 60 &
  owner=$!
  assert_status 0 awake begin inbox --reason "summarize the inbox" --owner "$owner"
  holder="$(status_field holderProcess)"
  assert_status 0 awake release
  assert_contains "$CAPTURED_STDOUT" "released: inbox"
  eventually holding_is false || fail "still holding after release"
  pmset_lists_sirven_for "$holder" && fail "the assertion outlived the release"
  assert_status 0 awake status
  assert_contains "$CAPTURED_STDOUT" "released by you"
  assert_status 0 awake end inbox
  eventually holder_gone || fail "the holder did not stop"
  stop_owner "$owner"
}

test_keep_awake_off_holds_nothing() {
  local owner
  keep_awake_ready || return 0
  assert_status 0 awake off
  sleep 60 &
  owner=$!
  assert_status 0 awake begin inbox --reason "summarize the inbox" --owner "$owner"
  assert_contains "$CAPTURED_STDOUT" "keep-awake is off"
  assert_eq false "$(status_field holding)"
  assert_status 0 awake on
  eventually holding_is true || fail "turning it on did not hold for the work in flight"
  assert_status 0 awake end inbox
  eventually holder_gone || fail "the holder did not stop"
  stop_owner "$owner"
}

test_keep_awake_run_holds_for_one_command_and_passes_its_exit_status_through() {
  local seen
  keep_awake_ready || return 0
  seen="$TEST_TMP/seen"
  assert_status 3 awake run --task nightly --reason "nightly digest" -- \
    sh -c "\"$REPO_DIR/bin/sirven\" awake status > \"$seen\"; exit 3"
  assert_contains "$(cat "$seen")" "holding: yes"
  assert_contains "$(cat "$seen")" "nightly digest"
  eventually holder_gone || fail "the holder did not stop after the command exited"
  assert_eq "" "$(ls "$SIRVEN_KEEP_AWAKE_DIR/work")" "no work left behind"
}

test_keep_awake_work_that_arrives_as_the_holder_drains_is_still_held() {
  local owner pause
  keep_awake_ready || return 0
  sleep 60 &
  owner=$!
  # the holder exits about 0.3 seconds after the queue drains; begin new work right around then.
  for pause in 0.2 0.28 0.3 0.32 0.36 0.45; do
    assert_status 0 awake begin "first-$pause" --reason "first" --owner "$owner"
    assert_status 0 awake end "first-$pause"
    sleep "$pause"
    assert_status 0 awake begin "second-$pause" --reason "second" --owner "$owner"
    assert_contains "$CAPTURED_STDOUT" "holding the Mac awake for second-$pause"
    assert_not_contains "$CAPTURED_STDERR" "has not confirmed"
    assert_status 0 awake end "second-$pause"
  done
  eventually holder_gone || fail "the holder did not stop"
  stop_owner "$owner"
}
