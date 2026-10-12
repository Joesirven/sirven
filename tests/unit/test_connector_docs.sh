# shellcheck shell=bash
# the agent-facing ride connector guide: its client harness must pass every scenario against
# the fake backends. the connector itself lives in connectors/ride; until it is in this
# checkout, the harness has nothing to run against and this test says so and passes.

test_connector_harness_scenarios_pass() {
  if [ ! -d "$REPO_DIR/connectors/ride/ride_connector" ]; then
    echo "skipped: connectors/ride is not in this checkout yet"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "skipped: python3 is not installed"
    return 0
  fi
  local output status
  output="$(python3 "$REPO_DIR/docs/connector/examples/harness.py" 2>&1)"
  status=$?
  assert_eq 0 "$status" "harness exit status; output follows
$output"
  assert_contains "$output" "harness: every check passed"
}
