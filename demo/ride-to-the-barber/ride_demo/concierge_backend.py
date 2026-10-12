"""concierge backend: Waymo through a person, behind the same connector as every backend.

the agent never learns that this backend exists. it sees a Waymo option like any other. what
it does see, because Jose decided the user is told plainly where a concierge operates, is the
consent the user gave before a person saw the trip, and the name of the concierge who booked.

the quote and the booking each wait on the concierge queue for at most their service-level
target. a late answer is withdrawn, recorded as a missed target, and reported; it is never
waited on silently and never routed around.

payment: none, in this build. the concierge receives no card and no payment details, only the
cap the user approved (the price the concierge quoted, with no tip) and a plain note that this
path has no payment method yet. how a concierge pays Waymo is a decision left for Jose. a fare
above the cap is still refused: nothing is booked at a price the user did not approve.
"""

import time
from datetime import datetime, timedelta

from . import service_levels
from .concierge_queue import QueueError
from .connector import ConnectorError, dollars, money, option_for

PROVIDER = "Waymo"
PRODUCT = "Waymo One"
NO_PAYMENT_METHOD = ("the concierge path has no payment method in this build; how a concierge pays "
                     "is Jose's decision. book nothing above the cap.")
PAID_BY = "nothing in this build: the concierge path has no payment method yet"


class ConciergeBackend:
    def __init__(self, queue, service_level_log, notify=print, poll_seconds=0.25,
                 quote_wait_seconds=service_levels.QUOTE_TARGET_SECONDS,
                 booking_wait_seconds=service_levels.BOOKING_TARGET_SECONDS):
        self.queue = queue
        self.service_level_log = service_level_log
        self.notify = notify
        self.poll_seconds = poll_seconds
        self.quote_wait_seconds = quote_wait_seconds
        self.booking_wait_seconds = booking_wait_seconds
        self.measurements = []
        self._pickups = {}
        self._caps = {}

    def _wait(self, request_id, done_states, seconds):
        deadline = time.monotonic() + seconds
        seen = None
        while time.monotonic() < deadline:
            request = self.queue.read(request_id)
            if request["state"] != seen:
                seen = request["state"]
                if seen.endswith("_claimed"):
                    self.notify("concierge %s claimed the request" % request["concierge"]["name"])
            if request["state"] in done_states:
                return request
            time.sleep(self.poll_seconds)
        return None

    def _withdraw(self, request_id, expected, reason):
        try:
            self.queue.move(request_id, expected, "withdrawn", withdrawn_because=reason)
            return None
        except QueueError:
            # the concierge answered in the instant between the deadline and the withdrawal.
            return self.queue.read(request_id)

    def _seen_by(self, request_id):
        """the concierge who claimed the request, or None when no one claimed it. a request
        that reached the queue is reported either way, so a failure never hides a person."""
        return self.queue.read(request_id).get("concierge", {}).get("name")

    def quote(self, origin, destination, departure_window, user_preferences, budget_ceiling):
        consent = user_preferences.get("human_assisted_booking")
        if not consent or not consent.get("granted"):
            return {"unavailable": [{"provider": PROVIDER, "reason": "needs_consent_for_human_assisted_booking"}]}
        # exactly what the disclosure says a concierge sees, and nothing else: no budget, and
        # no arrival time, because that comes from the user's calendar.
        trip = {"origin": origin, "destination": destination, "departure_window": departure_window,
                "provider": PROVIDER}
        request = self.queue.create(trip, consent)
        request_id = request["request_id"]
        started = self.queue.entered(request, "waiting_quote")
        self.notify("request %s is in the concierge queue, waiting for a quote" % request_id)
        answered = self._wait(request_id, ("quoted", "declined"), self.quote_wait_seconds)
        if answered is None:
            answered = self._withdraw(request_id, ("waiting_quote", "quote_claimed"), "quote_target_missed")
        if answered is None:
            entry = service_levels.missed(self.service_level_log, request_id, "quote", started,
                                          service_levels.QUOTE_TARGET_SECONDS, self.quote_wait_seconds)
            self.measurements.append(entry)
            self.notify(service_levels.describe(entry))
            return {"unavailable": [{"provider": PROVIDER, "reason": "quote_target_missed",
                                     "seen_by": self._seen_by(request_id)}]}
        if answered["state"] == "declined":
            reason = "declined: " + answered.get("declined_because", "no reason given")
            return {"unavailable": [{"provider": PROVIDER, "reason": reason, "seen_by": self._seen_by(request_id)}]}
        entry = service_levels.measure(self.service_level_log, request_id, "quote", started,
                                       self.queue.entered(answered, "quoted"), service_levels.QUOTE_TARGET_SECONDS)
        self.measurements.append(entry)
        self.notify(service_levels.describe(entry))
        seen = answered["quote"]
        option = option_for(request_id, PROVIDER, PRODUCT, seen["price_minor"], 0, seen["pickup_minutes"],
                            seen["trip_minutes"], departure_window, user_preferences)
        self._pickups[request_id] = datetime.fromisoformat(option["estimated_pickup"])
        # the most the user can approve for this ride: the quoted price, and no tip
        self._caps[request_id] = seen["price_minor"]
        return {"options": [option]}

    def book(self, request_id, quote_id):
        cap = self._caps.get(request_id)
        if cap is None:
            raise ConnectorError("unknown_quote", "no concierge quote %s" % quote_id)
        request = self.queue.move(request_id, "quoted", "waiting_booking",
                                  payment={"cap_minor": cap, "note": NO_PAYMENT_METHOD})
        started = self.queue.entered(request, "waiting_booking")
        self.notify("request %s is waiting for the concierge to book" % request_id)
        answered = self._wait(request_id, ("booked", "declined"), self.booking_wait_seconds)
        if answered is None:
            answered = self._withdraw(request_id, ("waiting_booking", "booking_claimed"), "booking_target_missed")
        if answered is None:
            entry = service_levels.missed(self.service_level_log, request_id, "booking", started,
                                          service_levels.BOOKING_TARGET_SECONDS, self.booking_wait_seconds)
            self.measurements.append(entry)
            self.notify(service_levels.describe(entry))
            raise ConnectorError("booking_target_missed", "the concierge did not confirm inside the booking target",
                                 seen_by=self._seen_by(request_id))
        if answered["state"] == "declined":
            raise ConnectorError("provider_declined", answered.get("declined_because", "the concierge could not book"),
                                 seen_by=self._seen_by(request_id))
        entry = service_levels.measure(self.service_level_log, request_id, "booking", started,
                                       self.queue.entered(answered, "booked"), service_levels.BOOKING_TARGET_SECONDS)
        self.measurements.append(entry)
        self.notify(service_levels.describe(entry))
        result = answered["booking"]
        if result["fare_minor"] > cap:
            self.queue.move(request_id, "booked", "withdrawn",
                            withdrawn_because="fare over the cap the user approved: cancel this ride in the Waymo app")
            raise ConnectorError("price_changed", "the fare the concierge saw, %s, is above the %s cap the user approved; "
                                 "the concierge must cancel the ride" % (dollars(money(result["fare_minor"])),
                                                                         dollars(money(cap))),
                                 seen_by=self._seen_by(request_id))
        pickup = self._pickups[request_id]
        return {
            "backend_reference": request_id,
            "status": "confirmed",
            "provider": PROVIDER,
            "price": {"amount_minor": result["fare_minor"], "currency": "USD"},
            "tip_ceiling": {"amount_minor": 0, "currency": "USD"},
            "tracking_url": result["tracking_url"],
            "cancellation_window": {
                "free_until": (pickup - timedelta(minutes=2)).isoformat(),
                "terms": "rehearsal assumption; Waymo's own cancellation terms are not yet checked",
            },
            "confirmation": {
                "provider_confirmation": result["confirmation_code"],
                "booked_by": "concierge " + answered["concierge"]["name"],
                "paid_by": PAID_BY,
            },
        }

    def cancel(self, request_id):
        request = self.queue.move(request_id, "booked", "withdrawn", withdrawn_because="user_cancelled")
        return {"status": "cancel_requested", "refund": "pending the concierge cancelling in the Waymo app",
                "request_id": request["request_id"]}
