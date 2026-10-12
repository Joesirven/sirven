"""the official-partner backend behind the contract gateway, against recorded carrier fixtures.

every payload goes through the gateway and is checked against the contract schema, so these
are the contract's own quote, book, and cancel round trips with Uber for Business and Lyft
Business underneath. run from connectors/ride/tests:

  python3 -m unittest test_partner_backend
"""

import glob
import json
import logging
import os
import unittest
from datetime import datetime, timedelta, timezone

from helpers import VALIDATOR, usd

from ride_connector.backend import BackendError, QuoteRequest
from ride_connector.fake import FakeClock, demo_backends
from ride_partner import LiveCallsBlocked, LyftBusiness, PartnerApprovalRequired, UberForBusiness, build_connector
from ride_partner import build_backend
from ride_partner.transport import FIXTURES_DIR, SandboxTransport, transport_for

# carrier failures are logged for operators; these tests check them through behavior.
logging.getLogger("sirven.ride_partner").setLevel(logging.CRITICAL)

NOW = datetime.fromtimestamp(1791000000, timezone.utc)
CITY_HALL = {"coordinates": {"latitude": 37.7793, "longitude": -122.4193}, "label": "City Hall"}
BARBER = {"coordinates": {"latitude": 37.7609, "longitude": -122.4350}, "label": "barber"}
RIDER = {"first_name": "Sample", "last_name": "Rider", "phone_number": "+14155550100"}


def carrier_secrets():
    """every carrier token, identifier, and error text in the fixtures."""
    found = set()

    def walk(value):
        if isinstance(value, dict):
            for item in value.values():
                walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)
        elif isinstance(value, str) and value.startswith("fixture-") and value != "fixture-organization":
            found.add(value)

    for path in glob.glob(os.path.join(FIXTURES_DIR, "*", "*.json")):
        with open(path, encoding="utf-8") as handle:
            walk(json.load(handle))
    return found


# words that would name the integration rather than the provider.
INTEGRATION_WORDS = (
    "fare_id", "cost_token", "request_id", "ride_id", "product_id", "ride_type", "guests", "concierge",
    "partner", "official", "uber.com", "lyft.com", "UberX", "UberXL", "Lyft XL", "Lux", "organization",
    "expense", "fixture",
)


class PartnerCase(unittest.TestCase):
    scenarios = None

    def setUp(self):
        self.clock = FakeClock(NOW)
        self.connector, self.backend = self.build(self.scenarios)
        self.seen = []

    def build(self, scenarios):
        return build_connector(self.clock, dict(RIDER), mode="fixture", scenarios=scenarios)

    def call(self, tool, arguments, expect_error=False, connector=None):
        is_error, payload = (connector or self.connector).call(tool, arguments)
        definition = "error_output" if is_error else tool + "_output"
        self.assertEqual([], VALIDATOR.validate(payload, definition), payload)
        self.assertEqual(expect_error, is_error, payload)
        self.seen.append(payload)
        return payload

    def quote(self, connector=None, budget=4000, **preferences):
        arguments = {
            "origin": CITY_HALL,
            "destination": BARBER,
            "departure_window": {"earliest": NOW.isoformat(), "latest": (NOW + timedelta(minutes=30)).isoformat()},
            "budget_ceiling": usd(budget),
        }
        if preferences:
            arguments["user_preferences"] = preferences
        return self.call("quote_ride", arguments, connector=connector)

    def option(self, payload, provider, vehicle_class="standard"):
        for option in payload["options"]:
            if option["provider"] == provider and option["vehicle_class"] == vehicle_class:
                return option
        self.fail("no %s %s option in %r" % (provider, vehicle_class, payload))

    def book(self, provider, connector=None, vehicle_class="standard"):
        option = self.option(self.quote(connector), provider, vehicle_class)
        return self.call("book_ride", {"quote_id": option["quote_id"], "payment_reference": "hold_test"},
                         connector=connector)["booking"]

    def carrier(self, name, backend=None):
        return next(carrier for carrier in (backend or self.backend).carriers if carrier.name == name)

    def sent(self, name, method=None, backend=None):
        return [call for call in self.carrier(name, backend).transport.calls if method in (None, call["method"])]


class QuoteTests(PartnerCase):
    def test_both_carriers_answer_with_contract_vehicle_classes(self):
        pairs = sorted((option["provider"], option["vehicle_class"]) for option in self.quote()["options"])
        # Uber Pet has no contract class; Lyft Lux Black's estimate is not valid.
        self.assertEqual([("Lyft", "large"), ("Lyft", "standard"), ("Uber", "large"),
                          ("Uber", "premium"), ("Uber", "standard")], pairs)

    def test_upfront_fares_are_fixed_and_ranges_are_estimates(self):
        payload = self.quote()
        uber, lyft = self.option(payload, "Uber"), self.option(payload, "Lyft")
        self.assertEqual("fixed", uber["price"]["kind"])
        self.assertEqual(2350, uber["price"]["amount"]["amount_minor"])
        self.assertEqual("estimate", lyft["price"]["kind"])
        self.assertEqual((1800, 2400), (lyft["price"]["amount"]["amount_minor"], lyft["price"]["maximum"]["amount_minor"]))
        self.assertIn("price_is_estimate", lyft["constraint_flags"])
        self.assertEqual(2400, lyft["charge_terms"]["fare_ceiling"]["amount_minor"])

    def test_surge_and_budget_flags(self):
        payload = self.quote()
        self.assertIn("surge_pricing", self.option(payload, "Lyft", "large")["constraint_flags"])
        premium = self.option(payload, "Uber", "premium")
        self.assertIn("over_budget", premium["constraint_flags"])
        self.assertFalse(premium["bookable"])

    def test_estimated_times_come_from_the_carrier(self):
        uber = self.option(self.quote(), "Uber")
        self.assertEqual(4, uber["estimated_pickup_wait_minutes"])
        self.assertEqual(18, uber["estimated_trip_minutes"])
        self.assertEqual((NOW + timedelta(minutes=5)).isoformat(timespec="seconds"), uber["expires_at"])

    def test_the_carrier_is_asked_with_coordinates(self):
        self.quote()
        body = self.sent("uber_for_business", "POST")[0]["body"]
        self.assertEqual({"latitude": 37.7793, "longitude": -122.4193}, body["pickup"])
        query = self.sent("lyft_business", "GET")[0]["query"]
        self.assertEqual(37.7609, query["end_lat"])

    def test_one_carrier_down_still_quotes_the_other(self):
        connector, _ = self.build({"lyft_business": "unavailable"})
        self.assertEqual({"Uber"}, {option["provider"] for option in self.quote(connector)["options"]})

    def test_address_only_places_need_a_geocoder(self):
        backend = build_backend(self.clock, dict(RIDER), mode="fixture")
        request = QuoteRequest(origin={"address": "1 Market St"}, destination=BARBER,
                               pickup_not_before=NOW, pickup_not_after=NOW, currency="USD",
                               vehicle_classes=frozenset(), accessibility_needs=frozenset())
        with self.assertRaises(BackendError) as caught:
            backend.quote(request)
        self.assertEqual("no_service", caught.exception.reason)
        geocoded = build_backend(self.clock, dict(RIDER), mode="fixture",
                                 geocode=lambda address: {"latitude": 37.7936, "longitude": -122.3958})
        self.assertTrue(geocoded.quote(request).options)


class BookTests(PartnerCase):
    def test_uber_booking_bills_the_corporate_account_with_the_quoted_fare(self):
        booking = self.book("Uber")
        self.assertEqual("confirmed", booking["status"])
        trip = [call for call in self.sent("uber_for_business", "POST") if call["path"] == "/v1/guests/trips"][0]
        self.assertEqual("fixture-uber-fare-uberx", trip["body"]["fare_id"])
        self.assertEqual("sirven-rides", trip["body"]["expense_code"])
        self.assertEqual("Sample", trip["body"]["guest"]["first_name"])
        self.assertNotIn("hold_test", json.dumps(trip["body"]))

    def test_lyft_booking_sends_the_cost_token_and_organization(self):
        self.book("Lyft")
        trip = [call for call in self.sent("lyft_business", "POST") if call["path"] == "/v1/concierge/rides"][0]
        self.assertEqual("fixture-lyft-cost-token-standard", trip["body"]["cost_token"])
        self.assertEqual("fixture-organization", trip["body"]["organization_id"])

    def test_no_held_funds_means_no_carrier_request(self):
        option = self.option(self.quote(), "Uber")
        payload = self.call("book_ride", {"quote_id": option["quote_id"]}, expect_error=True)
        self.assertEqual("payment_required", payload["error"]["code"])
        # and the backend refuses on its own, whatever gateway sits in front of it.
        with self.assertRaises(BackendError) as caught:
            self.backend.book("option-1", None, 2820)
        self.assertEqual("payment_declined", caught.exception.reason)
        self.assertEqual([], [call for call in self.sent("uber_for_business", "POST") if call["path"] == "/v1/guests/trips"])

    def test_booking_twice_requests_one_trip(self):
        option = self.option(self.quote(), "Uber")
        arguments = {"quote_id": option["quote_id"], "payment_reference": "hold_test"}
        first = self.call("book_ride", arguments)
        second = self.call("book_ride", arguments)
        self.assertEqual(first["booking"], second["booking"])
        self.assertTrue(second["replayed"])
        self.assertEqual(1, len([call for call in self.sent("uber_for_business", "POST") if call["path"] == "/v1/guests/trips"]))

    def test_expired_quote_never_reaches_the_carrier(self):
        option = self.option(self.quote(), "Uber")
        self.clock.advance(minutes=6)
        payload = self.call("book_ride", {"quote_id": option["quote_id"], "payment_reference": "hold_test"}, expect_error=True)
        self.assertEqual("quote_expired", payload["error"]["code"])

    def test_carrier_failure_is_a_plain_contract_error(self):
        connector, _ = self.build({"uber_for_business": "booking_fails"})
        option = self.option(self.quote(connector), "Uber")
        payload = self.call("book_ride", {"quote_id": option["quote_id"], "payment_reference": "hold_test"},
                            expect_error=True, connector=connector)
        self.assertEqual("service_unavailable", payload["error"]["code"])
        self.assertTrue(payload["error"]["retryable"])


class StatusAndCancelTests(PartnerCase):
    def test_status_carries_the_vehicle_once_a_driver_is_assigned(self):
        connector, _ = self.build({"uber_for_business": "trip_underway"})
        booking = self.book("Uber", connector)
        ride = self.call("get_ride", {"booking_id": booking["booking_id"]}, connector=connector)["booking"]
        self.assertEqual("driver_assigned", ride["status"])
        self.assertEqual("Silver Toyota Prius, plate 8FIX123", ride["tracking"]["vehicle_description"])

    def test_uber_completion_waits_for_the_receipt(self):
        connector, _ = self.build({"uber_for_business": "completed"})
        booking = self.book("Uber", connector)
        first = self.call("get_ride", {"booking_id": booking["booking_id"]}, connector=connector)["booking"]
        self.assertEqual("in_progress", first["status"])
        self.assertIsNone(first["final_charge"])
        done = self.call("get_ride", {"booking_id": booking["booking_id"]}, connector=connector)["booking"]
        self.assertEqual("completed", done["status"])
        # the fare ceiling is the upfront fare, so the 2280 fare stands and the tip fits the ceiling.
        self.assertEqual(2280, done["final_charge"]["fare"]["amount_minor"])
        self.assertEqual(300, done["final_charge"]["tip"]["amount_minor"])

    def test_lyft_completion_reads_fare_and_tip(self):
        connector, _ = self.build({"lyft_business": "completed"})
        booking = self.book("Lyft", connector)
        done = self.call("get_ride", {"booking_id": booking["booking_id"]}, connector=connector)["booking"]
        self.assertEqual("completed", done["status"])
        self.assertEqual(2210, done["final_charge"]["fare"]["amount_minor"])

    def test_cancel_inside_the_free_window_costs_nothing(self):
        booking = self.book("Uber")
        result = self.call("cancel_ride", {"booking_id": booking["booking_id"]})["booking"]
        self.assertEqual("cancelled", result["status"])
        self.assertEqual(0, result["final_charge"]["total"]["amount_minor"])
        self.assertEqual(1, len(self.sent("uber_for_business", "DELETE")))

    def test_late_uber_cancel_charges_the_policy_fee(self):
        booking = self.book("Uber")
        self.clock.advance(minutes=3)
        result = self.call("cancel_ride", {"booking_id": booking["booking_id"]})["booking"]
        self.assertEqual(500, result["final_charge"]["cancellation_fee"]["amount_minor"])

    def test_lyft_confirms_its_named_fee(self):
        connector, backend = self.build({"lyft_business": "cancel_with_fee"})
        booking = self.book("Lyft", connector)
        self.clock.advance(minutes=3)
        result = self.call("cancel_ride", {"booking_id": booking["booking_id"]}, connector=connector)["booking"]
        self.assertEqual(500, result["final_charge"]["cancellation_fee"]["amount_minor"])
        confirm = self.sent("lyft_business", "POST", backend)[-1]
        self.assertEqual({"cancel_confirmation_token": "fixture-lyft-cancel-token"}, confirm["body"])

    def test_a_lyft_fee_inside_the_free_window_is_not_passed_on(self):
        connector, _ = self.build({"lyft_business": "cancel_with_fee"})
        booking = self.book("Lyft", connector)
        result = self.call("cancel_ride", {"booking_id": booking["booking_id"]}, connector=connector)["booking"]
        self.assertEqual(0, result["final_charge"]["cancellation_fee"]["amount_minor"])

    def test_cancelling_twice_cancels_once(self):
        booking = self.book("Uber")
        self.call("cancel_ride", {"booking_id": booking["booking_id"]})
        again = self.call("cancel_ride", {"booking_id": booking["booking_id"]})
        self.assertTrue(again["already_cancelled"])
        self.assertEqual(1, len(self.sent("uber_for_business", "DELETE")))

    def test_a_carrier_refusing_to_cancel_is_not_cancellable(self):
        connector, backend = self.build({"uber_for_business": "trip_underway"})
        booking = self.book("Uber", connector)
        payload = self.call("cancel_ride", {"booking_id": booking["booking_id"]}, expect_error=True, connector=connector)
        self.assertEqual("not_cancellable", payload["error"]["code"])


class BlindnessTests(PartnerCase):
    """the calling agent must not be able to tell this backend produced the quote."""

    def exercise(self):
        for scenarios in ({}, {"uber_for_business": "booking_fails"}, {"lyft_business": "cancel_with_fee"},
                          {"uber_for_business": "trip_underway"}, {"uber_for_business": "completed"},
                          {"lyft_business": "completed"}):
            connector, _ = self.build(scenarios)
            for option in self.quote(connector, budget=9000)["options"]:
                is_error, booked = connector.call("book_ride", {"quote_id": option["quote_id"], "payment_reference": "hold_test"})
                self.seen.append(booked)
                if not is_error:
                    booking_id = booked["booking"]["booking_id"]
                    self.seen.append(connector.call("get_ride", {"booking_id": booking_id})[1])
                    self.seen.append(connector.call("cancel_ride", {"booking_id": booking_id})[1])

    def test_no_carrier_token_or_integration_word_reaches_the_caller(self):
        self.exercise()
        text = json.dumps(self.seen)
        for secret in carrier_secrets():
            self.assertNotIn(secret, text)
        for word in INTEGRATION_WORDS:
            self.assertNotIn(word, text)

    def test_options_have_the_same_shape_as_any_other_backend(self):
        ours = self.quote()["options"][0]
        clock = FakeClock()
        from ride_connector.gateway import RideConnector
        theirs_connector = RideConnector({"other": demo_backends(clock)["partner"]}, clock=clock)
        _, theirs = theirs_connector.quote_ride(
            origin=CITY_HALL, destination=BARBER, budget_ceiling=usd(9000),
            departure_window={"earliest": clock().isoformat(), "latest": (clock() + timedelta(minutes=30)).isoformat()})

        def shape(value):
            if isinstance(value, dict):
                return {key: shape(item) for key, item in value.items()}
            return type(value).__name__

        self.assertEqual(shape(theirs["options"][0]), shape(ours))


class SeamTests(unittest.TestCase):
    """where this backend waits on partner approval or on Jose."""

    def setUp(self):
        self.saved = {key: os.environ.pop(key, None) for key in
                      ("SIRVEN_UBER_FOR_BUSINESS_SANDBOX_TOKEN", "SIRVEN_LYFT_BUSINESS_SANDBOX_TOKEN",
                       "SIRVEN_RIDE_PARTNER_MODE")}

    def tearDown(self):
        for key, value in self.saved.items():
            os.environ.pop(key, None)
            if value is not None:
                os.environ[key] = value

    def test_live_mode_is_always_blocked(self):
        for carrier in (UberForBusiness, LyftBusiness):
            with self.assertRaises(LiveCallsBlocked):
                transport_for(carrier, "live")

    def test_sandbox_without_partner_credentials_is_blocked_on_approval(self):
        for carrier in (UberForBusiness, LyftBusiness):
            with self.assertRaises(PartnerApprovalRequired):
                transport_for(carrier, "sandbox").request("GET", "/v1/anything")

    def test_sandbox_transport_refuses_a_production_uber_host(self):
        with self.assertRaises(LiveCallsBlocked):
            SandboxTransport("https://api.uber.com", UberForBusiness.sandbox_hosts, "UNSET")

    def test_lyft_sandbox_never_creates_or_cancels_a_trip(self):
        os.environ["SIRVEN_LYFT_BUSINESS_SANDBOX_TOKEN"] = "placeholder-not-a-credential"
        lyft = LyftBusiness(transport_for(LyftBusiness, "sandbox"), None)
        with self.assertRaises(PartnerApprovalRequired):
            lyft.create_trip({"ride_type": "lyft", "cost_token": "x"}, CITY_HALL["coordinates"],
                             BARBER["coordinates"], RIDER, "memo")
        with self.assertRaises(PartnerApprovalRequired):
            lyft.cancel_trip({"ride_id": "x"}, 0)

    def test_sandbox_mode_without_credentials_is_service_unavailable_to_the_agent(self):
        clock = FakeClock(NOW)
        connector, _ = build_connector(clock, dict(RIDER), mode="sandbox")
        is_error, payload = connector.quote_ride(
            origin=CITY_HALL, destination=BARBER, budget_ceiling=usd(4000),
            departure_window={"earliest": NOW.isoformat(), "latest": (NOW + timedelta(minutes=30)).isoformat()})
        self.assertTrue(is_error)
        self.assertEqual("service_unavailable", payload["error"]["code"])

    def test_fixture_mode_is_the_default(self):
        backend = build_backend(FakeClock(NOW), dict(RIDER))
        self.assertEqual("FixtureTransport", type(backend.carriers[0].transport).__name__)


if __name__ == "__main__":
    unittest.main()
