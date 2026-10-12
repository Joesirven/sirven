# Peer routing, version 1

Status, 2026-10-12: the attestation layer, the site-allowlist review workflow, the allowlist
policy engine, and the reciprocity ledger all work end to end, and the carrier side of the
peer transport (`lib/peer_transport.py`) is now built and tested end to end on loopback
(`tests/peer_routing/test_transport.py`): a requesting process signs a real envelope, posts
to a carrier process, the carrier runs every real check through `lib/peer_routing.py` and, on
an allow, fetches the request from its own connection and returns the response bytes to the
requester. The reciprocity ledger records the transfer.

Peer routing is still not available to any user. Two things are open, and both are intentional:

- The runtime's user-side peer egress is not wired. `lib/sirven_runtime/seam.py` continues to
  refuse any `peer` route with reason `peer_routing_not_built`. A user asking the runtime for a
  peer route is refused there, before the transport is reached.
- The authenticated-traffic ship gate is closed. The policy engine's constant
  `SHIP_GATE_AUTHENTICATED_PEER_TRAFFIC` stays `"closed"`, so an authenticated peer request is
  refused with `ship_gate_closed`. Opening it is Jose's call, in the release that also ships
  the user-side wiring and the first approved site.

The ship gate, in Jose's words: "Do not ship any peer routing of authenticated traffic until the
attestation layer and the site-allowlist review workflow are both working end to end." Both
components work end to end today; the gate stays closed anyway, as a release gate, until the
rest ships together.

## How the pieces connect

`lib/peer_routing.py` is the one place they meet.

| Step | Component | Code |
| --- | --- | --- |
| A site is requested, prepared, voted on, built into the registry, and published | site-allowlist review workflow | `lib/allowlist_review.py` |
| The identity issuer signs that registry version, valid for 7 days by default | attestation layer | `cli.mjs registry sign` |
| A machine verifies the signature and installs the snapshot; any failure carries nothing | attestation layer, policy engine | `peer_routing.py refresh` |
| The requesting user's device signs an envelope for one peer, one domain, one size, and the exact request bytes | attestation layer | `cli.mjs sign --request-digest` |
| The carrying machine runs the decision table, then the peer verifier on the exact bytes | policy engine, attestation layer | `peer_routing.py carry` |
| The bytes are reserved against the 5,000,000,000 byte monthly cap | reciprocity ledger | `reciprocity.py check` |
| The runtime and the tier dial ask whether peer routing is available | runtime, tier dial | `peer_routing.py readiness`, `GET /v1/status` |

## What `tests/peer_routing` proves

Twenty cases, each through the real code: a reviewed site with a valid envelope is carried and
its bytes reserved; `www.` matches its registry entry; signed-in traffic is refused while the gate
is closed, and with the gate open it still needs a site reviewed for signed-in sessions. Refusals,
one per component: a site never reviewed, Solo, a tampered registry, a registry signed by an
untrusted key, an expired registry, an envelope for another peer, for other bytes, expired,
replayed, forged, from a revoked user, and past the 5 gigabyte cap. A fresh machine is not ready,
and a configured one is ready but still reports `peer_routing_available: false`.

## The peer transport, honestly

`lib/peer_transport.py` is the carrier side. One carrying machine runs the carrier server,
bound to `127.0.0.1` on a port of its choice, and takes a bearer token for the requester
process on the same host. The one endpoint is `POST /v1/carry`. The body carries the host, the
tier, the session, the exact request bytes (base64), the signed envelope, and the URL the
carrier should fetch on an allow. On an allow the carrier fetches the URL from its own
connection and returns `{"outcome": "ok", "status", "headers", "body_base64", "bytes",
"decision", "receipt"}`; on any refusal from the policy engine the carrier returns `403` with
the refusal record. The bytes actually moved are then appended to the reciprocity ledger as a
settled transfer.

What this ship does not carry:

- Any inter-machine authentication of the carrier endpoint itself. The carrier listens on
  loopback and takes a bearer token on the same host; the inter-machine link in production
  rides Tailscale, which supplies the host authentication and the encryption, and that wiring
  is open.
- `POST`, `PUT`, `DELETE`, `PATCH`. Version one of the carrier moves `GET` only. A different
  method is reported as `unsupported_method` and nothing leaves the carrier.
- Redirects. The carrier returns the origin's answer, redirects included, unfollowed; the
  requester decides what to do.

The end-to-end proof is `tests/peer_routing/test_transport.py`: a mock origin on loopback, a
real issuer, a real user device, a real reviewed registry, the real carrier, and a real
requester, with the bytes compared end to end. The suite also covers a refused site, a missing
bearer token, and a wrong path.

## What still stands between this and shipping peer routing

- **The runtime's user-side peer egress.** `lib/sirven_runtime/seam.py` refuses `peer` with
  `peer_routing_not_built`. Wiring the fetch channel through a carrier is a separate ship, so
  it can be reviewed on its own.
- **Opening the gate.** `SHIP_GATE_AUTHENTICATED_PEER_TRAFFIC` in `lib/policy_engine.py` stays
  `"closed"`. Opening it is Jose's call, in the release that ships the user-side wiring and
  the first approved public entry together.
- **An approved site.** The registry has no approved entries; three are pending. The first
  public publish is held for Jose.
- **The registry signing key.** It is the identity issuer's key, a file. The attestation document
  already says it belongs offline or in hardware before real users.
- **Votes are unsigned.** A vote still records a reviewer's name as typed (see
  `docs/allowlist-review.md`).

## Decisions made at integration, for Jose to confirm

- The registry version is signed by the identity issuer key, the trust anchor every peer already
  holds, rather than a second publisher key.
- Version 1 of the registry has no tier dimension, so every approved entry may be carried in both
  Neighborly and Co-op.
- Approved entries with `includes_subdomains: true`, or with signed-in sessions but not public
  pages, are left out of the snapshot (never carried) until the policy engine can express them.
- The attestation cap period is the calendar month in universal time; the reciprocity ledger's
  month is local time. Each enforces its own; reconciling them is open.
