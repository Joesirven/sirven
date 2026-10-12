"""the concierge console: what a concierge (Jose, in rehearsal) operates to take a request,
book the ride in the Waymo app, and hand back the confirmation inside the service-level targets.

two ways to run it. interactive, in a second terminal, where a person answers every prompt.
scripted, for the recorded run, where a timed operator answers with the rehearsal values and
says on every line that it is scripted.

the trust and safety rules below are a SUBSTITUTION for thread 10's protocol, which had not
been committed when this demo was built. they are the floor the thread 10 instructions set,
not the protocol itself.
"""

import threading
import time
from datetime import datetime

from . import service_levels
from .concierge_queue import ConciergeQueue, QueueError, now

RULES = (
    "you may see: the pickup, the destination, the time window, and the user's consent; at booking, the price cap the user approved",
    "never: contact the user yourself, or keep or share the trip",
    "never: book another service, another time, or above the cap; decline and say why instead",
    "anything unsafe or unclear: decline with the reason; sirven tells the user, honestly",
)

REHEARSAL_QUOTE = {"price_minor": 2140, "pickup_minutes": 7, "trip_minutes": 16}
REHEARSAL_BOOKING = {"confirmation_code": "REHEARSAL-WAYMO-0001", "fare_minor": 2140,
                     "tracking_url": "https://example.invalid/waymo/trip/rehearsal-0001"}


def dollars_from_minor(amount):
    return "$%d.%02d" % divmod(amount, 100)


def elapsed(request, state):
    started = ConciergeQueue.entered(request, state)
    return (now() - started).total_seconds()


def describe_request(request):
    trip = request["trip"]
    window = trip["departure_window"]
    lines = [
        "request %s for %s" % (request["request_id"], trip["provider"]),
        "  pickup:      %s" % trip["origin"],
        "  destination: %s" % trip["destination"],
        "  leave:       between %s and %s" % (
            datetime.fromisoformat(window["earliest"]).strftime("%-I:%M%p").lower(),
            datetime.fromisoformat(window["latest"]).strftime("%-I:%M%p").lower()),
        "  consent:     the user agreed at %s that a concierge may see this trip" % request["consent"]["at"],
    ]
    if "payment" in request:
        payment = request["payment"]
        lines.append("  cap:         %s; %s" % (dollars_from_minor(payment["cap_minor"]), payment["note"]))
    return lines


def claim(queue, request_id, name):
    request = queue.read(request_id)
    if request["state"] == "waiting_quote":
        return queue.move(request_id, "waiting_quote", "quote_claimed", concierge={"name": name})
    return queue.move(request_id, "waiting_booking", "booking_claimed")


def submit_quote(queue, request_id, price_minor, pickup_minutes, trip_minutes):
    return queue.move(request_id, "quote_claimed", "quoted", quote={
        "price_minor": price_minor, "pickup_minutes": pickup_minutes, "trip_minutes": trip_minutes})


def submit_booking(queue, request_id, confirmation_code, fare_minor, tracking_url):
    return queue.move(request_id, "booking_claimed", "booked", booking={
        "confirmation_code": confirmation_code, "fare_minor": fare_minor, "tracking_url": tracking_url})


def decline(queue, request_id, reason):
    return queue.move(request_id, ("quote_claimed", "booking_claimed"), "declined", declined_because=reason)


class ScriptedOperator:
    """a timed stand-in for the person at the console, for the recorded run and the tests.
    scenario normal answers inside both targets; late_quote claims and then never quotes;
    fare_over_cap reports a fare above the cap the user approved."""

    def __init__(self, queue, name, say, scenario="normal", delays=(2, 6, 2, 14), poll_seconds=0.2):
        self.queue = queue
        self.name = name
        self.say = say
        self.scenario = scenario
        self.claim_quote, self.quote, self.claim_booking, self.book = delays
        self.poll_seconds = poll_seconds
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self._thread.start()
        return self

    def stop(self):
        self._stop.set()
        self._thread.join(timeout=5)

    def _pause(self, seconds):
        return not self._stop.wait(seconds)

    def _run(self):
        done = set()
        while not self._stop.is_set():
            for request in self.queue.list(("waiting_quote", "waiting_booking")):
                key = (request["request_id"], request["state"])
                if key in done:
                    continue
                done.add(key)
                try:
                    if request["state"] == "waiting_quote":
                        self._quote(request)
                    else:
                        self._book(request)
                except QueueError as error:
                    self.say("stopped: %s" % error)
            self._stop.wait(self.poll_seconds)

    def _quote(self, request):
        request_id = request["request_id"]
        self.say("new request %s; the rules are on screen" % request_id)
        if not self._pause(self.claim_quote):
            return
        claim(self.queue, request_id, self.name)
        self.say("claimed by %s; opening the Waymo app for a price" % self.name)
        if self.scenario == "late_quote":
            self.say("the Waymo app is not answering; no quote sent (late_quote scenario)")
            return
        if not self._pause(self.quote):
            return
        answer = REHEARSAL_QUOTE
        submit_quote(self.queue, request_id, **answer)
        self.say("quote sent: %s, pickup in %d minutes, %d minute trip, at %.1f seconds of %d" % (
            dollars_from_minor(answer["price_minor"]), answer["pickup_minutes"], answer["trip_minutes"],
            elapsed(self.queue.read(request_id), "waiting_quote"), service_levels.QUOTE_TARGET_SECONDS))

    def _book(self, request):
        request_id = request["request_id"]
        self.say("booking requested for %s" % request_id)
        for line in describe_request(request)[-1:]:
            self.say(line.strip())
        if not self._pause(self.claim_booking):
            return
        claim(self.queue, request_id, self.name)
        self.say("booking in the Waymo app")
        if not self._pause(self.book):
            return
        answer = dict(REHEARSAL_BOOKING)
        if self.scenario == "fare_over_cap":
            answer["fare_minor"] = 2690
        submit_booking(self.queue, request_id, **answer)
        self.say("confirmation %s sent, fare %s, at %.1f seconds of %d" % (
            answer["confirmation_code"], dollars_from_minor(answer["fare_minor"]),
            elapsed(self.queue.read(request_id), "waiting_booking"), service_levels.BOOKING_TARGET_SECONDS))


def _ask(prompt, default):
    answer = input("%s [%s]: " % (prompt, default)).strip()
    return answer or str(default)


def _ask_dollars(prompt, default_minor):
    while True:
        text = _ask(prompt, "%d.%02d" % divmod(default_minor, 100)).lstrip("$")
        try:
            return int(round(float(text) * 100))
        except ValueError:
            print("  a dollar amount, like 21.40")


def interactive(queue, name, poll_seconds=0.5, once=False):
    """the console a person operates. it waits for requests, shows each with the rules and a
    running clock against its target, and writes back what the person enters. with once, it
    leaves after the first booking it confirms or request it declines."""
    print("sirven concierge console (rehearsal). concierge: %s" % name)
    print("rules for every request:")
    for rule in RULES:
        print("  - " + rule)
    print("waiting for requests. press control-c to leave.")
    told = set()
    while True:
        for request in queue.list(("withdrawn",)):
            if request["request_id"] not in told:
                told.add(request["request_id"])
                print("\nrequest %s withdrawn by the agent: %s" % (request["request_id"], request["withdrawn_because"]))
        waiting = queue.list(("waiting_quote", "waiting_booking"))
        if not waiting:
            time.sleep(poll_seconds)
            continue
        request = waiting[0]
        request_id = request["request_id"]
        state = request["state"]
        print()
        for line in describe_request(request):
            print(line)
        target = service_levels.QUOTE_TARGET_SECONDS if state == "waiting_quote" else service_levels.BOOKING_TARGET_SECONDS
        leg = "quote" if state == "waiting_quote" else "booking"
        print("the %s target is %d seconds; %.1f have passed" % (leg, target, elapsed(request, state)))
        if _ask("claim it? (y to claim, d to decline)", "y").lower().startswith("d"):
            try:
                claim(queue, request_id, name)
                decline(queue, request_id, _ask("why", "cannot book this trip"))
            except QueueError as error:
                print("  too late: %s" % error)
                continue
            if once:
                return
            continue
        try:
            claim(queue, request_id, name)
            if state == "waiting_quote":
                price = _ask_dollars("price the Waymo app shows", REHEARSAL_QUOTE["price_minor"])
                pickup = int(_ask("minutes until pickup", REHEARSAL_QUOTE["pickup_minutes"]))
                trip = int(_ask("trip minutes", REHEARSAL_QUOTE["trip_minutes"]))
                submit_quote(queue, request_id, price, pickup, trip)
            else:
                code = _ask("Waymo confirmation", REHEARSAL_BOOKING["confirmation_code"])
                fare = _ask_dollars("fare charged", REHEARSAL_BOOKING["fare_minor"])
                link = _ask("trip share link", REHEARSAL_BOOKING["tracking_url"])
                submit_booking(queue, request_id, code, fare, link)
        except QueueError as error:
            print("  too late, the agent stopped waiting: %s" % error)
            continue
        print("sent at %.1f seconds of %d" % (elapsed(queue.read(request_id), state), target))
        if once and state == "waiting_booking":
            return
