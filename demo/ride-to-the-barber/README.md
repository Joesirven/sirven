# Ride to the barber: the end to end rehearsal

"Book me a ride to the barber after my 2pm meeting, Waymo preferred, under $25", carried
through the sirven agent from the calendar back to the calendar, with the Waymo booking done
by a person at the concierge console, and Uber and Lyft booked on the owner's own iPhone.

This is a rehearsal. No real booking, no real money, no real phone, no real Waymo account, no
network call of any kind. The first live fire is Jose's. Everything below that stands in for another thread's
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

Terminal 2 asks its two questions; answer `yes`. If the Waymo quote misses its target and an
Uber ride is chosen instead, it also asks the two phone questions (the held tap, then the
phone's own Apple Pay prompt). Terminal 1 then shows each request with the
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
follows the concierge beats; it predates the phone path, so its card and partner lines are
history (see [Recordings](#recordings)).

1. **The run states what it is.** Tier Solo, nothing real, and the list of stand-ins.
2. **The ship gates, before anything happens.** The human-concierge gate is printed
   closed, with each of its three items and what is missing: thread 10's service-level
   monitoring, thread 10's trust and safety protocol, and Jose's approval of the disclosure
   copy. The peer routing gate is shown as not exercised, because Solo routes nothing through
   peers. The rehearsal demonstrates the gates; it does not waive them.
3. **The request and the calendar.** The agent finds the 2:00pm design review (ends 2:45pm),
   sees the 3:30pm haircut, and works out: leave between 2:50pm and 3:05pm, arrive by 3:25pm.
4. **Consent before a person sees the trip.** The disclosure says plainly that a person books
   Waymo rides, and exactly what they will and will not see: the pickup, the destination, and
   the time window, then at booking the most the user agreed to pay. That is all the queue
   carries; a test holds it to exactly those fields, so no budget and nothing from the calendar
   reaches a person. Answering no is shown in `--no-concierge`: the trip never reaches the
   queue and Waymo is reported unavailable.
5. **The phone is onboarded, then quotes come through one connector.** Before quoting, the real
   onboarding crawler (`lib/phone_crawler.py`) walks the rehearsal phone into a semantic map
   kept in memory, and the real iPhone ride backend
   (`connectors/ride/ride_phone/backend.py`, unchanged) finds each app's destination field
   through that map, types the address, and reads the priced rows. `quote_ride` returns Waymo
   and the Uber and Lyft vehicle classes, ranked, with flags (`preferred_provider`,
   `over_budget`). The agent cannot tell that the Waymo option came from a person and the
   others from a phone. Lines labeled `backend |` and `phone |` are the demo's narration of
   what happens behind the connector, not the agent's view; lines labeled `concierge |` are the
   console. The quote lands well inside the 30 second target.
6. **The choice and the reason.** Waymo One at $21.40: under $25, on time, and preferred.
7. **Solo asks before every real-world action.** The booking question names the price, the
   pickup, the arrival, the cap, and who books it.
8. **The charge record.** Before booking, the agent writes the quote, the cap ($21.40, no tip
   ceiling), and its reasoning to `charge-records.json`. There is no card and nothing from
   Stripe. The record later says how the ride was paid, or that it was not booked.
9. **The concierge books.** The console shows the cap and a plain note that the concierge path
   has no payment method in this build. The booking lands inside the 90 second target, and a
   fare above the cap is refused.
10. **The user is told who.** "Booked by Jose (rehearsal), a sirven concierge."
11. **The calendar write-back.** "Ride to Mission Street Barbers (Waymo)", 2:57pm to 3:13pm,
    with the booking, the confirmation, the tracking link, the free cancellation time, how it
    was paid, and why. Also written as a standard calendar file, `ride.ics`.
12. **The service levels.** Both legs, timed, against their targets.

The two failures, both recorded:

- **`late_quote`**: the concierge claims the request and never quotes. At 30 seconds the agent
  withdraws it, records the missed target, tells the user who saw the trip, says it will not
  keep trying behind their back, and books Uber Standard ($18.40) on the phone instead, asking
  first. The phone path then shows the money path Jose chose: the agent drives the Uber app to
  checkout, the bridge holds the "Request UberX" tap until the owner approves it (`sirven phone
  approve`), and then the phone shows its own Apple Pay sheet for that one purchase, which only
  the owner answers, on the phone. Nothing stores, replays, or stands in for that prompt, and
  no approval covers a later purchase. The rehearsal phone refuses every touch while the sheet
  is up, as the bridge does.
- **`fare_over_cap`**: the concierge reports a $26.90 fare against a $21.40 cap. The agent
  refuses it, nothing is booked or paid, the charge record says so, the console is told to
  cancel the ride, the user is told who saw the trip, and the agent offers the next option
  without booking it. Exit 4.

## Recordings

Each directory holds `transcript.txt` (lines with seconds since the start), `run.cast`
(replay with `asciinema play run.cast`), `events.jsonl` (one JSON object per step), and
`state/` (the calendar copy, `ride.ics`, the charge records, the service-level log, and the
concierge request as the queue left it).

| Recording | Result | Quote | Booking |
| --- | --- | --- | --- |
| [2026-10-11-scripted-normal](recordings/2026-10-11-scripted-normal/transcript.txt) | Waymo booked through the concierge, exit 0 | 8.4 seconds of 30 | 16.4 seconds of 90 |
| [2026-10-11-scripted-late_quote](recordings/2026-10-11-scripted-late_quote/transcript.txt) | Waymo withdrawn, UberX booked with consent, exit 0 | missed after 30 seconds | not used |
| [2026-10-11-scripted-fare_over_cap](recordings/2026-10-11-scripted-fare_over_cap/transcript.txt) | fare declined, card released, nothing booked, exit 4 | 8.4 seconds of 30 | 16.4 seconds of 90 |

These were made with the scripted operator. They predate the phone path: their Uber and Lyft
options came from the removed partner fixture and their payment from the removed test card,
so they are kept as history, not as the current script. A recording with Jose at the console
is the next one to make (see below).

## Stand-ins

| Stands in for | Here | Replace with |
| --- | --- | --- |
| Thread 08, the ride connector contract | `ride_demo/connector.py`: the three-call shape from the thread instructions | `docs/ride-connector-contract.md` and its schemas, once published |
| The owner's iPhone and the phone bridge | `ride_demo/rehearsal_phone.py`: an in-memory phone (`fixtures/rehearsal-phone.json`: a home screen, Uber, and Lyft, invented prices) that keeps the bridge's rules on money holds and the phone's own payment sheet; `ride_demo/phone_backend.py` wraps the real, unchanged iPhone ride backend over it | the owner's plugged-in iPhone through `lib/phone_bridge.py` |
| The owner's two approvals | the demo's questions: `sirven phone approve` for the held tap, then the phone's own Apple Pay prompt (`--yes` answers both, on screen) | the owner, at the Mac and then on the phone |
| Thread 10, the concierge queue | `ride_demo/concierge_queue.py`: one JSON file per request, locked and written atomically | thread 10's queue tooling |
| Thread 10, the trust and safety protocol | `RULES` in `ride_demo/console.py`: the floor the thread 10 instructions set | thread 10's protocol under `concierge-ops/` |
| Thread 10, service-level monitoring | `ride_demo/service_levels.py`: a timing log and on-screen verdicts | thread 10's monitoring and breach alerts |
| Charge records | `ride_demo/charges.py`: the quote, the cap, the reasoning, the booking, and how it was paid; no card | nothing to replace: the phone path pays in the ride app |
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
   of that file. One design point for thread 08: when a person saw a trip that then failed, the user is told who. The
   stand-in carries that as `seen_by` on an unavailable entry and on a booking error; the
   contract needs a field for it.
5. The phone path replaces the official-partner backend (thread 09) and Stripe Issuing
   (thread 11): Uber and Lyft are booked in the owner's own apps, and each purchase is approved
   live, twice, by the owner. A live fire swaps the rehearsal phone for the plugged-in iPhone
   through the phone bridge; the backend and its adapter stay as they are.
6. **How the concierge path pays: Jose's decision.** With the virtual cards gone, the concierge
   path has no payment method in this build. The concierge receives only the cap and a note
   saying so, and a fare above the cap is refused. A live Waymo ride needs Jose to choose how a
   concierge pays.

Then the questions the rehearsal cannot answer, each to verify before Jose's first ride:

7. **The ride app must pay with Apple Pay: Jose's decision to confirm.** The phone's own face
   recognition or Apple Pay prompt is the second approval, and it only appears when the ride app
   pays with Apple Pay. If the owner's Uber or Lyft account pays with a saved card, the app
   charges it with no prompt from the phone, and only the bridge's hold remains. The owner's ride
   apps should be set to Apple Pay before a live fire, and the backend should refuse to book
   when no prompt appears; it does not check that today.
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
idempotency and cancellation, the rehearsal phone's rules (a request tap is held, an approval
works once and for one tap, the payment sheet refuses every touch, declining on the phone books
nothing, a price above the cap is refused, onboarding never taps money), an absent phone
reported as unavailable, charge records with no card, a late answer never overwriting a
withdrawal, the gate staying closed until all three items are in place, the concierge receiving
exactly the disclosed fields, a second run on the same state, every end to end path above, a
person driving the interactive console, and Jose's language rules on every file here. They pass
on Python 3.9 and 3.12.
