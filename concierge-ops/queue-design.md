# Concierge queue design and tooling proposal

How a ride request reaches a concierge, how it is claimed, timed, and handed back. The
prototype is [tools/concierge_queue.py](tools/concierge_queue.py), tested by
`tests/unit/test_concierge_queue.sh` (run `bash tests/run.sh concierge`).

## 1. Service-level targets

From the scope, and the definitions this design commits to:

| Target | Clock starts | Clock stops | Limit |
| --- | --- | --- | --- |
| Quote | The request enters the queue (`submit`) | The quote reaches the agent (`quote`) | under 30 seconds |
| Booking | The user accepts the quote (`accept`) | The booking is confirmed (`book`) | under 90 seconds |

The booking clock starts at acceptance, not at submit, so the user's own thinking time never
counts against the concierge. **Jose decides** whether these definitions match what he meant.
Section 5 covers the other shape, where software quotes and a person only confirms.

## 2. The flow

```
user's personal agent
   │  quote_ride (ride connector contract)
   ▼
concierge backend ── consent recorded? ── no ──▶ not routed here; agent uses other backends
   │ yes
   ▼
queue: submit ─▶ claim ─▶ quote ─▶ (user accepts) ─▶ accept ─▶ book ─▶ closed
                  │  ▲       │                                   
                  ▼  │       └──▶ handback (with a reason) ─▶ closed
               release                                          
```

1. **Request arrives.** The agent calls `quote_ride` through the ride connector. When the
   concierge backend is a candidate (Waymo preferred, inside San Francisco, inside covered
   hours), and only if the user's consent is recorded, the request is submitted to the queue.
2. **Concierges are notified.** Every concierge on shift gets a push notification with no trip
   detail in it ("a ride request is waiting"). Trip details appear only inside the console.
3. **Claim.** The first concierge to tap claims it; claims are exclusive (a second claim is
   refused). The user is told a person is booking and sees the concierge's display name.
4. **Quote.** The concierge opens the service's app, enters the trip, and types the price and
   estimated arrival into the console. That goes back to the agent as one ranked option.
5. **Accept.** The agent presents options to the user; the user picks the concierge's one.
6. **Book.** The concierge books in the app and confirms in the console, with the tracking
   link and cancellation window the contract's `book_ride` returns.
7. **Handback** at any point before booking, with one of six reasons: `unavailable`,
   `over_budget`, `user_cancelled`, `safety`, `consent_withdrawn`, `other`. The agent tells the
   user plainly. A handback is a correct outcome, not a failure.
8. **Release.** A concierge who claimed but cannot continue (a call, a dead battery) releases
   it to the queue; the quote clock keeps running.

Cancellation after booking (`cancel_ride`) goes to the concierge who booked if they are on
shift, otherwise to whoever is; it is outside the two targets but tracked in the log.

## 3. What the prototype does

- One append-only JSON lines event log. Commands replay the log and append; nothing is ever
  rewritten, so the log is also the audit trail.
- Enforces the rules that protect users: no submit without consent, no claim by anyone not
  active on the roster, no double claim, no booking before acceptance, no events back in time,
  handback reasons from a fixed list.
- `check` prints warnings and breaches for open requests and exits with status 2 when there
  are any, so a scheduler can page on it. `report` prints the weekly summary.
- Holds no trip content (see [trust-and-safety.md](trust-and-safety.md), section 4).

It is a single-machine prototype for rehearsals and the work sample, not the production queue.
The end-to-end demo thread can drive it as the scripted concierge console's back end.

## 4. Tooling proposal for production

**Keep the event model, change the plumbing.**

- **Store:** the same events in a small database table (one row per event, append-only, with
  the request key and timestamp indexed). Same replay logic.
- **Concierge console:** a mobile-first web page. One screen per claimed request: trip fields
  from section 3 of the protocol, a quote field, and three buttons (quote, booked, hand back).
  Sign-in per concierge with two-step verification.
- **Notifications:** web push or a paging app to concierges on shift. No trip content in the
  notification.
- **Timers:** alerts must fire within seconds, which a schedule that runs every few minutes
  cannot do. The service holds a timer per open request and raises the `unclaimed` warning at
  10 seconds, the `slow_quote` warning at 15 seconds after claim, and breaches at the targets.
  A minute-level `bb automation` running `check` is a fine backstop for the rehearsal phase.
- **Build, not buy.** A help-desk or on-call product would add a vendor that sees trip
  content. The surface is small enough to build, and it keeps trip data in one place.

## 5. Two ways in: a person quotes, or a person only confirms

The ride connector contract thread (branch `model-context-protocol-connector-contract-for-ri-thr_jzapafb9uf`,
commit 5e9d5f9, not yet merged) already settled a shape for human-assisted rides that differs
from the flow in section 2:

- Software produces the quote for a concierge-served option (an estimate with a fare ceiling).
  No person touches the quote, so the 30 second quote target is met by software.
- The option carries `fulfillment.method` of `human_assisted` and a `fulfillment.disclosure`
  sentence the agent must show before the user approves.
- `book_ride` returns a booking in state `requested` with a `confirm_by` deadline. A person
  confirms it, or it becomes `failed` with nothing charged.

The prototype supports both: `submit --stage booking` enters a request that software quoted
and the user already accepted, so the booking clock starts at once and there is no quote step.

**Recommendation: adopt the contract's shape.** It is better for the user. A concierge sees only
trips the user has already chosen, never trips that were merely being priced, and consent is
the disclosure shown at approval. The cost: an estimate can be wrong. If the price in the
service's app is above the fare ceiling, the concierge hands back with `over_budget` and the
agent asks the user again. **Jose decides.**

Under that shape, two settings in the contract thread need to match this design:
1. `confirm_by` should sit at the 90 second booking target (the reference fake uses 15
   minutes). A request that misses it fails cleanly instead of leaving the user waiting.
2. The concierge's display name has no field yet. The protocol requires the user to see it once
   a person has the request; a backend-neutral optional field on the `requested` booking would
   carry it without naming any backend.

## 6. Dependencies on other threads

- **Ride connector contract:** the two settings above.
- **Consent.** Under the contract's shape, consent is the disclosure shown at approval, plus a
  standing setting so the user can turn concierge-served options off entirely. Under the
  person-quotes shape, consent must exist before routing, so it has to be a standing, revocable
  setting with a per-ride notice. **Jose decides** along with the shape.
- **Money layer.** The concierge's service account pays with a sirven card; the per-booking
  virtual card fits if the service accepts card changes per booking. Until then, test mode.
- **End-to-end demo.** The contract's fake concierge desk exposes `pending()`, `confirm()`, and
  `decline()` for a rehearsal console. That console can also write `submit --stage booking`,
  `claim`, and `book` or `handback` events to this prototype, so the rehearsal produces real
  service-level numbers. The rehearsal should include one handback and one breach to show the
  gates working.
