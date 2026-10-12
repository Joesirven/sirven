# shellcheck shell=bash
# reciprocity ledger: the cap at, under, and over its boundary, symmetry, solo, the monthly
# rollover, privacy refusals, the read-out a test consumer renders, and reconciliation.

export TZ=America/Los_Angeles
CAP=5000000000

ledger() {
  python3 "$REPO_DIR/lib/reciprocity.py" "$@" --ledger "$TEST_TMP/ledger.jsonl"
}

# epoch "2026-10-15 12:00:00": seconds since 1970 for a local time in TZ.
epoch() {
  python3 -c 'import sys, time; print(int(time.mktime(time.strptime(sys.argv[1], "%Y-%m-%d %H:%M:%S"))))' "$1"
}

MID_OCTOBER="$(epoch "2026-10-15 12:00:00")"

record() {
  local direction="$1" bytes="$2" at="${3:-$MID_OCTOBER}" transfer="${4:-t-$RANDOM$RANDOM}"
  ledger record --direction "$direction" --bytes "$bytes" --domain example.com \
    --session "s-$transfer" --transfer "$transfer" --peer peer-a --now "$at" \
    || fail "record $direction $bytes failed"
}

check() {
  local direction="$1" bytes="$2" at="${3:-$MID_OCTOBER}" tier="${4:-neighborly}"
  # macos bash 3.2 treats an empty array as unset under set -u, so the size is two words or none.
  if [ -n "$bytes" ]; then
    set -- --bytes "$bytes"
  else
    set --
  fi
  ledger check --direction "$direction" --tier "$tier" --domain example.com --session s-check \
    --peer peer-b --now "$at" "$@"
}

field() {
  python3 -c 'import json, sys; value = json.load(sys.stdin)[sys.argv[1]]; print(json.dumps(value) if not isinstance(value, str) else value)' "$1"
}

test_a_request_landing_exactly_on_the_cap_is_within_it() {
  record sent 4000000000
  assert_status 0 check carried 1000000000
  assert_eq true "$(printf '%s' "$CAPTURED_STDOUT" | field within_cap)"
  assert_eq 1000000000 "$(printf '%s' "$CAPTURED_STDOUT" | field remaining_bytes)"
}

test_one_byte_under_the_cap_is_within_it() {
  record sent 4000000000
  assert_status 0 check carried 999999999
}

test_one_byte_over_the_cap_is_refused_with_a_recorded_reason() {
  record sent 4000000000
  assert_status 3 check carried 1000000001
  assert_eq false "$(printf '%s' "$CAPTURED_STDOUT" | field within_cap)"
  assert_contains "$CAPTURED_STDOUT" "would go past your 5 gigabyte monthly cap"
  assert_contains "$CAPTURED_STDOUT" "Usage resets November 1."
  assert_contains "$(cat "$TEST_TMP/ledger.jsonl")" '"kind": "refusal"'
  assert_contains "$(cat "$TEST_TMP/ledger.jsonl")" "would go past your 5 gigabyte monthly cap"
}

test_sending_fills_the_cap_and_then_carrying_is_refused() {
  record sent "$CAP"
  assert_status 3 check carried 1
}

test_carrying_fills_the_cap_and_then_sending_is_refused() {
  record carried "$CAP"
  assert_status 3 check sent 1
}

test_carried_and_sent_add_up_against_one_cap() {
  record carried 2500000000
  record sent 2500000000
  assert_status 3 check sent 1
  assert_contains "$CAPTURED_STDOUT" '"used_bytes": 5000000000'
}

test_a_sizeless_check_asks_whether_any_room_is_left() {
  record carried 4999999999
  assert_status 0 check carried ""
  assert_eq 1 "$(printf '%s' "$CAPTURED_STDOUT" | field remaining_bytes)"
  record carried 1
  assert_status 3 check carried ""
  assert_contains "$CAPTURED_STDOUT" "Your 5 gigabyte monthly cap is used up"
}

test_solo_refuses_every_carry_and_send() {
  assert_status 3 check carried 1 "$MID_OCTOBER" solo
  assert_contains "$CAPTURED_STDOUT" "Solo shares nothing"
  assert_status 3 check sent "" "$MID_OCTOBER" solo
  assert_eq 0 "$(printf '%s' "$CAPTURED_STDOUT" | field cap_bytes)"
}

test_co_op_uses_the_neighborly_cap_until_one_is_set() {
  record sent "$CAP"
  assert_status 3 check sent 1 "$MID_OCTOBER" co-op
  assert_eq "$CAP" "$(printf '%s' "$CAPTURED_STDOUT" | field cap_bytes)"
}

test_the_month_rolls_over_at_local_midnight_on_the_first() {
  local last_second first_second
  last_second="$(epoch "2026-10-31 23:59:59")"
  first_second="$(epoch "2026-11-01 00:00:00")"
  record carried "$CAP" "$last_second"
  assert_status 3 check carried 1 "$last_second"
  assert_status 0 check carried "$CAP" "$first_second"
  assert_eq 0 "$(printf '%s' "$CAPTURED_STDOUT" | field used_bytes)"
}

test_december_rolls_over_into_january() {
  record sent "$CAP" "$(epoch "2026-12-31 23:00:00")"
  assert_status 0 check sent 1 "$(epoch "2027-01-01 00:00:01")"
  capture ledger read --now "$(epoch "2026-12-31 23:00:00")"
  assert_contains "$CAPTURED_STDOUT" '"resets_on": "January 1"'
}

test_a_url_or_path_is_never_stored_as_a_domain() {
  local bad
  for bad in "https://example.com" "example.com/account" "example.com?q=1" "user@example.com" "example.com:443" "localhost"; do
    assert_status 2 ledger record --direction sent --bytes 1 --domain "$bad" --session s --transfer t --peer p
    assert_contains "$CAPTURED_STDERR" "bare host name"
  done
  assert_no_file "$TEST_TMP/ledger.jsonl"
}

test_negative_bytes_are_refused() {
  assert_status 2 ledger record --direction sent --bytes -1 --domain example.com --session s --transfer t --peer p
}

test_the_ledger_stores_usage_metadata_only() {
  record carried 1000
  local keys
  keys="$(python3 -c 'import json, sys; print(" ".join(sorted(json.loads(open(sys.argv[1]).readline()))))' "$TEST_TMP/ledger.jsonl")"
  assert_eq "at bytes direction domain kind peer session transfer" "$keys"
}

test_the_usage_meter_consumer_renders_the_readout() {
  record carried 800000000 "$MID_OCTOBER" t1
  record sent 450000000 "$((MID_OCTOBER + 60))" t2
  check sent 4000000000 "$((MID_OCTOBER + 120))" > /dev/null
  capture ledger read --now "$((MID_OCTOBER + 180))"
  [ "$CAPTURED_STATUS" = 0 ] || fail "read failed: $CAPTURED_STDERR"
  printf '%s' "$CAPTURED_STDOUT" > "$TEST_TMP/readout.json"
  capture python3 "$REPO_DIR/tests/fixtures/usage_meter_consumer.py" < "$TEST_TMP/readout.json"
  assert_eq 0 "$CAPTURED_STATUS" "consumer failed: $CAPTURED_STDOUT $CAPTURED_STDERR"
  assert_contains "$CAPTURED_STDOUT" "meter [#####...............] 25% of the cap, October 2026"
  assert_contains "$CAPTURED_STDOUT" "You have used 1.25 gigabytes of your 5 gigabyte monthly cap: 800 megabytes carried for neighbors and 450 megabytes sent through neighbors. Resets November 1."
  assert_contains "$CAPTURED_STDOUT" "session Carried 800 megabytes to example.com for a neighbor."
  assert_contains "$CAPTURED_STDOUT" "session Sent 450 megabytes to example.com through a neighbor."
  assert_contains "$CAPTURED_STDOUT" "refused Sending this through a neighbor would go past"
  # newest session first
  assert_eq "session Sent 450 megabytes to example.com through a neighbor." \
    "$(printf '%s\n' "$CAPTURED_STDOUT" | grep '^session' | head -n 1)"
}

test_the_readout_only_counts_this_month() {
  record carried 3000000000 "$(epoch "2026-09-30 23:59:59")"
  record carried 1000000000
  capture ledger read --now "$MID_OCTOBER"
  assert_eq 1000000000 "$(printf '%s' "$CAPTURED_STDOUT" | field used_bytes)"
  assert_eq 20 "$(printf '%s' "$CAPTURED_STDOUT" | field percent_used)"
}

test_percent_used_never_shows_full_before_the_cap() {
  record carried 4999999999
  capture ledger read --now "$MID_OCTOBER"
  assert_eq 99 "$(printf '%s' "$CAPTURED_STDOUT" | field percent_used)"
}

test_solo_readout_says_nothing_is_shared() {
  capture ledger read --tier solo --now "$MID_OCTOBER"
  assert_contains "$CAPTURED_STDOUT" "Solo shares nothing, so there is no usage to count."
  printf '%s' "$CAPTURED_STDOUT" | python3 "$REPO_DIR/tests/fixtures/usage_meter_consumer.py" > /dev/null \
    || fail "consumer rejected the solo read-out"
}

test_concurrent_checks_and_records_never_corrupt_the_ledger() {
  local index
  for index in 1 2 3 4 5 6 7 8 9 10; do
    record carried 1000 "$MID_OCTOBER" "t$index" &
    check sent 1000 > /dev/null &
  done
  wait
  capture ledger read --now "$MID_OCTOBER"
  assert_eq 0 "$CAPTURED_STATUS" "the ledger no longer parses"
  assert_eq 10000 "$(printf '%s' "$CAPTURED_STDOUT" | field carried_bytes)"
}

receipt() {
  printf '{"transfer": "%s", "peer": "%s", "direction": "%s", "bytes": %s, "signature": "unsigned"}\n' "$@"
}

test_reconcile_sorts_transfers_into_agreed_discrepant_missing_and_unknown() {
  record sent 1000000 "$MID_OCTOBER" t-agreed
  record sent 1000000 "$MID_OCTOBER" t-in-flight
  record sent 1000000 "$MID_OCTOBER" t-inflated
  record sent 1000000 "$MID_OCTOBER" t-no-receipt
  {
    receipt t-agreed peer-a carried 1000000
    receipt t-in-flight peer-a carried 1050000
    receipt t-inflated peer-a carried 9000000
    receipt t-made-up peer-a carried 5000000
  } > "$TEST_TMP/receipts.jsonl"
  capture ledger reconcile --receipts "$TEST_TMP/receipts.jsonl" --now "$MID_OCTOBER"
  assert_eq 0 "$CAPTURED_STATUS" "$CAPTURED_STDERR"
  local statuses
  statuses="$(printf '%s' "$CAPTURED_STDOUT" | python3 -c 'import json, sys; print(" ".join("%s=%s" % (item["transfer"], item["status"]) for item in json.load(sys.stdin)["transfers"]))')"
  assert_eq "t-agreed=agreed t-in-flight=agreed t-inflated=discrepant t-made-up=unknown_to_us t-no-receipt=missing_receipt" "$statuses"
}

test_a_peer_receipt_never_changes_our_usage() {
  record sent 1000000 "$MID_OCTOBER" t1
  receipt t1 peer-a carried 4000000000 > "$TEST_TMP/receipts.jsonl"
  receipt t2 peer-a carried 4000000000 >> "$TEST_TMP/receipts.jsonl"
  ledger reconcile --receipts "$TEST_TMP/receipts.jsonl" --now "$MID_OCTOBER" > /dev/null
  capture ledger read --now "$MID_OCTOBER"
  assert_eq 1000000 "$(printf '%s' "$CAPTURED_STDOUT" | field used_bytes)"
  assert_eq 2 "$(printf '%s' "$CAPTURED_STDOUT" | python3 -c 'import json, sys; print(len(json.load(sys.stdin)["disagreements"]))')"
}

test_a_receipt_in_the_same_direction_is_discrepant() {
  record sent 1000 "$MID_OCTOBER" t1
  receipt t1 peer-a sent 1000 > "$TEST_TMP/receipts.jsonl"
  capture ledger reconcile --receipts "$TEST_TMP/receipts.jsonl" --now "$MID_OCTOBER"
  assert_contains "$CAPTURED_STDOUT" '"status": "discrepant"'
}

test_three_disagreements_mark_a_peer_to_stop_pairing_with() {
  local index
  for index in 1 2 3; do
    record carried 1000 "$MID_OCTOBER" "t$index"
    receipt "t$index" peer-a sent 900000 >> "$TEST_TMP/receipts.jsonl"
  done
  ledger reconcile --receipts "$TEST_TMP/receipts.jsonl" --now "$MID_OCTOBER" > /dev/null
  # running it again must not count the same disagreements twice.
  ledger reconcile --receipts "$TEST_TMP/receipts.jsonl" --now "$MID_OCTOBER" > /dev/null
  capture ledger read --now "$MID_OCTOBER"
  assert_eq '["peer-a"]' "$(printf '%s' "$CAPTURED_STDOUT" | field stop_pairing_with)"
  assert_eq 3 "$(printf '%s' "$CAPTURED_STDOUT" | python3 -c 'import json, sys; print(len(json.load(sys.stdin)["disagreements"]))')"
}

test_prune_keeps_this_month_and_the_previous_one() {
  record carried 1 "$(epoch "2026-08-31 23:59:59")" t-august
  record carried 1 "$(epoch "2026-09-01 00:00:00")" t-september
  record carried 1 "$MID_OCTOBER" t-october
  capture ledger prune --now "$MID_OCTOBER"
  assert_contains "$CAPTURED_STDOUT" "pruned 1 of 3 ledger lines older than September 2026"
  assert_not_contains "$(cat "$TEST_TMP/ledger.jsonl")" t-august
  assert_contains "$(cat "$TEST_TMP/ledger.jsonl")" t-september
}

test_plain_language_never_abbreviates_units_or_mentions_money() {
  record carried 1234567 "$MID_OCTOBER" t1
  check sent 6000000000 > "$TEST_TMP/check.json"
  ledger read --now "$MID_OCTOBER" > "$TEST_TMP/read.json"
  local text
  text="$(cat "$TEST_TMP/check.json" "$TEST_TMP/read.json")"
  if printf '%s' "$text" | grep -E -i -q '\b[0-9.]+ ?(GB|MB|KB)\b|\b(GB|MB|KB)\b'; then
    fail "an abbreviated unit reached plain language: $text"
  fi
  if printf '%s' "$text" | grep -E -i -q '\b(credit|balance|earn|pay|paid|price|dollars?)\b'; then
    fail "money language reached plain language: $text"
  fi
}
