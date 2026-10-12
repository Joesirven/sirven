# shellcheck shell=bash
# the iPhone ride backend end to end: the ride connector gateway over connectors/ride/ride_phone,
# the real phone bridge, and the fake phone in world mode, after onboarding built the map.
# connectors/ride/tests/phone_ride_check.py plays the owner: sirven phone approve, then the
# phone's own payment sheet. like test_phone.sh, it must run outside the agent sandbox.

start_world() {
  FAKE="$TEST_TMP/phone"
  mkdir -p "$FAKE"
  cp "$REPO_DIR/tests/lib/phone_world.json" "$FAKE/world.json"
  export FAKE SIRVEN_USBMUX_SOCKET="$FAKE/usbmuxd" SIRVEN_PHONE_DIR="$TEST_TMP/state" SIRVEN_PHONE_TEST_YES=yes
  python3 -B "$REPO_DIR/tests/lib/fake_phone.py" "$FAKE" > "$TEST_TMP/fake.log" 2>&1 &
  FAKE_PROCESS=$!
  trap 'kill $FAKE_PROCESS ${BRIDGE_PROCESS:-} 2>/dev/null' EXIT
  wait_until "[ -e '$FAKE/ready' ]"
  "$REPO_DIR/bin/sirven" phone serve --port 0 > "$TEST_TMP/bridge.log" 2>&1 &
  BRIDGE_PROCESS=$!
  wait_until "grep -q 'http://' '$TEST_TMP/bridge.log'"
  BRIDGE="$(sed -n 's|.*\(http://127.0.0.1:[0-9]*/v1/phone\).*|\1|p' "$TEST_TMP/bridge.log")"
  export BRIDGE
  "$REPO_DIR/bin/sirven" phone onboard > "$TEST_TMP/onboard.log" 2>&1 || fail "onboarding failed: $(cat "$TEST_TMP/onboard.log")"
  "$REPO_DIR/bin/sirven" phone allow --minutes 30 > /dev/null || fail "allow failed"
}

wait_until() {
  local tries=0
  until eval "$1"; do
    tries=$((tries + 1))
    [ "$tries" -lt 200 ] || fail "never true: $1"
    sleep 0.05
  done
}

ride_check() {
  capture env PYTHONDONTWRITEBYTECODE=1 python3 -B "$REPO_DIR/connectors/ride/tests/phone_ride_check.py" "$1"
  if [ "$CAPTURED_STATUS" -ne 0 ]; then
    fail "scenario $1 failed:
$CAPTURED_STDOUT
$CAPTURED_STDERR"
  fi
}

test_quote_and_book_with_both_live_approvals() {
  start_world
  cd "$REPO_DIR/connectors/ride/tests" || fail "connectors/ride/tests is missing"
  ride_check approve
  assert_contains "$CAPTURED_STDOUT" "providers: ['Uber']"
  assert_contains "$CAPTURED_STDOUT" "booked: confirmed Toyota Prius, white, 7ABC123"
  assert_contains "$CAPTURED_STDOUT" "status: driver_assigned"
  capture "$REPO_DIR/bin/sirven" phone log
  assert_contains "$CAPTURED_STDOUT" "held for the owner"
  assert_contains "$CAPTURED_STDOUT" "the owner approved tapping \"Request UberX\""
}

test_a_refused_hold_books_nothing() {
  start_world
  cd "$REPO_DIR/connectors/ride/tests" || fail "connectors/ride/tests is missing"
  ride_check deny_hold
  assert_contains "$CAPTURED_STDOUT" "error: payment_declined"
  assert_not_contains "$(cat "$FAKE/world-state.json")" "pay_sheet"
  assert_not_contains "$(cat "$FAKE/world-state.json")" "on_the_way"
}

test_declining_on_the_phone_books_nothing() {
  start_world
  cd "$REPO_DIR/connectors/ride/tests" || fail "connectors/ride/tests is missing"
  ride_check decline_on_phone
  assert_contains "$CAPTURED_STDOUT" "error: payment_declined"
  assert_not_contains "$(cat "$FAKE/world-state.json")" "on_the_way"
}

test_a_price_that_rose_is_never_booked() {
  start_world
  cd "$REPO_DIR/connectors/ride/tests" || fail "connectors/ride/tests is missing"
  ride_check price_rose
  assert_contains "$CAPTURED_STDOUT" "error: price_changed"
  assert_contains "$CAPTURED_STDOUT" "owner did: []"
}

test_cancel_after_booking() {
  start_world
  cd "$REPO_DIR/connectors/ride/tests" || fail "connectors/ride/tests is missing"
  ride_check cancel
  assert_contains "$CAPTURED_STDOUT" "cancelled: cancelled"
}

test_nothing_touches_the_phones_own_payment_sheet() {
  start_world
  cd "$REPO_DIR/connectors/ride/tests" || fail "connectors/ride/tests is missing"
  ride_check approve
  assert_no_file "$FAKE/sheet_touched"
}
