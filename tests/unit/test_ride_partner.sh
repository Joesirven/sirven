# shellcheck shell=bash
# the official-partner ride backend in connectors/ride: its python unit tests against the
# recorded fixtures. test_language.sh holds its files to the house language rules.

test_ride_partner_backend_unit_tests() {
  capture python3 -m unittest discover -s "$REPO_DIR/connectors/ride/tests" -t "$REPO_DIR/connectors/ride/tests"
  assert_eq 0 "$CAPTURED_STATUS" "ride partner unit tests failed: $CAPTURED_STDERR"
}

