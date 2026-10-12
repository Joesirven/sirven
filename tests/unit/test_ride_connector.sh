# shellcheck shell=bash
# the ride connector contract: its schema, quote, book, and cancel round trips against the fake
# backends, backend blindness, and the model context protocol server. the python tests live in
# connectors/ride/tests and need only the python standard library.

ride_tests() {
  capture env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -q "$@"
  if [ "$CAPTURED_STATUS" -ne 0 ]; then
    fail "python tests failed:
$CAPTURED_STDOUT
$CAPTURED_STDERR"
  fi
}

ride_dir() {
  cd "$REPO_DIR/connectors/ride/tests" || fail "connectors/ride/tests is missing"
}

test_ride_connector_schema() {
  ride_dir
  ride_tests test_schema
}

test_ride_connector_round_trips() {
  ride_dir
  ride_tests test_round_trips
}

test_ride_connector_backend_blindness() {
  ride_dir
  ride_tests test_backend_blindness
}

test_ride_connector_server() {
  ride_dir
  ride_tests test_server
}

test_ride_connector_language() {
  ride_dir
  ride_tests test_language
}
