"""the phone backend: Uber and Lyft on the owner's own iPhone, behind the demo's connector.

this is the real ride backend (connectors/ride/ride_phone/backend.py, PhoneRideBackend), used
unchanged, wrapped in the three calls the demo's Router makes: quote, book, and cancel. it
replaces the official-partner backend and the per-booking virtual cards.

how a booking is paid: nothing is paid through sirven. the agent drives the ride app as far as
checkout; the bridge holds the request tap until the owner approves it (sirven phone approve);
then the phone shows its own face recognition or Apple Pay prompt for that one purchase, and
only the owner answers it, on the phone. one approval never covers a later purchase.

what stays inside this file: the backend's option and booking references, the app's bundle
name, and the screen text. the agent sees the provider, a vehicle class as the product, the
price, and the times, the same fields as every other backend.
"""

import os
import sys
from datetime import datetime

DEMO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_DIR = os.path.dirname(os.path.dirname(DEMO_DIR))
for _path in (os.path.join(REPO_DIR, "connectors", "ride"), os.path.join(REPO_DIR, "lib")):
    if _path not in sys.path:
        sys.path.insert(0, _path)

from ride_connector.backend import BackendError, QuoteRequest  # noqa: E402
from ride_phone import PhoneRideBackend  # noqa: E402

from .connector import ConnectorError, money, option_for  # noqa: E402

BOOKED_BY = "the owner's phone, approved live"
PAID_BY = ("the owner, live, for this one purchase: the phone bridge's hold (sirven phone approve), then the "
           "phone's own face recognition or Apple Pay prompt; no card, nothing through sirven")

# the real backend's failure reasons, as the demo connector's error codes and plain words. the
# backend's own detail (the bridge's words) stays in its private log and never reaches the agent.
ERRORS = {
    "payment_declined": ("payment_declined", "the purchase was not approved, so nothing was booked or paid"),
    "price_changed": ("price_changed", "the price is now above what was approved, so nothing was booked"),
    "unavailable": ("provider_unavailable", "the ride service is not reachable right now"),
    "no_service": ("no_service", "the ride service does not serve this trip"),
    "not_cancellable": ("not_cancellable", "the ride can no longer be cancelled"),
    "rate_limited": ("rate_limited", "the ride service asked to wait before trying again"),
    "blocked": ("blocked", "the ride service refused this request"),
    "down": ("provider_down", "the ride service did not answer as expected"),
}
ERROR_CODES = {reason: code for reason, (code, _) in ERRORS.items()}


def connector_error(error):
    code, words = ERRORS.get(error.reason, ERRORS["down"])
    return ConnectorError(code, words)


class PhoneBackend:
    """client: the phone bridge's client, or the rehearsal phone. clock: None means the
    rehearsal's clock, the start of the departure window being quoted, because the rehearsal's
    calendar is a fixture on a fixed day; a live fire passes the real clock."""

    def __init__(self, client, clock=None):
        self._fixed_now = None
        self._clock = clock
        self.backend = PhoneRideBackend(client=client, clock=self.now, poll_seconds=0, sleep=lambda seconds: None)
        self._options = {}
        self._bookings = {}

    def now(self):
        if self._clock is not None:
            return self._clock()
        return self._fixed_now or datetime.now().astimezone()

    def quote(self, origin, destination, departure_window, user_preferences, budget_ceiling):
        earliest = datetime.fromisoformat(departure_window["earliest"])
        latest = datetime.fromisoformat(departure_window["latest"])
        self._fixed_now = earliest
        request = QuoteRequest(origin={"address": origin}, destination={"address": destination},
                               pickup_not_before=earliest, pickup_not_after=latest,
                               currency=budget_ceiling.get("currency", "USD"),
                               vehicle_classes=frozenset(), accessibility_needs=frozenset())
        try:
            quoted = self.backend.quote(request)
        except BackendError as error:
            # said plainly, for every service this backend would have asked, with the contract's code
            # and not the phone's own words, which stay in the backend's private log
            return {"unavailable": [{"provider": name, "reason": ERROR_CODES.get(error.reason, "provider_down")}
                                    for name in self.backend.apps]}
        now = self.now()
        options = []
        for found in quoted.options:
            pickup_minutes = int((found.pickup_at - now).total_seconds() // 60)
            # tips happen in the app afterwards, so the cap is the fare and no more
            option = option_for(found.reference, found.provider, found.vehicle_class.title(), found.fare_minor, 0,
                                pickup_minutes, found.trip_minutes, departure_window, user_preferences)
            self._options[found.reference] = found
            options.append(option)
        return {"options": options}

    def book(self, reference, quote_id):
        found = self._options.get(reference)
        if found is None:
            raise ConnectorError("unknown_quote", "that option is no longer on the phone")
        try:
            booked = self.backend.book(reference, None, found.fare_maximum_minor)
        except BackendError as error:
            raise connector_error(error)
        self._bookings[booked.reference] = found
        return {
            "backend_reference": booked.reference,
            "status": "confirmed" if booked.confirmed else "pending",
            "provider": found.provider,
            # the backend books only at or under the quoted fare, so this is the most it can be
            "price": money(found.fare_minor, found.currency),
            "tip_ceiling": money(0, found.currency),
            "tracking_url": "the %s app on your phone" % found.provider,
            "cancellation_window": {
                "free_until": found.cancellation_free_until.isoformat(),
                "terms": "assumed two minutes before pickup until checked against %s's published terms" % found.provider,
            },
            "confirmation": {
                "provider_confirmation": booked.vehicle_description or "shown in the %s app" % found.provider,
                "booked_by": BOOKED_BY,
                "paid_by": PAID_BY,
            },
        }

    def cancel(self, reference):
        found = self._bookings.get(reference)
        if found is None:
            raise ConnectorError("unknown_booking", "no such booking on this phone")
        try:
            cancelled = self.backend.cancel(reference, found.cancellation_fee_minor)
        except BackendError as error:
            raise connector_error(error)
        return {"status": "cancelled", "fee": money(cancelled.fee_minor, found.currency),
                "cancelled_at": self.now().isoformat(timespec="seconds")}
