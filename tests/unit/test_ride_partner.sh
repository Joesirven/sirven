# shellcheck shell=bash
# the official-partner ride backend in connectors/ride: Uber for Business and Lyft Business
# behind the contract gateway, against recorded carrier fixtures. connectors/ride/tests/
# test_language.py holds its files to the house language rules.

test_ride_partner_backend() {
  cd "$REPO_DIR/connectors/ride/tests" || fail "connectors/ride/tests is missing"
  capture env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -q test_partner_backend
  if [ "$CAPTURED_STATUS" -ne 0 ]; then
    fail "python tests failed:
$CAPTURED_STDOUT
$CAPTURED_STDERR"
  fi
}
