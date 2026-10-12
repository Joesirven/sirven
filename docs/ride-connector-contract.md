# Ride connector contract

Version **1.0.0**, published 2026-10-11. Stable: the rules in [Versioning and stability](#versioning-and-stability) govern every change from here on.

This is the contract between a personal agent and sirven's ride connector, served as model context protocol tools. It is service-agnostic: it names no ride service and no backend. A ride service appears only as the value of a `provider` field in results.

| Piece | Where |
|---|---|
| This document | `docs/ride-connector-contract.md` |
| Machine-readable schema (source of truth) | `connectors/ride/schemas/v1/ride-connector.schema.json` |
| Model context protocol tool list, generated, self-contained per tool | `connectors/ride/schemas/v1/tools.json` |
| Reference gateway, backend interface, fake backend, server | `connectors/ride/ride_connector/` |
| Schema-validating test suite | `connectors/ride/tests/`, run by `make test` |

Where this document and the schema disagree, the schema wins and the disagreement is a bug in this document.

## The calls

| Tool | What it does | Side effects |
|---|---|---|
| `quote_ride` | Ranked options for a trip within a departure window and a budget. | None. Nothing is held, booked, or charged. |
| `book_ride` | Commits one quoted option by its `quote_id`. | Books a ride. The agent asks the person first. |
| `cancel_ride` | Cancels a booking and reconciles what is owed. | Cancels a ride; may incur the published fee. |
| `get_ride` | Reads a booking's status, tracking details, and final charge. | None. |

`quote_ride`, `book_ride`, and `cancel_ride` are the three primary calls. `get_ride` is the read-only tracking surface that `book_ride` points to; it is how the agent and the money layer learn that a trip finished and what it cost.

Every call takes an optional `contract_version` argument and every result carries `contract_version`. Every argument object and every result object is closed: a field the schema does not name is refused on the way in and can never appear on the way out.

## Shared types

**Money.** `{"amount_minor": 2350, "currency": "USD"}`. `amount_minor` is a whole number in the currency's smallest unit (cents for US dollars), never a floating point number. `currency` is a three-letter uppercase currency code. Every amount in one option or booking shares one currency.

**Timestamps.** Request for Comments 3339 date and time with an explicit offset: `2026-10-12T15:00:00-07:00` or `2026-10-12T22:00:00Z`. A timestamp without an offset is refused.

**Places.** An object with `address`, `coordinates` (`latitude`, `longitude`), or both, plus an optional `label` (a human name like "barber", shown back to the person and never used for routing) and optional `pickup_notes`. When both are present, coordinates win.

**Identifiers.** `quote_id` looks like `qt_` followed by 26 lowercase letters and digits; `booking_id` is the same with `bk_`. Both are random tokens minted by the gateway. They are opaque: never parse them, and they never encode which backend served the ride.

**Absent values.** In results, every field is always present. A value that does not apply is `null`, never a missing key.

## quote_ride

### Arguments

| Argument | Required | Meaning |
|---|---|---|
| `origin` | yes | A place. |
| `destination` | yes | A place. |
| `departure_window` | yes | `{earliest, latest}` timestamps: when the rider wants to be picked up. `latest` must not be before `earliest`, and the window must not already be over. An `earliest` in the past means as soon as possible. |
| `budget_ceiling` | yes | Money: the most the person will pay in total, **tip included**. |
| `user_preferences` | no | See below. Every field is optional. |
| `contract_version` | no | `"1"` or a full version like `"1.0.0"`. |

`user_preferences`:

| Field | Kind | Meaning |
|---|---|---|
| `preferred_providers` | list of names | Rank these first, in the order given. A preference, not a filter. Matching ignores letter case. |
| `avoided_providers` | list of names | Never offer these. A filter: their options are left out entirely. |
| `vehicle_classes` | list | `standard`, `comfort`, `large`, `premium`, `accessible`, `autonomous`, `shared`. Other classes are still offered, flagged `vehicle_class_not_requested`. |
| `accessibility_needs` | list | `wheelchair_accessible`, `service_animal`, `assistance_boarding`, `car_seat`. Hard requirements. |
| `max_pickup_wait_minutes` | 1 to 120 | Options that wait longer are flagged `long_pickup_wait` (advisory). |
| `tip_ceiling_percent` | 0 to 100, default 20 | The most the rider will tip, as a percent of the fare ceiling. |
| `ranking` | `balanced` (default), `cheapest`, `fastest` | How to order bookable options. |

### Result

`{"contract_version", "options", "notices", "quoted_at"}`: options best first, notices about the quote as a whole, and the time the quote was made.

Each option:

| Field | Meaning |
|---|---|
| `quote_id` | Pass to `book_ride`. |
| `rank` | 1 is the best match. Ranks are dense and start at 1. |
| `bookable` | `false` when any blocking flag is present. `book_ride` refuses unbookable options. |
| `provider` | The ride service the rider will see on the car or the receipt, as a display name. |
| `vehicle_class` | One of the vehicle classes above. |
| `price` | `{kind, amount, maximum}`. `fixed`: the fare is guaranteed until the quote expires, and `maximum` equals `amount`. `estimate`: the final fare may land anywhere up to `maximum`, never above it. |
| `charge_terms` | What the money layer holds funds against. See [What the money layer reads](#what-the-money-layer-reads). |
| `estimated_pickup_at` | When the vehicle should arrive at the origin. |
| `estimated_dropoff_at` | When the rider should arrive at the destination. |
| `estimated_pickup_wait_minutes` | Minutes from the start of the window (or from now, if later) to pickup. |
| `estimated_trip_minutes` | Minutes from pickup to drop-off. |
| `constraint_flags` | See the table below. |
| `fulfillment` | `{method, disclosure}`. See [Human-assisted fulfillment](#human-assisted-fulfillment). |
| `cancellation_policy` | `{free_until, fee_after_free_period}`. See [cancel_ride](#cancel_ride). |
| `expires_at` | After this, `book_ride` returns `quote_expired`. |

### Constraint flags

| Flag | Blocking | Meaning |
|---|---|---|
| `over_budget` | yes | `charge_terms.authorization_cap` is above `budget_ceiling`. |
| `outside_departure_window` | yes | The estimated pickup falls outside the departure window. |
| `accessibility_not_met` | yes | The option cannot meet one of `accessibility_needs`. |
| `provider_not_preferred` | no | Preferences named providers and this is not one of them. |
| `vehicle_class_not_requested` | no | Preferences named vehicle classes and this is not one of them. |
| `long_pickup_wait` | no | The wait is longer than `max_pickup_wait_minutes`. |
| `price_is_estimate` | no | `price.kind` is `estimate`. |
| `surge_pricing` | no | The ride service is charging a demand premium right now. |
| `shared_ride` | no | The rider may share the vehicle with strangers. |
| `human_assisted` | no | A person books this ride. Mirrors `fulfillment.method`. |

Unbookable options are still returned, ranked after every bookable one, so the agent can tell the person honestly why a familiar choice is missing ("the Waymo ride would be 27 dollars, over your 25 dollar budget") instead of silently dropping it.

### Ranking

The gateway ranks across all backends at once. Bookable options always come first. Within each group:

- `balanced`: providers in `preferred_providers` order first, then the lowest `authorization_cap`, then the earliest drop-off.
- `cheapest`: lowest `authorization_cap`, then earliest drop-off.
- `fastest`: earliest drop-off, then lowest `authorization_cap`.

Ties are broken at random, so equal options never come out grouped by backend.

### Budget rule

An option is within budget when `fare_ceiling + tip_ceiling` (which is `authorization_cap`) is at or below `budget_ceiling`. The tip ceiling counts because it is money the person may be charged. Where a provider does not take tips, its tip ceiling is zero.

### Notices and refusals

When some ride services could not contribute, the result still succeeds and carries notices:

| Notice | Meaning |
|---|---|
| `blocked` | A ride service refused access to agents. Nothing was routed around that refusal. |
| `no_service` | A ride service does not serve this trip. |
| `partial_results` | A ride service could not be reached, so the list may be incomplete. |

Notices never say which service or backend. When no option at all can be returned, `quote_ride` fails instead, with `blocked` if any service refused agents, otherwise `no_service`, otherwise `rate_limited` or `service_unavailable`. A blocked result is surfaced to the person as a block; the connector never retries a refusal through another route.

## book_ride

### Arguments

| Argument | Required | Meaning |
|---|---|---|
| `quote_id` | yes | From a `quote_ride` result. |
| `payment_reference` | no in version 1 | An opaque handle from the sirven money layer for funds already held against this booking: letters, digits, `_` and `-`, 8 to 128 characters. **Never a card number or any card detail.** A long run of digits is refused as `invalid_argument` before any backend sees it. A gateway configured to require held funds returns `payment_required` without it. |
| `contract_version` | no | As for `quote_ride`. |

### Result

`{"contract_version", "booking", "replayed"}`. `replayed` is `true` when this `quote_id` was already booked and this is that original booking returned again.

The booking:

| Field | Meaning |
|---|---|
| `booking_id` | Pass to `get_ride` and `cancel_ride`. |
| `quote_id` | The quote this booking came from. |
| `status` | See the status table below. |
| `provider`, `vehicle_class`, `price`, `charge_terms`, `fulfillment`, `cancellation_policy` | Copied unchanged from the quoted option. |
| `origin`, `destination` | As the agent sent them to `quote_ride`. |
| `estimated_pickup_at`, `estimated_dropoff_at` | Current estimates; `get_ride` updates them. |
| `confirm_by` | For `requested` bookings: if a person has not confirmed by then, the booking becomes `failed` and nothing is charged. `null` once confirmed. |
| `tracking` | `{status_call: "get_ride", poll_interval_seconds, share_url, vehicle_description}`. Poll `get_ride` no more often than the interval. `share_url` is a sirven-relayed page or `null`; it is never a ride service's own link. |
| `final_charge` | `null` until the booking is completed, cancelled, or failed. |
| `created_at`, `updated_at` | Timestamps. |

### Booking status

| Status | Meaning | Terminal |
|---|---|---|
| `requested` | Accepted, waiting for confirmation. Human-assisted bookings start here. | no |
| `confirmed` | A ride is promised. Automated bookings start here. | no |
| `driver_assigned` | A vehicle is on its way. | no |
| `in_progress` | The trip started. | no |
| `completed` | The trip ended; `final_charge` is set. | yes |
| `cancelled` | Cancelled through `cancel_ride`; `final_charge` is set. | yes |
| `failed` | Never confirmed, or declined; `final_charge` is set with a zero total. | yes |

A booking only moves forward through this list. The agent should not tell the person a ride is booked until the status is `confirmed` or later.

## cancel_ride

### Arguments

`booking_id` (required), optional `reason` (`plans_changed`, `found_alternative`, `booked_by_mistake`, `pickup_too_late`, `other`), optional `contract_version`.

### Semantics

- Before `cancellation_policy.free_until`: cancelling costs nothing.
- From `free_until` until the trip starts: cancelling costs exactly `cancellation_policy.fee_after_free_period`, never more. If a ride service charges more, sirven absorbs the difference.
- Once the status is `in_progress`, `completed`, or `failed`: `cancel_ride` returns `not_cancellable`, and the error carries the booking as it stands.
- A `requested` booking can always be cancelled under the same policy.

### Result and reconciliation

`{"contract_version", "booking", "already_cancelled"}`. The booking's status is `cancelled`, and its `final_charge` is the reconciliation:

| Field | Meaning |
|---|---|
| `fare` | Zero for a cancelled booking. |
| `tip` | Zero for a cancelled booking. |
| `cancellation_fee` | Zero or the published fee. |
| `total` | `fare + tip + cancellation_fee`. |
| `amount_to_release` | `authorization_cap - total`: what the money layer releases from its hold. |

If the cancellation could not reach the ride service, `cancel_ride` returns a retryable error and the booking is **not** marked cancelled. The agent retries; it never tells the person a ride is cancelled on an error.

## get_ride

Argument: `booking_id`. Result: `{"contract_version", "booking"}`, refreshed from the ride service. On `completed`, `final_charge` holds the actual `fare` and `tip` with a zero `cancellation_fee`. `fare` never exceeds `charge_terms.fare_ceiling`, `tip` never exceeds `charge_terms.tip_ceiling`, so `total` never exceeds `authorization_cap`: the gateway clamps anything above and logs the discrepancy for sirven's operators.

## What the money layer reads

The money layer (Stripe Issuing per-booking virtual cards) needs no side channel. Everything it needs is in `charge_terms` on the quoted option and the booking, and in `final_charge`:

| Need | Field |
|---|---|
| Expected fare to show the person | `charge_terms.quoted_amount` |
| Most the fare can be | `charge_terms.fare_ceiling` |
| Pre-authorized tip ceiling | `charge_terms.tip_ceiling` |
| Card spending cap | `charge_terms.authorization_cap` (fare ceiling plus tip ceiling) |
| Currency | `charge_terms.currency` |
| Link from held funds to the booking | `payment_reference` on `book_ride`; `booking_id` and `quote_id` on the booking |
| Settle on completion | `final_charge.total` when `get_ride` reports `completed` |
| Release on cancellation or failure | `final_charge.amount_to_release` |
| Rationale record (amount paired with why) | The quoted option (price, flags, rank) plus the booking |

The intended order: `quote_ride`, the person approves an option, the money layer holds `authorization_cap` and returns a `payment_reference`, then `book_ride`. Card numbers, card verification codes, and expiry dates never appear in any argument or result. They travel only between the money layer and the backend inside sirven, outside this contract.

## Backend blindness

The calling agent cannot tell which backend produced a quote or a booking. This holds by construction, in the gateway, not by backend good behavior:

1. **Identifiers are minted by the gateway** as random tokens. Backend references stay in the gateway's private tables.
2. **Results are rebuilt field by field** from plain backend records (see `connectors/ride/ride_connector/backend.py`). A backend has no way to add a field.
3. **Every result is validated** against the closed schema on the way out. If a bug ever copied an extra field in, the call fails as `internal_error` rather than leaking it.
4. **Messages are written by the gateway** from a fixed table, one per error and notice code. A backend's own error text goes only to sirven's private operator log.
5. **Ranking is global** across backends, with random tie-breaking.
6. **Tracking links are relayed** through sirven, never a ride service's own link.

What remains visible, deliberately: the `provider` value (the person needs to know which car to get into) and `fulfillment.method` (the person must know when a human books on their behalf). A provider served by only one backend therefore reveals that backend's involvement by inference; that is a property of the market, not a leak in the contract, and the contract does not try to hide it.

The test `connectors/ride/tests/test_backend_blindness.py` runs two backends selling an identical product and asserts their options and bookings are equal field for field apart from identifiers and rank.

## Human-assisted fulfillment

Some rides are booked by a person on the sirven concierge team rather than by software. The contract treats this as a back-end detail, disclosed plainly where it operates:

- `fulfillment.method` is `human_assisted`, the option carries the `human_assisted` flag, and `fulfillment.disclosure` is a plain sentence the agent shows the person before they approve the booking. For automated options `disclosure` is `null`.
- The booking starts as `requested` with a `confirm_by` deadline, moves to `confirmed` when the person on the concierge team confirms it, and becomes `failed` (with nothing charged) if they decline or the deadline passes.

The contract carrying this shape does not ship the human-concierge tier. Per Jose's ship gate, that tier does not ship until the service-level targets, the concierge trust and safety protocol, and the user-facing disclosure of concierge involvement are all in place. The reference gateway enforces this: `RideConnector` drops every `human_assisted` option unless it is built with `allow_human_assisted=True`, which only the fake demo setup does.

## Errors

A failed call returns an error object instead of a result:

```json
{
  "contract_version": "1.0.0",
  "error": {
    "code": "quote_expired",
    "message": "That quote has expired. Ask for new quotes.",
    "retryable": false,
    "retry_after_seconds": null,
    "field": "/quote_id"
  }
}
```

`field` is a slash-separated path to the offending argument, or `null`. `not_cancellable` errors also carry `booking`. Over the model context protocol, an error is a tool result with `isError: true` and this object as its structured content, never a protocol-level error.

| Code | Calls | When | Retryable | What the agent does |
|---|---|---|---|---|
| `invalid_argument` | all | An argument is missing, malformed, outside its range, unknown, or a payment reference looks like a card number. | no | Fix the argument named in `field`. |
| `unsupported_contract_version` | all | `contract_version` names a major version this gateway does not speak. | no | Use the version in the error's `contract_version`. |
| `quote_not_found` | `book_ride` | No such `quote_id`. | no | Quote again. |
| `quote_expired` | `book_ride` | Past the option's `expires_at`. | no | Quote again. |
| `over_budget` | `book_ride` | The option is flagged `over_budget`. | no | Ask the person to raise the budget or pick another option. |
| `option_not_bookable` | `book_ride` | Another blocking flag is present. | no | Pick another option. |
| `option_unavailable` | `book_ride` | The ride is gone since the quote. | no | Quote again. The `quote_id` stays unbooked. |
| `price_changed` | `book_ride` | The ride service raised the price above the quote. | no | Quote again and show the person the new price. |
| `idempotency_conflict` | `book_ride` | The quote was already booked with a different `payment_reference`. | no | Use the original booking; do not book again. |
| `payment_required` | `book_ride` | The gateway requires held funds and none were referenced. | no | Hold funds through the money layer, then book. |
| `payment_declined` | `book_ride` | The held funds were declined. | no | Tell the person. |
| `booking_not_found` | `get_ride`, `cancel_ride` | No such `booking_id`. | no | Check the identifier. |
| `not_cancellable` | `cancel_ride` | The trip started, finished, or failed. | no | Tell the person; the error carries the booking. |
| `no_service` | `quote_ride` | No ride service serves this trip at this time. | no | Tell the person. |
| `blocked` | `quote_ride` | The ride services refused agent access. Nothing was routed around the refusal. | no | Tell the person plainly; do not try another route. |
| `rate_limited` | all | Too many requests. | yes | Wait `retry_after_seconds`, then retry. |
| `service_unavailable` | all | Ride services cannot be reached. | yes | Retry with backoff. |
| `internal_error` | all | A fault inside the connector. | yes | Retry with backoff; report if it persists. |

A failed `book_ride` never consumes the quote: the same `quote_id` can be booked on retry until it expires.

## Idempotency

- **`quote_ride`** has no side effects. Each call returns fresh options with new identifiers; earlier quotes stay valid until they expire.
- **`book_ride`** is keyed on `quote_id`. A quote is booked at most once. Repeating the call with the same `quote_id` and the same `payment_reference` (or none both times) returns the original booking with `replayed: true`, at any time, even after the quote expired. A different `payment_reference` returns `idempotency_conflict`. An agent unsure whether a booking went through repeats the call; it never quotes again to retry a booking.
- **`cancel_ride`** is idempotent. Repeating it returns the first cancellation unchanged, with `already_cancelled: true`.
- **`get_ride`** has no side effects.

## Versioning and stability

`contract_version` is a semantic version: major, minor, patch. The schema file records it as `x-contract-version`.

Requests may send a bare major (`"1"`) or a full version. A gateway refuses a different major with `unsupported_contract_version`. A gateway serving 1.4 accepts requests marked 1.0 and serves them.

**May change within a major version (minor release):**

- A new optional argument, ignored by gateways that predate it.
- A new result field. Because every result field is required, a new one is always present in newer results; agents must ignore result fields they do not know.
- A new value in a result enumeration that is documented as open to additions: `constraint_flags`, `notices`, `vehicle_class`, booking `status` (a new non-terminal status only). Agents treat an unknown constraint flag as advisory and an unknown non-terminal status as "in progress, keep polling".
- A new tool.

**Patch release:** wording in descriptions and this document, with no change in meaning.

**May not change without a new major version:**

- The meaning of any field, argument, or value.
- Which arguments are required, or making an optional argument required. (A gateway may require `payment_reference` by configuration, signalled by `payment_required`; that is not a contract change.)
- The set of error codes, or what any code means or whether it is retryable.
- Removing or renaming a tool, field, argument, or enumeration value.
- Units: minor units for money, offset timestamps.
- The idempotency and cancellation rules above.
- The blocking status of a constraint flag.

A new major version is published side by side (`schemas/v2/`) and the previous major stays served for at least six months after the new one ships.

## Model context protocol wiring

`connectors/ride/schemas/v1/tools.json` is the tool list a model context protocol server returns from `tools/list`: each tool's `inputSchema` and `outputSchema` is self-contained, with only the definitions it uses. It is generated from the schema, and a test fails if it falls out of date:

```sh
cd connectors/ride && python3 -m ride_connector.server --tools > schemas/v1/tools.json
```

`connectors/ride/ride_connector/server.py` is a minimal model context protocol server over standard input and output (protocol version 2025-06-18) that serves the four tools from the fake backends. Each tool result carries the payload both as `structuredContent` and as JSON text content.

## Building a backend

A backend implements `RideBackend` in `connectors/ride/ride_connector/backend.py`: `quote`, `book`, `cancel`, and `status`, speaking plain records (`BackendOption`, `BackendBooking`, `BackendStatus`, `BackendCancellation`) to the gateway. It raises `BackendError` with one of `blocked`, `no_service`, `unavailable`, `price_changed`, `payment_declined`, `not_cancellable`, `rate_limited`, `down`; the gateway maps those to contract codes. Free-form `detail` on a `BackendError` goes to the operator log only.

A backend never sees the person's preferences or budget, only the trip and window (`QuoteRequest`), and never mints anything the agent sees. It does report `human_assisted` honestly on every option it serves through a person.

## Running against the fake backend

```sh
cd connectors/ride/tests && python3 -m unittest            # the full suite
cd connectors/ride && python3 -m ride_connector.server      # a model context protocol server on standard input and output
```

In Python, `ride_connector.fake.demo_connector()` returns a gateway over two fake backends (an automated partner offering Uber and Lyft products, and a concierge desk offering Waymo), the controllable clock, and the backends. The concierge backend's `pending()`, `confirm(reference)`, and `decline(reference)` are the seam a rehearsal console drives. `connectors/ride/tests/test_round_trips.py` (`BarberScenarioTests`) walks the barber scenario: after the 2pm meeting, Waymo preferred, under 25 dollars.
