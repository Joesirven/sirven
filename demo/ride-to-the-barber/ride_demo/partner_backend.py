"""official-partner backend: a stand-in for thread 09.

SUBSTITUTION. thread 09 (Uber for Business and Lyft Business behind the connector) had
committed nothing when this demo was built. this backend answers from a recorded fixture,
fixtures/partner-quotes.json, with invented prices. it books nothing anywhere: a booking here
is a row in memory with a fake tracking link on example.invalid, a domain that cannot resolve.
"""

import json
import secrets
from datetime import datetime, timedelta

from .connector import ConnectorError, option_for


class FixturePartnerBackend:
    def __init__(self, fixture_path):
        with open(fixture_path) as handle:
            self._options = json.load(handle)["options"]
        self._quotes = {}
        self._bookings = {}

    def quote(self, origin, destination, departure_window, user_preferences, budget_ceiling):
        options = []
        for row in self._options:
            reference = "partner-" + secrets.token_hex(4)
            option = option_for(
                reference, row["provider"], row["product"], row["price_minor"], row["tip_ceiling_minor"],
                row["pickup_minutes"], row["trip_minutes"], departure_window, user_preferences,
            )
            self._quotes[reference] = option
            options.append(option)
        return {"options": options}

    def book(self, reference, quote_id):
        if reference not in self._quotes:
            raise ConnectorError("unknown_quote", "the partner fixture has no quote %s" % reference)
        option = self._quotes[reference]
        booking_reference = "partner-booking-" + secrets.token_hex(4)
        pickup = datetime.fromisoformat(option["estimated_pickup"])
        booking = {
            "backend_reference": booking_reference,
            "status": "confirmed",
            "provider": option["provider"],
            "price": option["price"],
            "tip_ceiling": option["tip_ceiling"],
            "tracking_url": "https://example.invalid/track/" + booking_reference,
            "cancellation_window": {"free_until": (pickup - timedelta(minutes=2)).isoformat()},
            "confirmation": {"provider_confirmation": "FIXTURE", "booked_by": "fixture"},
        }
        self._bookings[booking_reference] = booking
        return dict(booking)

    def cancel(self, reference):
        if reference not in self._bookings:
            raise ConnectorError("unknown_booking", "the partner fixture has no booking %s" % reference)
        self._bookings[reference]["status"] = "cancelled"
        return {"status": "cancelled", "refund": "full", "cancelled_at": datetime.now().astimezone().isoformat(timespec="seconds")}
