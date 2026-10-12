# Official-partner ride backend

`ride_partner` is a ride backend for the sirven ride connector: Uber for Business and Lyft
Business, reached through their partner interfaces. Sirven is merchant of record: the user pays
sirven, and sirven pays the carrier through its corporate account with that carrier.

Status: fixtures only. No live rides, no live charges, nothing submitted to either carrier.

## How it fits the contract

Thread 08 owns the contract: `docs/ride-connector-contract.md`, `schemas/v1/`, and the gateway in
`ride_connector/`. The gateway is the only thing an agent talks to. It serves `quote_ride`,
`book_ride`, `cancel_ride`, and `get_ride`, mints every identifier, ranks and flags options, and
validates every result against the schema. `PartnerRideBackend` implements the gateway's
`RideBackend` interface (`quote`, `book`, `cancel`, `status`) and nothing more.

- `ride_partner/backend.py`: `PartnerRideBackend`.
- `ride_partner/carriers.py`: `UberForBusiness` and `LyftBusiness`, one adapter per carrier.
- `ride_partner/transport.py`: fixture, sandbox, and live transports.
- `ride_partner/fixtures/`: carrier scenarios (standard, booking fails, trip underway,
  completed, cancel with a fee, carrier down).
- `tests/test_partner_backend.py`: the suite, through the gateway, with every payload checked
  against the contract schema. `make test` runs it through `tests/unit/test_ride_partner.sh`.

From `connectors/ride`:

    cd tests && python3 -m unittest test_partner_backend
    python3 -m ride_partner        # a printed quote, book, and cancel round trip

## Backend blindness

The gateway makes backend identity invisible by construction; this backend keeps its side:

- Carrier fare identifiers, cost tokens, and trip identifiers stay in `PartnerRideBackend`.
  The option and booking references it hands the gateway are plain counters.
- Carrier product names (UberX, Lyft XL) become contract vehicle classes (standard, large).
- Carrier error text goes to the operator log as `<carrier> answered <status>` and becomes a
  backend error reason; the gateway writes the message the agent sees.
- The provider (Uber, Lyft) is an ordinary returned value, as the contract allows.

`BlindnessTests` drives every scenario through quote, book, status, and cancel, fails if any
carrier token, carrier identifier, or integration word reaches a payload, and checks that an
option from this backend has the same shape as one from the contract's fake backend.

## Money

- Booking refuses without a `payment_reference` (funds the money layer, thread 11, has already
  held). `build_connector` sets the gateway to require it, and the backend refuses on its own
  too, so sirven never fronts a fare on its corporate account. The reference is kept with the
  booking for reconciliation and never sent to a carrier.
- Uber Guest Rides fares are upfront, so they are `fixed`. Lyft gives a range, so its options
  are `estimate`, priced at the low end with the high end as the fare ceiling; the authorization
  cap the gateway computes covers the ceiling plus the tip ceiling.
- A completed Uber trip reads as `in_progress` until Uber's receipt exists, so the gateway never
  settles a zero fare.

## Blocked seams

Each is explicit in code; search for the names given.

1. **Sandbox access, blocked on partner approval (thread 07).** `SandboxTransport` raises
   `PartnerApprovalRequired` until `SIRVEN_UBER_FOR_BUSINESS_SANDBOX_TOKEN` or
   `SIRVEN_LYFT_BUSINESS_SANDBOX_TOKEN` is set, which only an approved application can supply.
   Store them with `bb secret`; never commit them. The transport takes a ready bearer token; the
   client-credentials exchange for it is written once partner documentation confirms the flow.
   The agent sees `service_unavailable`.
2. **Live calls, blocked on Jose's approval** of the partner accounts and the money layer.
   `transport_for(..., "live")` always raises `LiveCallsBlocked`, and `SandboxTransport` refuses
   Uber's production host. Lyft's sandbox shares its production host, so a credential alone
   cannot prove a call is a sandbox call: in sandbox mode `LyftBusiness` quotes but refuses to
   create or cancel trips (`_refuse_unconfirmed_sandbox`) until partner documentation names a
   separate sandbox host or credential marker.
3. **Fixtures are written, not recorded.** They follow the carriers' public references as read
   on 2026-10-11 (Uber Guest Rides: `/v1/guests/trips/estimates`, `/v1/guests/trips`; Lyft:
   `/cost`, `/eta`, `/rides`, `/rides/{id}/cancel`). Assumed until partner documentation: the
   Lyft Concierge path prefix (`/v1/concierge/...`), Lyft ride status names and price fields,
   and the Uber receipt fields. Re-record every scenario once seam 1 opens and fix the adapters
   wherever the recordings disagree.
4. **Carrier policy constants to confirm** under the partner agreements: the two-minute free
   cancellation window and the five-dollar late cancellation fee for both carriers, and the
   five-minute Lyft cost token lifetime.
5. **Uber cancellation fee reconciliation.** Uber names a late cancellation fee on the receipt,
   after the fact. The backend reports the policy fee the gateway expects; comparing it with
   the receipt waits on sandbox access and the receipt webhook.
6. **Rider identity.** The contract's backend calls carry no rider, but carriers need the
   rider's name and phone number. One backend instance serves one person (`rider=`). Raised
   with thread 08.
7. **Geocoding.** Carriers need coordinates. An address-only place needs a `geocode` function;
   without one the backend answers `no_service` for that quote.
8. **Partial carrier failure.** When one carrier fails and the other answers, the gateway sees
   one healthy backend, so the agent gets no `partial_results` notice. Raised with thread 08.
9. **Durable storage.** Options and bookings live in memory. They must survive a restart before
   anything books a real ride.
10. **Corporate account references** come from `SIRVEN_UBER_FOR_BUSINESS_ORGANIZATION` and
    `SIRVEN_LYFT_BUSINESS_ORGANIZATION` outside fixture mode; they exist once the accounts do.
11. **Scheduled rides.** Only immediate pickups are quoted. A departure window that starts later
    gets every option flagged `outside_departure_window` by the gateway.
