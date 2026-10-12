#!/usr/bin/env python3
"""concierge queue: the ride-request queue a human concierge works, and its service-level clock.

a prototype of the tooling in concierge-ops/queue-design.md and concierge-ops/monitoring.md.
standard library only. state is one append-only JSON lines event log; every command reads
the whole log, replays it, and (for writes) appends one event. nothing is ever rewritten.

the log holds timings and outcomes, never trip content: no addresses, no names, no phone
numbers. the trip request itself travels to the concierge through the console and is
dropped when the request closes (see concierge-ops/trust-and-safety.md, section on data).

every write takes --at, a timestamp like 2026-10-11T14:00:05Z, so tests and rehearsals are
deterministic. leave it out and the current time is used.

subcommands

  submit   --log F --request R --consent disclosed [--service NAME] [--at T]
      a ride request enters the queue. refused unless the user's consent to a human seeing
      the trip request is recorded as disclosed.
  claim    --log F --request R --concierge C --roster ROSTER [--at T]
      a concierge takes an open request. refused if the concierge is not active on the
      roster, or the request is already claimed. prints the concierge's display name, which
      is what the user is told.
  release  --log F --request R [--at T]
      the concierge gives the request back to the queue unworked.
  quote    --log F --request R --amount-cents N [--currency USD] [--at T]
      the concierge returns a price to the user's agent. stops the quote clock.
  accept   --log F --request R [--at T]
      the user accepts the quote. starts the booking clock.
  book     --log F --request R [--at T]
      the concierge confirms the booking. stops the booking clock and closes the request.
  handback --log F --request R --reason REASON [--at T]
      the request goes back to the agent unbooked, with an honest reason. closes it.
      reasons: unavailable, over_budget, user_cancelled, safety, consent_withdrawn, other.
  check    --log F [--at T]
      print one alert line per open request past a target. exit status 2 when there is
      at least one, so an automation can page on it.
  report   --log F --from DAY --to DAY
      print the weekly summary in markdown, for the consolidated status.

service-level targets (from the scope): quote under 30 seconds from submit, booking under
90 seconds from the user's acceptance. a claim that sits 15 seconds without a quote is a
warning, so a second concierge can step in before the quote target is breached.
"""

import argparse
import datetime
import json
import math
import os
import statistics
import sys

QUOTE_TARGET_SECONDS = 30
BOOKING_TARGET_SECONDS = 90
UNCLAIMED_WARNING_SECONDS = 10
CLAIMED_WARNING_SECONDS = 15
HANDBACK_REASONS = ("unavailable", "over_budget", "user_cancelled", "safety", "consent_withdrawn", "other")


class Refused(Exception):
    pass


def parse_time(text):
    if text is None:
        return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    try:
        value = datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        raise Refused(f"timestamp {text!r} must look like 2026-10-11T14:00:05Z")
    return value.replace(tzinfo=datetime.timezone.utc)


def format_time(value):
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")


def read_events(path):
    if not os.path.exists(path):
        return []
    events = []
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                raise Refused(f"{path}:{number} is not a JSON line")
    return events


def append_event(path, event):
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(event, sort_keys=True) + "\n")


def replay(events):
    """fold the event log into one record per request, in submit order."""
    requests = {}
    for event in events:
        at = parse_time(event["at"])
        request_id = event["request"]
        kind = event["event"]
        if kind == "submit":
            requests[request_id] = {
                "request": request_id,
                "service": event.get("service", ""),
                "submitted": at,
                "claimed": None,
                "concierge": None,
                "claims": 0,
                "quoted": None,
                "accepted": None,
                "booked": None,
                "handed_back": None,
                "reason": None,
            }
            continue
        record = requests[request_id]
        if kind == "claim":
            record["claimed"] = at
            record["concierge"] = event["concierge"]
            record["claims"] += 1
        elif kind == "release":
            record["claimed"] = None
            record["concierge"] = None
        elif kind == "quote":
            record["quoted"] = at
        elif kind == "accept":
            record["accepted"] = at
        elif kind == "book":
            record["booked"] = at
        elif kind == "handback":
            record["handed_back"] = at
            record["reason"] = event["reason"]
    return requests


def is_closed(record):
    return record["booked"] is not None or record["handed_back"] is not None


def quote_seconds(record):
    if record["quoted"] is None:
        return None
    return int((record["quoted"] - record["submitted"]).total_seconds())


def booking_seconds(record):
    if record["booked"] is None or record["accepted"] is None:
        return None
    return int((record["booked"] - record["accepted"]).total_seconds())


def latest_time(record):
    if record is None:
        return None
    stamps = [record[key] for key in ("submitted", "claimed", "quoted", "accepted", "booked", "handed_back")]
    return max(stamp for stamp in stamps if stamp is not None)


def load_roster(path):
    with open(path, encoding="utf-8") as handle:
        roster = json.load(handle)
    return {entry["concierge"]: entry for entry in roster["concierges"]}


def open_record(requests, request_id):
    record = requests.get(request_id)
    if record is None:
        raise Refused(f"request {request_id} was never submitted")
    if is_closed(record):
        raise Refused(f"request {request_id} is already closed")
    return record


def command_submit(args, requests):
    if args.request in requests:
        raise Refused(f"request {args.request} was already submitted")
    if args.consent != "disclosed":
        raise Refused("the user has not consented to a human concierge seeing this trip request")
    return {"event": "submit", "request": args.request, "service": args.service, "consent": "disclosed"}


def command_claim(args, requests):
    record = open_record(requests, args.request)
    roster = load_roster(args.roster)
    entry = roster.get(args.concierge)
    if entry is None or entry.get("status") != "active":
        raise Refused(f"concierge {args.concierge} is not active on the roster")
    if record["concierge"] is not None:
        raise Refused(f"request {args.request} is already claimed by {record['concierge']}")
    print(f"claimed {args.request}; the user is told: {entry['display_name']}")
    return {"event": "claim", "request": args.request, "concierge": args.concierge}


def command_release(args, requests):
    record = open_record(requests, args.request)
    if record["concierge"] is None:
        raise Refused(f"request {args.request} is not claimed")
    return {"event": "release", "request": args.request}


def command_quote(args, requests):
    record = open_record(requests, args.request)
    if record["concierge"] is None:
        raise Refused(f"request {args.request} must be claimed before it is quoted")
    if args.amount_cents <= 0:
        raise Refused("a quote needs a positive amount")
    return {"event": "quote", "request": args.request, "amount_cents": args.amount_cents, "currency": args.currency}


def command_accept(args, requests):
    record = open_record(requests, args.request)
    if record["quoted"] is None:
        raise Refused(f"request {args.request} has no quote to accept")
    return {"event": "accept", "request": args.request}


def command_book(args, requests):
    record = open_record(requests, args.request)
    if record["accepted"] is None:
        raise Refused(f"request {args.request} cannot be booked before the user accepts the quote")
    return {"event": "book", "request": args.request}


def command_handback(args, requests):
    open_record(requests, args.request)
    if args.reason not in HANDBACK_REASONS:
        raise Refused(f"reason must be one of: {', '.join(HANDBACK_REASONS)}")
    return {"event": "handback", "request": args.request, "reason": args.reason}


def alerts(requests, now):
    lines = []
    for record in requests.values():
        if is_closed(record):
            continue
        request_id = record["request"]
        waiting = int((now - record["submitted"]).total_seconds())
        if record["quoted"] is None:
            if waiting > QUOTE_TARGET_SECONDS:
                lines.append(f"breach\tquote\t{request_id}\t{waiting} seconds since submit, target {QUOTE_TARGET_SECONDS}")
            elif record["concierge"] is None and waiting > UNCLAIMED_WARNING_SECONDS:
                lines.append(f"warning\tunclaimed\t{request_id}\t{waiting} seconds with no concierge")
            elif record["concierge"] is not None:
                held = int((now - record["claimed"]).total_seconds())
                if held > CLAIMED_WARNING_SECONDS:
                    lines.append(f"warning\tslow_quote\t{request_id}\t{held} seconds claimed by {record['concierge']} with no quote")
        elif record["accepted"] is not None:
            booking = int((now - record["accepted"]).total_seconds())
            if booking > BOOKING_TARGET_SECONDS:
                lines.append(f"breach\tbooking\t{request_id}\t{booking} seconds since acceptance, target {BOOKING_TARGET_SECONDS}")
    return lines


def percentile(values, fraction):
    # nearest rank: the smallest value with at least that fraction of values at or below it.
    ordered = sorted(values)
    return ordered[max(0, math.ceil(fraction * len(ordered)) - 1)]


def describe_timings(values, target):
    if not values:
        return "none recorded"
    within = sum(1 for value in values if value < target)
    return (f"median {int(statistics.median(values))} seconds, 90th percentile {percentile(values, 0.9)} seconds, "
            f"{within} of {len(values)} under the {target} second target")


def report(requests, start, end):
    window = [r for r in requests.values() if start <= r["submitted"] < end]
    quotes = [s for s in (quote_seconds(r) for r in window) if s is not None]
    bookings = [s for s in (booking_seconds(r) for r in window) if s is not None]
    booked = sum(1 for r in window if r["booked"] is not None)
    handed_back = [r for r in window if r["handed_back"] is not None]
    still_open = sum(1 for r in window if not is_closed(r))
    # a request handed back unquoted after the quote target also missed it.
    quote_breaches = sum(1 for s in quotes if s >= QUOTE_TARGET_SECONDS) + sum(
        1 for r in window if r["quoted"] is None and r["handed_back"] is not None
        and (r["handed_back"] - r["submitted"]).total_seconds() >= QUOTE_TARGET_SECONDS)
    booking_breaches = sum(1 for s in bookings if s >= BOOKING_TARGET_SECONDS)
    reclaimed = sum(1 for r in window if r["claims"] > 1)

    last_day = end - datetime.timedelta(days=1)
    out = [
        f"## Concierge service levels, {start:%Y-%m-%d} to {last_day:%Y-%m-%d}",
        "",
        f"- Requests: {len(window)} submitted, {booked} booked, {len(handed_back)} handed back, {still_open} still open.",
        f"- Quote time (submit to quote): {describe_timings(quotes, QUOTE_TARGET_SECONDS)}.",
        f"- Booking time (acceptance to confirmation): {describe_timings(bookings, BOOKING_TARGET_SECONDS)}.",
        f"- Breaches: {quote_breaches} quote, {booking_breaches} booking. Requests claimed more than once: {reclaimed}.",
    ]
    if handed_back:
        counts = {}
        for record in handed_back:
            counts[record["reason"]] = counts.get(record["reason"], 0) + 1
        reasons = ", ".join(f"{reason} {counts[reason]}" for reason in sorted(counts))
        out.append(f"- Handback reasons: {reasons}.")
    per_concierge = {}
    for record in window:
        if record["concierge"] is not None and (record["booked"] or record["quoted"]):
            per_concierge.setdefault(record["concierge"], []).append(record)
    if per_concierge:
        out.append("- By concierge:")
        for name in sorted(per_concierge):
            records = per_concierge[name]
            done = sum(1 for r in records if r["booked"] is not None)
            out.append(f"  - {name}: {len(records)} worked, {done} booked.")
    return "\n".join(out)


def parse_day(text):
    try:
        value = datetime.datetime.strptime(text, "%Y-%m-%d")
    except ValueError:
        raise Refused(f"day {text!r} must look like 2026-10-11")
    return value.replace(tzinfo=datetime.timezone.utc)


def build_parser():
    parser = argparse.ArgumentParser(prog="concierge_queue.py", description="concierge ride-request queue")
    sub = parser.add_subparsers(dest="command", required=True)

    def add(name, *, request=True, at=True):
        command = sub.add_parser(name)
        command.add_argument("--log", required=True)
        if request:
            command.add_argument("--request", required=True)
        if at:
            command.add_argument("--at")
        return command

    submit = add("submit")
    submit.add_argument("--consent", required=True)
    submit.add_argument("--service", default="")
    claim = add("claim")
    claim.add_argument("--concierge", required=True)
    claim.add_argument("--roster", required=True)
    add("release")
    quote = add("quote")
    quote.add_argument("--amount-cents", type=int, required=True)
    quote.add_argument("--currency", default="USD")
    add("accept")
    add("book")
    handback = add("handback")
    handback.add_argument("--reason", required=True)
    add("check", request=False)
    weekly = add("report", request=False, at=False)
    weekly.add_argument("--from", dest="start", required=True)
    weekly.add_argument("--to", dest="end", required=True)
    return parser


WRITES = {
    "submit": command_submit,
    "claim": command_claim,
    "release": command_release,
    "quote": command_quote,
    "accept": command_accept,
    "book": command_book,
    "handback": command_handback,
}


def main(argv):
    args = build_parser().parse_args(argv)
    try:
        requests = replay(read_events(args.log))
        if args.command in WRITES:
            at = parse_time(args.at)
            last = latest_time(requests.get(args.request))
            if last is not None and at < last:
                raise Refused(f"{format_time(at)} is earlier than the last event on {args.request}, {format_time(last)}")
            event = WRITES[args.command](args, requests)
            event["at"] = format_time(at)
            append_event(args.log, event)
            return 0
        if args.command == "check":
            lines = alerts(requests, parse_time(args.at))
            for line in lines:
                print(line)
            return 2 if lines else 0
        start = parse_day(args.start)
        end = parse_day(args.end) + datetime.timedelta(days=1)
        print(report(requests, start, end))
        return 0
    except Refused as refusal:
        print(f"refused: {refusal}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
