# Attestation

Status: built and tested for Jose's review, 2026-10-11. Code in `lib/attestation/`, tests in
`tests/attestation/` and `tests/unit/test_attestation.sh`.

Every request one sirven device carries for another sirven user travels with a signed envelope.
The envelope says: this is a personal agent, acting for this identified sirven user, carried by
this one peer, going to this one allowlisted domain, inside this user's cap for this month. A peer that cannot check
every part of that refuses the request. Nothing is carried on trust.

This is the primitive the ship gate rests on: "Do not ship any peer routing of authenticated
traffic until the attestation layer and the site-allowlist review workflow are both working end
to end." Peer routing itself is not part of this deliverable. The egress path will call the
library described here before it carries a single byte.

## Roles

| Role | Holds | Never holds |
|---|---|---|
| Identity issuer | The issuer signing key; a record of every certificate it issued; the revocation list it publishes | Any user's signing key |
| Originator (the user's own device) | The user's signing key, generated on the device; the certificate for that key; bytes sent this month | Anyone else's key |
| Peer (the device asked to carry a request) | A random peer identifier, made once at `peer init`; the issuer public keys it trusts; its allowlist; the newest revocation list; its ledger of bytes carried per user per month; nonces it accepted; every envelope it carried; an audit log of every verification | Any signing key of anyone else |

Who runs the identity issuer: the sirven network. For the first ship that means Jose. Binding a
real person to a user handle is an identity-verification attestation, which stays Jose's call;
the tooling here signs a certificate once that decision is made, and never makes it.

## Trust model

1. **The device key proves the request came from the device.** Each user's signing key is
   generated on that user's own device (`user init`), written once with mode 0600 in a directory
   with mode 0700, and never overwritten. The command refuses to sign with a key file that others
   can read. Only the public key leaves the device, inside a certification request the device
   signs with the private key, so the issuer knows the asker holds it.
2. **The certificate proves the device key belongs to a person.** The identity issuer signs a
   certificate binding a user handle to that public key (`issuer certify`). It refuses a request
   whose signature does not verify, and refuses to certify a key it already certified for a
   different user: one key, one person. A key the user made
   alone proves nothing about who they are; the certificate is what makes the posture
   identity-attested.
3. **The envelope proves the request is bounded.** The device key signs each request: the peer
   that will carry it, the domain, the cap, a lifetime of at most five minutes, and a random
   nonce. Naming the peer means an envelope seen on its way to one peer cannot be spent at
   another, so a peer's audit log never attributes someone else's traffic to the user. The certificate rides inside the
   signed envelope.
4. **The revocation list proves the user is still in good standing.** The identity issuer signs
   a list of revoked users and revoked keys, with a sequence number that only goes up and a
   time by which it must be renewed.
5. **The peer trusts only the issuer public keys it was configured with.** Everything else is
   checked against those.

What this does not protect against: a user's device that is itself compromised can sign as that
user until the key or the user is revoked. That is what revocation and traceability are for.

## Signed objects

All three object types share one outer shape:

```json
{"sirven_attestation": 1, "type": "request", "payload": "<base64url>", "signature": "<base64url>"}
```

- `sirven_attestation` is the envelope format version. A peer refuses a version it does not know.
- `payload` is base64url of the JSON payload bytes, exactly as signed.
- `signature` is Ed25519 (the Edwards-curve digital signature scheme over Curve25519) over a context line, `sirven attestation <type> v<version>` followed by
  a newline, then the payload bytes. The context line means a signature made for one type can
  never be passed off as another, and a signature made for version 1 cannot be replayed under a
  later version.
- The verifier checks the signature over the bytes it received, then parses them. There is no
  JSON canonicalization to disagree about. Base64url is decoded strictly: one text, one byte
  string.
- Ed25519 comes from node's built-in crypto, so there is no third-party library. Stock macOS
  `/usr/bin/openssl` (LibreSSL 3.3.6) has no Ed25519, which ruled out a shell implementation.

Times are whole seconds since the epoch. Byte counts are whole numbers. A key identifier is the
first 16 bytes of the SHA-256 hash (the 256-bit Secure Hash Algorithm) of the raw 32-byte
public key, in base64url.

### Certification request payload (signed by the user's own device key)

| Field | Meaning |
|---|---|
| `version`, `type` | `1`, `"certification-request"` |
| `user` | The user handle asked for |
| `public_key`, `key` | The device's public key and its key identifier; the signature must verify against this key |
| `issued_at` | When the device made the request |

### Certificate payload (signed by the identity issuer)

| Field | Meaning |
|---|---|
| `version`, `type` | `1`, `"certificate"`; must match the outer object |
| `posture` | `"identity"` |
| `issuer` | Key identifier of the issuer key |
| `serial` | Random, unique per certificate; the issuer records which user it went to |
| `user` | The user handle: lowercase letters, digits, dot, dash, underscore, up to 64 characters |
| `public_key` | The user's raw Ed25519 public key, base64url |
| `key` | Key identifier of `public_key` |
| `issued_at`, `expires_at` | Validity window; 365 days by default |

### Request payload (signed by the user's device key)

| Field | Meaning |
|---|---|
| `version`, `type` | `1`, `"request"` |
| `posture` | `"identity"` |
| `credential` | The whole signed certificate object |
| `agent` | `"personal"`: a personal agent acting for its own user |
| `user`, `key` | Must equal the certificate's |
| `audience` | The identifier of the one peer this envelope is for |
| `domain` | One exact domain, lowercase, no trailing dot, no wildcard, port, scheme, or path |
| `cap.period` | The calendar month in universal time, like `2026-10` |
| `cap.limit_bytes` | The user's cap for the month |
| `cap.used_bytes` | What the originator had already sent this month |
| `cap.request_bytes` | The size of this request |
| `issued_at`, `expires_at` | At most 300 seconds apart; 120 by default |
| `nonce` | 16 random bytes, base64url; a peer accepts each nonce once |

### Revocation list payload (signed by the identity issuer)

| Field | Meaning |
|---|---|
| `version`, `type` | `1`, `"revocation-list"` |
| `issuer` | Key identifier of the issuer key |
| `sequence` | Goes up by one with every list; a peer refuses a list older than the one it has |
| `issued_at`, `next_update` | After `next_update` the list is stale; 24 hours by default |
| `users` | `{user, revoked_at, reason}`: every envelope from that user is refused, on any key |
| `keys` | `{key, revoked_at, reason}`: envelopes signed by that key are refused, for a lost device |

## What a peer checks, in order

The peer checks the envelope against the request it is actually being asked to carry, not just
against the envelope's own claims. Each refusal has a stable reason string.

| Step | Check | Refusal reason |
|---|---|---|
| 0 | It is a JSON envelope with a signature | `malformed`, `unsigned` |
| 1 | Format version and posture are known | `unsupported-version`, `unsupported-posture` |
| 1 | The device signature verifies over the exact payload bytes | `bad-signature` |
| 2 | The certificate is from a trusted issuer, its signature verifies, it is in date | `untrusted-issuer`, `bad-signature`, `certificate-invalid`, `certificate-expired` |
| 2 | Envelope user and key equal the certificate's; the agent is a personal agent | `user-mismatch`, `not-personal-agent` |
| 3 | The peer has a revocation list from that issuer, and it is not stale | `revocation-list-missing`, `revocation-list-stale` |
| 3 | Neither the user nor the key is revoked | `revoked` |
| 4 | The envelope is in its lifetime (30 seconds of clock skew allowed), and the lifetime is at most 300 seconds | `expired`, `not-yet-valid`, `lifetime-too-long` |
| 5 | The envelope names this peer | `wrong-audience` |
| 5 | The envelope's domain is the host actually requested, and that domain is on this peer's allowlist | `wrong-domain`, `domain-not-allowlisted` |
| 6 | The period is this month; the request is no bigger than declared; declared use fits the cap; this peer's own ledger for the user fits the cap | `wrong-period`, `over-declared-size`, `over-cap` |
| 7 | The nonce has not been accepted before | `replayed` |

The peer fails closed. No revocation list, a stale one, or one from a different issuer refuses
everything. A peer that cannot reach the issuer for a day stops carrying, rather than carrying
for someone who may have been revoked.

On acceptance, a peer adds the bytes to its ledger for that user and month, remembers the nonce
until the envelope expires, and keeps a copy of the envelope. Every verification, accepted or
refused, is one line in the peer's `audit.jsonl`.

## The cap

Jose's decision: 5 gigabytes per person per month, symmetric, so carrying and sending count the
same. The code reads gigabytes as decimal: `DEFAULT_CAP_BYTES` is 5,000,000,000 bytes. If Jose
means 5 × 2^30 bytes (5,368,709,120), it is one constant and the `--cap-bytes` peer option.

What a peer can enforce on its own:

- The originator refuses to sign a request that would take the user over the cap.
- The peer refuses when the declared use plus this request exceeds the smaller of the envelope's
  limit and the peer's own cap. An originator that inflates its own limit is still held to the
  peer's.
- The peer refuses when what it has already carried for that user this month, plus this request,
  exceeds its cap.

What it cannot: an originator that under-reports its own use to many different peers stays under
each peer's ledger. Network-wide accounting, where carrying and sending are summed across every
peer, belongs to the per-user reciprocity accounting work. The envelope already carries what that
accounting needs (user, period, declared use, request size), and `verifyRequest` takes the peer's
ledger as a function, so the reciprocity ledger plugs in without a format change.

## Abuse traceability

- **From envelope to person.** `trace` takes an envelope the peer kept and verifies both
  signatures, ignoring expiry and revocation, then names the user handle, key identifier, and
  certificate serial. The issuer's `issued.jsonl` maps the serial to the person it vetted. A
  tampered envelope traces to no one: tracing requires the same signature checks as acceptance.
- **From revocation to refusal.** `issuer revoke` then `issuer publish` produce a list with a
  higher sequence number. A peer that installs it refuses that user's envelopes from then on, and
  a peer that does not install a newer list within a day refuses everyone. Revoking a user covers
  every key they hold; revoking a key covers a lost or retired device only.

## Posture: identity first, pseudonymous later

Jose's decision for the first ship is identity-attested per user: strong attribution and strong
revocation. The format leaves room for a pseudonymous posture without a breaking change:

- `posture` sits in both the certificate and the request. A peer that does not know a posture
  refuses it, so an old peer can never mistake a pseudonymous envelope for an identified one.
- `credential` holds the whole credential object. A pseudonymous posture brings its own
  credential type (for example, an issuer-blinded token that proves membership in good standing
  without naming the user) and its own verification step 2. Steps 3 to 7 are unchanged.
- `sirven_attestation` versions the outer format if a change ever does need to break.

What a pseudonymous posture gives up has to be decided before it ships: who can trace an abusive
envelope to a person, and how revocation reaches a user the peer cannot name.

## Running it

```sh
bash lib/attestation/demo.sh           # the two-process demo, in a scratch directory
bash tests/run.sh attestation          # the command and demo tests
node --test tests/attestation/attestation.test.mjs   # the library tests
node lib/attestation/cli.mjs --help    # every command
```

The demo runs the issuer, the originator, and the peer as separate processes that share only
files: the originator signs, the peer verifies and accepts, then refuses a tampered envelope and
a replay; a second peer refuses the same envelope because it was meant for the first; and after
the issuer revokes the user, the first peer refuses a fresh envelope from that user.

Requires node 18 or newer. `SIRVEN_ATTESTATION_NOW` fixes the clock for tests.

## Not built yet

- **Serving the revocation list.** Peers install a list from a file. Fetching it on a schedule
  belongs with the egress path.
- **Learning the peer identifier.** The originator passes `--audience` by hand. The egress path
  will learn it when it picks a peer.
- **Concurrent verification.** The peer command reads and writes its ledger and nonce files
  without a lock. A peer daemon has to verify one request at a time per peer, or hold a lock.
- **Key rotation and recovery.** A new device means a new `user init`, a new certificate, and
  revoking the old key. There is no backup of a signing key, on purpose.
- **Issuer key protection.** The issuer key is a file. Before real users, it belongs in hardware
  or at least offline, with a second issuer key peers already trust for rollover.
