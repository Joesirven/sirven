# shellcheck shell=bash
# the ride-to-the-barber rehearsal in demo/ride-to-the-barber: its own unit and end to end
# tests, run with the python standard library and nothing else.

test_ride_demo() {
  assert_status 0 python3 -B -m unittest discover -s "$REPO_DIR/demo/ride-to-the-barber/tests"
}
