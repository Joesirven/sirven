#!/usr/bin/env bash
# the local attestation demo: an originator signs, a separate peer process verifies, and the
# peer refuses a tampered envelope, a replay, and a revoked user. nothing touches the network:
# the processes share files in a scratch directory, the way a peer would receive an envelope
# alongside the request it is asked to carry.
#
#   bash lib/attestation/demo.sh            run it in a fresh scratch directory, then remove it
#   bash lib/attestation/demo.sh --keep     keep the scratch directory and print where it is
#
# exit status 0 means every step came out the way the trust model says it must.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATTEST_COMMAND="$HERE/cli.mjs"
KEEP=no
[ "${1:-}" = "--keep" ] && KEEP=yes

if ! command -v node >/dev/null 2>&1; then
  echo "error: the attestation demo needs node 18 or newer" >&2
  exit 1
fi

umask 077
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sirven-attestation-demo.XXXXXX")"
if [ "$KEEP" = no ]; then
  trap 'rm -rf "$WORK"' EXIT
fi
ISSUER="$WORK/issuer"
ORIGINATOR="$WORK/originator"
PEER="$WORK/peer"
failures=0

attest() {
  node "$ATTEST_COMMAND" "$@"
}

say() {
  printf '\n== %s\n' "$*"
}

# expect WANT OUTCOME_FILE: WANT is accepted or a refusal reason.
expect() {
  local want="$1" file="$2" got
  got="$(node -e '
    const verdict = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    process.stdout.write(verdict.accepted ? "accepted" : verdict.reason);
  ' "$file")"
  if [ "$got" = "$want" ]; then
    printf 'pass: %s\n' "$got"
  else
    printf 'FAIL: wanted %s, got %s\n' "$want" "$got"
    failures=$((failures + 1))
  fi
}

# peer_verify HOST BYTES ENVELOPE OUTPUT: the peer, as its own process.
peer_verify() {
  attest peer verify --dir "$PEER" --host "$1" --bytes "$2" --envelope "$3" > "$4" || true
  cat "$4"
}

say "identity issuer: create the issuer key"
attest issuer init --dir "$ISSUER"

say "originator: generate the user's signing key on the user's own device"
attest user init --dir "$ORIGINATOR" --user alice > "$WORK/request.json"
cat "$WORK/request.json"

say "identity issuer: certify the public key (only the public key leaves the device)"
attest issuer certify --dir "$ISSUER" --request "$WORK/request.json" > "$WORK/certificate.json"
attest user install-certificate --dir "$ORIGINATOR" --certificate "$WORK/certificate.json"

say "identity issuer: publish the revocation list (empty)"
attest issuer publish --dir "$ISSUER" > /dev/null

say "peer: trust the issuer, set the allowlist, install the revocation list"
printf 'shop.example.com\n' > "$WORK/allowlist"
attest peer init --dir "$PEER" --issuer-public-key "$ISSUER/issuer.pub" --allowlist "$WORK/allowlist"
attest peer install-revocation-list --dir "$PEER" --list "$ISSUER/revocation-list.json"

say "originator: sign a 2048 byte request to shop.example.com"
attest sign --dir "$ORIGINATOR" --domain shop.example.com --bytes 2048 > "$WORK/envelope.json"

say "peer: verify the signed envelope"
peer_verify shop.example.com 2048 "$WORK/envelope.json" "$WORK/verdict-good.json"
expect accepted "$WORK/verdict-good.json"

say "attacker: change the domain inside the signed payload, keep the signature"
node -e '
  const fs = require("fs");
  const envelope = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const payload = JSON.parse(Buffer.from(envelope.payload, "base64url").toString("utf8"));
  payload.domain = "bank.example.com";
  envelope.payload = Buffer.from(JSON.stringify(payload)).toString("base64url");
  fs.writeFileSync(process.argv[2], JSON.stringify(envelope));
' "$WORK/envelope.json" "$WORK/envelope-tampered.json"
peer_verify bank.example.com 2048 "$WORK/envelope-tampered.json" "$WORK/verdict-tampered.json"
expect bad-signature "$WORK/verdict-tampered.json"

say "attacker: replay the envelope the peer already accepted"
peer_verify shop.example.com 2048 "$WORK/envelope.json" "$WORK/verdict-replay.json"
expect replayed "$WORK/verdict-replay.json"

say "abuse report: trace the carried envelope back to its user"
attest trace --dir "$PEER" --envelope "$WORK/envelope.json" > "$WORK/trace.json"
cat "$WORK/trace.json"
if grep -q '"user": "alice"' "$WORK/trace.json"; then
  printf 'pass: traced to alice\n'
else
  printf 'FAIL: trace did not name alice\n'
  failures=$((failures + 1))
fi

say "identity issuer: revoke alice and publish a new list; the peer installs it"
attest issuer revoke --dir "$ISSUER" --user alice --reason "demo: abuse report upheld" > /dev/null
attest issuer publish --dir "$ISSUER" > /dev/null
attest peer install-revocation-list --dir "$PEER" --list "$ISSUER/revocation-list.json"

say "originator: sign a fresh request; the peer must refuse it"
attest sign --dir "$ORIGINATOR" --domain shop.example.com --bytes 1024 > "$WORK/envelope-after.json"
peer_verify shop.example.com 1024 "$WORK/envelope-after.json" "$WORK/verdict-revoked.json"
expect revoked "$WORK/verdict-revoked.json"

say "peer audit log"
cat "$PEER/audit.jsonl"

if [ "$KEEP" = yes ]; then
  printf '\nscratch directory kept at %s\n' "$WORK"
fi
if [ "$failures" -gt 0 ]; then
  printf '\ndemo: %s step(s) did not come out as expected\n' "$failures"
  exit 1
fi
printf '\ndemo: every step came out as expected\n'
