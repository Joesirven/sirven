# Allowlist policy engine

Status: built and tested on 2026-10-11, and wired end to end with the attestation layer, the
site-allowlist review workflow, and the reciprocity ledger through `lib/peer_routing.py` the
same night. See `docs/peer-routing.md`; the envelope and reviewer sections below now describe
the committed formats.
Code: `lib/policy_engine.py`. Tests: `tests/policy/test_policy_engine.py` and
`tests/unit/test_policy_engine.sh`, both run by `make test`.

The engine runs on every node and answers one question for each request leaving it: may this go
out, and as whose traffic? It has three answers:

| Action | Meaning |
|---|---|
| `allow_local` | The user's own traffic, out through the user's own egress. |
| `allow_peer_carrier` | Another sirven user's personal-agent traffic, carried by this node. |
| `refuse` | Not sent. Comes with a stable `code` and a plain-language `reason` the user interface can show as written. |

## Rules that hold whatever the inputs

- Solo never carries traffic for anyone else.
- A domain that is not on the published registry, for this node's tier, is never carried for a
  peer. Matching is exact: no subdomains, parent domains, wildcards, addresses, or full links.
- A fresh install has no registry, so it carries nothing for anyone until thread 05 publishes one.
- Peer traffic needs an identity attestation that the attestation verifier accepted.
- Authenticated (signed-in) peer traffic is refused while the ship gate is closed. The gate is a
  constant in code, `SHIP_GATE_AUTHENTICATED_PEER_TRAFFIC = "closed"`, not a setting and not
  anything a request can carry.
- The user's own traffic is always `allow_local`, in every tier, with or without a registry. The
  engine never blocks it; the runtime surfaces any site-side blocking honestly.

## Decision table

Checks run in order; the first that fails decides.

| Step | Check | On failure |
|---|---|---|
| 1 | Request is well formed and names a plain domain | `invalid_request`, `invalid_domain` |
| 2 | Direction is `own` | (passes) `allow_local` / `own_egress` |
| 3 | Tier is not Solo | `solo_never_carries` |
| 4 | A current, verified registry is on the node | `registry_unavailable`, `registry_expired` |
| 5 | The domain is on it | `site_not_allowlisted` |
| 6 | The entry lists this node's tier | `tier_not_reviewed` |
| 7 | Authenticated only: ship gate is `"open"` | `ship_gate_closed` |
| 8 | Authenticated only: the entry is reviewed for signed-in sessions | `authenticated_not_reviewed` |
| 9 | The envelope passes the engine's own structural checks | `attestation_<state>` |
| 10 | The attestation verifier accepts it for this exact request | `attestation_<state>` |
| 11 | All passed | `allow_peer_carrier` / `reviewed_peer_request` |

The verifier is called at step 10 only, so a request refused for any other reason never reserves
sharing allowance against the 5 gigabyte monthly cap.

Envelope states (`ENVELOPE_STATES`): `valid`, `missing`, `malformed`, `unsupported_posture`,
`invalid_signature`, `expired`, `revoked`, `wrong_domain`, `wrong_request`, `wrong_peer`,
`replayed`, `over_cap`, `verifier_unavailable`. The tests cover every state in both carrying
tiers, with the ship gate closed and open.

Tier ordering: Neighborly and Co-op each carry only the entries that list them, so a broader
Co-op allowlist is a registry decision (entries listing only `"Co-op"`), not engine logic.

## The classification seam (for thread 01)

`docs/runtime-interface.md` did not exist when this was built, so this section defines the seam.
Thread 01 should either adopt it or tell the coordinator what to change.

The runtime calls the engine once per outbound request, before dispatch:

```python
from policy_engine import Request, classify_and_log

decision = classify_and_log(
    Request(domain, tier, direction, authenticated, request_digest, envelope),
    registry_state,        # the parsed registry state file, or None
    now,                   # integer seconds, from the runtime's clock
    log_path,              # the node's decision log
    verify_attestation,    # thread 02's verifier, adapted (below)
)
```

- `direction` is `"own"` or `"peer"`, and `authenticated` is whether the request carries a
  session (cookies, an authorization header). **The runtime decides both from the traffic
  itself.** Never take either from the requesting peer: a peer claiming `"own"` or
  `authenticated: false` must not be believed.
- `request_digest` is the SHA-256 of the exact request bytes, in lowercase hexadecimal, the same
  digest thread 02 signs (`requestDigest`).
- Dispatch only on `allow_local` or `allow_peer_carrier`. If `classify_and_log` raises (the log
  could not be written), refuse. From another language, the command line does the same: exit
  status 1 means refuse.
- The committed runtime's seam (`lib/sirven_runtime/seam.py`) refuses any request that carries
  a `signed_envelope` (`peer_traffic_refused`). That stays right until the peer transport
  ships: the allowlist comes from the registry state file, never from a request.

Command line, for a runtime not written in Python:

```sh
printf '%s' "$request_json" | python3 lib/policy_engine.py classify \
  --registry-state STATE_FILE --log LOG_FILE --attestation-verifier VERIFY_COMMAND --now SECONDS
```

The request JSON has the `Request` field names; unknown fields are refused.

## Registry snapshot and refresh (for thread 05)

The engine accepts this snapshot, after the publisher's signature has been checked:

```json
{"schema_version": 1, "status": "published", "serial": 7, "reviewer": "Jose",
 "published_at": 1800000000, "expires_at": 1800086400,
 "entries": [{"domain": "example.org", "tiers": ["Neighborly", "Co-op"],
              "authenticated_sessions": false}]}
```

- `reviewer` must be in `REVIEWERS`, which is `("Jose",)` for the first six months.
- `tiers` lists only `Neighborly` and `Co-op`. `authenticated_sessions` (default false) is the
  review decision that a site may be carried signed in.
- Any unknown field, duplicate domain, or non-plain domain rejects the whole snapshot.

`refresh_registry(fetch, verify, now)` is separate from the decision path and is the only place
the network is touched. `verify` must check thread 05's publisher signature over the fetched
bytes; the engine does not ship a signature scheme of its own, so thread 05 owns it. Any failure
(offline, bad signature, invalid or expired snapshot) writes an `unavailable` state and **drops
the previous snapshot**: carrying stops until the next good refresh (fail closed), and own
egress is untouched (fail open). Error text is never stored, only the error class, because fetch
errors can contain addresses or credentials. A snapshot that expires between refreshes stops
carrying at `expires_at` with `registry_expired`.

## Attestation (for thread 02)

`verify_attestation(envelope, request, now)` returns an `Attestation(state, posture, domain,
request_digest, key_id, nonce, maximum_bytes)`, with every field taken from the verified payload.
The engine re-checks posture, domain, digest, and a positive `maximum_bytes` against the request,
and treats an exception or any other return value as `verifier_unavailable`.

Before calling the verifier, the engine decodes the envelope's base64url payload in the
`lib/attestation` format and checks `posture`, `issued_at`, `expires_at`, `domain`, and
`request_digest`. Those checks never replace the verifier's signature, revocation, replay, and
cap checks.

`ATTESTATION_ERROR_STATES` maps the refusal reasons of `lib/attestation/attestation.mjs`
(`REFUSAL`) to envelope states. A
verifier command for the command line prints either the `Attestation` fields as JSON or
`{"error": CODE}`.

Postures: `identity` is accepted. `pseudonymous` is recognized and refused with
`attestation_unsupported_posture`; enabling it later is adding it to `ACCEPTED_POSTURES`.

## Decision log (for threads 04 and 06)

One JSON line per decision, appended to a private file (mode 600, owned by the node's user,
never a link) and flushed before the decision returns.

| Field | Present | Notes |
|---|---|---|
| `schema_version`, `decision_id`, `time` | always | `decision_id` is random, for joining with byte counts |
| `direction`, `tier`, `action`, `code`, `reason` | always | the user interface shows `reason` |
| `domain`, `authenticated` | peer traffic only | own traffic is logged without its domain, so the log never becomes a browsing history |
| `registry_serial` | once a registry was consulted | |
| `attestation_state` | once the envelope was checked | |
| `posture`, `key_id`, `nonce_digest`, `maximum_bytes` | `allow_peer_carrier` only | for the usage meter: who to count against the 5 gigabyte cap, and how much was reserved |

The envelope, its signature, and its nonce never enter the log; only a SHA-256 digest of the
nonce. `read_log(path)` returns the records and skips a torn last line.

## Proving the ship gate

The gate names two components: attestation and the site-allowlist review workflow. This engine
makes both load-bearing in code:

- With the gate closed, no input produces `allow_peer_carrier` for authenticated traffic. Tested.
- With the gate open (tests pass `ship_gate="open"`), authenticated carrying still needs a
  published registry entry with `authenticated_sessions: true` and a `valid` identity
  attestation; every other envelope state, a missing registry, or an unreviewed entry refuses.
  Tested.
- `python3 lib/policy_engine.py gate-status` reports the gate, the registry state, and which sites
  are reviewed for signed-in sessions.

Opening the gate is a one-line change to the constant, made only in the release whose end-to-end
test runs thread 05's real published registry and thread 02's real verifier through this engine.
That end-to-end test now exists: `tests/peer_routing/test_end_to_end.py`. The gate stays closed
until the peer transport ships.
