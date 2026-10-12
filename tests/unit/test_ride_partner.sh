# shellcheck shell=bash
# the official-partner ride backend in connectors/ride: its python unit tests against the
# recorded fixtures, and the house language rules on its files.

test_ride_partner_backend_unit_tests() {
  capture python3 -m unittest discover -s "$REPO_DIR/connectors/ride/tests" -t "$REPO_DIR/connectors/ride/tests"
  assert_eq 0 "$CAPTURED_STATUS" "ride partner unit tests failed: $CAPTURED_STDERR"
}

test_ride_partner_files_follow_the_language_rules() {
  local em en pattern hits
  em="$(printf '\342\200\224')"
  en="$(printf '\342\200\223')"
  pattern='\b(ACLs?|OS|CLI|UID|GID|PID|TODO|FIXME|IP|DNS|UTC|ISO|PIN|OTP|VM|VPN|TCP|UDP|EOF|TTY|CPU|YAML|CI|UI|IDs?|OK|ETA|MCP|PA|PR|KB)\b|\be\.g\.|\bi\.e\.'
  hits="$(cd "$REPO_DIR" && find connectors/ride -type f -not -path '*/__pycache__/*' | sort | while IFS= read -r file; do
    grep -n -e "$em" -e "$en" "$file" | sed "s|^|$file:|"
    grep -n -E "$pattern" "$file" | sed "s|^|$file:|"
  done)"
  assert_eq "" "$hits" "em dashes, en dashes, or acronyms in connectors/ride"
}
