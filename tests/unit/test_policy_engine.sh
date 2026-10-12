# shellcheck shell=bash
# allowlist policy engine: the decision table in tests/policy, then the command line the
# runtime and other programs call: refresh, classify, gate-status, and the decision log.

engine() {
  python3 "$REPO_DIR/lib/policy_engine.py" "$@"
}

NOW=1800000000

# a published registry the verify command passes through unchanged.
write_registry() {
  cat > "$TEST_TMP/published.json" <<END
{"schema_version": 1, "status": "published", "serial": 9, "reviewer": "Jose Sirven",
 "published_at": $((NOW - 60)), "expires_at": $((NOW + 3600)),
 "entries": [{"domain": "public.example.org", "tiers": ["Neighborly", "Co-op"]}]}
END
}

# an envelope in the lib/attestation shape with an unchecked signature: the engine's own checks
# are structural. real signatures run through the engine in tests/peer_routing.
structural_envelope() {
  python3 -c 'import base64, json, sys
payload = {"version": 1, "type": "request", "posture": "identity", "domain": "public.example.org",
           "request_digest": sys.argv[1], "issued_at": int(sys.argv[2]) - 1, "expires_at": int(sys.argv[2]) + 60}
encoded = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
print(json.dumps({"sirven_attestation": 1, "type": "request", "payload": encoded, "signature": "s"}))' "$1" "$NOW"
}

refresh_from_file() {
  engine refresh --registry-state "$TEST_TMP/state.json" --now "$NOW" \
    --fetch-command "cat '$TEST_TMP/published.json'" --verify-command cat
}

test_decision_table() {
  capture python3 -m unittest discover -s "$REPO_DIR/tests/policy"
  assert_eq 0 "$CAPTURED_STATUS" "decision table tests failed:
$CAPTURED_STDERR"
}

test_a_fresh_install_refuses_peer_traffic_and_allows_own() {
  capture engine classify --registry-state "$TEST_TMP/missing.json" --now "$NOW" <<END
{"domain": "public.example.org", "tier": "Neighborly", "direction": "peer"}
END
  assert_contains "$CAPTURED_STDOUT" '"code": "registry_unavailable"'
  capture engine classify --registry-state "$TEST_TMP/missing.json" --now "$NOW" <<END
{"domain": "anything.example.com", "tier": "Solo", "direction": "own"}
END
  assert_contains "$CAPTURED_STDOUT" '"action": "allow_local"'
}

test_refresh_writes_a_current_state() {
  write_registry
  capture refresh_from_file
  assert_eq 0 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDOUT" '"status": "current"'
  assert_contains "$(cat "$TEST_TMP/state.json")" '"serial": 9'
}

test_refresh_while_offline_drops_the_old_snapshot() {
  write_registry
  refresh_from_file > /dev/null
  capture engine refresh --registry-state "$TEST_TMP/state.json" --now "$NOW" \
    --fetch-command "exit 7" --verify-command cat
  assert_eq 0 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDOUT" '"status": "unavailable"'
  assert_not_contains "$(cat "$TEST_TMP/state.json")" "public.example.org"
  capture engine classify --registry-state "$TEST_TMP/state.json" --now "$NOW" <<END
{"domain": "public.example.org", "tier": "Co-op", "direction": "peer"}
END
  assert_contains "$CAPTURED_STDOUT" '"code": "registry_unavailable"'
  capture engine classify --registry-state "$TEST_TMP/state.json" --now "$NOW" <<END
{"domain": "public.example.org", "tier": "Co-op", "direction": "own"}
END
  assert_contains "$CAPTURED_STDOUT" '"action": "allow_local"'
}

test_classify_calls_the_attestation_verifier_and_logs() {
  local digest
  write_registry
  refresh_from_file > /dev/null
  digest="$(printf 'request' | shasum -a 256 | cut -d ' ' -f 1)"
  cat > "$TEST_TMP/verifier.sh" <<END
#!/bin/sh
cat > /dev/null
printf '%s\n' '{"state": "valid", "posture": "identity", "domain": "public.example.org", "request_digest": "$digest", "key_id": "k", "nonce": "n", "maximum_bytes": 2048}'
END
  chmod +x "$TEST_TMP/verifier.sh"
  capture engine classify --registry-state "$TEST_TMP/state.json" --now "$NOW" \
    --log "$TEST_TMP/decisions.jsonl" --attestation-verifier "$TEST_TMP/verifier.sh" <<END
{"domain": "public.example.org", "tier": "Neighborly", "direction": "peer", "request_digest": "$digest",
 "envelope": $(structural_envelope "$digest")}
END
  assert_eq 0 "$CAPTURED_STATUS" "$CAPTURED_STDERR"
  assert_contains "$CAPTURED_STDOUT" '"action": "allow_peer_carrier"'
  assert_contains "$(cat "$TEST_TMP/decisions.jsonl")" '"maximum_bytes": 2048'
}

test_a_verifier_error_code_becomes_a_plain_refusal() {
  local digest
  write_registry
  refresh_from_file > /dev/null
  digest="$(printf 'request' | shasum -a 256 | cut -d ' ' -f 1)"
  capture engine classify --registry-state "$TEST_TMP/state.json" --now "$NOW" \
    --attestation-verifier "cat > /dev/null; echo '{\"error\": \"over-cap\"}'" <<END
{"domain": "public.example.org", "tier": "Neighborly", "direction": "peer", "request_digest": "$digest",
 "envelope": $(structural_envelope "$digest")}
END
  assert_contains "$CAPTURED_STDOUT" '"code": "attestation_over_cap"'
  assert_contains "$CAPTURED_STDOUT" "5 gigabyte monthly sharing limit"
}

test_an_unwritable_log_exits_1_so_nothing_dispatches() {
  mkdir "$TEST_TMP/decisions.jsonl"
  assert_status 1 engine classify --registry-state "$TEST_TMP/missing.json" --now "$NOW" \
    --log "$TEST_TMP/decisions.jsonl" <<END
{"domain": "public.example.org", "tier": "Solo", "direction": "own"}
END
  assert_contains "$CAPTURED_STDERR" "refuse to dispatch"
}

test_unreadable_request_is_refused_not_crashed() {
  capture engine classify --registry-state "$TEST_TMP/missing.json" --now "$NOW" <<END
{"domain": "public.example.org", "tier": "Neighborly", "direction": "peer", "trusted": true}
END
  assert_eq 0 "$CAPTURED_STATUS"
  assert_contains "$CAPTURED_STDOUT" '"code": "invalid_request"'
}

test_gate_status_starts_closed() {
  capture engine gate-status --registry-state "$TEST_TMP/missing.json" --now "$NOW"
  assert_contains "$CAPTURED_STDOUT" '"ship_gate": "closed"'
  assert_contains "$CAPTURED_STDOUT" '"authenticated_peer_traffic_possible": false'
}
