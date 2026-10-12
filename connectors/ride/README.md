# Ride connector and the iPhone ride backend

`ride_connector/` is the sirven ride connector: the contract gateway an agent talks to
(`docs/ride-connector-contract.md`, `schemas/v1/`). It serves `quote_ride`, `book_ride`,
`cancel_ride`, and `get_ride`, mints every identifier, ranks and flags options, and validates
every result against the schema. Backends implement `RideBackend` (`quote`, `book`, `cancel`,
`status`) in `ride_connector/backend.py`.

`ride_phone/` is the ride backend sirven ships: `PhoneRideBackend` books a ride in the owner's
own Uber or Lyft app, on the owner's own iPhone, plugged into the Mac, through the phone bridge
(`lib/phone_bridge.py`, `docs/phone-interface.md`). The owner's own account, the owner's own
payment method, the owner's own session. No partner integration, no corporate account, and no
card issued by sirven: the earlier partner backend and the Stripe Issuing virtual cards are out
of the booking path.

Status: tested end to end against a fake phone. Not yet run against a real iPhone, a real Uber
or Lyft app, or a real charge.

## How a booking happens

1. **The map.** Once a day, when the owner first connects the phone, `sirven phone onboard`
   builds a semantic map of the ride apps (`lib/phone_map.py`). The backend reads it through
   `GET /v1/phone/map` to learn which installed app is which, where the destination field is,
   and which control leads back to that screen from wherever the app was left. Screens that
   only appear after typing a destination are read live and named with the same roles.
2. **Quote.** Open the app, enter the destination, read each priced row (product, price,
   minutes away, trip minutes). Each becomes an option with the provider (Uber or Lyft) as a
   plain value.
3. **Book.** Re-read the price. If it rose above the quote or the authorization cap, stop with
   `price_changed`: nothing is booked at a price nobody approved. Then choose the row and tap
   the request button, which the bridge holds as money bearing.
4. **The owner approves, live, twice, for this one purchase.** First `sirven phone approve
   HOLD` (the bridge's money hold). Then the phone shows its own face recognition or Apple Pay
   prompt, and only the owner answers it, on the phone. While it is up the bridge refuses every
   touch, so nothing in sirven can press it. A refusal at either step books nothing and returns
   `payment_declined`.
5. **Confirm.** The backend waits, touching nothing, until the app shows the trip, then reads
   the vehicle and pickup time.

`status` reads the trip screen; `cancel` taps the app's cancel control, and a cancellation with
a fee is held for the owner like a booking.

## Backend blindness

The app's bundle name, row labels, and screen text stay in `PhoneRideBackend`. The references
it hands the gateway are random tokens. The phone bridge's refusals go to the backend's private
log; the gateway writes what the agent sees.

## Running it

    python3 -m ride_connector.server --phone    # the model context protocol server over the phone

The bridge must be serving (`sirven phone serve`), a phone session open (`sirven phone allow`),
and the map built (`sirven phone onboard`). `make test` runs the end to end scenarios in
`tests/unit/test_phone_ride.sh` (book with both approvals, a refused hold, a decline on the
phone, a price that rose, cancel, and the payment sheet never touched), through
`tests/phone_ride_check.py`.

## Open seams

1. **The phone's own prompt appears only for Apple Pay.** A ride app charging a saved card may
   book on the request tap with no prompt on the phone; then the money hold is the only
   approval. The owner sets Apple Pay as the app's payment method for the prompt to appear.
   Whether sirven should refuse to book when no prompt appeared is a decision for Jose.
2. **Real app labels are not verified.** The quote reads rows shaped like "UberX, 4 min away,
   14 min trip, $18.40", and the roles match words like Request and Cancel ride. The real
   apps' accessibility labels must be checked on a real phone and the patterns adjusted.
3. **Pickup is where the phone is.** The app proposes the pickup from the phone's location;
   the backend does not yet type a different origin.
4. **Cancellation terms** (two minutes free, five dollars after) are assumptions until checked
   against each service's published terms.
5. **One owner, one phone, in memory.** Options and bookings live in memory and must survive a
   restart before anything books a real ride.
