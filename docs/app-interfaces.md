# The tier dial, consent moment, site list, and usage meter: what they read

The four surfaces live in `app/`. They are plain HTML, CSS, and JavaScript with no build
step, served on this Mac only by `app/serve.py`. Every word on screen comes from
`copy/consent-moment.md` and `copy/surfaces.md`, which the page reads directly.

    python3 app/serve.py                         # the first-block scenario on port 7420
    python3 app/serve.py --scenario near-cap     # any scenario below
    python3 app/serve.py --peer-preview          # lets the consent moment finish (fakes only)

Then open `http://127.0.0.1:7420/`. Add `?view=meter` or `?view=list` to open on another
surface.

## Where the data comes from

By default `app/serve.py` serves fakes from `app/fakes/` in the shapes below, so every
surface can be shown in every state. With `--live` it reads the real interfaces instead and
maps them onto the same shapes; the page does not change:

    sirven runtime serve &                       # the runtime, on 127.0.0.1:47290
    python3 app/serve.py --live                  # reads it, the ledger, and the registry

| Endpoint | Live source |
| --- | --- |
| `GET /api/state` | the runtime's `GET /v1/status`: `tier`, `peer_routing_available`, `last_block`. `consent` is kept by `app/serve.py` in `app-consent.json` in the runtime folder |
| `POST /api/tier` | refused here while `peer_routing_available` is false, then the runtime's `PUT /v1/tier` |
| `GET /api/ledger` | `lib/reciprocity.py read` on `peer-routing/reciprocity.jsonl` in the runtime folder |
| `GET /api/registry` | the approved list of `allowlist/registry.json`, or `--registry FILE` |

`tests/app/test_live_shapes.py` starts a real runtime and checks that every live answer has
exactly the keys of its fake.

| Endpoint | Owner | Fake files |
| --- | --- | --- |
| `GET /api/state`, `POST /api/tier`, `POST /api/consent` | thread 01, runtime | `app/fakes/runtime/` |
| `GET /api/ledger` | thread 04, reciprocity accounting | `app/fakes/ledger/` |
| `GET /api/registry` | thread 05, site review and registry | `app/fakes/registry/` |

## Runtime state (thread 01)

    {
      "version": 1,
      "tier": "solo",                     // solo, neighborly, or coop
      "peer_routing_available": false,    // true only when signing and site review both work end to end
      "consent": {"prompted": false, "decision": null},
      "last_block": {                     // the latest block result, or null
        "version": 1, "mode": "solo", "route": "local",
        "outcome": "blocked", "reason": "site_refused", "http_status": 403,
        "host": "tickets.example", "at": "2026-10-11T16:42:00Z"
      }
    }

`last_block` reuses the result object the runtime already returns for a blocked read
(`version`, `mode`, `route`, `outcome`, `reason`), plus the two fields the consent moment
needs: `host` and `at`. What thread 01 needs to add: a way to read the latest block, and the
`peer_routing_available` flag.

`POST /api/tier` with `{"tier": "neighborly"}` answers `409 {"error": "peer_routing_unavailable"}`
while the flag is false, and `409 {"error": "tier_not_open"}` for Co-op. This is the first
ship gate enforced at the interface, not only in the page.

`POST /api/consent` with `{"decision": ...}` records how the consent moment ended: `solo`,
`neighborly`, `dismissed` (closed without choosing), or `not_open` (shown while Neighborly
was closed). Any of these sets `prompted`, and the page never asks again on later blocks.

## Reciprocity ledger (thread 04)

    {
      "version": 1,
      "period": {"start": "2026-10-01T00:00:00Z", "end": "2026-11-01T00:00:00Z"},
      "cap_bytes": 5000000000,
      "carried_bytes": 1240000000,        // carried for other members
      "sent_bytes": 610000000,            // sent through other members
      "used_bytes": 1850000000,           // carried plus sent: one symmetric cap
      "state": "under",                   // under or over
      "sessions": [
        {"id": "s-0007", "direction": "carried", "domain": "rides.example",
         "bytes": 84000000, "started_at": "2026-10-11T15:58:00Z", "ended_at": null}
      ]
    }

The page polls every two seconds. A session with `ended_at` of `null` is shown as live.
`period.end` is shown as the reset day. 5 gigabytes means 5,000,000,000 bytes, the way
macOS counts sizes: confirmed by `lib/reciprocity.py` (thread 04) and `DEFAULT_CAP_BYTES` in
`lib/attestation/attestation.mjs` (thread 02). Domains appear at the granularity the
registry publishes, never as page addresses.

## Site registry (thread 05)

    {
      "version": 1,
      "registry_version": "2026.10.3",
      "published_at": "2026-10-09T00:00:00Z",   // null before the first publish
      "test_data": true,                       // the page shows a "Test data" badge
      "entries": [
        {"domain": "rides.example", "status": "approved", "scope": "authenticated",
         "approved_at": "...", "last_reviewed_at": "...", "next_review_by": "...",
         "rationale": "Why it is on the list, in plain words.",
         "public_positions": [{"label": "Terms of service", "url": "https://rides.example/terms"}]}
      ]
    }

Only `approved` entries are shown. `scope` is `read` or `authenticated`. Only `https` links
are rendered. The registry starts empty, so the empty state is the one most people will see
first; `--scenario empty-list` shows it. Fake entries use reserved `.example` names so test
data can never be mistaken for a real approval.

## Scenarios

| Scenario | Shows |
| --- | --- |
| `first-block` | Solo, the agent was just blocked: the consent moment opens |
| `first-block-gated` | the same with an empty registry, the way first ship will look |
| `solo` | Solo with nothing blocked |
| `neighborly` | Neighborly with a live session, under the cap |
| `near-cap` | Neighborly at 92 percent, still growing |
| `over-cap` | Neighborly at the cap, carrying and sending stopped |
| `empty-list` | Solo with the registry empty |

`--growth` sets how many bytes per second a live fake session grows, so the meter can be
watched moving; it stops at the cap the way enforcement will.

## Rules the surfaces keep

- The consent moment opens once, the first time the agent is blocked in Solo. After that
  the choice lives on the dial.
- Moving up to Neighborly always goes through the consent moment. Moving back to Solo is one
  step with no questions.
- Every choice is two buttons of equal weight. Nothing is preselected and nothing counts down.
- Co-op is shown on the dial so the scale is honest, and cannot be chosen until it exists.
- Motion follows `docs/DESIGN-LANGUAGE.md`: transform and opacity only, closing faster than
  opening, a 40 millisecond stagger, and a reduced-motion fallback.
