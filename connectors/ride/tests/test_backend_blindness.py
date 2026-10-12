"""the agent cannot tell which backend produced a quote or a booking."""

import json
import unittest

from helpers import VALIDATOR, quote_arguments
from ride_connector.backend import BackendError
from ride_connector.fake import FakeClock, FakeProduct, FakeRideBackend
from ride_connector.gateway import RideConnector

SAME = FakeProduct("Citywide", "standard", base_minor=300, per_km_minor=145)
BACKEND_SECRETS = ("alpha", "bravo", "option-", "booking-", "carrier internal")


def twin_connector():
    """two backends selling the identical product, so only leaks could tell them apart."""
    clock = FakeClock()
    alpha = FakeRideBackend(products=[SAME], clock=clock)
    bravo = FakeRideBackend(products=[SAME], clock=clock, serial=900)
    return RideConnector({"alpha": alpha, "bravo": bravo}, clock=clock), clock, {"alpha": alpha, "bravo": bravo}


class BlindnessTests(unittest.TestCase):
    def setUp(self):
        self.connector, self.clock, self.backends = twin_connector()

    def call(self, tool, arguments):
        is_error, payload = self.connector.call(tool, arguments)
        self.assertEqual([], VALIDATOR.validate(payload, "error_output" if is_error else tool + "_output"))
        self.assert_no_secrets(payload)
        return is_error, payload

    def assert_no_secrets(self, payload):
        text = json.dumps(payload).lower()
        for secret in BACKEND_SECRETS:
            self.assertNotIn(secret, text)

    def test_identical_products_from_different_backends_are_indistinguishable(self):
        _, payload = self.call("quote_ride", quote_arguments(self.clock))
        self.assertEqual(2, len(payload["options"]))
        stripped = [{k: v for k, v in option.items() if k not in ("quote_id", "rank")} for option in payload["options"]]
        self.assertEqual(stripped[0], stripped[1])

    def test_bookings_from_different_backends_are_indistinguishable(self):
        _, payload = self.call("quote_ride", quote_arguments(self.clock))
        bookings = []
        for option in payload["options"]:
            _, booked = self.call("book_ride", {"quote_id": option["quote_id"]})
            bookings.append({k: v for k, v in booked["booking"].items() if k not in ("booking_id", "quote_id")})
        self.assertEqual(bookings[0], bookings[1])

    def test_rank_order_does_not_follow_backend_order(self):
        winners = set()
        for _ in range(40):
            _, payload = self.call("quote_ride", quote_arguments(self.clock))
            first = payload["options"][0]["quote_id"]
            winners.add(self.connector._quotes[first]["backend"])
        self.assertEqual({"alpha", "bravo"}, winners)

    def test_backend_error_detail_never_reaches_the_agent(self):
        self.backends["alpha"].refuse = "down"
        self.backends["bravo"].refuse = "down"
        self.backends["alpha"].quote = _raiser(BackendError("down", "carrier internal 500 at alpha.example"))
        is_error, payload = self.call("quote_ride", quote_arguments(self.clock))
        self.assertTrue(is_error)
        self.assertTrue(any("carrier internal" in entry.get("detail", "") for entry in self.connector.private_log))

    def test_a_backend_bug_is_partial_results_without_detail(self):
        self.backends["alpha"].quote = _raiser(RuntimeError("alpha exploded"))
        is_error, payload = self.call("quote_ride", quote_arguments(self.clock))
        self.assertFalse(is_error)
        self.assertEqual(["partial_results"], [notice["code"] for notice in payload["notices"]])
        self.assertEqual(1, len(payload["options"]))

    def test_identifiers_are_random_not_derived(self):
        _, first = self.call("quote_ride", quote_arguments(self.clock))
        _, second = self.call("quote_ride", quote_arguments(self.clock))
        ids = [o["quote_id"] for o in first["options"] + second["options"]]
        self.assertEqual(len(ids), len(set(ids)))

    def test_a_backend_cannot_slip_a_field_through(self):
        # results are rebuilt from records; even if a bug copied an extra field in, the schema
        # check on the way out turns it into internal_error instead of a leak.
        original = self.connector._describe

        def leaky(*args, **kwargs):
            described = original(*args, **kwargs)
            described["carrier_trip_id"] = "alpha-123"
            return described

        self.connector._describe = leaky
        is_error, payload = self.call("quote_ride", quote_arguments(self.clock))
        self.assertTrue(is_error)
        self.assertEqual("internal_error", payload["error"]["code"])


def _raiser(error):
    def raise_it(*args, **kwargs):
        raise error
    return raise_it


if __name__ == "__main__":
    unittest.main()
