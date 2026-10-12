"""shared fixtures for the ride connector tests."""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from ride_connector.fake import FakeClock, demo_connector  # noqa: E402
from ride_connector.schema import Validator  # noqa: E402

VALIDATOR = Validator()

OFFICE_POINT = {"coordinates": {"latitude": 37.7936, "longitude": -122.3958}}
BARBER_POINT = {"coordinates": {"latitude": 37.7647, "longitude": -122.4216}}
# coordinates fix the fake's distance, so prices do not hinge on how the address is spelled.
ORIGIN = dict(OFFICE_POINT, address="1 Market St, San Francisco, California", label="office")
BARBER = dict(BARBER_POINT, address="500 Valencia St, San Francisco, California", label="barber")


def window(clock, start_minutes=0, length_minutes=30):
    from datetime import timedelta
    start = clock() + timedelta(minutes=start_minutes)
    return {
        "earliest": start.isoformat(timespec="seconds"),
        "latest": (start + timedelta(minutes=length_minutes)).isoformat(timespec="seconds"),
    }


def usd(amount_minor):
    return {"amount_minor": amount_minor, "currency": "USD"}


def quote_arguments(clock, budget=5000, **preferences):
    arguments = {
        "origin": ORIGIN,
        "destination": BARBER,
        "departure_window": window(clock),
        "budget_ceiling": usd(budget),
    }
    if preferences:
        arguments["user_preferences"] = preferences
    return arguments


class ConnectorCase:
    """mixin: a fresh demo connector per test, plus checks that every payload keeps the contract."""

    def setUp(self):
        self.connector, self.clock, self.backends = demo_connector(FakeClock())

    def call(self, tool, arguments, expect_error=False):
        is_error, payload = self.connector.call(tool, arguments)
        definition = "error_output" if is_error else tool + "_output"
        self.assertEqual([], VALIDATOR.validate(payload, definition), payload)
        if expect_error is not None:
            self.assertEqual(expect_error, is_error, payload)
        return payload

    def error_code(self, tool, arguments):
        return self.call(tool, arguments, expect_error=True)["error"]["code"]

    def quote(self, **preferences):
        budget = preferences.pop("budget", 5000)
        return self.call("quote_ride", quote_arguments(self.clock, budget=budget, **preferences))

    def first(self, payload, provider=None, bookable=True):
        for option in payload["options"]:
            if (provider is None or option["provider"] == provider) and option["bookable"] == bookable:
                return option
        self.fail("no matching option in %r" % payload)
