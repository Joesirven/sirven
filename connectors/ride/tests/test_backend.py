"""the official-partner ride backend against recorded fixtures. run from connectors/ride:

  python3 -m unittest discover -s tests
"""

import glob
import json
import logging
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

from ride_partner import (  # noqa: E402
    LiveCallsBlocked, LyftBusiness, PartnerApprovalRequired, PaymentDeclined, RideConnectorError,
    UberForBusiness, build_backend, contract,
)
from ride_partner.transport import FIXTURES_DIR, transport_for  # noqa: E402

# carrier failures are logged for operators; the tests check them through behavior instead.
logging.getLogger("sirven.ride_partner").setLevel(logging.CRITICAL)

NOW = 1791000000
CITY_HALL = {"latitude": 37.7793, "longitude": -122.4193}
CASTRO = {"latitude": 37.7609, "longitude": -122.4350}
WINDOW = {"earliest": NOW, "latest": NOW + 900}
BUDGET = {"amount_minor": 4000, "currency": "USD"}
RIDER = {"first_name": "Sample", "last_name": "Rider", "phone_number": "+14155550100"}


class FakePayments:
    def __init__(self, decline=False):
        self.decline = decline
        self.events = []

    def authorize(self, reference, amount_minor, currency):
        self.events.append(("authorize", amount_minor, currency))
        if self.decline:
            raise PaymentDeclined()
        return "hold-" + reference

    def capture(self, handle, amount_minor):
        self.events.append(("capture", amount_minor))

    def release(self, handle):
        self.events.append(("release",))


class Clock:
    def __init__(self, now=NOW):
        self.now = now

    def __call__(self):
        return self.now


def carrier_secrets():
    """every carrier token, identifier, and error text in the fixtures. none may reach a caller."""
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
BACKEND_TELLS = (
    "fare_id", "cost_token", "request_id", "ride_id", "product_id", "ride_type", "guests",
    "concierge", "Concierge", "partner", "official", "uber.com", "lyft.com", "UberX", "UberXL",
    "Lyft XL", "Black", "Lux", "organization", "expense",
)


class Harness(unittest.TestCase):
    scenarios = None

    def setUp(self):
        self.payments = FakePayments()
        self.clock = Clock()
        self.backend = self.build()
        self.seen = []

    def build(self, payments=None, scenarios=None):
        return build_backend(payments or self.payments, lambda user_ref: dict(RIDER), mode="fixture",
                             scenarios=scenarios or self.scenarios, clock=self.clock)

    def quote(self, backend=None, **preferences):
        budget = preferences.pop("budget", BUDGET)
        window = preferences.pop("window", WINDOW)
        response = (backend or self.backend).quote_ride(CITY_HALL, CASTRO, window, preferences, budget, "user-1")
        self.seen.append(response)
        return response

    def first(self, response, provider, vehicle_class="standard"):
        for quote in response["quotes"]:
            if quote["provider"] == provider and quote["vehicle_class"] == vehicle_class:
                return quote
        self.fail("no %s %s quote" % (provider, vehicle_class))

    def transport(self, backend, carrier_name):
        return next(carrier.transport for carrier in backend.carriers if carrier.name == carrier_name)

    def assert_error(self, code, call, *args):
        with self.assertRaises(RideConnectorError) as caught:
            call(*args)
        self.assertEqual(code, caught.exception.code)
        self.seen.append(caught.exception.to_dict())
        return caught.exception


class QuoteTests(Harness):
    def test_quotes_pass_the_strict_contract_validator(self):
        contract.validate_quote_response(self.quote())

    def test_unknown_or_unavailable_products_are_left_out(self):
        response = self.quote()
        pairs = sorted((quote["provider"], quote["vehicle_class"]) for quote in response["quotes"])
        # Uber Pet has no contract class; Lyft Lux Black's estimate is not valid.
        self.assertEqual([("Lyft", "large"), ("Lyft", "standard"), ("Uber", "large"),
                          ("Uber", "premium"), ("Uber", "standard")], pairs)

    def test_ranked_by_price_by_default_with_blocked_options_last(self):
        quotes = self.quote()["quotes"]
        self.assertEqual([1, 2, 3, 4, 5], [quote["rank"] for quote in quotes])
        self.assertEqual(["exceeds_budget", "surge_pricing"], quotes[-1]["constraint_flags"])
        prices = [quote["price"]["amount_minor"] for quote in quotes[:-1]]
        self.assertEqual(sorted(prices), prices)

    def test_optimize_for_pickup(self):
        quotes = self.quote(optimize_for="pickup", budget={"amount_minor": 9000, "currency": "USD"})["quotes"]
        pickups = [quote["estimated_pickup_seconds"] for quote in quotes]
        self.assertEqual(sorted(pickups), pickups)

    def test_a_price_range_is_quoted_at_its_upper_bound_and_flagged(self):
        lyft = self.first(self.quote(), "Lyft")
        self.assertEqual(2400, lyft["price"]["amount_minor"])
        self.assertIn("price_is_upper_bound", lyft["constraint_flags"])

    def test_tip_ceiling_counts_against_the_budget(self):
        # 2350 plus a 1700 tip ceiling is 4050, over the 4000 budget.
        uber = self.first(self.quote(tip_ceiling={"amount_minor": 1700, "currency": "USD"}), "Uber")
        self.assertIn("exceeds_budget", uber["constraint_flags"])

    def test_pickup_outside_the_window_is_flagged(self):
        late = {"earliest": NOW + 1800, "latest": NOW + 2700}
        for quote in self.quote(window=late)["quotes"]:
            self.assertIn("pickup_outside_window", quote["constraint_flags"])

    def test_vehicle_class_and_passenger_filters(self):
        quotes = self.quote(vehicle_classes=["large"], passengers=5)["quotes"]
        self.assertEqual({"large"}, {quote["vehicle_class"] for quote in quotes})
        self.assertEqual(2, len(quotes))

    def test_quote_lifetime_is_capped_the_same_for_every_carrier(self):
        expiries = {quote["expires_at"] for quote in self.quote()["quotes"]}
        self.assertEqual({NOW + 120}, expiries)

    def test_bad_arguments_are_invalid_request(self):
        self.assert_error("invalid_request", self.backend.quote_ride, {"latitude": 91, "longitude": 0}, CASTRO,
                          WINDOW, {}, BUDGET, "user-1")
        self.assert_error("invalid_request", self.backend.quote_ride, CITY_HALL, CASTRO, WINDOW,
                          {"carrier": "Uber"}, BUDGET, "user-1")


class QuoteEdgeTests(Harness):
    def test_no_matching_class_is_no_options(self):
        with self.assertRaises(RideConnectorError) as caught:
            self.quote(vehicle_classes=["accessible"])
        self.assertEqual("no_options", caught.exception.code)

    def test_one_carrier_down_still_quotes_the_other(self):
        backend = self.build(scenarios={"lyft_business": "unavailable"})
        providers = {quote["provider"] for quote in self.quote(backend)["quotes"]}
        self.assertEqual({"Uber"}, providers)


class BookTests(Harness):
    def test_book_authorizes_price_plus_tip_then_bills_the_corporate_account(self):
        quote = self.first(self.quote(tip_ceiling={"amount_minor": 400, "currency": "USD"}), "Uber")
        booking = self.backend.book_ride(quote["quote_id"])
        self.seen.append(booking)
        contract.validate_booking_response(booking)
        self.assertEqual([("authorize", 2750, "USD")], self.payments.events)
        sent = self.transport(self.backend, "uber_for_business").calls[-1]
        self.assertEqual("/v1/guests/trips", sent["path"])
        self.assertEqual("fixture-uber-fare-uberx", sent["body"]["fare_id"])
        self.assertEqual("sirven-rides", sent["body"]["expense_code"])
        self.assertEqual("Sample", sent["body"]["guest"]["first_name"])
        self.assertEqual(NOW + 120, booking["cancellation_window"]["free_until"])
        self.assertEqual("/rides/" + booking["booking_id"], booking["tracking"]["status_path"])

    def test_lyft_booking_sends_the_cost_token_and_organization(self):
        quote = self.first(self.quote(), "Lyft")
        self.seen.append(self.backend.book_ride(quote["quote_id"]))
        sent = self.transport(self.backend, "lyft_business").calls[-1]
        self.assertEqual("fixture-lyft-cost-token-standard", sent["body"]["cost_token"])
        self.assertEqual("fixture-organization", sent["body"]["organization_id"])

    def test_booking_twice_returns_the_same_booking_and_charges_once(self):
        quote_id = self.first(self.quote(), "Uber")["quote_id"]
        first = self.backend.book_ride(quote_id)
        second = self.backend.book_ride(quote_id)
        self.assertEqual(first, second)
        self.assertEqual(1, len(self.payments.events))
        trips = [call for call in self.transport(self.backend, "uber_for_business").calls
                 if call["path"] == "/v1/guests/trips"]
        self.assertEqual(1, len(trips))

    def test_unknown_quote(self):
        self.assert_error("quote_not_found", self.backend.book_ride, "quote_" + "0" * 32)

    def test_expired_quote_never_touches_money_or_carrier(self):
        quote_id = self.first(self.quote(), "Uber")["quote_id"]
        self.clock.now = NOW + 121
        self.assert_error("quote_expired", self.backend.book_ride, quote_id)
        self.assertEqual([], self.payments.events)

    def test_over_budget_quote_is_refused(self):
        quote = self.first(self.quote(), "Uber", "premium")
        self.assert_error("constraint_not_met", self.backend.book_ride, quote["quote_id"])
        self.assertEqual([], self.payments.events)

    def test_declined_payment_never_reaches_the_carrier(self):
        payments = FakePayments(decline=True)
        backend = self.build(payments=payments)
        quote_id = self.first(self.quote(backend), "Uber")["quote_id"]
        self.assert_error("payment_declined", backend.book_ride, quote_id)
        paths = [call["path"] for call in self.transport(backend, "uber_for_business").calls]
        self.assertNotIn("/v1/guests/trips", paths)

    def test_carrier_failure_releases_the_hold_and_hides_the_carrier_text(self):
        backend = self.build(scenarios={"uber_for_business": "booking_fails"})
        quote_id = self.first(self.quote(backend), "Uber")["quote_id"]
        error = self.assert_error("provider_unavailable", backend.book_ride, quote_id)
        self.assertEqual(("release",), self.payments.events[-1])
        self.assertTrue(error.to_dict()["retryable"])


class CancelTests(Harness):
    def book(self, provider, backend=None):
        backend = backend or self.backend
        booking = backend.book_ride(self.first(self.quote(backend), provider)["quote_id"])
        self.seen.append(booking)
        return booking

    def test_cancel_inside_the_free_window_releases_the_hold(self):
        booking = self.book("Uber")
        result = self.backend.cancel_ride(booking["booking_id"])
        self.seen.append(result)
        contract.validate_cancel_response(result)
        self.assertEqual({"status": "settled", "cancellation_fee": {"amount_minor": 0, "currency": "USD"}},
                         result["settlement"])
        self.assertEqual(("release",), self.payments.events[-1])

    def test_late_uber_cancel_waits_for_the_receipt(self):
        booking = self.book("Uber")
        self.clock.now = NOW + 300
        result = self.backend.cancel_ride(booking["booking_id"])
        self.assertEqual({"status": "pending_receipt", "cancellation_fee": None}, result["settlement"])
        self.assertEqual("authorize", self.payments.events[-1][0])
        self.backend.settle_receipt(booking["booking_id"], 500)
        self.assertEqual(("capture", 500), self.payments.events[-1])
        settled = self.backend.cancel_ride(booking["booking_id"])
        self.assertEqual({"amount_minor": 500, "currency": "USD"}, settled["settlement"]["cancellation_fee"])

    def test_lyft_fee_is_confirmed_and_only_the_fee_is_captured(self):
        backend = self.build(scenarios={"lyft_business": "cancel_with_fee"})
        booking = self.book("Lyft", backend)
        result = backend.cancel_ride(booking["booking_id"])
        self.seen.append(result)
        self.assertEqual({"amount_minor": 500, "currency": "USD"}, result["settlement"]["cancellation_fee"])
        self.assertEqual(("capture", 500), self.payments.events[-1])
        confirm = self.transport(backend, "lyft_business").calls[-1]
        self.assertEqual({"cancel_confirmation_token": "fixture-lyft-cancel-token"}, confirm["body"])

    def test_cancelling_twice_cancels_once(self):
        booking = self.book("Uber")
        first = self.backend.cancel_ride(booking["booking_id"])
        second = self.backend.cancel_ride(booking["booking_id"])
        self.assertEqual(first, second)
        deletes = [call for call in self.transport(self.backend, "uber_for_business").calls
                   if call["method"] == "DELETE"]
        self.assertEqual(1, len(deletes))

    def test_trip_underway_is_not_cancellable(self):
        backend = self.build(scenarios={"uber_for_business": "trip_underway"})
        booking = self.book("Uber", backend)
        self.assert_error("not_cancellable", backend.cancel_ride, booking["booking_id"])

    def test_unknown_booking(self):
        self.assert_error("booking_not_found", self.backend.cancel_ride, "booking_" + "0" * 32)


class BlindnessTests(Harness):
    """the calling agent must not be able to tell this backend produced the quote."""

    def exercise(self):
        for scenarios in ({}, {"uber_for_business": "booking_fails"}, {"lyft_business": "cancel_with_fee"},
                          {"uber_for_business": "trip_underway"}):
            backend = self.build(scenarios=scenarios)
            quotes = self.quote(backend, tip_ceiling={"amount_minor": 200, "currency": "USD"})
            for quote in quotes["quotes"]:
                try:
                    booking = backend.book_ride(quote["quote_id"])
                    self.seen.append(booking)
                    self.seen.append(backend.cancel_ride(booking["booking_id"]))
                except RideConnectorError as error:
                    self.seen.append(error.to_dict())

    def test_no_carrier_token_or_integration_word_reaches_the_caller(self):
        self.exercise()
        text = json.dumps(self.seen)
        for secret in carrier_secrets():
            self.assertNotIn(secret, text)
        for word in BACKEND_TELLS:
            self.assertNotIn(word, text)

    def test_identifiers_are_opaque(self):
        self.exercise()
        quote_ids = [quote["quote_id"] for item in self.seen if "quotes" in item for quote in item["quotes"]]
        for quote_id in quote_ids:
            self.assertRegex(quote_id, r"^quote_[0-9a-f]{32}$")
        self.assertEqual(len(quote_ids), len(set(quote_ids)))

    def test_errors_carry_only_the_fixed_contract_message(self):
        self.exercise()
        for item in self.seen:
            if "code" in item:
                self.assertEqual(contract.ERROR_CODES[item["code"]], item["message"])

    def test_the_validator_refuses_any_extra_field(self):
        response = self.quote()
        response["quotes"][0]["backend"] = "official_partner"
        with self.assertRaises(ValueError):
            contract.validate_quote_response(response)


class SeamTests(unittest.TestCase):
    """the places this backend waits on partner approval or on Jose."""

    def setUp(self):
        self.saved = {key: os.environ.pop(key, None) for key in
                      ("SIRVEN_UBER_FOR_BUSINESS_SANDBOX_TOKEN", "SIRVEN_LYFT_BUSINESS_SANDBOX_TOKEN",
                       "SIRVEN_RIDE_PARTNER_MODE")}

    def tearDown(self):
        for key, value in self.saved.items():
            if value is not None:
                os.environ[key] = value

    def test_live_mode_is_always_blocked(self):
        for carrier in (UberForBusiness, LyftBusiness):
            with self.assertRaises(LiveCallsBlocked):
                transport_for(carrier, "live")

    def test_sandbox_without_partner_credentials_is_blocked_on_approval(self):
        for carrier in (UberForBusiness, LyftBusiness):
            transport = transport_for(carrier, "sandbox")
            with self.assertRaises(PartnerApprovalRequired):
                transport.request("GET", "/v1/anything")

    def test_sandbox_transport_refuses_a_production_uber_host(self):
        from ride_partner.transport import SandboxTransport
        with self.assertRaises(LiveCallsBlocked):
            SandboxTransport("https://api.uber.com", UberForBusiness.sandbox_hosts, "UNSET")

    def test_lyft_sandbox_never_creates_or_cancels_a_trip(self):
        os.environ["SIRVEN_LYFT_BUSINESS_SANDBOX_TOKEN"] = "placeholder-not-a-credential"
        try:
            lyft = LyftBusiness(transport_for(LyftBusiness, "sandbox"), None)
            with self.assertRaises(PartnerApprovalRequired):
                lyft.create_trip({"ride_type": "lyft", "cost_token": "x"}, CITY_HALL, CASTRO, RIDER, "memo")
            with self.assertRaises(PartnerApprovalRequired):
                lyft.cancel_trip({"ride_id": "x"}, NOW, NOW)
        finally:
            del os.environ["SIRVEN_LYFT_BUSINESS_SANDBOX_TOKEN"]

    def test_a_backend_with_no_reachable_carrier_says_provider_unavailable(self):
        backend = build_backend(FakePayments(), lambda user_ref: dict(RIDER), mode="sandbox", clock=Clock())
        with self.assertRaises(RideConnectorError) as caught:
            backend.quote_ride(CITY_HALL, CASTRO, WINDOW, {}, BUDGET, "user-1")
        self.assertEqual("provider_unavailable", caught.exception.code)

    def test_fixture_mode_is_the_default(self):
        backend = build_backend(FakePayments(), lambda user_ref: dict(RIDER), clock=Clock())
        self.assertTrue(backend.quote_ride(CITY_HALL, CASTRO, WINDOW, {}, BUDGET, "user-1")["quotes"])


if __name__ == "__main__":
    unittest.main()
