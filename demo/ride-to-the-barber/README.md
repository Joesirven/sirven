# Ride to the barber: the end to end rehearsal

"Book me a ride to the barber after my 2pm meeting, Waymo preferred, under $25", carried
through the sirven agent from the calendar back to the calendar, with the Waymo booking done
by a person at the concierge console.

This is a rehearsal. No real booking, no real money, no real Waymo account, no network call of
any kind. The first live fire is Jose's. Everything below that stands in for another thread's
work, or for the outside world, is listed under [Stand-ins](#stand-ins) and marked
`SUBSTITUTION` in its own file.

Needs only `python3` (3.9 or newer, standard library only). Run everything from this directory.

## Run it

### The recorded run, one terminal

A timed, clearly labeled operator plays the concierge. About 30 seconds:

```
python3 demo.py run --yes --scripted-concierge --record recordings/my-run --state recordings/my-run/state
```

`--yes` answers every question yes and says so on screen. `--scenario late_quote` and
`--scenario fare_over_cap` show the two honest failures (below).

### The rehearsal with a person at the console, two terminals

Terminal 1, Jose as the concierge:

```
python3 demo.py console --state /tmp/sirven-ride-rehearsal --name "Jose"
```

Terminal 2, the user talking to their agent:

```
python3 demo.py run --state /tmp/sirven-ride-rehearsal
```

Terminal 2 asks its two questions; answer `yes`. Terminal 1 then shows each request with the
rules and a running clock. For the quote: `y` to claim, then the price, minutes to pickup, and
trip minutes the Waymo app would show (press return to accept the rehearsal values: $21.40, 7,
16). For the booking: `y` to claim, then the confirmation, the fare, and the trip share link.
To decline, answer `d` and give the reason; the agent tells the user. Add `--once` to the
console to leave after one ride.

### The gates alone

```
python3 demo.py gates
```

Exits 0 only when the human-concierge gate is open. Today it exits 1.

## The demo script

What to show, in order, and what each beat proves. The recorded transcript at
[recordings/2026-10-11-scripted-normal/transcript.txt](recordings/2026-10-11-scripted-normal/transcript.txt)
follows it line for line.

1. **The run states what it is.** Tier Solo, nothing real, and the list of stand-ins.
2. **The ship gates, before anything happens.** The human-concierge gate is printed
   closed, with each of its three items and what is missing: thread 10's service-level
   monitoring, thread 10's trust and safety protocol, and Jose's approval of the disclosure
   copy. The peer routing gate is shown as not exercised, because Solo routes nothing through
   peers. The rehearsal demonstrates the gates; it does not waive them.
3. **The request and the calendar.** The agent finds the 2:00pm design review (ends 2:45pm),
   sees the 3:30pm haircut, and works out: leave between 2:50pm and 3:05pm, arrive by 3:25pm.
4. **Consent before a person sees the trip.** The disclosure says plainly that a person books
   Waymo rides, and exactly what they will and will not see. Answering no is shown in
   `--no-concierge`: the trip never reaches the queue and Waymo is reported unavailable.
5. **Quotes through one connector.** `quote_ride` returns Waymo, UberX, Lyft, and Uber Black,
   ranked, with flags (`preferred_provider`, `over_budget`). The agent cannot tell that the
   Waymo option came from a person and the others from a partner backend. On the concierge
   side, the quote lands well inside the 30 second target.
6. **The choice and the reason.** Waymo One at $21.40: under $25, on time, and preferred.
7. **Solo asks before every real-world action.** The booking question names the price, the
   pickup, the arrival, the card's limit, and that a concierge books it.
8. **The money.** A one-time test card, limited to the quoted $21.40 plus a $0 tip ceiling,
   ride services only. Its charge record pairs the amount with the reason.
9. **The concierge books.** The console shows the card's last four digits and limit, never the
   number. The booking lands inside the 90 second target, and the fare is authorized against
   the card's limit.
10. **The user is told who.** "Booked by Jose (rehearsal), a sirven concierge."
11. **The calendar write-back.** "Ride to Mission Street Barbers (Waymo)", 2:57pm to 3:13pm,
    with the booking, the confirmation, the tracking link, the free cancellation time, the
    card, and why. Also written as a standard calendar file, `ride.ics`.
12. **The service levels.** Both legs, timed, against their targets.

The two failures, both recorded:

- **`late_quote`**: the concierge claims the request and never quotes. At 30 seconds the agent
  withdraws it, records the missed target, tells the user it will not keep trying behind their
  back, and offers UberX instead, asking first.
- **`fare_over_cap`**: the concierge reports a $26.90 fare against a $21.40 card. The card
  declines it, the agent releases the hold, nothing is charged, the console is told to cancel
  the ride, and the agent offers the next option without booking it.

## Recordings

Each directory holds `transcript.txt` (lines with seconds since the start), `run.cast`
(replay with `asciinema play run.cast`), `events.jsonl` (one JSON object per step), and
`state/` (the calendar copy, `ride.ics`, the charge records, the service-level log, and the
concierge request as the queue left it).

| Recording | Result | Quote | Booking |
| --- | --- | --- | --- |
| [2026-10-11-scripted-normal](recordings/2026-10-11-scripted-normal/transcript.txt) | Waymo booked through the concierge, exit 0 | 8.4 seconds of 30 | 16.2 seconds of 90 |
| [2026-10-11-scripted-late_quote](recordings/2026-10-11-scripted-late_quote/transcript.txt) | Waymo withdrawn, UberX booked with consent, exit 0 | missed after 30 seconds | not used |
| [2026-10-11-scripted-fare_over_cap](recordings/2026-10-11-scripted-fare_over_cap/transcript.txt) | fare declined, card released, nothing booked, exit 4 | 8.3 seconds of 30 | 16.2 seconds of 90 |

These were made with the scripted operator. A recording with Jose at the console is the next
one to make (see below).

## Stand-ins

| Stands in for | Here | Replace with |
| --- | --- | --- |
| Thread 08, the ride connector contract | `ride_demo/connector.py`: the three-call shape from the thread instructions | `docs/ride-connector-contract.md` and its schemas, once published |
| Thread 09, the official-partner backend | `ride_demo/partner_backend.py`: Uber and Lyft from `fixtures/partner-quotes.json`, invented prices | thread 09's adapters in sandbox |
| Thread 10, the concierge queue | `ride_demo/concierge_queue.py`: one JSON file per request, locked and written atomically | thread 10's queue tooling |
| Thread 10, the trust and safety protocol | `RULES` in `ride_demo/console.py`: the floor the thread 10 instructions set | thread 10's protocol under `concierge-ops/` |
| Thread 10, service-level monitoring | `ride_demo/service_levels.py`: a timing log and on-screen verdicts | thread 10's monitoring and breach alerts |
| Thread 11, per-booking virtual cards | `ride_demo/payment.py`: an in-memory test card, no Stripe call | thread 11's Stripe Issuing test mode |
| The user's calendar | `fixtures/calendar.json`, written back to a copy and `ride.ics` | a calendar connector (no thread owns this yet) |
| The agent reading the request | `ride_demo/request.py`: fixed patterns | the personal agent's language model through the sirven runtime (thread 01) |
| The Waymo app | the person (or scripted operator) at the console types what it shows | the concierge's real Waymo app |

## What remains between this rehearsal and a live fire

The ship gate first. The human-concierge tier does not ship, and a live fire does not start
(`demo.py run --live` refuses), until all three are in place:

1. Thread 10 commits the concierge trust and safety protocol under `concierge-ops/`.
2. Thread 10 commits service-level monitoring with breach alerts under `concierge-ops/`.
3. Jose approves [copy/concierge-disclosure.md](copy/concierge-disclosure.md) and sets its
   status line to `status: approved`. That file is every word the user sees about the
   concierge; the demo reads from it, so the run cannot drift from what he approves.

Then the dependencies:

4. Thread 08 publishes the contract and schemas. Swap `connector.py`'s field checks for the
   schemas and rename any field that differs; the demo reads only the fields listed at the top
   of that file. One design point for thread 08: the concierge backend needs the held card at
   booking time, and the stand-in passes the quote identifier to the backend for that lookup.
   The contract should say how a backend finds its booking's card without the agent seeing it.
5. Thread 11 delivers test-mode minting, the cap, the ride-services restriction, and webhook
   reconciliation, and settles on ride completion (the rehearsal stops at authorized). Stripe
   Issuing approval and live mode wait for Jose.
6. Thread 09 is off the critical path for a Waymo live fire, but the fallback options come
   from it; until it lands, a live fire should show no fallback rather than fixture prices.

Then the questions the rehearsal cannot answer, each to verify before Jose's first ride:

7. **How the concierge pays Waymo without seeing the card number.** The disclosure promises the
   concierge never sees it, and the console shows only the last four digits. A real booking
   needs the per-booking card on the concierge's Waymo account. Either that happens without a
   person seeing the number (an issuer-to-wallet push, for example), or the disclosure changes.
8. **How the rider gets into the car.** If the booking lives in the concierge's Waymo account,
   the rider still needs to be identified at pickup and to unlock and start the ride. Verify
   what Waymo supports for booking on someone else's behalf before the first live fire.
9. **Waymo's real cancellation terms and trip sharing.** The rehearsal assumes free
   cancellation until two minutes before pickup and a shareable trip link, and says so on
   screen and on the calendar. Both need Waymo's actual terms.
10. **Service area.** Confirm both addresses (or Jose's real ones) are inside Waymo's San
    Francisco service area.
11. **The concierge's Waymo account.** Thread 10's account-provisioning runbook, and Jose's own
    hiring decision. In rehearsal, Jose is the concierge.
12. **A real calendar.** No thread owns a calendar connector. The live fire needs read access to
    find the meeting and write access for the ride; until then, Jose can import `ride.ics` by hand.
13. **The agent and the runtime.** The live request is read by the personal agent's language
    model, through the sirven runtime (thread 01). This rehearsal makes no web request at all,
    so it does not exercise the Solo egress path.
14. **A rehearsal with Jose at the console.** Everything here is tested with a scripted
    operator and with piped keyboard answers; a recording with Jose operating the console and
    the Waymo app open (booking nothing) is the last step before a live fire.

## Tests

```
python3 -m unittest discover -s tests
```

From the repo root, `make test` runs them too (`tests/unit/test_ride_demo.sh`). They cover the
request reading, ranking and the budget (the tip ceiling counts), backend blindness, booking
idempotency and cancellation, the card's cap and category, a late answer never overwriting a
withdrawal, the gate staying closed until all three items are in place, every end to end path
above, a person driving the interactive console, and Jose's language rules on every file here.
