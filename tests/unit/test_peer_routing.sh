# shellcheck shell=bash
# peer routing, end to end: the attestation layer, the site-allowlist review workflow, the
# policy engine, and the reciprocity ledger through lib/peer_routing.py. the python suite is in
# tests/peer_routing. it needs node for the attestation layer; without node it fails rather than
# skipping, because a skipped run here would read as a passing ship gate.

test_peer_routing_end_to_end() {
  command -v python3 >/dev/null 2>&1 || return 0
  assert_status 0 command -v node
  capture python3 -m unittest discover -s "$REPO_DIR/tests/peer_routing"
  assert_eq 0 "$CAPTURED_STATUS" "peer routing end-to-end tests failed:
$CAPTURED_STDERR"
  assert_not_contains "$CAPTURED_STDERR" "skipped"
}

test_peer_routing_readiness_on_a_fresh_node() {
  command -v python3 >/dev/null 2>&1 || return 0
  capture python3 "$REPO_DIR/lib/peer_routing.py" readiness --state "$TEST_TMP"
  assert_eq 0 "$CAPTURED_STATUS" "$CAPTURED_STDERR"
  assert_contains "$CAPTURED_STDOUT" '"peer_routing_available": false'
  assert_contains "$CAPTURED_STDOUT" '"attestation": "no_peer_identity"'
}
