# Concierge service-level monitoring

Per-request timings, breach alerts, and a weekly summary for the consolidated status. Built on
the event log in [tools/concierge_queue.py](tools/concierge_queue.py).

## 1. Per-request timings

Every event carries a timestamp, so each request yields:

- **Quote time:** submit to quote. Target under 30 seconds.
- **Booking time:** acceptance to booking. Target under 90 seconds.
- **Time to claim:** submit to first claim. No target; it explains slow quotes.
- **Claims:** more than one means a release and a second concierge.
- **Outcome:** booked, or handed back with a reason.

## 2. Alerts

| Alert | Fires when | Who acts |
| --- | --- | --- |
| `warning unclaimed` | Over 10 seconds in the queue with no concierge | Any concierge on shift; else the second line |
| `warning slow_quote` | Over 15 seconds claimed with no quote | The claiming concierge, or release it |
| `breach quote` | Over 30 seconds from submit with no quote | Concierge finishes or hands back; noted for the weekly review |
| `breach booking` | Over 90 seconds from acceptance with no booking | Same |

Warnings exist so someone can step in before a breach. A breach is not a disciplinary event;
patterns are reviewed weekly.

Run it by hand or from a scheduler:

```
python3 concierge-ops/tools/concierge_queue.py check --log queue.jsonl
```

Exit status 0 means quiet, 2 means at least one line printed, 1 means the command refused (a
bad log or arguments). During rehearsals a minute-level `bb automation` running `check` and
notifying on status 2 is enough; production needs per-request timers (see
[queue-design.md](queue-design.md), section 4).

## 3. Weekly summary

```
python3 concierge-ops/tools/concierge_queue.py report --log queue.jsonl --from 2026-10-12 --to 2026-10-18
```

prints a short markdown block, ready to paste into the consolidated weekly status:

```
## Concierge service levels, 2026-10-12 to 2026-10-18

- Requests: 4 submitted, 3 booked, 1 handed back, 0 still open.
- Quote time (submit to quote): median 12 seconds, 90th percentile 45 seconds, 2 of 3 under the 30 second target.
- Booking time (acceptance to confirmation): median 60 seconds, 90th percentile 60 seconds, 3 of 3 under the 90 second target.
- Breaches: 1 quote, 0 booking. Requests claimed more than once: 0.
- Handback reasons: unavailable 1.
- By concierge:
  - concierge-1: 2 worked, 2 booked.
  - concierge-2: 1 worked, 1 booked.
```

(That is the exact output for the week the test suite builds.) The summary names concierges by
roster key, never users or trips. A week is counted by when requests were submitted.

## 4. What else to watch, weekly

Not in the tool yet; add when there is real traffic.

- **Coverage gaps:** requests the agent could not route because no shift was open. Shows
  whether to widen the window.
- **Handback rate per concierge**, especially under the hybrid pay model, where a bonus per
  booking could pull against honest handbacks.
- **Consent withdrawals** and their timing.
- **Escalations** from the trust and safety protocol, by level, with notes linked.
- **Service account notices:** any warning or limit from a service is a same-day escalation
  and a line in the weekly summary.

## 5. Ship gate status

The service-level targets are "in place" for the ship gate when: the targets are defined
(section 1 of the queue design), measured on every request (this document, section 1),
alerted on before and at breach (section 2), and reported weekly (section 3). The prototype
does all four for rehearsals; production timers are the remaining piece.
