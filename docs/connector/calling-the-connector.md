# calling the ride connector

This page walks through the connector's calls in the order an agent makes them, and covers authentication, errors, idempotency, cancellation, and budget ceilings. Field names in `code` are literal contract identifiers. The contract is the document [docs/ride-connector-contract.md](../ride-connector-contract.md) together with the schema at `connectors/ride/schemas/v1/ride-connector.schema.json`, and the schema wins where they differ. This page explains how to use them and does not redefine anything.

Contract version documented here: `1.0.0`.

## connecting

The connector is a model context protocol server that speaks over standard input and output: one JSON message per line. Your agent's runtime starts it as a child process and lists its tools:

```bash
PYTHONPATH=connectors/ride python3 -m ride_connector.server           # serve the fake demo backends on the real clock
PYTHONPATH=connectors/ride python3 -m ride_connector.server --tools   # print the tool list and exit
```

Most agent runtimes take a server entry like this one:

```json
{
  "command": "python3",
  "args": ["-m", "ride_connector.server"],
  "env": {"PYTHONPATH": "/path/to/sirven/connectors/ride"}
}
```

Every tool result carries `structuredContent` (the result as JSON) and the same JSON as text. When `isError` is true, the result is an error payload (see [errors](#errors)).

## authentication

> **Moving.** Contract version `1.0.0` does not define authentication. This section is tracked against the contract and will follow it when it does.

What holds today, from the published server: the connector runs as a local child process of whatever starts it, with that account's access and nothing more. No call takes a token, key, or password as an argument. Do not add one to the arguments; the schema rejects unknown fields with `invalid_argument`.

## the calls

There are four tools. Three do the work and one reads.

| tool | what it does | changes anything? |
| --- | --- | --- |
| `quote_ride` | asks every ride service for options and returns them ranked | no |
| `book_ride` | commits one quoted option | yes: a ride is requested |
| `get_ride` | reads a booking's current state | no |
| `cancel_ride` | cancels a booking and settles what is owed | yes: the ride is cancelled |

Every call accepts an optional `contract_version`. Leave it out, or send the version you were built against; a different major version fails with `unsupported_contract_version`. Every result carries the server's `contract_version`.

### quote_ride

Required: `origin`, `destination`, `departure_window`, `budget_ceiling`. Optional: `user_preferences`.

```json
{
  "origin": {"label": "office", "address": "1 Ferry Building, San Francisco",
             "coordinates": {"latitude": 37.7955, "longitude": -122.3937}},
  "destination": {"label": "barber", "address": "Valencia Street and 18th Street, San Francisco",
                  "coordinates": {"latitude": 37.7617, "longitude": -122.4216}},
  "departure_window": {"earliest": "2026-10-12T15:00:00-07:00", "latest": "2026-10-12T15:20:00-07:00"},
  "user_preferences": {"preferred_providers": ["Waymo"]},
  "budget_ceiling": {"amount_minor": 2500, "currency": "USD"}
}
```

- A place needs an address, coordinates, or both; when both are given the coordinates win. `label` is shown back to the person and never used for routing.
- Times are dates and times with an explicit offset, like `2026-10-12T15:00:00-07:00`. An `earliest` in the past means as soon as possible.
- Money is always an integer in the currency's smallest unit: `2500` with `USD` is 25 dollars. Never send a floating point number.
- `user_preferences` is all optional. `preferred_providers` ranks those providers first but does not filter. `avoided_providers` filters them out entirely. `accessibility_needs` are hard requirements. `ranking` is `balanced` (the default), `cheapest`, or `fastest`. `tip_ceiling_percent` (default 20) sets the most the person will tip.

The result has `options` (ranked, best first), `notices`, and `quoted_at`. Each option has a `quote_id` and `rank`, who provides it (`provider`, `vehicle_class`), what it costs (`price`, `charge_terms`), when (`estimated_pickup_at`, `estimated_dropoff_at`, `estimated_pickup_wait_minutes`, `estimated_trip_minutes`), whether it can be booked (`bookable`, `constraint_flags`), how it is carried out (`fulfillment`), the `cancellation_policy`, and `expires_at`.

`provider` is a value, not a field per provider: the contract never says which backend served an option, and `quote_id` is an opaque token that does not encode it. Do not parse it.

`notices` tells you when the list is incomplete: some services refused agents (`blocked`), do not serve the trip (`no_service`), or could not be reached (`partial_results`). Pass a notice on to the person when it changes their choice.

### book_ride

Required: `quote_id`. Optional: `payment_reference`.

```json
{"quote_id": "qt_f56hzunev63sh7uzsjk5rdxp2z"}
```

`payment_reference` is an opaque handle from the sirven money layer for the funds held against this booking. It is never a card number or any card detail: a long run of digits is refused as `invalid_argument` before any ride service sees it. The fake demo server books without one; a connector configured to require held funds fails with `payment_required` when it is missing.

The order is: `quote_ride`, the person approves an option, the money layer holds that option's `charge_terms.authorization_cap` and returns a `payment_reference`, then `book_ride`.

> **Moving.** How an agent asks the money layer for that hold is the money layer's interface, which is not published yet. Tracked against it.

Book before `expires_at`. Quotes from the demo backends live ten minutes; after that, a quote that was never booked fails with `quote_expired` and you quote again. A quote that was already booked keeps replaying its booking even after `expires_at` (see [idempotency](#idempotency)), so retrying a lost `book_ride` reply is safe at any time. A failed `book_ride` never uses up the quote: the same `quote_id` can be booked on retry until it expires.

The result is a `booking` and a `replayed` flag (see [idempotency](#idempotency)). A booking starts in one of two states:

- `confirmed`: a ride is promised.
- `requested`: accepted but not yet confirmed. Bookings whose `fulfillment.method` is `human_assisted` sit here until a person on the sirven concierge team confirms them, by the time in `confirm_by`. If that time passes without confirmation the booking becomes `failed` and nothing is charged.

Do not tell the person a ride is booked until its status is `confirmed` or later.

### get_ride

Required: `booking_id`. Returns the `booking` as it stands now. Poll it no more often than `tracking.poll_interval_seconds`. `tracking.share_url`, when not null, is a page the person can open to follow the ride. `tracking.vehicle_description` fills in once a vehicle is known.

The states, in order: `requested`, `confirmed`, `driver_assigned`, `in_progress`, `completed`. `cancelled` and `failed` are terminal. When a booking reaches `completed`, `cancelled`, or `failed`, `final_charge` is set.

### cancel_ride

Required: `booking_id`. Optional: `reason`, one of `plans_changed`, `found_alternative`, `booked_by_mistake`, `pickup_too_late`, `other`.

The result is the `booking`, now `cancelled`, and an `already_cancelled` flag. See [cancellation](#cancellation).

## budget ceilings

`budget_ceiling` is the most the person will pay in total, tip included. The connector compares it with each option's `charge_terms.authorization_cap`, not with the headline price:

```
authorization_cap = fare_ceiling + tip_ceiling
fare_ceiling      = the fare, or for an estimate (price.kind "estimate") the most it can come to
tip_ceiling       = fare_ceiling times tip_ceiling_percent, or 0 where tips are not accepted
```

So a 9.51 dollar ride with the default 20 percent tip allowance has an authorization cap of 11.41 dollars, and a budget ceiling of 11 dollars flags it `over_budget`. Lower `tip_ceiling_percent` if the person tips less; that is their call, not the agent's.

`authorization_cap` is the most the money layer holds for the booking. The final charge is clamped to it: the fare never exceeds `fare_ceiling` and the tip never exceeds `tip_ceiling`. When the ride settles, `final_charge.amount_to_release` is what goes back.

The connector does not hide options over the ceiling. It returns them with `bookable: false` and the `over_budget` flag, ranked after every bookable option, so the agent can tell the person what a slightly higher limit would buy. Booking one fails with `over_budget`.

### constraint flags

Three flags block booking: `over_budget`, `outside_departure_window`, `accessibility_not_met`. An option with any of them has `bookable: false`, and `book_ride` on it fails (`over_budget` or `option_not_bookable`).

The rest are advisory, worth a short clause when you describe the option: `provider_not_preferred`, `vehicle_class_not_requested`, `long_pickup_wait`, `price_is_estimate`, `surge_pricing`, `shared_ride`, `human_assisted`.

## errors

Every failure has the same shape, and `isError` is true:

```json
{
  "contract_version": "1.0.0",
  "error": {
    "code": "over_budget",
    "message": "That option costs more than the budget allows.",
    "retryable": false,
    "retry_after_seconds": null,
    "field": "/quote_id"
  }
}
```

- Branch on `code`. It is stable within a major version.
- `message` is a plain sentence written for a person. You may show it as is.
- `retryable` says whether the same call can succeed later unchanged. When it is true, wait at least `retry_after_seconds` (when given) before trying again.
- `field` points at the argument that caused the error, when there is one.
- A `cancel_ride` that fails with `not_cancellable` also carries the current `booking`.

| code | retryable | what the agent does |
| --- | --- | --- |
| `invalid_argument` | no | fix the argument named in `field`; this is a bug in the call |
| `unsupported_contract_version` | no | send the major version the server speaks |
| `quote_not_found`, `quote_expired` | no | quote again |
| `over_budget` | no | ask the person to raise the limit or pick a bookable option |
| `option_not_bookable` | no | pick another option; tell the person which flag ruled it out |
| `option_unavailable`, `price_changed` | no | quote again and show the person the new options |
| `idempotency_conflict` | no | the quote was already booked with a different `payment_reference`; call `book_ride` again with the original `payment_reference` to get that booking back, and do not book a new option |
| `payment_required`, `payment_declined` | no | go back to the money layer; do not book without held funds |
| `booking_not_found` | no | check the `booking_id` |
| `not_cancellable` | no | the trip started or ended; tell the person and show the returned `booking` |
| `no_service` | no | tell the person no ride serves that trip at that time |
| `blocked` | no | tell the person the ride services refused agents; never try to get around it |
| `rate_limited`, `service_unavailable`, `internal_error` | yes | wait, then retry the same call |

`blocked` deserves its own sentence. It means the ride services for the trip refused access to agents, and the connector did not route around the refusal. Neither should the agent: no retries through another path, no alternate account, no workaround. Tell the person plainly and leave the choice with them.

## idempotency

Both calls that change something are safe to repeat.

- **`book_ride` is idempotent per `quote_id`.** Calling it again with the same `quote_id` and the same `payment_reference` (or none, both times) returns the same booking with `replayed: true`, and books nothing new. So when a reply is lost, call `book_ride` again with the same arguments; do not quote again and book a new option, or the person may end up with two rides. Calling it with a different `payment_reference` fails with `idempotency_conflict`.
- **`cancel_ride` is idempotent per `booking_id`.** Cancelling a booking that is already cancelled returns it with `already_cancelled: true` and changes nothing.
- `quote_ride` and `get_ride` change nothing and can be called any number of times. Each `quote_ride` mints new `quote_id`s, so book from the most recent quote you showed the person.

## cancellation

Each option and booking carries a `cancellation_policy`: `free_until` (a time) and `fee_after_free_period` (an amount). Before `free_until`, cancelling costs nothing. From then until the trip starts, cancelling costs the fee. Once the booking is `in_progress`, `completed`, or `failed`, `cancel_ride` fails with `not_cancellable`.

A successful cancel sets `final_charge`: `cancellation_fee` is what the person pays (never more than the policy said), and `amount_to_release` is what the money layer releases from the held funds.

A `requested` booking (for example one waiting on a concierge) can be cancelled the same way.

If the cancellation could not reach the ride service, `cancel_ride` returns a retryable error and the booking is not cancelled. Retry it, and never tell the person a ride is cancelled on an error.

On the Solo tier, cancelling is a real-world action like booking: ask the person first. Before `free_until`, say it is free; after, say the fee.

## the concierge, and what the agent must show

Some options are carried out by a person on the sirven concierge team instead of by software (in San Francisco first). Those options have `fulfillment.method` set to `human_assisted`, carry the `human_assisted` flag, and have a `fulfillment.disclosure` sentence. Show that sentence to the person before they approve the booking, exactly as the connector returns it; do not write your own. It is part of how the service works, not a headline: one plain sentence, where it applies, and nothing more. See [presenting-options.md](presenting-options.md).

The wording of the sentence is not part of the contract. It belongs to the concierge trust and safety protocol, and the sentence the reference connector returns today ("A person on the sirven concierge team books this ride for you.") is placeholder text awaiting Jose's approval. That is one more reason to pass along whatever the connector sends rather than a copy.

Human-assisted options only appear where the human-concierge tier is turned on. The tier does not ship until its service-level targets, its trust and safety protocol, and the user-facing disclosure are all in place, so the reference connector leaves these options out unless it is built with `allow_human_assisted=True`. The fake demo server turns it on for rehearsal; a production connector does not, today. An agent should handle both: a list with human-assisted options, and the same list without them.

## versioning

Contract version `1.0.0`. The full policy is in the contract document's versioning and stability section; what an agent needs from it:

- Send a bare major (`"1"`) or a full version as `contract_version`, or leave it out. A different major fails with `unsupported_contract_version`.
- Ignore result fields you do not recognize; new ones can appear in a minor release.
- Treat an unknown constraint flag as advisory, and an unknown booking status that is not terminal as "still in progress, keep polling".
- Arguments are closed. Send a newer optional argument only after a result's `contract_version` shows the connector speaks that minor version; an older connector refuses it with `invalid_argument` rather than ignoring it.
- If you validate results, validate against the schemas the running server returns from `tools/list`, not a copy you saved.
- Field meanings, required arguments, error codes and whether they are retryable, units, and the idempotency and cancellation rules only change with a new major version, and the previous major stays served for at least six months after.
