# worked examples

Four conversations, each with the calls behind it. Every request and result here comes from a real run of [examples/harness.py](examples/harness.py) against the fake demo backends; run it yourself to see the full results (`--json` prints them all). The fake backends price rides from straight-line distance, and their clock stands still at 1:00 pm Pacific time on October 12, 2026, so the times below are relative to that. Results are trimmed to the fields each example is about; `quote_id` and `booking_id` values differ on every run.

The trip in every example: from the office at the Ferry Building to a barber at Valencia Street and 18th Street in San Francisco, picked up between 3:00 and 3:20 pm.

## 1. the barber: a ride after a 2pm meeting, Waymo preferred, under 25 dollars

The person says: "Book me a ride to the barber after my 2pm meeting, Waymo preferred, under 25 dollars." The agent reads the calendar, finds the meeting ends at 3:00, and quotes a pickup from 3:00 to 3:20.

```json
quote_ride {
  "origin": {"label": "office", "address": "1 Ferry Building, San Francisco",
             "coordinates": {"latitude": 37.7955, "longitude": -122.3937}},
  "destination": {"label": "barber", "address": "Valencia Street and 18th Street, San Francisco",
                  "coordinates": {"latitude": 37.7617, "longitude": -122.4216}},
  "departure_window": {"earliest": "2026-10-12T15:00:00-07:00", "latest": "2026-10-12T15:20:00-07:00"},
  "user_preferences": {"preferred_providers": ["Waymo"]},
  "budget_ceiling": {"amount_minor": 2500, "currency": "USD"}
}
```

The top option, trimmed:

```json
{
  "quote_id": "qt_f56hzunev63sh7uzsjk5rdxp2z",
  "rank": 1,
  "bookable": true,
  "provider": "Waymo",
  "vehicle_class": "autonomous",
  "price": {"kind": "fixed", "amount": {"amount_minor": 1073, "currency": "USD"}, ...},
  "charge_terms": {"authorization_cap": {"amount_minor": 1073, "currency": "USD"},
                   "tip_ceiling": {"amount_minor": 0, "currency": "USD"}, ...},
  "estimated_pickup_at": "2026-10-12T15:00:00-07:00",
  "estimated_dropoff_at": "2026-10-12T15:11:00-07:00",
  "constraint_flags": ["human_assisted"],
  "fulfillment": {
    "method": "human_assisted",
    "disclosure": "A person on the sirven concierge team books this ride for you using the details shown here. They see the pickup, drop-off, and time, and nothing else."
  },
  "cancellation_policy": {"free_until": "2026-10-12T14:30:00-07:00",
                          "fee_after_free_period": {"amount_minor": 300, "currency": "USD"}},
  "expires_at": "2026-10-12T13:10:00-07:00"
}
```

Waymo ranks first because it is preferred and bookable. This option is carried out by the concierge team, so the agent shows the disclosure sentence before asking:

> The best match is a Waymo, 10.73 dollars, picks up around 3:00, arrives around 3:11.
> Also available: a Lyft at 9.51 dollars, same times.
> A person on the sirven concierge team books this ride for you using the details shown here. They see the pickup, drop-off, and time, and nothing else.
> Book the Waymo for 10.73 dollars? You can cancel free until 2:30.

The person says yes. The agent books before `expires_at`:

```json
book_ride {"quote_id": "qt_f56hzunev63sh7uzsjk5rdxp2z"}
```

```json
{
  "booking": {
    "booking_id": "bk_lzdlk7vo767mlbe4rxjuogrcxq",
    "status": "requested",
    "confirm_by": "2026-10-12T13:15:00-07:00",
    "provider": "Waymo",
    "tracking": {"status_call": "get_ride", "poll_interval_seconds": 30, "share_url": null, "vehicle_description": null},
    "final_charge": null,
    ...
  },
  "replayed": false
}
```

`requested` means not yet promised. The agent says so, and does not put the ride on the calendar as confirmed until `get_ride` says `confirmed`:

> Requested. The Waymo is not confirmed yet; I will tell you by 1:15, and I will look for another ride if it is not.

If the reply to `book_ride` had been lost, the agent calls `book_ride` again with the same `quote_id`. It gets the same booking back with `replayed: true`. One ride, not two.

## 2. a budget-constrained quote

The person says: "Get me there for 11 dollars at most, cheapest you can." The agent quotes the same trip with `"ranking": "cheapest"` and `"budget_ceiling": {"amount_minor": 1100, "currency": "USD"}`.

The Lyft fare is 9.51 dollars, under the limit. But the budget ceiling covers the tip too, and with the default 20 percent tip allowance the Lyft's `authorization_cap` is 11.41 dollars:

```json
{
  "rank": 2,
  "bookable": false,
  "provider": "Lyft",
  "vehicle_class": "standard",
  "price": {"kind": "fixed", "amount": {"amount_minor": 951, "currency": "USD"}, ...},
  "charge_terms": {"quoted_amount": {"amount_minor": 951, "currency": "USD"},
                   "tip_ceiling": {"amount_minor": 190, "currency": "USD"},
                   "authorization_cap": {"amount_minor": 1141, "currency": "USD"}, ...},
  "constraint_flags": ["over_budget"]
}
```

Only the Waymo, which takes no tips, fits. The over-budget options are still returned, ranked after the bookable one, so the agent can say what a higher limit would buy:

> Within 11 dollars: a Waymo, 10.73 dollars, picks up around 3:00. A person on the sirven concierge team books this ride for you using the details shown here. They see the pickup, drop-off, and time, and nothing else.
> A Lyft would be 9.51 dollars, but up to 11.41 dollars once a tip is allowed for, which is over your limit.
> Book the Waymo, or raise the limit?

If the agent tries to book an over-budget option anyway, the connector refuses:

```json
{"error": {"code": "over_budget", "message": "That option costs more than the budget allows.",
           "retryable": false, "retry_after_seconds": null, "field": "/quote_id"}}
```

If the person tips less than 20 percent, sending `"tip_ceiling_percent": 10` lowers every cap and may bring more options under the limit. That is the person's setting to choose, not the agent's.

## 3. a cancellation

The agent books a Lyft for the same trip (`"preferred_providers": ["Lyft"], "vehicle_classes": ["standard"]`). It is an automated booking, so it comes back `confirmed` at once, with `"free_until": "2026-10-12T14:30:00-07:00"`.

> Booked. Lyft picks you up around 3:00. Free cancellation until 2:30.

Later the meeting runs long. The agent asks, the person says cancel, and it is before 2:30:

```json
cancel_ride {"booking_id": "bk_we52zpmnixiqj2t55zxngz22wm", "reason": "plans_changed"}
```

```json
{
  "already_cancelled": false,
  "booking": {
    "status": "cancelled",
    "final_charge": {
      "fare": {"amount_minor": 0, "currency": "USD"},
      "tip": {"amount_minor": 0, "currency": "USD"},
      "cancellation_fee": {"amount_minor": 0, "currency": "USD"},
      "total": {"amount_minor": 0, "currency": "USD"},
      "amount_to_release": {"amount_minor": 1141, "currency": "USD"}
    },
    ...
  }
}
```

> Cancelled. No fee; the 11.41 dollars held for it is released.

Had it been after 2:30, `cancellation_fee` would be the policy's 5 dollars, and the agent would have said so before cancelling. Calling `cancel_ride` again returns the same booking with `already_cancelled: true` and changes nothing.

## 4. a blocked ride

This time every ride service for the trip refuses access to agents. (The harness shows this with `examples/fake_blocked_server.py`, the same demo server with every fake backend set to refuse.)

```json
{
  "contract_version": "1.0.0",
  "error": {
    "code": "blocked",
    "message": "The ride services for this trip refused access to agents. Nothing was routed around that refusal.",
    "retryable": false,
    "retry_after_seconds": null,
    "field": null
  }
}
```

`blocked` is not retryable, and the agent does not look for a way around it. It tells the person what happened and what they can still do:

> I could not get you a ride: the ride services for this trip refuse requests from agents, and I do not work around that. You can still book it yourself in the ride service's own app.

When only some services refuse, `quote_ride` still succeeds with the rest, and a `blocked` notice in `notices` says the list is incomplete. Pass that on when it matters to the choice ("some ride services refuse agents, so this list may be missing options").
