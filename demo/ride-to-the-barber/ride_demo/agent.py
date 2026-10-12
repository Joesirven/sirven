"""the agent side of the demo: one request, carried from the calendar to the calendar.

  1. read the request
  2. read the calendar: find the meeting, compute the window after it, find the barber
  3. ask before a person sees the trip (the concierge disclosure)
  4. quote through the connector; pick the preferred service under the budget
  5. ask before booking: Solo asks before every real-world action
  6. write a charge record (the quote, the cap, and why), then book through the connector. on
     the phone path the owner approves that one purchase live, twice: the bridge's hold, then
     the phone's own face recognition or Apple Pay prompt. no card is held anywhere.
  7. write the booking to the calendar with tracking and the cancellation window

the agent never decides which backend to use and never learns which one answered.
"""

import json
import os
import re
import uuid
from datetime import datetime, timedelta

from . import gates, request, service_levels
from .calendar_source import FixtureCalendar, after_window, clock_time
from .charges import ChargeRecords
from .concierge_backend import ConciergeBackend
from .concierge_queue import ConciergeQueue
from .connector import ConnectorError, Router, dollars, money
from .phone_backend import PhoneBackend
from .rehearsal_phone import RehearsalPhone

import phone_crawler  # noqa: E402  (lib/, put on the path by rehearsal_phone)
import phone_map  # noqa: E402

DEMO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_DIR = os.path.dirname(os.path.dirname(DEMO_DIR))
FIXTURES = os.path.join(DEMO_DIR, "fixtures")
COPY_PATH = os.path.join(DEMO_DIR, "copy", "concierge-disclosure.md")
DEMO_SENTENCE = "book me a ride to the barber after my 2pm meeting, Waymo preferred, under $25"
ARRIVE_EARLY_MINUTES = 5

SUBSTITUTIONS = (
    ("thread 08, ride connector contract", "ride_demo/connector.py: the three-call shape from the thread instructions; no published schemas yet"),
    ("the owner's iPhone and the phone bridge", "ride_demo/rehearsal_phone.py: an in-memory phone with Uber and Lyft (fixtures/rehearsal-phone.json, invented prices) that keeps the bridge's hold and payment sheet rules; the real ride backend drives it"),
    ("the owner approving on the phone", "the demo's questions: sirven phone approve for the held tap, then the phone's own Apple Pay prompt; with --yes, both are answered yes on screen"),
    ("thread 10, concierge queue and protocol", "ride_demo/concierge_queue.py and console.py: a file queue and the floor of the trust and safety rules"),
    ("the user's calendar", "fixtures/calendar.json, written back to a copy and a .ics file in the run's state directory"),
    ("the language model reading the request", "ride_demo/request.py: fixed patterns for the demo sentence"),
    ("the Waymo app", "a person at the concierge console types what the app would show; in a recorded run, a scripted operator does"),
)

EXIT_BOOKED = 0
EXIT_REFUSED = 2
EXIT_USER_DECLINED = 3
EXIT_BOOKING_FAILED = 4
EXIT_NOTHING_BOOKABLE = 5

PHONE_APPS = ("Uber", "Lyft")
PHONE_BOOKING_LINE = ("Then sirven holds the request until you approve it (sirven phone approve), and your phone "
                      "asks you itself, with face recognition or Apple Pay, for this one ride.")


def load_copy(path=COPY_PATH):
    with open(path) as handle:
        text = handle.read()
    sections = {}
    for match in re.finditer(r"^## ([a-z-]+)\n(.*?)(?=^## |\Z)", text, re.MULTILINE | re.DOTALL):
        sections[match.group(1)] = " ".join(match.group(2).split())
    return sections


class Asker:
    """asks the user. --yes answers yes and says so; without a terminal and without --yes,
    every answer is no, because Solo never acts without a person saying yes."""

    def __init__(self, recorder, yes=False, refuse_concierge=False, interactive=False):
        self.recorder = recorder
        self.yes = yes
        self.refuse_concierge = refuse_concierge
        self.interactive = interactive

    def __call__(self, question, kind):
        self.recorder.say("")
        self.recorder.say("  ? " + question)
        # the phone's own prompt is answered on the phone, never by sirven; in the rehearsal the
        # person at the terminal (or --yes) plays the owner holding it
        on_phone = " on the phone" if kind == "phone_payment" else ""
        if kind == "concierge" and self.refuse_concierge:
            answer, how = False, "no (answered by --no-concierge)"
        elif self.yes:
            answer, how = True, "yes%s (answered by --yes, for the recording)" % on_phone
        elif self.interactive:
            answer = input("    yes or no%s: " % on_phone).strip().lower().startswith("y")
            how = ("yes" if answer else "no") + on_phone
        else:
            answer, how = False, "no (no terminal to ask and no --yes)"
        self.recorder.say("    " + how)
        self.recorder.event("asked", kind=kind, question=question, answer=answer)
        return answer


def onboard(phone, recorder):
    """the owner's onboarding, run on the rehearsal phone with the real crawler, into a map kept
    in memory. the ride backend then finds each app's destination field through that map."""
    the_map = phone_map.empty_map()
    try:
        summaries = phone_crawler.onboard(phone.driver(), the_map, PHONE_APPS,
                                          datetime.now().astimezone().isoformat(timespec="seconds"))
    except phone_crawler.CrawlStopped as stopped:
        # an unfinished map is not used: the phone backend then reports itself unavailable
        recorder.say("onboarding the rehearsal phone stopped: %s" % stopped.said, who="phone")
        return None
    phone.the_map = the_map
    mapped = ", ".join("%s %d screens" % (s["name"], s["screens"]) if "screens" in s else "%s %s" % (s["name"], s["result"])
                       for s in summaries)
    fields = [name for name in PHONE_APPS if phone_map.find(the_map, name, "destination_field")]
    recorder.say("onboarded the rehearsal phone with the real crawler, map kept in memory: %s; destination field "
                 "found through the map in %s" % (mapped, ", ".join(fields) or "no app"), who="phone")
    recorder.event("phone_onboarded", summaries=summaries)
    return the_map


def build_router(state_dir, recorder, quote_wait, booking_wait, ask):
    queue = ConciergeQueue(os.path.join(state_dir, "concierge-queue"))
    concierge = ConciergeBackend(
        queue, os.path.join(state_dir, "service-levels.jsonl"),
        notify=lambda line: recorder.say(line, who="backend"), quote_wait_seconds=quote_wait,
        booking_wait_seconds=booking_wait)
    phone = RehearsalPhone(ask)
    onboard(phone, recorder)
    return Router([concierge, PhoneBackend(phone)]), concierge


def option_line(option):
    pickup = datetime.fromisoformat(option["estimated_pickup"])
    arrival = pickup + timedelta(minutes=option["estimated_trip_minutes"])
    flags = ", ".join(option["constraint_flags"]) or "none"
    return "  %d. %-6s %-14s %7s  pickup %s, arrive %s  flags: %s" % (
        option["rank"], option["provider"], option["product"], dollars(option["price"]),
        clock_time(pickup), clock_time(arrival), flags)


def tell_who_saw(say, copy, entry):
    """a trip that reached the concierge queue is never hidden: say who saw it, or that no one
    took it. entries without seen_by never reached a person."""
    if "seen_by" not in entry:
        return
    if entry["seen_by"]:
        say("agent: " + copy["seen-by-concierge"].format(concierge=entry["seen_by"]))
    else:
        say("agent: " + copy["queued-unclaimed"])


def say_service_levels(recorder, concierge):
    """the run's narration, not the agent: the agent never learns a concierge was involved."""
    lines = [service_levels.describe(entry) for entry in concierge.measurements]
    for line in ["service levels:"] + (lines or ["none: no concierge was involved in this run"]):
        recorder.say(line, who="backend")


def choose(options):
    """the first ranked option that breaks no hard constraint, or None."""
    for option in options:
        if not {"over_budget", "arrives_late", "outside_departure_window"} & set(option["constraint_flags"]):
            return option
    return None


def run(args, recorder):
    say = recorder.say
    copy = load_copy()
    state_dir = args.state
    os.makedirs(state_dir, exist_ok=True)

    say("sirven rehearsal: one request, end to end. tier: Solo.")
    say("no real booking, no real money, no real phone, no real Waymo account. the first live fire is Jose's.")
    say("")
    say("stand-ins in this run (each is marked SUBSTITUTION in its file):")
    for what, how in SUBSTITUTIONS:
        say("  - %s -> %s" % (what, how))
    say("")
    concierge_gate = gates.concierge_gate(REPO_DIR, COPY_PATH)
    peer_gate = gates.peer_routing_gate()
    say("ship gates (the rehearsal demonstrates them; it does not waive them):")
    for line in gates.describe(concierge_gate) + gates.describe(peer_gate):
        say("  " + line)
    recorder.event("gates", concierge=concierge_gate, peer_routing=peer_gate)

    if args.live:
        say("")
        say("refusing a live fire: this build drives no real phone, has no payment method for the concierge path,")
        say("and has no real Waymo account,")
        say("and the human-concierge gate is %s. see the README's list of what remains." % (
            "open" if concierge_gate["open"] else "closed"))
        return EXIT_REFUSED

    say("")
    say('user: "%s"' % args.request)
    intent = request.parse(args.request)
    recorder.event("intent", **intent)
    ask = Asker(recorder, yes=args.yes, refuse_concierge=args.no_concierge, interactive=args.interactive)

    # 2. the calendar
    calendar = FixtureCalendar(os.path.join(FIXTURES, "calendar.json"), state_dir)
    with open(os.path.join(FIXTURES, "places.json")) as handle:
        places = json.load(handle)["places"]
    meeting = calendar.meeting_at(*intent["after_meeting_at"])
    if meeting is None:
        say("agent: I could not find a meeting at that time on your calendar, so I am not booking anything.")
        return EXIT_NOTHING_BOOKABLE
    earliest, latest = after_window(meeting)
    place = places.get(intent["destination_place"], {"name": intent["destination_place"], "address": intent["destination_place"]})
    appointment = calendar.next_event_matching(meeting["end"], (intent["destination_place"], "haircut"))
    destination = appointment["location"] if appointment else place["address"]
    arrive_by = appointment["start"] - timedelta(minutes=ARRIVE_EARLY_MINUTES) if appointment else None
    say("")
    say("agent: calendar read")
    say("  the meeting: %s, %s to %s, at %s" % (
        meeting["title"], clock_time(meeting["start"]), clock_time(meeting["end"]), meeting["location"]))
    if appointment:
        say("  next: %s at %s, so I will aim to have you there by %s" % (
            appointment["title"], clock_time(appointment["start"]), clock_time(arrive_by)))
    say("  leave between %s and %s, from %s to %s" % (clock_time(earliest), clock_time(latest), meeting["location"], destination))
    recorder.event("calendar_read", meeting=meeting["event_id"], earliest=earliest.isoformat(),
                   latest=latest.isoformat(), arrive_by=arrive_by.isoformat() if arrive_by else None)

    # 3. a person may see the trip only after the user says so
    window_text = "%s to %s" % (clock_time(earliest), clock_time(latest))
    consented = ask(copy["consent-before-quote"].format(origin=meeting["location"], destination=destination,
                                                        window=window_text), "concierge")
    if not consented:
        say("agent: " + copy["declined-consent"])
    preferences = {
        "preferred_providers": intent["preferred_providers"],
        "arrive_by": arrive_by.isoformat() if arrive_by else None,
        "human_assisted_booking": {"granted": consented, "at": datetime.now().astimezone().isoformat(timespec="seconds"),
                                   "disclosure": os.path.relpath(COPY_PATH, REPO_DIR),
                                   "disclosure_status": gates.copy_status(COPY_PATH)},
    }
    budget = money(intent["budget_ceiling_minor"])

    # 4. quote
    router, concierge = build_router(state_dir, recorder, args.quote_wait, args.booking_wait, ask)
    charges = ChargeRecords(os.path.join(state_dir, "charge-records.json"))
    say("")
    say("agent: quote_ride(%s -> %s, leave %s, prefer %s, under %s)" % (
        meeting["location"], destination, window_text, ", ".join(intent["preferred_providers"]) or "nothing", dollars(budget)))
    quotes = router.quote_ride(meeting["location"], destination,
                               {"earliest": earliest.isoformat(), "latest": latest.isoformat()}, preferences, budget)
    recorder.event("quoted", options=quotes["options"], unavailable=quotes["unavailable"])
    for line in map(option_line, quotes["options"]):
        say(line)
    for missing in quotes["unavailable"]:
        say("  -  %-6s unavailable: %s" % (missing["provider"], missing["reason"]))
    for missing in quotes["unavailable"]:
        tell_who_saw(say, copy, missing)
    preferred_missing = [m for m in quotes["unavailable"] if m["provider"] in intent["preferred_providers"]]
    if preferred_missing and consented:
        say("agent: " + copy["waymo-unavailable"].format(reason=preferred_missing[0]["reason"]))
    chosen = choose(quotes["options"])
    if chosen is None:
        say("agent: nothing fits under %s and in time, so I am not booking anything." % dollars(budget))
        return EXIT_NOTHING_BOOKABLE
    cap = chosen["price"]["amount_minor"] + chosen["tip_ceiling"]["amount_minor"]
    name = chosen["product"] if chosen["product"].startswith(chosen["provider"]) else "%s %s" % (
        chosen["provider"], chosen["product"])
    reason = "%s at %s%s is the best option under %s that arrives on time" % (
        name, dollars(chosen["price"]),
        " plus up to %s tip" % dollars(chosen["tip_ceiling"]) if chosen["tip_ceiling"]["amount_minor"] else "",
        dollars(budget))
    if chosen["provider"] in intent["preferred_providers"]:
        reason += ", and it is your preferred service"
    say("agent: choosing option %d: %s." % (chosen["rank"], reason))

    # 5. Solo asks before every real-world action
    pickup = datetime.fromisoformat(chosen["estimated_pickup"])
    arrival = pickup + timedelta(minutes=chosen["estimated_trip_minutes"])
    concierge_backed = chosen["provider"] == "Waymo"
    question = copy["consent-before-booking"].format(
        product=name, price=dollars(chosen["price"]), pickup=clock_time(pickup),
        origin=meeting["location"], arrival=clock_time(arrival), cap=dollars(money(cap)),
        booked_by_line=copy["booked-by-concierge-line"] if concierge_backed else PHONE_BOOKING_LINE).strip()
    if not ask(question, "booking"):
        say("agent: not booked. nothing was paid.")
        return EXIT_USER_DECLINED

    # 6. the charge record, then the booking
    record = charges.write(chosen, cap, reason)
    say("agent: charge record %s: %s at %s, cap %s, and why. no card is held for it." % (
        record["record_id"], name, dollars(chosen["price"]), dollars(money(cap))))
    recorder.event("charge_record_written", record_id=record["record_id"], cap_minor=cap)
    say("agent: book_ride(%s)" % chosen["quote_id"])
    try:
        booking = router.book_ride(chosen["quote_id"], idempotency_key=str(uuid.uuid4()))
    except ConnectorError as error:
        charges.not_booked(record["record_id"], error.code)
        recorder.event("booking_failed", code=error.code, message=str(error))
        say("agent: the booking did not go through (%s): %s" % (error.code, error))
        if error.seen_by:
            tell_who_saw(say, copy, {"seen_by": error.seen_by})
        say("agent: nothing was paid, and the charge record says so. I have not booked anything else.")
        fallback = choose([option for option in quotes["options"] if option["quote_id"] != chosen["quote_id"]])
        if fallback:
            say("agent: if you want, I can book option %d (%s %s, %s) instead; I will ask first." % (
                fallback["rank"], fallback["provider"], fallback["product"], dollars(fallback["price"])))
        say_service_levels(recorder, concierge)
        return EXIT_BOOKING_FAILED
    record = charges.booked(record["record_id"], booking)
    recorder.event("booked", booking=booking)
    say("agent: booked %s, status %s" % (booking["booking_id"], booking["status"]))
    if booking["confirmation"]["booked_by"].startswith("concierge "):
        say("agent: " + copy["booked-by-concierge"].format(
            concierge=booking["confirmation"]["booked_by"][len("concierge "):],
            confirmation=booking["confirmation"]["provider_confirmation"]))
    else:
        say("  booked by: %s; confirmation: %s" % (booking["confirmation"]["booked_by"],
                                                  booking["confirmation"]["provider_confirmation"]))
    say("  paid: %s" % record["paid_how"])
    say("  tracking: %s" % booking["tracking_url"])
    say("  free cancellation until %s%s" % (
        clock_time(datetime.fromisoformat(booking["cancellation_window"]["free_until"])),
        " (%s)" % booking["cancellation_window"]["terms"] if "terms" in booking["cancellation_window"] else ""))

    # 7. the calendar
    description = "\n".join([
        "%s %s, %s, booked by the sirven agent" % (booking["provider"], chosen["product"], dollars(booking["price"])),
        "booking: %s" % booking["booking_id"],
        "confirmation: %s (%s)" % (booking["confirmation"]["provider_confirmation"], booking["confirmation"]["booked_by"]),
        "tracking: %s" % booking["tracking_url"],
        "free cancellation until: %s" % booking["cancellation_window"]["free_until"],
        "paid: %s; cap %s" % (record["paid_how"], dollars(money(cap))),
        "why: %s" % reason,
    ])
    event, ics_path = calendar.write_back(
        "Ride to %s (%s)" % (place["name"], booking["provider"]), pickup, arrival, meeting["location"],
        description, booking["booking_id"])
    recorder.event("calendar_written", event=event, ics=os.path.relpath(ics_path, state_dir))
    say("agent: on your calendar: %s, %s to %s" % (event["title"], clock_time(pickup), clock_time(arrival)))

    say("")
    say("done.")
    say_service_levels(recorder, concierge)
    say("state written to %s: calendar.json, ride.ics, charge-records.json, service-levels.jsonl, concierge-queue/" % state_dir)
    return EXIT_BOOKED
