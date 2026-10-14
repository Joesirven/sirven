# shellcheck shell=bash
# the bb watcher and its installer, on a Mac, against fakes: a fake bb that answers from a schedule,
# a fake keep-awake program, and a fake launchctl. the fakes come first on PATH, and the tests never
# run the real launchctl, the real keep-awake program, or the real bb, so the live agent and the
# real setting are never touched. skipped on other systems.

WATCHER="$REPO_DIR/macos/keep-awake/bb-watcher/sirven-bb-awake-watcher.sh"
INSTALLER="$REPO_DIR/macos/keep-awake/bb-watcher/install.sh"
FAKE_HOST="host_testmac01"

watcher_ready() {
  if [ "$(uname -s)" != Darwin ]; then
    echo "skipped: the bb watcher is macos only"
    return 1
  fi
  return 0
}

# bin/bb answers each query from the schedule file (one word per query: busy, idle, or fail; the last
# word repeats). bin/sirven-keep-awake and bin/launchctl record every call in calls.log, in order.
make_fakes() {
  local bin="$TEST_TMP/bin" state="$TEST_TMP/state"
  mkdir -p "$bin" "$state" "$TEST_TMP/home/Applications/Sirven.app/Contents/MacOS" "$TEST_TMP/tmp"
  printf '[{"environmentHostId":"%s","status":"active","activity":{}}]\n' "$FAKE_HOST" > "$state/busy.json"
  printf '[{"environmentHostId":"%s","status":"idle","activity":{}}]\n' "$FAKE_HOST" > "$state/idle.json"
  echo '{"work":[]}' > "$state/status.json"
  cat > "$bin/bb" <<'SH'
#!/bin/bash
if [ "$1 $2" = "status --json" ]; then
  printf '{"thread":{"environment":{"hostId":"%s"}}}\n' "$FAKE_HOST"
  exit 0
fi
[ "$1 $2" = "thread list" ] || { echo "fake bb: unexpected $*" >&2; exit 2; }
n=$(( $(cat "$FAKE_STATE/bb-count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$FAKE_STATE/bb-count"
step="$(sed -n "${n}p" "$FAKE_STATE/schedule")"
[ -n "$step" ] || step="$(tail -n 1 "$FAKE_STATE/schedule")"
case "$step" in
  busy) cat "$FAKE_STATE/busy.json" ;;
  idle) cat "$FAKE_STATE/idle.json" ;;
  *) echo "fake bb: the query failed" >&2; exit 1 ;;
esac
SH
  cat > "$bin/sirven-keep-awake" <<'SH'
#!/bin/bash
echo "awake $*" >> "$FAKE_STATE/calls.log"
if [ "$1" = status ]; then cat "$FAKE_STATE/status.json"; fi
SH
  cat > "$bin/launchctl" <<'SH'
#!/bin/bash
echo "launchctl $*" >> "$FAKE_STATE/calls.log"
[ "$1" = print ] && exit 1
exit 0
SH
  printf '#!/bin/sh\nexit 0\n' > "$bin/node"
  chmod +x "$bin/bb" "$bin/sirven-keep-awake" "$bin/launchctl" "$bin/node"
  # the installer looks for the program inside Sirven.app, in the fake home.
  cp "$bin/sirven-keep-awake" "$TEST_TMP/home/Applications/Sirven.app/Contents/MacOS/sirven-keep-awake"
}

# set_schedule busy busy idle: one word for each query the watcher will make.
set_schedule() {
  printf '%s\n' "$@" > "$TEST_TMP/state/schedule"
  rm -f "$TEST_TMP/state/bb-count"
}

# run_watcher [NAME=value...]: the watcher with its settings, run to the end of its passes.
run_watcher() {
  env -i HOME="$TEST_TMP/home" TMPDIR="$TEST_TMP/tmp" PATH="$TEST_TMP/bin:/usr/bin:/bin" \
    FAKE_HOST="$FAKE_HOST" FAKE_STATE="$TEST_TMP/state" \
    SIRVEN_BB_HOST="$FAKE_HOST" SIRVEN_BB_COMMAND="$TEST_TMP/bin/bb" \
    SIRVEN_KEEP_AWAKE_BIN="$TEST_TMP/bin/sirven-keep-awake" SIRVEN_KEEP_AWAKE_DIR="$TEST_TMP/keep-awake" \
    SIRVEN_BB_INTERVAL=0 SIRVEN_BB_TIMEOUT=5 SIRVEN_BB_RENEW=90 SIRVEN_BB_IDLE=0 \
    "$@" bash "$WATCHER" > "$TEST_TMP/watcher.out" 2>&1
}

# run the installer or the fakes' environment, the same way the watcher is run.
installer() {
  env -i HOME="$TEST_TMP/home" TMPDIR="$TEST_TMP/tmp" PATH="$TEST_TMP/bin:/usr/bin:/bin" \
    FAKE_HOST="$FAKE_HOST" FAKE_STATE="$TEST_TMP/state" "$@"
}

# how many calls in calls.log contain the text.
calls_containing() {
  [ -f "$TEST_TMP/state/calls.log" ] || { echo 0; return 0; }
  grep -F -c "$1" "$TEST_TMP/state/calls.log" || true
}

# how many events the watcher wrote with this name.
events_named() {
  [ -f "$TEST_TMP/keep-awake/events.jsonl" ] || { echo 0; return 0; }
  grep -c "\"event\": \"$1\"" "$TEST_TMP/keep-awake/events.jsonl" || true
}

test_watcher_holds_while_bb_is_busy_and_releases_once_bb_is_idle() {
  watcher_ready || return 0
  make_fakes
  set_schedule busy idle
  run_watcher SIRVEN_BB_PASSES=2 || fail "the watcher failed: $(cat "$TEST_TMP/watcher.out")"
  assert_eq 1 "$(calls_containing 'awake begin bb-agents')" "a busy pass begins the hold once"
  assert_eq 1 "$(events_named bb-watcher-release)" "the idle pass releases it with an event"
  assert_eq 1 "$(calls_containing 'awake end bb-agents')" "the release ends the task"
}

test_a_busy_pass_renews_the_lease_each_time() {
  watcher_ready || return 0
  make_fakes
  set_schedule busy busy busy
  run_watcher SIRVEN_BB_PASSES=3 SIRVEN_BB_RENEW=0 || fail "the watcher failed: $(cat "$TEST_TMP/watcher.out")"
  assert_eq 3 "$(calls_containing 'awake begin bb-agents')" "each busy pass renews the lease"
  assert_eq 1 "$(events_named bb-watcher-hold)" "a renewal for the same reason logs nothing new"
}

test_the_hold_survives_the_idle_window() {
  watcher_ready || return 0
  make_fakes
  set_schedule busy idle idle
  run_watcher SIRVEN_BB_PASSES=3 SIRVEN_BB_IDLE=300 || fail "the watcher failed: $(cat "$TEST_TMP/watcher.out")"
  assert_eq 0 "$(events_named bb-watcher-release)" "two idle passes inside a 300 second window release nothing"
  assert_eq 1 "$(calls_containing 'awake begin bb-agents')" "the hold was begun once and kept"
}

test_a_failed_query_counts_toward_the_idle_window() {
  watcher_ready || return 0
  make_fakes
  set_schedule busy fail
  run_watcher SIRVEN_BB_PASSES=2 || fail "the watcher failed: $(cat "$TEST_TMP/watcher.out")"
  assert_eq 1 "$(events_named bb-watcher-release)" "an unreachable bb releases the hold once the window is over"
  assert_eq 1 "$(calls_containing 'awake begin bb-agents')" "the failed query begins nothing"
}

test_the_ceiling_releases_a_hold_and_holds_again_only_after_bb_is_idle() {
  watcher_ready || return 0
  make_fakes
  set_schedule busy busy idle busy
  run_watcher SIRVEN_BB_PASSES=4 SIRVEN_BB_MAX_HOLD=0 || fail "the watcher failed: $(cat "$TEST_TMP/watcher.out")"
  assert_eq 1 "$(events_named bb-watcher-max-hold)" "the ceiling is logged once"
  assert_eq 2 "$(calls_containing 'awake begin bb-agents')" "after the idle pass, a busy pass holds again"
}

test_the_ceiling_does_not_hold_again_while_bb_stays_busy() {
  watcher_ready || return 0
  make_fakes
  set_schedule busy busy busy
  run_watcher SIRVEN_BB_PASSES=3 SIRVEN_BB_MAX_HOLD=0 || fail "the watcher failed: $(cat "$TEST_TMP/watcher.out")"
  assert_eq 1 "$(calls_containing 'awake begin bb-agents')" "busy passes after the ceiling begin nothing"
  assert_eq 1 "$(calls_containing 'awake end bb-agents')" "the ceiling ends the hold once"
}

test_a_user_release_is_respected_until_bb_goes_idle() {
  watcher_ready || return 0
  make_fakes
  echo '{"work":[{"task":"bb-agents","releasedAt":"2026-10-13T10:00:00Z"}]}' > "$TEST_TMP/state/status.json"
  set_schedule busy busy busy
  run_watcher SIRVEN_BB_PASSES=3 SIRVEN_BB_IDLE=300 || fail "the watcher failed: $(cat "$TEST_TMP/watcher.out")"
  assert_eq 1 "$(calls_containing 'awake begin bb-agents')" "the released hold is not taken back while bb stays busy"
  assert_eq 1 "$(events_named bb-watcher-respecting-release)" "the release is respected with one event"
}

test_the_host_is_required() {
  watcher_ready || return 0
  make_fakes
  assert_status 1 env -i HOME="$TEST_TMP/home" PATH="$TEST_TMP/bin:/usr/bin:/bin" bash "$WATCHER"
  assert_contains "$CAPTURED_STDERR" "SIRVEN_BB_HOST"
}

test_the_scratch_files_are_removed_when_the_watcher_exits() {
  watcher_ready || return 0
  make_fakes
  set_schedule busy idle
  run_watcher SIRVEN_BB_PASSES=2 || fail "the watcher failed: $(cat "$TEST_TMP/watcher.out")"
  assert_eq "" "$(ls -A "$TEST_TMP/tmp")" "no scratch directory is left behind"
}

test_the_installer_rejects_an_unknown_argument_before_touching_anything() {
  watcher_ready || return 0
  make_fakes
  assert_status 64 installer bash "$INSTALLER" bogus
  assert_contains "$CAPTURED_STDERR" "usage"
  assert_eq 0 "$(calls_containing 'launchctl')" "no launchctl call was made"
}

test_the_installer_stops_nothing_when_a_prerequisite_is_missing() {
  watcher_ready || return 0
  make_fakes
  rm "$TEST_TMP/bin/bb"
  assert_status 1 installer bash "$INSTALLER"
  assert_eq 0 "$(calls_containing 'launchctl')" "the agent is not stopped when bb is missing"
  assert_no_file "$TEST_TMP/home/Library/LaunchAgents/xyz.sirven.keep-awake-bb-watcher.plist"
}

test_install_stops_then_writes_a_private_plist_without_the_server_url_then_starts() {
  watcher_ready || return 0
  make_fakes
  assert_status 0 installer bash "$INSTALLER"
  local plist="$TEST_TMP/home/Library/LaunchAgents/xyz.sirven.keep-awake-bb-watcher.plist"
  assert_eq "600" "$(stat -f %Lp "$plist")" "the plist is readable only by the user"
  assert_contains "$(cat "$plist")" "<string>$FAKE_HOST</string>" "the host is written into the plist"
  assert_not_contains "$(cat "$plist")" "BB_SERVER_URL" "the server address is not copied"
  assert_file_exists "$TEST_TMP/home/Library/Application Support/sirven/bb-watcher/sirven-bb-awake-watcher.sh"
  local first last
  first="$(grep -m1 'launchctl' "$TEST_TMP/state/calls.log")"
  last="$(grep 'launchctl' "$TEST_TMP/state/calls.log" | tail -n 1)"
  assert_contains "$first" "bootout" "the old agent is stopped first"
  assert_contains "$last" "bootstrap" "the new agent is started last"
}

test_remove_stops_the_agent_before_removing_its_files_and_unregistering_the_helper() {
  watcher_ready || return 0
  make_fakes
  assert_status 0 installer bash "$INSTALLER"
  assert_status 0 installer bash "$INSTALLER" remove
  local stopped unregistered
  stopped="$(grep -n 'bootout' "$TEST_TMP/state/calls.log" | tail -n 1 | cut -d: -f1)"
  unregistered="$(grep -n 'helper unregister' "$TEST_TMP/state/calls.log" | cut -d: -f1)"
  [ -n "$unregistered" ] || fail "the helper was not asked to unregister"
  [ "$stopped" -lt "$unregistered" ] || fail "the agent must stop before the helper is unregistered"
  assert_no_file "$TEST_TMP/home/Library/LaunchAgents/xyz.sirven.keep-awake-bb-watcher.plist"
  assert_no_file "$TEST_TMP/home/Library/Application Support/sirven/bb-watcher"
}
