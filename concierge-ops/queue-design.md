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

## 5. Dependencies on other threads

- **Ride connector contract.** Two things to ask for:
  1. *Time to quote.* A concierge quote can take up to 30 seconds. Either `quote_ride` waits
     that long, or the contract allows a pending option that fills in later. Without one of
     these, concierge options can never appear.
  2. *Disclosure without naming the backend.* The contract keeps the backend invisible to the
     agent, but the user must be told a person is involved and who. The proposal: a
     backend-neutral optional field on a quoted option (for example `human_involvement`, with
     the disclosure text and the person's display name) that the agent must show. This keeps
     backend blindness and makes disclosure part of the contract.
- **Consent.** Consent must exist before routing, which means it is collected ahead of time (a
  standing, revocable setting) and restated per ride. **Jose decides** standing consent with a
  per-ride notice, or a per-ride question every time.
- **Money layer.** The concierge's service account pays with a sirven card; the per-booking
  virtual card fits if the service accepts card changes per booking. Until then, test mode.
- **End-to-end demo.** Can use the prototype as its scripted console; the demo's rehearsal
  should include one handback and one breach to show the gates working.
