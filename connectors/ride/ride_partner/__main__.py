"""a fixture round trip through the three calls, printed as JSON:

  python3 -m ride_partner        (run from connectors/ride)

nothing leaves the machine: fixture mode only, with a stand-in money layer that only
prints what it would do."""

import json
import sys

from . import build_backend

FIXTURE_NOW = 1791000000


class PrintingPayments:
    def authorize(self, reference, amount_minor, currency):
        print("money layer: authorize %s %s for %s" % (amount_minor, currency, reference), file=sys.stderr)
        return reference

    def capture(self, handle, amount_minor):
        print("money layer: capture %s on %s" % (amount_minor, handle), file=sys.stderr)

    def release(self, handle):
        print("money layer: release %s" % handle, file=sys.stderr)


def main():
    backend = build_backend(PrintingPayments(), lambda user_ref: {
        "first_name": "Sample", "last_name": "Rider", "phone_number": "+14155550100"},
        mode="fixture", clock=lambda: FIXTURE_NOW)
    quotes = backend.quote_ride(
        origin={"latitude": 37.7793, "longitude": -122.4193, "address": "San Francisco City Hall"},
        destination={"latitude": 37.7609, "longitude": -122.4350, "address": "Castro Street"},
        departure_window={"earliest": FIXTURE_NOW, "latest": FIXTURE_NOW + 900},
        user_preferences={"optimize_for": "price"},
        budget_ceiling={"amount_minor": 4000, "currency": "USD"},
        user_ref="sample-user",
    )
    print(json.dumps(quotes, indent=2))
    booking = backend.book_ride(quotes["quotes"][0]["quote_id"])
    print(json.dumps(booking, indent=2))
    print(json.dumps(backend.cancel_ride(booking["booking_id"]), indent=2))


main()
