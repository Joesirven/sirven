# shellcheck shell=bash
# the phone bridge, end to end against a fake iPhone: a fake USB multiplexer and a fake
# WebDriverAgent (tests/lib/fake_phone.py). detect, consent, read the screen, tap, type, the
# money hold, the plain-language log, and every refusal.

phone() {
  "$REPO_DIR/bin/sirven" phone "$@"
}

# start_phone: a fake phone in TEST_TMP/phone, the bridge state in TEST_TMP/state.
start_phone() {
  FAKE="$TEST_TMP/phone"
  mkdir -p "$FAKE"
  export SIRVEN_USBMUX_SOCKET="$FAKE/usbmuxd"
  export SIRVEN_PHONE_DIR="$TEST_TMP/state"
  export SIRVEN_PHONE_TEST_YES=yes
  python3 "$REPO_DIR/tests/lib/fake_phone.py" "$FAKE" > "$TEST_TMP/fake.log" 2>&1 &
  FAKE_PROCESS=$!
  trap 'kill $FAKE_PROCESS ${BRIDGE_PROCESS:-} 2>/dev/null' EXIT
  wait_for_file "$FAKE/ready"
}

# start_bridge: the local interface on a free port, into BRIDGE and TOKEN.
start_bridge() {
  phone serve --port 0 > "$TEST_TMP/bridge.log" 2>&1 &
  BRIDGE_PROCESS=$!
  wait_for_file "$SIRVEN_PHONE_DIR/token"
  local tries=0
  until grep -q 'http://' "$TEST_TMP/bridge.log"; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || fail "the bridge never started: $(cat "$TEST_TMP/bridge.log")"
    sleep 0.05
  done
  BRIDGE="$(sed -n 's|.*\(http://127.0.0.1:[0-9]*/v1/phone\).*|\1|p' "$TEST_TMP/bridge.log")"
  TOKEN="$(cat "$SIRVEN_PHONE_DIR/token")"
}

wait_for_file() {
  local tries=0
  until [ -e "$1" ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || fail "$1 never appeared"
    sleep 0.05
  done
}

# ask METHOD ROUTE [JSON]: call the bridge as the agent would. RESPONSE and HTTP_STATUS.
ask() {
  local method="$1" route="$2" body="${3:-}"
  if [ -n "$body" ]; then
    RESPONSE="$(curl -s --max-time 10 -w '\n%{http_code}' -X "$method" -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/json' --data "$body" "$BRIDGE$route")"
  else
    RESPONSE="$(curl -s --max-time 10 -w '\n%{http_code}' -X "$method" -H "Authorization: Bearer $TOKEN" "$BRIDGE$route")"
  fi
  HTTP_STATUS="${RESPONSE##*$'\n'}"
  RESPONSE="${RESPONSE%$'\n'*}"
}

taps() {
  if [ -f "$FAKE/calls.jsonl" ]; then grep -c '/wda/tap' "$FAKE/calls.jsonl" || true; else printf '0'; fi
}

test_detect_finds_a_trusted_phone() {
  start_phone
  assert_status 0 phone detect
  assert_eq "an iPhone is plugged in and trusts this Mac" "$CAPTURED_STDOUT"
}

test_detect_is_honest_about_no_phone_an_untrusted_phone_and_several() {
  start_phone
  printf '0' > "$FAKE/phones"
  assert_status 1 phone detect
  assert_contains "$CAPTURED_STDOUT" "no iPhone is plugged in"
  printf '1' > "$FAKE/phones"
  touch "$FAKE/untrusted"
  assert_status 1 phone detect
  assert_contains "$CAPTURED_STDOUT" "has not trusted this Mac yet"
  rm "$FAKE/untrusted"
  printf '2' > "$FAKE/phones"
  assert_status 1 phone detect
  assert_contains "$CAPTURED_STDOUT" "sirven drives one personal phone"
}

test_detect_never_prints_the_serial_or_the_pair_record() {
  start_phone
  assert_status 0 phone detect --json
  assert_not_contains "$CAPTURED_STDOUT" "fake-serial"
  assert_not_contains "$CAPTURED_STDOUT" "pair record"
}

test_no_usb_multiplexer_is_an_honest_error() {
  export SIRVEN_USBMUX_SOCKET="$TEST_TMP/nothing-here"
  export SIRVEN_PHONE_DIR="$TEST_TMP/state"
  assert_status 1 phone detect
  assert_contains "$CAPTURED_STDERR" "the Mac's USB multiplexer did not answer"
}

test_the_interface_needs_the_bearer_token_and_listens_on_loopback_only() {
  start_phone
  start_bridge
  assert_contains "$BRIDGE" "http://127.0.0.1:"
  TOKEN=wrong ask GET /status
  assert_eq 401 "$HTTP_STATUS"
  assert_eq 600 "$(stat -f %Lp "$SIRVEN_PHONE_DIR/token" 2>/dev/null || stat -c %a "$SIRVEN_PHONE_DIR/token")"
}

test_without_a_session_every_action_is_refused_and_nothing_reaches_the_phone() {
  start_phone
  start_bridge
  ask GET "/screen?reason=look"
  assert_eq 403 "$HTTP_STATUS"
  assert_contains "$RESPONSE" '"result": "no_consent"'
  ask POST /tap '{"x": 50, "y": 220, "reason": "pick a pickup spot"}'
  assert_eq 403 "$HTTP_STATUS"
  assert_eq 0 "$(taps)"
}

test_allow_needs_the_owner_at_a_terminal() {
  start_phone
  unset SIRVEN_PHONE_TEST_YES
  assert_status 1 phone allow
  assert_contains "$CAPTURED_STDERR" "needs the owner at a terminal, typing yes"
  assert_no_file "$SIRVEN_PHONE_DIR/session.json"
}

test_the_test_yes_never_works_against_the_real_usb_multiplexer() {
  export SIRVEN_PHONE_DIR="$TEST_TMP/state"
  export SIRVEN_PHONE_TEST_YES=yes
  unset SIRVEN_USBMUX_SOCKET
  assert_status 1 phone allow
  assert_no_file "$SIRVEN_PHONE_DIR/session.json"
}

test_read_the_screen_then_tap_then_the_log_says_so() {
  start_phone
  start_bridge
  assert_status 0 phone allow --minutes 15
  assert_contains "$CAPTURED_STDOUT" "phone session open until"
  ask GET "/screen?reason=see+the+ride+options"
  assert_eq 200 "$HTTP_STATUS"
  assert_contains "$RESPONSE" '"app": "com.example.rides"'
  assert_contains "$RESPONSE" '"label": "Request ride"'
  assert_contains "$RESPONSE" '"screenshot_png_base64": "iVBORw0KGgo="'
  ask POST /tap '{"label": "Choose pickup", "reason": "set the pickup to home"}'
  assert_eq 200 "$HTTP_STATUS"
  assert_contains "$RESPONSE" "tapped \\\"Choose pickup\\\" in com.example.rides"
  assert_contains "$(cat "$FAKE/calls.jsonl")" '"path": "/session/fake-session/wda/tap", "body": {"x": 195.0, "y": 225.0}'
  capture phone log
  assert_contains "$CAPTURED_STDOUT" "the owner opened a phone session for 15 minutes"
  assert_contains "$CAPTURED_STDOUT" "read the screen in com.example.rides, because: see the ride options"
  assert_contains "$CAPTURED_STDOUT" "tapped \"Choose pickup\" in com.example.rides, because: set the pickup to home"
}

test_a_tap_by_point_names_what_it_landed_on() {
  start_phone
  start_bridge
  phone allow > /dev/null
  ask POST /tap '{"x": 40, "y": 120, "reason": "focus the destination"}'
  assert_eq 200 "$HTTP_STATUS"
  assert_contains "$RESPONSE" "tapped \\\"Where to?\\\""
  ask POST /tap '{"x": 5, "y": 5, "reason": "dismiss"}'
  assert_contains "$RESPONSE" "an unlabeled spot at 5, 5"
}

test_every_action_needs_a_reason() {
  start_phone
  start_bridge
  phone allow > /dev/null
  ask POST /tap '{"x": 40, "y": 120}'
  assert_eq 400 "$HTTP_STATUS"
  assert_eq 0 "$(taps)"
}

test_a_money_bearing_tap_waits_for_the_owner_then_works_once() {
  local hold
  start_phone
  start_bridge
  phone allow > /dev/null
  ask POST /tap '{"label": "Request ride", "reason": "book the ride under 25 dollars"}'
  assert_eq 409 "$HTTP_STATUS"
  assert_contains "$RESPONSE" '"result": "held_for_approval"'
  assert_eq 0 "$(taps)"
  hold="$(printf '%s' "$RESPONSE" | sed -n 's/.*"hold": "\([a-z0-9]*\)".*/\1/p')"
  ask POST /tap "{\"label\": \"Request ride\", \"approval\": \"$hold\", \"reason\": \"try anyway\"}"
  assert_eq 403 "$HTTP_STATUS"
  assert_contains "$RESPONSE" "has not been approved"
  capture phone holds
  assert_contains "$CAPTURED_STDOUT" "$hold  tap \"Request ride\" in com.example.rides"
  assert_status 0 phone approve "$hold"
  ask POST /tap "{\"label\": \"Request ride\", \"approval\": \"$hold\", \"reason\": \"the owner approved\"}"
  assert_eq 200 "$HTTP_STATUS"
  assert_eq 1 "$(taps)"
  ask POST /tap "{\"label\": \"Request ride\", \"approval\": \"$hold\", \"reason\": \"again\"}"
  assert_eq 403 "$HTTP_STATUS"
  assert_eq 1 "$(taps)" "an approval is good once"
  capture phone log
  assert_contains "$CAPTURED_STDOUT" "held for the owner"
  assert_contains "$CAPTURED_STDOUT" "the owner approved tapping \"Request ride\""
}

test_an_approval_covers_only_the_label_it_was_given_for() {
  local hold
  start_phone
  start_bridge
  phone allow > /dev/null
  ask POST /tap '{"label": "Choose pickup", "money": true, "reason": "agent says this costs money"}'
  assert_eq 409 "$HTTP_STATUS"
  hold="$(printf '%s' "$RESPONSE" | sed -n 's/.*"hold": "\([a-z0-9]*\)".*/\1/p')"
  phone approve "$hold" > /dev/null
  ask POST /tap "{\"label\": \"Request ride\", \"approval\": \"$hold\", \"reason\": \"swap\"}"
  assert_eq 403 "$HTTP_STATUS"
  assert_contains "$RESPONSE" "approved for a different action"
  assert_eq 0 "$(taps)"
}

test_a_denied_hold_cannot_be_used() {
  local hold
  start_phone
  start_bridge
  phone allow > /dev/null
  ask POST /tap '{"label": "Request ride", "reason": "book it"}'
  hold="$(printf '%s' "$RESPONSE" | sed -n 's/.*"hold": "\([a-z0-9]*\)".*/\1/p')"
  assert_status 0 phone deny "$hold"
  ask POST /tap "{\"label\": \"Request ride\", \"approval\": \"$hold\", \"reason\": \"book it\"}"
  assert_eq 403 "$HTTP_STATUS"
  assert_status 1 phone approve "$hold"
}

test_typing_works_but_never_into_a_password_field() {
  start_phone
  start_bridge
  phone allow > /dev/null
  ask POST /type '{"text": "Barber on Valencia", "reason": "the destination"}'
  assert_eq 200 "$HTTP_STATUS"
  assert_contains "$(cat "$FAKE/calls.jsonl")" '"value": ["Barber on Valencia"]'
  printf 'XCUIElementTypeSecureTextField' > "$FAKE/focused"
  ask POST /type '{"text": "hunter2", "reason": "log in"}'
  assert_eq 403 "$HTTP_STATUS"
  assert_contains "$RESPONSE" '"result": "secure_field"'
  assert_not_contains "$(cat "$FAKE/calls.jsonl")" "hunter2"
  assert_not_contains "$(cat "$SIRVEN_PHONE_DIR/actions.jsonl")" "hunter2"
}

test_return_needs_a_session_opened_with_allow_submit() {
  start_phone
  start_bridge
  phone allow > /dev/null
  ask POST /type '{"text": "on my way", "submit": true, "reason": "reply"}'
  assert_eq 403 "$HTTP_STATUS"
  assert_contains "$RESPONSE" "submit_not_allowed"
  ask POST /type '{"text": "line\nbreak", "reason": "reply"}'
  assert_eq 403 "$HTTP_STATUS"
  phone allow --allow-submit > /dev/null
  ask POST /type '{"text": "on my way", "submit": true, "reason": "reply"}'
  assert_eq 200 "$HTTP_STATUS"
  assert_contains "$RESPONSE" "and pressed return"
}

test_a_locked_phone_is_reported_not_unlocked() {
  start_phone
  start_bridge
  phone allow > /dev/null
  touch "$FAKE/locked"
  ask POST /tap '{"x": 40, "y": 120, "reason": "focus"}'
  assert_eq 409 "$HTTP_STATUS"
  assert_contains "$RESPONSE" '"result": "phone_locked"'
  assert_eq 0 "$(taps)"
}

test_stop_ends_control_at_once() {
  start_phone
  start_bridge
  phone allow > /dev/null
  ask POST /home '{"reason": "start clean"}'
  assert_eq 200 "$HTTP_STATUS"
  assert_status 0 phone stop
  assert_contains "$CAPTURED_STDOUT" "phone session ended"
  ask POST /home '{"reason": "start clean"}'
  assert_eq 403 "$HTTP_STATUS"
}

test_an_expired_session_is_no_session() {
  start_phone
  start_bridge
  SIRVEN_TIME_OVERRIDE=2020-01-01T08:00:00Z phone allow --minutes 5 > /dev/null
  ask POST /home '{"reason": "start clean"}'
  assert_eq 403 "$HTTP_STATUS"
  assert_contains "$RESPONSE" "no_consent"
}

test_launch_and_swipe_are_logged_in_plain_words() {
  start_phone
  start_bridge
  phone allow > /dev/null
  ask POST /launch '{"bundle": "com.example.rides", "reason": "open the ride app"}'
  assert_eq 200 "$HTTP_STATUS"
  ask POST /swipe '{"from_x": 200, "from_y": 700, "to_x": 200, "to_y": 300, "reason": "see more options"}'
  assert_eq 200 "$HTTP_STATUS"
  capture phone log
  assert_contains "$CAPTURED_STDOUT" "opened com.example.rides, because: open the ride app"
  assert_contains "$CAPTURED_STDOUT" "swiped from 200, 700 to 200, 300 in com.example.rides"
}

test_setup_only_prints_and_checks_its_inputs() {
  assert_status 64 phone setup --team nope --bundle com.example.Runner
  assert_status 0 phone setup --team ABCDE12345 --bundle com.example.Runner
  assert_contains "$CAPTURED_STDOUT" "sirven only prints this"
  assert_contains "$CAPTURED_STDOUT" "DEVELOPMENT_TEAM=ABCDE12345"
}

test_unknown_phone_commands_are_usage_errors() {
  assert_status 64 phone
  assert_status 64 phone teleport
  assert_status 64 phone allow --minutes 9999
}
