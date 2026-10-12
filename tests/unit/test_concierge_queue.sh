# shellcheck shell=bash
# concierge queue: consent, claiming, the service-level clock, alerts, and the weekly report.
# the house style check for concierge-ops lives in test_language.sh, with the other style rules.

queue() {
  python3 "$REPO_DIR/concierge-ops/tools/concierge_queue.py" "$@"
}

ROSTER="$REPO_DIR/concierge-ops/tools/roster.example.json"

# a request from submit to booking: quoted at +12 seconds, accepted at +40, booked at +100.
booked_request() {
  local log="$1" request="$2" day="${3:-2026-10-12}"
  queue submit --log "$log" --request "$request" --consent disclosed --service waymo --at "${day}T14:00:00Z"
  queue claim --log "$log" --request "$request" --concierge concierge-1 --roster "$ROSTER" --at "${day}T14:00:03Z" > /dev/null
  queue quote --log "$log" --request "$request" --amount-cents 1840 --at "${day}T14:00:12Z"
  queue accept --log "$log" --request "$request" --at "${day}T14:00:40Z"
  queue book --log "$log" --request "$request" --at "${day}T14:01:40Z"
}

test_submit_without_consent_is_refused() {
  capture queue submit --log "$TEST_TMP/log" --request r1 --consent none --at 2026-10-12T14:00:00Z
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "has not consented"
  assert_no_file "$TEST_TMP/log"
}

test_claim_tells_the_user_who_the_concierge_is() {
  queue submit --log "$TEST_TMP/log" --request r1 --consent disclosed --at 2026-10-12T14:00:00Z
  capture queue claim --log "$TEST_TMP/log" --request r1 --concierge concierge-2 --roster "$ROSTER" --at 2026-10-12T14:00:02Z
  assert_eq 0 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDOUT" "the user is told: Example B., sirven concierge"
}

test_offboarded_concierge_cannot_claim() {
  queue submit --log "$TEST_TMP/log" --request r1 --consent disclosed --at 2026-10-12T14:00:00Z
  capture queue claim --log "$TEST_TMP/log" --request r1 --concierge concierge-3 --roster "$ROSTER" --at 2026-10-12T14:00:02Z
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "not active on the roster"
}

test_a_claimed_request_cannot_be_claimed_twice() {
  queue submit --log "$TEST_TMP/log" --request r1 --consent disclosed --at 2026-10-12T14:00:00Z
  queue claim --log "$TEST_TMP/log" --request r1 --concierge concierge-1 --roster "$ROSTER" --at 2026-10-12T14:00:02Z > /dev/null
  capture queue claim --log "$TEST_TMP/log" --request r1 --concierge concierge-2 --roster "$ROSTER" --at 2026-10-12T14:00:03Z
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "already claimed by concierge-1"
}

test_booking_needs_the_users_acceptance() {
  queue submit --log "$TEST_TMP/log" --request r1 --consent disclosed --at 2026-10-12T14:00:00Z
  queue claim --log "$TEST_TMP/log" --request r1 --concierge concierge-1 --roster "$ROSTER" --at 2026-10-12T14:00:02Z > /dev/null
  queue quote --log "$TEST_TMP/log" --request r1 --amount-cents 1840 --at 2026-10-12T14:00:10Z
  capture queue book --log "$TEST_TMP/log" --request r1 --at 2026-10-12T14:00:20Z
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "before the user accepts"
}

test_events_cannot_go_back_in_time() {
  queue submit --log "$TEST_TMP/log" --request r1 --consent disclosed --at 2026-10-12T14:00:10Z
  capture queue claim --log "$TEST_TMP/log" --request r1 --concierge concierge-1 --roster "$ROSTER" --at 2026-10-12T14:00:05Z
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "earlier than the last event"
}

test_the_log_holds_no_trip_content() {
  booked_request "$TEST_TMP/log" r1
  local keys
  keys="$(python3 -c 'import json,sys; print(" ".join(sorted({k for l in open(sys.argv[1]) for k in json.loads(l)})))' "$TEST_TMP/log")"
  assert_eq "amount_cents at concierge consent currency event request service" "$keys"
}

test_check_is_quiet_when_everything_is_on_time() {
  queue submit --log "$TEST_TMP/log" --request r1 --consent disclosed --at 2026-10-12T14:00:00Z
  capture queue check --log "$TEST_TMP/log" --at 2026-10-12T14:00:05Z
  assert_eq 0 "$CAPTURED_STATUS"
  assert_eq "" "$CAPTURED_STDOUT"
}

test_check_warns_on_an_unclaimed_request_before_it_breaches() {
  queue submit --log "$TEST_TMP/log" --request r1 --consent disclosed --at 2026-10-12T14:00:00Z
  capture queue check --log "$TEST_TMP/log" --at 2026-10-12T14:00:12Z
  assert_eq 2 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDOUT" "warning	unclaimed	r1"
}

test_check_reports_a_quote_breach() {
  queue submit --log "$TEST_TMP/log" --request r1 --consent disclosed --at 2026-10-12T14:00:00Z
  queue claim --log "$TEST_TMP/log" --request r1 --concierge concierge-1 --roster "$ROSTER" --at 2026-10-12T14:00:02Z > /dev/null
  capture queue check --log "$TEST_TMP/log" --at 2026-10-12T14:00:31Z
  assert_eq 2 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDOUT" "breach	quote	r1	31 seconds since submit, target 30"
}

test_check_reports_a_booking_breach_from_acceptance_not_submit() {
  queue submit --log "$TEST_TMP/log" --request r1 --consent disclosed --at 2026-10-12T14:00:00Z
  queue claim --log "$TEST_TMP/log" --request r1 --concierge concierge-1 --roster "$ROSTER" --at 2026-10-12T14:00:02Z > /dev/null
  queue quote --log "$TEST_TMP/log" --request r1 --amount-cents 1840 --at 2026-10-12T14:00:10Z
  queue accept --log "$TEST_TMP/log" --request r1 --at 2026-10-12T14:02:00Z
  capture queue check --log "$TEST_TMP/log" --at 2026-10-12T14:03:00Z
  assert_eq 0 "$CAPTURED_STATUS" "60 seconds after acceptance is inside the booking target"
  capture queue check --log "$TEST_TMP/log" --at 2026-10-12T14:03:31Z
  assert_eq 2 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDOUT" "breach	booking	r1	91 seconds since acceptance, target 90"
}

test_a_closed_request_raises_no_alert() {
  booked_request "$TEST_TMP/log" r1
  capture queue check --log "$TEST_TMP/log" --at 2026-10-12T15:00:00Z
  assert_eq 0 "$CAPTURED_STATUS"
}

test_handback_needs_a_known_reason() {
  queue submit --log "$TEST_TMP/log" --request r1 --consent disclosed --at 2026-10-12T14:00:00Z
  capture queue handback --log "$TEST_TMP/log" --request r1 --reason because --at 2026-10-12T14:00:05Z
  assert_eq 1 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDERR" "reason must be one of"
}

# the week the weekly report tests and the sample in concierge-ops/monitoring.md both use.
sample_week() {
  local log="$1"
  booked_request "$log" r1 2026-10-12
  booked_request "$log" r2 2026-10-13
  # r3: quoted late (45 seconds), then booked on time.
  queue submit --log "$log" --request r3 --consent disclosed --at 2026-10-14T09:00:00Z
  queue claim --log "$log" --request r3 --concierge concierge-2 --roster "$ROSTER" --at 2026-10-14T09:00:20Z > /dev/null
  queue quote --log "$log" --request r3 --amount-cents 2200 --at 2026-10-14T09:00:45Z
  queue accept --log "$log" --request r3 --at 2026-10-14T09:01:00Z
  queue book --log "$log" --request r3 --at 2026-10-14T09:01:50Z
  # r4: no car available, handed back honestly before the quote target.
  queue submit --log "$log" --request r4 --consent disclosed --at 2026-10-15T09:00:00Z
  queue handback --log "$log" --request r4 --reason unavailable --at 2026-10-15T09:00:20Z
  # r5: outside the week.
  booked_request "$log" r5 2026-10-20
}

test_weekly_report_counts_timings_and_breaches() {
  local log="$TEST_TMP/log"
  sample_week "$log"
  capture queue report --log "$log" --from 2026-10-12 --to 2026-10-18
  assert_eq 0 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDOUT" "## Concierge service levels, 2026-10-12 to 2026-10-18"
  assert_contains "$CAPTURED_STDOUT" "Requests: 4 submitted, 3 booked, 1 handed back, 0 still open."
  assert_contains "$CAPTURED_STDOUT" "Quote time (submit to quote): median 12 seconds, 90th percentile 45 seconds, 2 of 3 under the 30 second target."
  assert_contains "$CAPTURED_STDOUT" "Booking time (acceptance to confirmation): median 60 seconds, 90th percentile 60 seconds, 3 of 3 under the 90 second target."
  assert_contains "$CAPTURED_STDOUT" "Breaches: 1 quote, 0 booking."
  assert_contains "$CAPTURED_STDOUT" "Handback reasons: unavailable 1."
  assert_contains "$CAPTURED_STDOUT" "  - concierge-1: 2 worked, 2 booked."
  assert_contains "$CAPTURED_STDOUT" "  - concierge-2: 1 worked, 1 booked."
}

test_monitoring_sample_is_the_real_report() {
  local documented
  sample_week "$TEST_TMP/log"
  documented="$(sed -n '/^## Concierge service levels/,/concierge-2: 1 worked/p' "$REPO_DIR/concierge-ops/monitoring.md")"
  assert_eq "$documented" "$(queue report --log "$TEST_TMP/log" --from 2026-10-12 --to 2026-10-18)" "monitoring.md sample drifted from the tool"
}

# the ride connector contract's human-assisted path: software quoted, the user accepted, and a
# person only confirms the booking.
test_booking_stage_request_skips_the_quote_and_times_the_booking() {
  local log="$TEST_TMP/log"
  queue submit --log "$log" --request r1 --consent disclosed --stage booking --at 2026-10-12T14:00:00Z
  capture queue quote --log "$log" --request r1 --amount-cents 1840 --at 2026-10-12T14:00:05Z
  assert_eq 1 "$CAPTURED_STATUS" "a software-quoted request takes no human quote"
  capture queue book --log "$log" --request r1 --at 2026-10-12T14:00:05Z
  assert_eq 1 "$CAPTURED_STATUS" "nobody has claimed it yet"
  capture queue check --log "$log" --at 2026-10-12T14:00:40Z
  assert_contains "$CAPTURED_STDOUT" "warning	unclaimed	r1	40 seconds with no concierge"
  assert_not_contains "$CAPTURED_STDOUT" "quote"
  queue claim --log "$log" --request r1 --concierge concierge-1 --roster "$ROSTER" --at 2026-10-12T14:00:41Z > /dev/null
  capture queue check --log "$log" --at 2026-10-12T14:01:31Z
  assert_contains "$CAPTURED_STDOUT" "breach	booking	r1	91 seconds since acceptance, target 90"
  queue book --log "$log" --request r1 --at 2026-10-12T14:01:35Z
  capture queue report --log "$log" --from 2026-10-12 --to 2026-10-12
  assert_contains "$CAPTURED_STDOUT" "Quote time (submit to quote): none recorded."
  assert_contains "$CAPTURED_STDOUT" "median 95 seconds, 90th percentile 95 seconds, 0 of 1 under the 90 second target."
  assert_contains "$CAPTURED_STDOUT" "Breaches: 0 quote, 1 booking."
}
