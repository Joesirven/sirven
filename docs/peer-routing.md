# Peer routing, version 1

Status, 2026-10-11: the two components the first ship gate names, the attestation layer and the
site-allowlist review workflow, work end to end through the policy engine and the reciprocity
ledger, and `tests/peer_routing` proves it with every real component and no fakes. Peer routing
itself is still not available to anyone: the gate constant is closed, and the peer transport
that would move bytes between two machines is not built.

The ship gate, in Jose's words: "Do not ship any peer routing of authenticated traffic until the
attestation layer and the site-allowlist review workflow are both working end to end."

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

## What still stands between this and shipping peer routing

- **The peer transport.** Nothing moves bytes between two machines yet. `TRANSPORT_BUILT` in
  `lib/peer_routing.py` is false, so `peer_routing_available` is false everywhere, and the
  runtime seam still refuses every peer route.
- **Opening the gate.** `SHIP_GATE_AUTHENTICATED_PEER_TRAFFIC` in `lib/policy_engine.py` stays
  `"closed"`. Opening it is Jose's call, in the release that ships the transport.
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
