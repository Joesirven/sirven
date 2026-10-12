# Official-partner ride backend

The ride connector's three calls (`quote_ride`, `book_ride`, `cancel_ride`) served through
Uber for Business and Lyft Business partner interfaces. Sirven is merchant of record: the user
pays sirven, and sirven pays the carrier through its corporate account with that carrier.

Status: fixtures only. No live rides, no live charges, nothing submitted to either carrier.

## Layout

- `ride_partner/contract.py`: the contract as this backend reads it. **Provisional**: thread 08
  owns the published contract (`docs/ride-connector-contract.md` and its schemas), which had not
  landed when this was written. Every field name, error code, and identifier format a caller can
  see lives in this one file, so adopting the published schemas is a change here plus the tests.
- `ride_partner/backend.py`: `PartnerRideBackend`, the three calls. Quotes from both carriers are
  normalized, flagged, and ranked; booking authorizes the user's payment before the carrier is
  asked, and releases it if the carrier fails; cancelling reconciles the authorization.
- `ride_partner/carriers.py`: `UberForBusiness` and `LyftBusiness`, one adapter per carrier.
- `ride_partner/transport.py`: fixture, sandbox, and live transports.
- `ride_partner/fixtures/`: recorded scenarios per carrier.
- `tests/test_backend.py`: the suite. `make test` runs it through `tests/unit/test_ride_partner.sh`.

Run the suite or a printed round trip from this directory:

    python3 -m unittest discover -s tests
    python3 -m ride_partner

## Backend blindness

The calling agent must not be able to tell this backend produced a quote. How that holds:

- The contract validators are strict: no unknown fields, no missing fields. Every response is
  validated before it is returned, so this backend's output has exactly the contract's shape.
- Quote and booking identifiers are random (`quote_` or `booking_` plus 32 hexadecimal
  characters). Carrier fare identifiers, cost tokens, and trip identifiers stay inside.
- Carrier product names (UberX, Lyft XL) become contract vehicle classes (standard, large).
- Errors are contract codes with a fixed message per code. Carrier error text is logged for
  operators and never returned.
- Quote lifetime is capped at 120 seconds for every carrier, and tracking is a sirven path
  (`/rides/<booking_id>`), not a carrier link.
- The provider (Uber, Lyft) is an ordinary returned value, as the contract brief allows.

`BlindnessTests` drives every scenario and fails if any carrier token, carrier identifier, or
integration word appears in anything a caller received.

## Money, as the money layer (thread 11) sees it

`PartnerRideBackend` takes a `payments` object with `authorize(reference, amount_minor,
currency)`, `capture(handle, amount_minor)`, and `release(handle)`. Booking authorizes the quoted
price plus the tip ceiling. A cancel with no fee releases the hold; a cancel with a fee captures
only the fee. A Lyft range is quoted, and authorized, at its upper bound and flagged
`price_is_upper_bound`. `service_fee_minor` (what sirven adds to the fare) is zero: that is a
pricing decision for Jose.

## Blocked seams

Each is explicit in code; search for the names given.

1. **Sandbox access, blocked on partner approval (thread 07).** `SandboxTransport` raises
   `PartnerApprovalRequired` until `SIRVEN_UBER_FOR_BUSINESS_SANDBOX_TOKEN` or
   `SIRVEN_LYFT_BUSINESS_SANDBOX_TOKEN` is set, which only an approved application can supply.
   Store them with `bb secret`; never commit them. The transport takes a ready bearer token; the
   client-credentials exchange for it is written once the carriers' partner documentation
   confirms the flow.
2. **Live calls, blocked on Jose's approval** of the partner accounts and the money layer.
   `transport_for(..., "live")` always raises `LiveCallsBlocked`, and `SandboxTransport` refuses
   Uber's production host. Lyft's sandbox shares its production host, so for Lyft only the
   sandbox credential keeps calls in the sandbox: treat that token's provenance with care.
3. **Fixtures are written, not recorded.** They follow the carriers' public references as read
   on 2026-10-11 (Uber Guest Rides: `/v1/guests/trips/estimates`, `/v1/guests/trips`; Lyft:
   `/cost`, `/eta`, `/rides`, `/rides/{id}/cancel`). Lyft's Concierge path prefix
   (`/v1/concierge/...`) and some field names are assumed. Re-record every scenario against the
   sandboxes once seam 1 opens, and fix the adapters wherever the recordings disagree.
4. **Carrier policy constants to confirm** under the partner agreements: the two-minute free
   cancellation window for both carriers, and the five-minute Lyft cost token lifetime.
5. **Uber cancellation fees after the free window** arrive later on the trip receipt. The cancel
   response says `pending_receipt` and the hold stays open until `settle_receipt` is called. The
   receipt webhook handler that calls it waits on sandbox access.
6. **Durable storage.** Quotes and bookings live in memory. They must survive a restart before
   anything books a real ride.
7. **Corporate account references** come from `SIRVEN_UBER_FOR_BUSINESS_ORGANIZATION` and
   `SIRVEN_LYFT_BUSINESS_ORGANIZATION` outside fixture mode; they exist once the accounts do.
8. **Scheduled rides.** Only immediate pickups are quoted. A departure window that starts later
   flags every option `pickup_outside_window`; scheduled pickups need confirmed partner support.
