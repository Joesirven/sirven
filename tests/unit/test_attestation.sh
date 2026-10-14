# shellcheck shell=bash
# attestation: the library tests under node --test, the command each role runs, and the
# two-process demo. every key is generated inside TEST_TMP and removed with it.

have_node() {
  command -v node >/dev/null 2>&1
}

attest() {
  node "$REPO_DIR/lib/attestation/cli.mjs" "$@"
}

# a fixed moment in the middle of a month, so no test straddles a cap period by accident.
fixed_clock() {
  SIRVEN_ATTESTATION_NOW=1792065600
  export SIRVEN_ATTESTATION_NOW
}

# setup_roles: an issuer, a certified originator for alice, and a peer that trusts the issuer
# and carries traffic to shop.example.com.
setup_roles() {
  umask 077
  fixed_clock
  attest issuer init --dir "$TEST_TMP/issuer" > /dev/null || fail "issuer init"
  attest user init --dir "$TEST_TMP/originator" --user alice > "$TEST_TMP/request.json" || fail "user init"
  attest issuer certify --dir "$TEST_TMP/issuer" --request "$TEST_TMP/request.json" > "$TEST_TMP/certificate.json" || fail "issuer certify"
  attest user install-certificate --dir "$TEST_TMP/originator" --certificate "$TEST_TMP/certificate.json" > /dev/null || fail "install certificate"
  attest issuer publish --dir "$TEST_TMP/issuer" > /dev/null || fail "issuer publish"
  printf 'shop.example.com\n' > "$TEST_TMP/allowlist"
  attest peer init --dir "$TEST_TMP/peer" --issuer-public-key "$TEST_TMP/issuer/issuer.pub" --allowlist "$TEST_TMP/allowlist" > /dev/null || fail "peer init"
  attest peer install-revocation-list --dir "$TEST_TMP/peer" --list "$TEST_TMP/issuer/revocation-list.json" > /dev/null || fail "install list"
}

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}

test_attestation_library() {
  have_node || return 0
  assert_status 0 node --test "$REPO_DIR/tests/attestation/attestation.test.mjs"
  assert_contains "$CAPTURED_STDOUT" "fail 0"
}

test_signing_keys_are_private_and_never_overwritten() {
  have_node || return 0
  setup_roles
  assert_eq 600 "$(file_mode "$TEST_TMP/originator/signing.key")" "user signing key mode"
  assert_eq 600 "$(file_mode "$TEST_TMP/issuer/issuer.key")" "issuer key mode"
  assert_eq 700 "$(file_mode "$TEST_TMP/originator")" "originator directory mode"
  assert_status 64 attest user init --dir "$TEST_TMP/originator" --user alice
  assert_contains "$CAPTURED_STDERR" "never overwritten"
}

test_certification_request_holds_no_private_key() {
  have_node || return 0
  setup_roles
  assert_not_contains "$(cat "$TEST_TMP/request.json")" "PRIVATE KEY"
  assert_not_contains "$(cat "$TEST_TMP/certificate.json")" "PRIVATE KEY"
}

test_a_signing_key_readable_by_others_is_refused() {
  have_node || return 0
  setup_roles
  chmod 644 "$TEST_TMP/originator/signing.key"
  assert_status 1 attest sign --dir "$TEST_TMP/originator" --audience "$(cat "$TEST_TMP/peer/peer-identifier")" --domain shop.example.com --bytes 10
  assert_contains "$CAPTURED_STDERR" "readable by others"
}

test_peer_accepts_then_refuses_a_replay() {
  have_node || return 0
  setup_roles
  attest sign --dir "$TEST_TMP/originator" --audience "$(cat "$TEST_TMP/peer/peer-identifier")" --domain shop.example.com --bytes 100 > "$TEST_TMP/envelope.json"
  assert_status 0 attest peer verify --dir "$TEST_TMP/peer" --host shop.example.com --bytes 100 --envelope "$TEST_TMP/envelope.json"
  assert_contains "$CAPTURED_STDOUT" '"accepted": true'
  assert_status 3 attest peer verify --dir "$TEST_TMP/peer" --host shop.example.com --bytes 100 --envelope "$TEST_TMP/envelope.json"
  assert_contains "$CAPTURED_STDOUT" '"reason": "replayed"'
}

test_peer_verify_removes_an_unreadable_lock_left_behind() {
  have_node || return 0
  setup_roles
  attest sign --dir "$TEST_TMP/originator" --audience "$(cat "$TEST_TMP/peer/peer-identifier")" --domain shop.example.com --bytes 100 > "$TEST_TMP/envelope.json"
  : > "$TEST_TMP/peer/verify.lock"
  touch -t 200001010000 "$TEST_TMP/peer/verify.lock"
  assert_status 0 attest peer verify --dir "$TEST_TMP/peer" --host shop.example.com --bytes 100 --envelope "$TEST_TMP/envelope.json"
  assert_no_file "$TEST_TMP/peer/verify.lock"
}

# a lock owner record: the holder's process number, host name, and token, as the verify lock writes it.
write_lock_record() {
  printf '{"pid": %s, "host": "%s", "token": "%s"}\n' "$1" "$2" "$3" > "$TEST_TMP/peer/verify.lock"
}

this_host() {
  node -e 'process.stdout.write(require("os").hostname())'
}

# a process number that belongs to no running process: a child that has already exited.
gone_pid() {
  sh -c 'exit 0' &
  wait "$!"
  printf '%s' "$!"
}

test_peer_verify_refuses_a_lock_held_by_a_live_process() {
  have_node || return 0
  setup_roles
  attest sign --dir "$TEST_TMP/originator" --audience "$(cat "$TEST_TMP/peer/peer-identifier")" --domain shop.example.com --bytes 100 > "$TEST_TMP/envelope.json"
  write_lock_record "$$" "$(this_host)" live-holder
  export SIRVEN_ATTESTATION_TEST_LOCK_WAIT_MS=300
  assert_status 3 attest peer verify --dir "$TEST_TMP/peer" --host shop.example.com --bytes 100 --envelope "$TEST_TMP/envelope.json"
  assert_contains "$CAPTURED_STDOUT" '"reason": "lock_unavailable"'
  assert_contains "$(cat "$TEST_TMP/peer/verify.lock")" live-holder
}

test_peer_verify_clears_the_lock_of_a_process_that_is_gone() {
  have_node || return 0
  setup_roles
  attest sign --dir "$TEST_TMP/originator" --audience "$(cat "$TEST_TMP/peer/peer-identifier")" --domain shop.example.com --bytes 100 > "$TEST_TMP/envelope.json"
  write_lock_record "$(gone_pid)" "$(this_host)" dead-holder
  assert_status 0 attest peer verify --dir "$TEST_TMP/peer" --host shop.example.com --bytes 100 --envelope "$TEST_TMP/envelope.json"
  assert_no_file "$TEST_TMP/peer/verify.lock"
}

test_peer_verify_refuses_a_lock_held_on_another_host() {
  have_node || return 0
  setup_roles
  attest sign --dir "$TEST_TMP/originator" --audience "$(cat "$TEST_TMP/peer/peer-identifier")" --domain shop.example.com --bytes 100 > "$TEST_TMP/envelope.json"
  write_lock_record "$(gone_pid)" "elsewhere.invalid" other-host
  export SIRVEN_ATTESTATION_TEST_LOCK_WAIT_MS=300
  assert_status 3 attest peer verify --dir "$TEST_TMP/peer" --host shop.example.com --bytes 100 --envelope "$TEST_TMP/envelope.json"
  assert_contains "$CAPTURED_STDOUT" '"reason": "lock_unavailable"'
  assert_contains "$(cat "$TEST_TMP/peer/verify.lock")" other-host
}

test_a_write_failing_after_the_nonce_is_remembered_refuses_the_replay() {
  have_node || return 0
  setup_roles
  attest sign --dir "$TEST_TMP/originator" --audience "$(cat "$TEST_TMP/peer/peer-identifier")" --domain shop.example.com --bytes 100 > "$TEST_TMP/envelope.json"
  # the carried folder cannot be made, so the verify fails after it has written the nonce memory.
  rm -rf "$TEST_TMP/peer/carried"
  printf 'not a folder\n' > "$TEST_TMP/peer/carried"
  assert_status 1 attest peer verify --dir "$TEST_TMP/peer" --host shop.example.com --bytes 100 --envelope "$TEST_TMP/envelope.json"
  rm -f "$TEST_TMP/peer/carried"
  assert_status 3 attest peer verify --dir "$TEST_TMP/peer" --host shop.example.com --bytes 100 --envelope "$TEST_TMP/envelope.json"
  assert_contains "$CAPTURED_STDOUT" '"reason": "replayed"'
}

test_peer_refuses_unsigned_wrong_domain_expired_and_tampered() {
  have_node || return 0
  setup_roles
  attest sign --dir "$TEST_TMP/originator" --audience "$(cat "$TEST_TMP/peer/peer-identifier")" --domain shop.example.com --bytes 100 --lifetime 60 > "$TEST_TMP/envelope.json"

  sed '/"signature"/d; s/"payload": \("[^"]*"\),/"payload": \1/' "$TEST_TMP/envelope.json" > "$TEST_TMP/unsigned.json"
  assert_status 3 attest peer verify --dir "$TEST_TMP/peer" --host shop.example.com --bytes 100 --envelope "$TEST_TMP/unsigned.json"
  assert_contains "$CAPTURED_STDOUT" '"reason": "unsigned"'

  assert_status 3 attest peer verify --dir "$TEST_TMP/peer" --host bank.example.com --bytes 100 --envelope "$TEST_TMP/envelope.json"
  assert_contains "$CAPTURED_STDOUT" '"reason": "wrong-domain"'

  SIRVEN_ATTESTATION_NOW=$((SIRVEN_ATTESTATION_NOW + 61)) assert_status 3 attest peer verify --dir "$TEST_TMP/peer" --host shop.example.com --bytes 100 --envelope "$TEST_TMP/envelope.json"
  assert_contains "$CAPTURED_STDOUT" '"reason": "expired"'

  # flip one character in the middle of the payload.
  node -e '
    const fs = require("fs");
    const envelope = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const middle = Math.floor(envelope.payload.length / 2);
    const swap = envelope.payload[middle] === "A" ? "B" : "A";
    envelope.payload = envelope.payload.slice(0, middle) + swap + envelope.payload.slice(middle + 1);
    fs.writeFileSync(process.argv[2], JSON.stringify(envelope));
  ' "$TEST_TMP/envelope.json" "$TEST_TMP/tampered.json"
  assert_status 3 attest peer verify --dir "$TEST_TMP/peer" --host shop.example.com --bytes 100 --envelope "$TEST_TMP/tampered.json"
  assert_contains "$CAPTURED_STDOUT" '"accepted": false'
  assert_not_contains "$CAPTURED_STDOUT" '"reason": "replayed"'
}

test_an_envelope_is_good_at_its_own_peer_only() {
  have_node || return 0
  setup_roles
  attest peer init --dir "$TEST_TMP/other-peer" --issuer-public-key "$TEST_TMP/issuer/issuer.pub" --allowlist "$TEST_TMP/allowlist" > /dev/null
  attest peer install-revocation-list --dir "$TEST_TMP/other-peer" --list "$TEST_TMP/issuer/revocation-list.json" > /dev/null
  attest sign --dir "$TEST_TMP/originator" --audience "$(cat "$TEST_TMP/peer/peer-identifier")" --domain shop.example.com --bytes 100 > "$TEST_TMP/envelope.json"
  assert_status 3 attest peer verify --dir "$TEST_TMP/other-peer" --host shop.example.com --bytes 100 --envelope "$TEST_TMP/envelope.json"
  assert_contains "$CAPTURED_STDOUT" '"reason": "wrong-audience"'
  assert_status 0 attest peer verify --dir "$TEST_TMP/peer" --host shop.example.com --bytes 100 --envelope "$TEST_TMP/envelope.json"
}

test_issuer_needs_proof_the_requester_holds_the_key() {
  have_node || return 0
  setup_roles
  # bob asks for a certificate on alice's public key, with a request he could not sign.
  node -e '
    const fs = require("fs");
    const request = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const payload = JSON.parse(Buffer.from(request.payload, "base64url").toString("utf8"));
    payload.user = "bob";
    request.payload = Buffer.from(JSON.stringify(payload)).toString("base64url");
    fs.writeFileSync(process.argv[2], JSON.stringify(request));
  ' "$TEST_TMP/request.json" "$TEST_TMP/forged-request.json"
  assert_status 3 attest issuer certify --dir "$TEST_TMP/issuer" --request "$TEST_TMP/forged-request.json"
  assert_contains "$CAPTURED_STDERR" "bad-signature"
}

test_issuer_never_certifies_one_key_for_two_users() {
  have_node || return 0
  setup_roles
  # alice's own device signs a request for a second handle; the issuer still refuses.
  node --input-type=module -e "
    import { readFileSync, writeFileSync } from 'node:fs';
    const { makeCertificationRequest, privateKeyFromPem } = await import('$REPO_DIR/lib/attestation/attestation.mjs');
    const key = privateKeyFromPem(readFileSync('$TEST_TMP/originator/signing.key', 'utf8'));
    writeFileSync('$TEST_TMP/second-request.json', JSON.stringify(makeCertificationRequest({ userPrivateKey: key, user: 'alice2', now: 1792065600 })));
  " || fail "could not make the second request"
  assert_status 1 attest issuer certify --dir "$TEST_TMP/issuer" --request "$TEST_TMP/second-request.json"
  assert_contains "$CAPTURED_STDERR" "already certified for another user"
}

test_revocation_reaches_the_peer() {
  have_node || return 0
  setup_roles
  attest issuer revoke --dir "$TEST_TMP/issuer" --user alice --reason test > /dev/null
  attest issuer publish --dir "$TEST_TMP/issuer" > /dev/null
  attest peer install-revocation-list --dir "$TEST_TMP/peer" --list "$TEST_TMP/issuer/revocation-list.json" > /dev/null
  attest sign --dir "$TEST_TMP/originator" --audience "$(cat "$TEST_TMP/peer/peer-identifier")" --domain shop.example.com --bytes 100 > "$TEST_TMP/envelope.json"
  assert_status 3 attest peer verify --dir "$TEST_TMP/peer" --host shop.example.com --bytes 100 --envelope "$TEST_TMP/envelope.json"
  assert_contains "$CAPTURED_STDOUT" '"reason": "revoked"'
}

test_peer_refuses_an_older_revocation_list() {
  have_node || return 0
  setup_roles
  cp "$TEST_TMP/issuer/revocation-list.json" "$TEST_TMP/old-list.json"
  attest issuer publish --dir "$TEST_TMP/issuer" > /dev/null
  attest peer install-revocation-list --dir "$TEST_TMP/peer" --list "$TEST_TMP/issuer/revocation-list.json" > /dev/null
  assert_status 3 attest peer install-revocation-list --dir "$TEST_TMP/peer" --list "$TEST_TMP/old-list.json"
  assert_contains "$CAPTURED_STDERR" "revocation-list-rollback"
}

test_peer_without_a_revocation_list_refuses() {
  have_node || return 0
  setup_roles
  rm "$TEST_TMP/peer/revocation-list.json"
  attest sign --dir "$TEST_TMP/originator" --audience "$(cat "$TEST_TMP/peer/peer-identifier")" --domain shop.example.com --bytes 100 > "$TEST_TMP/envelope.json"
  assert_status 3 attest peer verify --dir "$TEST_TMP/peer" --host shop.example.com --bytes 100 --envelope "$TEST_TMP/envelope.json"
  assert_contains "$CAPTURED_STDOUT" '"reason": "revocation-list-missing"'
}

test_peer_ledger_holds_the_cap() {
  have_node || return 0
  umask 077
  setup_roles
  rm -rf "$TEST_TMP/peer"
  attest peer init --dir "$TEST_TMP/peer" --issuer-public-key "$TEST_TMP/issuer/issuer.pub" --allowlist "$TEST_TMP/allowlist" --cap-bytes 150 > /dev/null
  attest peer install-revocation-list --dir "$TEST_TMP/peer" --list "$TEST_TMP/issuer/revocation-list.json" > /dev/null
  attest sign --dir "$TEST_TMP/originator" --audience "$(cat "$TEST_TMP/peer/peer-identifier")" --domain shop.example.com --bytes 100 > "$TEST_TMP/first.json"
  attest sign --dir "$TEST_TMP/originator" --audience "$(cat "$TEST_TMP/peer/peer-identifier")" --domain shop.example.com --bytes 100 > "$TEST_TMP/second.json"
  assert_status 0 attest peer verify --dir "$TEST_TMP/peer" --host shop.example.com --bytes 100 --envelope "$TEST_TMP/first.json"
  assert_status 3 attest peer verify --dir "$TEST_TMP/peer" --host shop.example.com --bytes 100 --envelope "$TEST_TMP/second.json"
  assert_contains "$CAPTURED_STDOUT" '"reason": "over-cap"'
}

test_every_verification_is_audited_and_traceable() {
  have_node || return 0
  setup_roles
  attest sign --dir "$TEST_TMP/originator" --audience "$(cat "$TEST_TMP/peer/peer-identifier")" --domain shop.example.com --bytes 100 > "$TEST_TMP/envelope.json"
  attest peer verify --dir "$TEST_TMP/peer" --host shop.example.com --bytes 100 --envelope "$TEST_TMP/envelope.json" > /dev/null
  attest peer verify --dir "$TEST_TMP/peer" --host bank.example.com --bytes 100 --envelope "$TEST_TMP/envelope.json" > /dev/null || true
  assert_eq 2 "$(grep -c '"event":"attestation_verify"' "$TEST_TMP/peer/audit.jsonl")" "audit entries"
  assert_contains "$(cat "$TEST_TMP/peer/audit.jsonl")" '"outcome":"accepted","user":"alice"'
  assert_contains "$(cat "$TEST_TMP/peer/audit.jsonl")" '"outcome":"refused","reason":"wrong-domain"'
  assert_eq 1 "$(find "$TEST_TMP/peer/carried" -type f | grep -c .)" "carried envelopes kept"
  assert_status 0 attest trace --dir "$TEST_TMP/peer" --envelope "$(find "$TEST_TMP/peer/carried" -type f)"
  assert_contains "$CAPTURED_STDOUT" '"user": "alice"'
}

test_usage_errors() {
  have_node || return 0
  assert_status 64 attest
  assert_status 64 attest sign --dir "$TEST_TMP/nowhere"
  assert_contains "$CAPTURED_STDERR" "--domain is required"
  assert_status 64 attest peer verify --unknown x
}

test_two_process_demo() {
  have_node || return 0
  assert_status 0 bash "$REPO_DIR/lib/attestation/demo.sh"
  assert_contains "$CAPTURED_STDOUT" "demo: every step came out as expected"
  assert_not_contains "$CAPTURED_STDOUT" "FAIL"
}
