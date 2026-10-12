# shellcheck shell=bash
# the semantic map of the owner's phone, end to end against the fake iPhone in world mode
# (tests/lib/fake_phone.py with tests/lib/phone_world.json): onboarding with the typed yes,
# showing and pruning the map, the offer on the first connection of the day, the status flag,
# the agent's read of the map, and the privacy rules on what the saved map may hold. the python
# unit tests for lib/phone_map.py and lib/phone_crawler.py run from here too.

phone() {
  "$REPO_DIR/bin/sirven" phone "$@"
}

# start_phone: a fake phone in TEST_TMP/phone playing the world, the bridge state in TEST_TMP/state.
start_phone() {
  FAKE="$TEST_TMP/phone"
  mkdir -p "$FAKE"
  cp "$REPO_DIR/tests/lib/phone_world.json" "$FAKE/world.json"
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

# change_world PYTHON: edit the fake phone's world before the bridge acts. the python sees the
# world as w and a helper named(app, screen, label) that finds one element.
change_world() {
  python3 -B - "$FAKE/world.json" "$1" <<'PYTHON'
import json, sys
path, change = sys.argv[1], sys.argv[2]
with open(path) as handle:
    w = json.load(handle)
def named(app, screen, label):
    return [e for e in w["apps"][app]["screens"][screen]["elements"] if e["label"] == label][0]
exec(change)
with open(path, "w") as handle:
    json.dump(w, handle)
PYTHON
}

# the bank's icon moved to the first home screen page, so the login test does not hang on paging
BANK_ON_PAGE_ONE='pages = w["apps"]["com.apple.springboard"]["screens"]
bank = [e for e in pages["page2"]["elements"] if e["label"] == "First Neighborhood Bank"][0]
pages["page2"]["elements"].remove(bank)
pages["page1"]["elements"].append(dict(bank, frame=[24, 170, 64, 64]))'

# tapped_labels: what every tap the fake phone received landed on, one label per line
tapped_labels() {
  [ -f "$FAKE/calls.jsonl" ] || return 0
  python3 -B "$REPO_DIR/tests/phone/fake_driver.py" "$FAKE/world.json" "$FAKE/calls.jsonl"
}

# map_value PYTHON: evaluate an expression over the saved map, loaded as m
map_value() {
  python3 -B -c 'import json, sys; m = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' \
    "$SIRVEN_PHONE_DIR/map.json" "$1"
}

status_value() {
  phone status | python3 -B -c 'import json, sys; print(json.load(sys.stdin).get(sys.argv[1]))' "$1"
}

assert_map_is_private() {
  local saved word
  assert_file_exists "$SIRVEN_PHONE_DIR/map.json"
  saved="$(cat "$SIRVEN_PHONE_DIR/map.json")"
  for word in Jose hunter2 Mom jose.sirven "Sign in" screenshot iVBORw0KGgo '"value"' '"elements"' \
    "Good afternoon" "Barber" "18.40" "Apple Pay"; do
    assert_not_contains "$saved" "$word" "the saved map holds something it never may"
  done
}

assert_never_tapped_anything_unsafe() {
  local tapped label
  tapped="$(tapped_labels)"
  for label in "Request UberX" "Request Comfort" "Request UberXL" Reserve Rent Wallet "Sign out" "Cancel ride" \
    "Yes, cancel" Compose "Log in"; do
    if printf '%s\n' "$tapped" | grep -Fxq "$label"; then
      fail "the crawler tapped \"$label\"; every tap: $tapped"
    fi
  done
  if [ -f "$FAKE/calls.jsonl" ]; then
    assert_not_contains "$(cat "$FAKE/calls.jsonl")" "/wda/keys" "the crawler typed"
  fi
}

test_onboarding_needs_the_owner_typing_yes() {
  start_phone
  unset SIRVEN_PHONE_TEST_YES
  assert_status 1 phone onboard
  assert_no_file "$SIRVEN_PHONE_DIR/map.json"
  assert_eq "" "$(tapped_labels)" "nothing was tapped without the yes"
}

test_onboarding_maps_the_ride_apps_and_keeps_nothing_private() {
  local tapped
  start_phone
  assert_status 0 phone onboard
  assert_contains "$CAPTURED_STDOUT" "Uber"
  assert_contains "$CAPTURED_STDOUT" "Lyft"
  assert_eq 600 "$(stat -f %Lp "$SIRVEN_PHONE_DIR/map.json" 2>/dev/null || stat -c %a "$SIRVEN_PHONE_DIR/map.json")"
  assert_eq 1 "$(map_value 'm["schema_version"]')"
  assert_eq True "$(map_value '"com.ubercab.UberClient" in m["apps"] and "com.zimride.instant" in m["apps"]')"
  assert_eq True "$(map_value 'len(m["apps"]["com.ubercab.UberClient"]["screens"]) >= 4')"
  assert_eq True "$(map_value '"First Neighborhood Bank" in m["inventory"]["names"] and "Messages" in m["inventory"]["names"]')"
  assert_eq False "$(map_value '"com.apple.MobileSMS" in m["apps"]')" "only the chosen apps are crawled"
  assert_map_is_private
  assert_never_tapped_anything_unsafe
  tapped="$(tapped_labels)"
  assert_contains "$tapped" "Where to?" "the crawl did tap through the safe menus"
  assert_contains "$tapped" "Services"
  assert_no_file "$SIRVEN_PHONE_DIR/session.json"
  assert_contains "$(cat "$SIRVEN_PHONE_DIR/actions.jsonl")" '"event": "onboard"'
}

test_onboarding_leaves_only_a_count_for_a_login_screen() {
  start_phone
  change_world "$BANK_ON_PAGE_ONE"
  assert_status 0 phone onboard --app "First Neighborhood Bank"
  assert_eq 1 "$(map_value 'm["apps"]["com.example.bank"]["login_screens_skipped"]')"
  assert_eq 0 "$(map_value 'len(m["apps"]["com.example.bank"].get("screens") or {})')"
  assert_map_is_private
  assert_not_contains "$(cat "$SIRVEN_PHONE_DIR/map.json")" "Password"
  assert_not_contains "$(cat "$SIRVEN_PHONE_DIR/map.json")" "Username"
  assert_never_tapped_anything_unsafe
  assert_not_contains "$(cat "$SIRVEN_PHONE_DIR/actions.jsonl")" "hunter2"
}

test_priced_rows_are_stored_only_as_shapes() {
  start_phone
  change_world 'named("com.ubercab.UberClient", "home", "Where to?")["goto"] = "options"'
  assert_status 0 phone onboard --app Uber
  assert_contains "$(cat "$SIRVEN_PHONE_DIR/map.json")" 'UberX, # min away, # min trip, $#.#'
  assert_map_is_private
  assert_not_contains "$(cat "$SIRVEN_PHONE_DIR/map.json")" "31.75"
  assert_never_tapped_anything_unsafe
}

test_the_crawl_stops_when_the_phone_shows_its_own_payment_approval() {
  start_phone
  change_world 'named("com.ubercab.UberClient", "services", "Ride")["goto"] = "pay_sheet"'
  capture phone onboard
  [ "$CAPTURED_STATUS" -ne 0 ] || fail "onboarding claimed success over the payment sheet: $CAPTURED_STDOUT"
  assert_eq pay_sheet "$(python3 -B -c 'import json, sys; print(json.load(open(sys.argv[1]))["screen"])' "$FAKE/world-state.json")" \
    "the payment sheet is left for the owner"
  assert_no_file "$FAKE/sheet_touched"
  assert_not_contains "$(tapped_labels)" "Lyft" "the crawl went on to the next app"
  assert_not_contains "$(tapped_labels)" "Cancel"
  assert_never_tapped_anything_unsafe
  assert_eq True "$(status_value onboarding_due)" "a stopped crawl is not an onboarding"
  if [ -f "$SIRVEN_PHONE_DIR/map.json" ]; then assert_map_is_private; fi
}

test_the_map_is_shown_and_pruned_by_the_owner() {
  local before after screen
  start_phone
  phone onboard > /dev/null || fail "onboarding failed"
  assert_status 0 phone map
  assert_contains "$CAPTURED_STDOUT" "Uber"
  assert_status 0 phone map --json
  assert_eq 1 "$(printf '%s' "$CAPTURED_STDOUT" | python3 -B -c 'import json, sys; print(json.load(sys.stdin)["schema_version"])')"
  before="$(map_value 'len(m["apps"]["com.ubercab.UberClient"]["screens"])')"
  screen="$(map_value 'sorted(m["apps"]["com.ubercab.UberClient"]["screens"])[0]')"
  assert_status 0 phone map prune com.ubercab.UberClient "$screen"
  after="$(map_value 'len(m["apps"]["com.ubercab.UberClient"]["screens"])')"
  assert_eq $((before - 1)) "$after" "one screen was pruned"
  assert_eq True "$(map_value '"'"$screen"'" not in m["apps"]["com.ubercab.UberClient"]["screens"]')"
  assert_status 0 phone map prune Lyft
  assert_eq False "$(map_value '"com.zimride.instant" in m["apps"]')"
  assert_eq True "$(map_value '"com.ubercab.UberClient" in m["apps"]')"
  capture phone map prune com.example.nothing
  [ "$CAPTURED_STATUS" -ne 0 ] || fail "pruning an app the map does not have claimed success"
  assert_contains "$(cat "$SIRVEN_PHONE_DIR/actions.jsonl")" '"event": "prune"'
}

test_allow_offers_onboarding_on_the_first_connection_of_the_day_only() {
  start_phone
  assert_status 0 phone allow
  assert_contains "$CAPTURED_STDOUT" "sirven phone onboard"
  assert_no_file "$SIRVEN_PHONE_DIR/map.json"
  assert_eq "" "$(tapped_labels)" "the offer does not run onboarding by itself"
  phone stop > /dev/null
  phone onboard > /dev/null || fail "onboarding failed"
  phone stop > /dev/null
  assert_status 0 phone allow
  assert_not_contains "$CAPTURED_STDOUT" "sirven phone onboard"
}

test_status_says_when_onboarding_is_due() {
  start_phone
  assert_eq True "$(status_value onboarding_due)"
  phone onboard > /dev/null || fail "onboarding failed"
  assert_eq False "$(status_value onboarding_due)"
}

test_the_agent_reads_the_map_only_with_the_token_and_a_session() {
  start_phone
  phone onboard > /dev/null || fail "onboarding failed"
  start_bridge
  TOKEN=wrong ask GET /map
  assert_eq 401 "$HTTP_STATUS"
  phone stop > /dev/null
  ask GET /map
  assert_eq 403 "$HTTP_STATUS"
  assert_contains "$RESPONSE" "no_consent"
  phone allow > /dev/null
  ask GET /map
  assert_eq 200 "$HTTP_STATUS"
  assert_contains "$RESPONSE" "com.ubercab.UberClient"
  assert_contains "$RESPONSE" "com.zimride.instant"
  ask GET "/map?app=com.ubercab.UberClient"
  assert_eq 200 "$HTTP_STATUS"
  assert_contains "$RESPONSE" "Where to?"
  assert_not_contains "$RESPONSE" "com.zimride.instant"
  for word in Jose hunter2 Mom jose.sirven "Sign in" screenshot; do
    assert_not_contains "$RESPONSE" "$word"
  done
}

test_the_python_unit_tests_pass() {
  local output status=0
  output="$(cd "$REPO_DIR" && python3 -B -m unittest discover -s "$REPO_DIR/tests/phone" 2>&1)" || status=$?
  find "$REPO_DIR/tests/phone" "$REPO_DIR/lib" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null
  [ "$status" -eq 0 ] || fail "the python unit tests failed:
$output"
  assert_contains "$output" "Ran "
}
