"""a fixture round trip through the contract's three calls, printed as JSON:

  python3 -m ride_partner        (run from connectors/ride)

nothing leaves the machine: fixture mode only, and the payment reference is a stand-in for
funds the money layer would hold."""

import json
from datetime import datetime, timedelta, timezone

from . import build_connector

FIXTURE_NOW = datetime.fromtimestamp(1791000000, timezone.utc)


def main():
    connector, _ = build_connector(lambda: FIXTURE_NOW, {
        "first_name": "Sample", "last_name": "Rider", "phone_number": "+14155550100"}, mode="fixture")
    _, quotes = connector.quote_ride(
        origin={"coordinates": {"latitude": 37.7793, "longitude": -122.4193}, "label": "City Hall"},
        destination={"coordinates": {"latitude": 37.7609, "longitude": -122.4350}, "label": "barber"},
        departure_window={"earliest": FIXTURE_NOW.isoformat(), "latest": (FIXTURE_NOW + timedelta(hours=1)).isoformat()},
        budget_ceiling={"amount_minor": 4000, "currency": "USD"},
        user_preferences={"ranking": "cheapest"},
    )
    print(json.dumps(quotes, indent=2))
    _, booking = connector.book_ride(quote_id=quotes["options"][0]["quote_id"], payment_reference="hold_sample")
    print(json.dumps(booking, indent=2))
    print(json.dumps(connector.cancel_ride(booking_id=booking["booking"]["booking_id"])[1], indent=2))


main()
