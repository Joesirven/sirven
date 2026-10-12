"""concierge backend: Waymo through a person, behind the same connector as every backend.

the agent never learns that this backend exists. it sees a Waymo option like any other. what
it does see, because Jose decided the user is told plainly where a concierge operates, is the
consent the user gave before a person saw the trip, and the name of the concierge who booked.

the quote and the booking each wait on the concierge queue for at most their service-level
target. a late answer is withdrawn, recorded as a missed target, and reported; it is never
waited on silently and never routed around.
"""

import time
from datetime import datetime, timedelta

from . import service_levels
from .concierge_queue import QueueError
from .connector import ConnectorError, option_for
from .payment import RIDE_CATEGORY, Declined

PROVIDER = "Waymo"
PRODUCT = "Waymo One"


class ConciergeBackend:
    def __init__(self, queue, cards, service_level_log, notify=print, poll_seconds=0.25,
                 quote_wait_seconds=service_levels.QUOTE_TARGET_SECONDS,
                 booking_wait_seconds=service_levels.BOOKING_TARGET_SECONDS):
        self.queue = queue
        self.cards = cards
        self.service_level_log = service_level_log
        self.notify = notify
        self.poll_seconds = poll_seconds
        self.quote_wait_seconds = quote_wait_seconds
        self.booking_wait_seconds = booking_wait_seconds
        self.measurements = []
        self._pickups = {}

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

    def quote(self, origin, destination, departure_window, user_preferences, budget_ceiling):
        consent = user_preferences.get("human_assisted_booking")
        if not consent or not consent.get("granted"):
            return {"unavailable": [{"provider": PROVIDER, "reason": "needs_consent_for_human_assisted_booking"}]}
        trip = {
            "origin": origin,
            "destination": destination,
            "departure_window": departure_window,
            "arrive_by": user_preferences.get("arrive_by"),
            "budget_ceiling": budget_ceiling,
            "provider": PROVIDER,
        }
        request = self.queue.create(trip, consent)
        request_id = request["request_id"]
        started = self.queue.entered(request, "waiting_quote")
        self.notify("request %s is in the concierge queue, waiting for a quote" % request_id)
        answered = self._wait(request_id, ("quoted", "declined"), self.quote_wait_seconds)
        if answered is None:
            answered = self._withdraw(request_id, ("waiting_quote", "quote_claimed"), "quote_target_missed")
        if answered is None:
            entry = service_levels.missed(self.service_level_log, request_id, "quote", started,
                                          service_levels.QUOTE_TARGET_SECONDS)
            self.measurements.append(entry)
            self.notify(service_levels.describe(entry))
            return {"unavailable": [{"provider": PROVIDER, "reason": "quote_target_missed"}]}
        if answered["state"] == "declined":
            reason = "declined: " + answered.get("declined_because", "no reason given")
            return {"unavailable": [{"provider": PROVIDER, "reason": reason}]}
        entry = service_levels.measure(self.service_level_log, request_id, "quote", started,
                                       self.queue.entered(answered, "quoted"), service_levels.QUOTE_TARGET_SECONDS)
        self.measurements.append(entry)
        self.notify(service_levels.describe(entry))
        seen = answered["quote"]
        option = option_for(request_id, PROVIDER, PRODUCT, seen["price_minor"], 0, seen["pickup_minutes"],
                            seen["trip_minutes"], departure_window, user_preferences)
        self._pickups[request_id] = datetime.fromisoformat(option["estimated_pickup"])
        return {"options": [option]}

    def book(self, request_id, quote_id):
        card = self.cards.card_for_quote(quote_id)
        if card is None:
            raise ConnectorError("payment_required", "no held card for quote %s" % quote_id)
        request = self.queue.move(request_id, "quoted", "waiting_booking", payment={
            "card_id": card["card_id"],
            "mode": card["mode"],
            "last4": card["last4"],
            "spending_limit_minor": card["spending_limit_minor"],
            "allowed_categories": card["allowed_categories"],
        })
        started = self.queue.entered(request, "waiting_booking")
        self.notify("request %s is waiting for the concierge to book" % request_id)
        answered = self._wait(request_id, ("booked", "declined"), self.booking_wait_seconds)
        if answered is None:
            answered = self._withdraw(request_id, ("waiting_booking", "booking_claimed"), "booking_target_missed")
        if answered is None:
            entry = service_levels.missed(self.service_level_log, request_id, "booking", started,
                                          service_levels.BOOKING_TARGET_SECONDS)
            self.measurements.append(entry)
            self.notify(service_levels.describe(entry))
            raise ConnectorError("booking_target_missed", "the concierge did not confirm inside the booking target")
        if answered["state"] == "declined":
            raise ConnectorError("provider_declined", answered.get("declined_because", "the concierge could not book"))
        entry = service_levels.measure(self.service_level_log, request_id, "booking", started,
                                       self.queue.entered(answered, "booked"), service_levels.BOOKING_TARGET_SECONDS)
        self.measurements.append(entry)
        self.notify(service_levels.describe(entry))
        result = answered["booking"]
        try:
            self.cards.authorize(card["card_id"], result["fare_minor"], RIDE_CATEGORY)
        except Declined as declined:
            raise ConnectorError("payment_declined", "the fare the concierge saw was declined: %s; "
                                 "the concierge must cancel the ride" % declined.reason)
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
            },
        }

    def cancel(self, request_id):
        request = self.queue.move(request_id, "booked", "withdrawn", withdrawn_because="user_cancelled")
        return {"status": "cancel_requested", "refund": "pending the concierge cancelling in the Waymo app",
                "request_id": request["request_id"]}
