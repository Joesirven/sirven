"""tests for lib/issuing, run against the in-memory stand-in for Stripe test mode."""
import atexit
import io
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "lib"))

from issuing import demo, records as R, webhook  # noqa: E402
from issuing.booking_cards import BookingCards, ReservationFailed, card_parameters  # noqa: E402
from issuing.booking_cards import FlowError  # noqa: E402
from issuing.contract import ContractError, booking_details, quote_terms  # noqa: E402
from issuing.fake_stripe import FakeStripe, decode_form  # noqa: E402
from issuing.stripe_api import LiveModeRefused, StripeClient, encode_form  # noqa: E402

SECRET = "whsec_test_unit"


def money(amount, currency="USD"):
    return {"amount_minor": amount, "currency": currency}


def quote(price=1840, tip=500, currency="USD", fare_ceiling=None):
    """a quoted option shaped like the ride connector contract version 1."""
    ceiling = price if fare_ceiling is None else fare_ceiling
    cap = ceiling + tip if isinstance(ceiling, int) and isinstance(tip, int) else 0
    return {"quote_id": "q-1", "rank": 1, "bookable": True, "provider": "a ride service",
            "price": {"kind": "fixed", "amount": money(price, currency), "maximum": money(ceiling, currency)},
            "charge_terms": {"quoted_amount": money(price, currency), "fare_ceiling": money(ceiling, currency),
                             "tip_ceiling": money(tip, currency), "authorization_cap": money(cap, currency),
                             "currency": currency},
            "constraint_flags": [], "estimated_pickup_at": None, "estimated_trip_minutes": 12}


def booking():
    return {"booking_id": "b-1", "quote_id": "q-1", "status": "confirmed",
            "cancellation_policy": {"free_until": "2026-10-12T14:32:00-07:00", "fee_after_free_period": money(500)},
            "final_charge": None}


def finished(total):
    return dict(booking(), final_charge={"fare": money(total), "tip": money(0), "cancellation_fee": money(0),
                                         "total": money(total), "amount_to_release": money(2340 - total)})


class Wired:
    """a booking flow wired to a fresh stand-in, with webhooks delivered."""

    def __init__(self, deliver=True):
        directory = tempfile.mkdtemp(prefix="sirven-issuing-test.")
        atexit.register(shutil.rmtree, directory, True)
        self.fake = FakeStripe(webhook_secret=SECRET, issuing_balance=100000)
        self.client = StripeClient("sk_test_unit", self.fake)
        cardholder = self.client.post("/v1/issuing/cardholders", {"type": "company", "name": "Sirven ride bookings"})
        self.store = R.RecordStore(directory)
        self.cards = BookingCards(self.client, self.store, cardholder["id"], webhook_secret=SECRET)
        if deliver:
            self.fake.endpoint = self.cards.handle_webhook
        self.customer = self.client.post("/v1/customers", {})["id"]

    def user(self, method="pm_card_visa"):
        return {"reference": "user-1", "customer": self.customer, "payment_method": method}

    def reserve(self, price=1840, tip=500):
        return self.cards.reserve_and_mint(quote_terms(quote(price, tip)),
                                           {"reasoning_summary": "cheapest arriving on time"}, self.user())

    def mint(self, price=1840, tip=500):
        self.reserve(price, tip)
        return self.cards.attach_booking("q-1", booking())

    def authorize(self, record, amount, category="taxicabs_limousines"):
        return self.client.post("/v1/test_helpers/issuing/authorizations", {
            "card": record["stripe"]["card"], "amount": amount,
            "merchant_data": {"category": category, "name": "Ride Service"}})

    def capture(self, authorization, amount=None):
        params = {} if amount is None else {"capture_amount": amount}
        return self.client.post(f"/v1/test_helpers/issuing/authorizations/{authorization['id']}/capture", params)

    def record(self):
        return self.store.get("q-1")

    def intents(self):
        return [o for o in self.fake.objects.values() if o.get("object") == "payment_intent"]

    def cards_minted(self):
        return [o for o in self.fake.objects.values() if o.get("object") == "issuing.card"]


class TestModeLock(unittest.TestCase):
    def test_live_and_publishable_keys_are_refused_before_any_request(self):
        for key in ("sk_live_x", "rk_live_x", "pk_test_x", "", None):
            with self.assertRaises(LiveModeRefused):
                StripeClient(key, lambda *a: self.fail("no request may be built"))

    def test_refusal_message_never_contains_the_key(self):
        with self.assertRaises(LiveModeRefused) as caught:
            StripeClient("sk_live_supersecretvalue")
        self.assertNotIn("supersecret", str(caught.exception))

    def test_a_live_mode_response_is_refused(self):
        client = StripeClient("sk_test_x", lambda *a: (200, b'{"id": "x", "livemode": true}'))
        with self.assertRaises(LiveModeRefused):
            client.get("/v1/balance")

    def test_live_mode_webhook_events_are_refused(self):
        wired = Wired()
        payload = json.dumps({"id": "evt_1", "type": "issuing_authorization.created", "livemode": True,
                              "data": {"object": {}}}).encode()
        status, _, _ = wired.cards.handle_webhook(payload, webhook.sign(SECRET, payload))
        self.assertEqual(400, status)


class FormEncoding(unittest.TestCase):
    def test_nested_parameters_round_trip(self):
        params = {"spending_controls": {"allowed_categories": ["taxicabs_limousines"],
                                        "spending_limits": [{"amount": 2340, "interval": "all_time"}]},
                  "confirm": True}
        pairs = dict(encode_form(params))
        self.assertEqual("taxicabs_limousines", pairs["spending_controls[allowed_categories][0]"])
        self.assertEqual("2340", pairs["spending_controls[spending_limits][0][amount]"])
        self.assertEqual("true", pairs["confirm"])
        import urllib.parse
        decoded = decode_form(urllib.parse.urlencode(encode_form(params)))
        self.assertEqual(["taxicabs_limousines"], decoded["spending_controls"]["allowed_categories"])


class Signatures(unittest.TestCase):
    payload = b'{"id": "evt_1"}'

    def test_a_good_signature_verifies(self):
        self.assertEqual({"id": "evt_1"}, webhook.verify(SECRET, self.payload, webhook.sign(SECRET, self.payload)))

    def test_a_wrong_secret_fails(self):
        with self.assertRaises(webhook.SignatureError):
            webhook.verify(SECRET, self.payload, webhook.sign("whsec_other", self.payload))

    def test_a_changed_payload_fails(self):
        with self.assertRaises(webhook.SignatureError):
            webhook.verify(SECRET, b'{"id": "evt_2"}', webhook.sign(SECRET, self.payload))

    def test_a_stale_timestamp_fails(self):
        header = webhook.sign(SECRET, self.payload, timestamp=1000)
        with self.assertRaises(webhook.SignatureError):
            webhook.verify(SECRET, self.payload, header, now=1000 + 301)

    def test_missing_header_or_secret_fails(self):
        for secret, header in ((SECRET, None), (None, "t=1,v1=x"), (SECRET, "garbage")):
            with self.assertRaises(webhook.SignatureError):
                webhook.verify(secret, self.payload, header)

    def test_the_endpoint_answers_400_to_a_bad_signature(self):
        status, _, _ = Wired().cards.handle_webhook(self.payload, "t=1,v1=00")
        self.assertEqual(400, status)


class ContractFields(unittest.TestCase):
    def test_cap_is_the_contract_authorization_cap(self):
        terms = quote_terms(quote(1840, 500, fare_ceiling=2100))
        self.assertEqual((1840, 2100, 500, 2600, "usd"),
                         (terms["quoted"], terms["fare_ceiling"], terms["tip_ceiling"], terms["cap"], terms["currency"]))

    def test_bad_money_is_refused(self):
        wrong_cap = quote()
        wrong_cap["charge_terms"]["authorization_cap"] = money(9999)
        mixed = quote()
        mixed["charge_terms"]["tip_ceiling"] = money(500, "EUR")
        bad = [quote(18.40), quote(-1), quote(0), quote(currency="EUR"), quote(2000, fare_ceiling=1900),
               wrong_cap, mixed, dict(quote(), bookable=False), dict(quote(), charge_terms=None)]
        for item in bad:
            with self.assertRaises(ContractError):
                quote_terms(item)

    def test_a_booking_for_another_quote_is_refused(self):
        with self.assertRaises(ContractError):
            booking_details("q-1", dict(booking(), quote_id="q-other"))
        with self.assertRaises(ContractError):
            booking_details("q-1", {"quote_id": "q-1"})


class CardParameters(unittest.TestCase):
    def test_card_is_virtual_ride_only_and_capped(self):
        params = card_parameters(quote_terms(quote(1840, 500)), "ich_1")
        self.assertEqual("virtual", params["type"])
        self.assertEqual(["taxicabs_limousines"], params["spending_controls"]["allowed_categories"])
        self.assertEqual([{"amount": 2340, "interval": "per_authorization"}, {"amount": 2340, "interval": "all_time"}],
                         params["spending_controls"]["spending_limits"])
        self.assertEqual(2, params["lifecycle_controls"]["cancel_after"]["payment_count"])
        self.assertEqual("q-1", params["metadata"]["sirven_quote_id"])

    def test_no_tip_ceiling_means_a_single_use_card(self):
        params = card_parameters(quote_terms(quote(1840, 0)), "ich_1")
        self.assertEqual(1, params["lifecycle_controls"]["cancel_after"]["payment_count"])


class Minting(unittest.TestCase):
    def test_minting_holds_the_cap_and_records_no_card_secrets(self):
        wired = Wired()
        record = wired.mint()
        intent = wired.intents()[0]
        self.assertEqual(("manual", "requires_capture", 2340), (intent["capture_method"], intent["status"], intent["amount"]))
        self.assertEqual(2340, record["amounts"]["reserved_on_user_card"])
        text = json.dumps(record)
        for secret_field in ('"number"', '"cvc"', '"exp_month"', '"exp_year"'):
            self.assertNotIn(secret_field, text)

    def test_minting_twice_is_one_hold_and_one_card(self):
        wired = Wired()
        first, second = wired.mint(), wired.mint()
        self.assertEqual(first["stripe"], second["stripe"])
        self.assertEqual((1, 1), (len(wired.intents()), len(wired.cards_minted())))

    def test_a_declined_user_card_mints_nothing(self):
        wired = Wired()
        with self.assertRaises(ReservationFailed):
            wired.cards.reserve_and_mint(quote_terms(quote()), {}, wired.user("pm_card_chargeDeclined"))
        self.assertEqual([], wired.cards_minted())
        self.assertIsNone(wired.record())

    def test_a_failed_mint_releases_the_hold(self):
        wired = Wired()
        wired.cards.cardholder_id = "ich_missing"
        with self.assertRaises(ReservationFailed):
            wired.mint()
        self.assertEqual("canceled", wired.intents()[0]["status"])
        self.assertIsNone(wired.record())


class BookingOrder(unittest.TestCase):
    def test_the_reservation_exists_before_any_booking(self):
        wired = Wired()
        record = wired.reserve()
        self.assertIsNone(record["booking_id"])
        self.assertEqual("requires_capture", wired.intents()[0]["status"])
        self.assertEqual(record["stripe"]["card"], wired.cards.card_for_quote("q-1"))
        self.assertEqual("sirven_hold_q-1", record["payment_reference"])
        self.assertEqual(record["stripe"]["card"], wired.cards.card_for_payment_reference(record["payment_reference"]))
        for unknown in ("sirven_hold_other", "../q-1", ""):
            with self.assertRaises(FlowError):
                wired.cards.card_for_payment_reference(unknown)

    def test_attaching_the_booking_records_it_once(self):
        wired = Wired()
        wired.reserve()
        record = wired.cards.attach_booking("q-1", booking())
        self.assertEqual("b-1", record["booking_id"])
        self.assertEqual(money(500), record["rationale"]["booking"]["cancellation_policy"]["fee_after_free_period"])
        self.assertEqual(record, wired.cards.attach_booking("q-1", booking()))
        with self.assertRaises(FlowError):
            wired.cards.attach_booking("q-1", dict(booking(), booking_id="b-2"))

    def test_a_booking_for_another_quote_is_refused(self):
        wired = Wired()
        wired.reserve()
        with self.assertRaises(ContractError):
            wired.cards.attach_booking("q-1", dict(booking(), quote_id="q-other"))
        self.assertIsNone(wired.record()["booking_id"])

    def test_a_failed_book_ride_releases_the_hold_and_closes_the_card(self):
        wired = Wired()
        record = wired.reserve()
        record = wired.cards.release("q-1")
        self.assertEqual("cancelled", record["state"])
        self.assertEqual("canceled", wired.intents()[0]["status"])
        self.assertEqual("canceled", wired.fake.objects[record["stripe"]["card"]]["status"])
        with self.assertRaises(FlowError):
            wired.cards.card_for_quote("q-1")
        with self.assertRaises(FlowError):
            wired.cards.attach_booking("q-1", booking())


class Authorizations(unittest.TestCase):
    def test_ride_charges_within_the_cap_are_approved_and_answered_with_a_version(self):
        wired = Wired()
        record = wired.mint()
        seen = []
        endpoint = wired.fake.endpoint
        wired.fake.endpoint = lambda payload, header: seen.append(endpoint(payload, header)) or seen[-1]
        self.assertTrue(wired.authorize(record, 1840)["approved"])
        status, headers, body = seen[0]
        self.assertEqual(200, status)
        self.assertIn("Stripe-Version", headers)
        self.assertEqual({"approved": True, "metadata": {"sirven_reason": "within_cap"}}, json.loads(body))

    def test_other_merchant_categories_are_declined_by_spending_controls(self):
        wired = Wired()
        authorization = wired.authorize(wired.mint(), 500, "fast_food_restaurants")
        self.assertFalse(authorization["approved"])
        self.assertEqual("spending_controls", authorization["request_history"][-1]["reason"])

    def test_one_charge_over_the_cap_is_declined(self):
        wired = Wired()
        self.assertFalse(wired.authorize(wired.mint(), 2341)["approved"])

    def test_charges_that_add_up_past_the_cap_are_declined_by_sirven(self):
        wired = Wired()
        record = wired.mint()
        wired.capture(wired.authorize(record, 1840))
        # remove the stand-in's own all-time limit, so the decline must come from sirven's decision.
        wired.fake.objects[record["stripe"]["card"]]["spending_controls"]["spending_limits"] = []
        authorization = wired.authorize(record, 600)
        self.assertFalse(authorization["approved"])
        self.assertEqual("webhook_declined", authorization["request_history"][-1]["reason"])
        decisions = [e["detail"] for e in wired.record()["timeline"] if e["kind"] == "authorization_decision"]
        self.assertTrue(decisions[-1].endswith("over_cap"))

    def test_decide_reasons(self):
        wired = Wired()
        record = wired.mint()
        ride = {"pending_request": {"amount": 100, "currency": "usd"}, "merchant_data": {"category": "taxicabs_limousines"}}
        self.assertEqual((False, "unknown_card"), wired.cards.decide(None, ride))
        self.assertEqual((False, "currency_mismatch"),
                         wired.cards.decide(record, dict(ride, pending_request={"amount": 100, "currency": "eur"})))
        self.assertEqual((True, "within_cap"), wired.cards.decide(record, ride))
        self.assertEqual((False, "booking_closed"), wired.cards.decide(dict(record, state="settled"), ride))

    def test_a_card_sirven_did_not_mint_is_declined(self):
        approved, reason = Wired().cards.authorize({"card": {"id": "ic_unknown", "metadata": {}}})
        self.assertEqual((False, "unknown_card"), (approved, reason))


class Settlement(unittest.TestCase):
    def test_completed_ride_charges_exactly_what_the_card_spent_and_closes_it(self):
        wired = Wired()
        record = wired.mint()
        wired.capture(wired.authorize(record, 1840))
        wired.capture(wired.authorize(record, 300))
        record = wired.cards.complete("q-1")
        intent = wired.intents()[0]
        self.assertEqual(("settled", 2140), (record["state"], record["amounts"]["charged_to_user"]))
        self.assertEqual(("succeeded", 2140), (intent["status"], intent["amount_received"]))
        self.assertEqual("canceled", wired.fake.objects[record["stripe"]["card"]]["status"])

    def test_settlement_waits_for_pending_authorizations(self):
        wired = Wired()
        record = wired.mint()
        fare = wired.authorize(record, 1840)
        self.assertEqual("reserved", wired.cards.complete("q-1")["state"])
        wired.capture(fare)
        self.assertEqual("settled", wired.record()["state"])

    def test_partial_reversal_then_capture(self):
        wired = Wired()
        record = wired.mint()
        fare = wired.authorize(record, 1840)
        wired.client.post(f"/v1/test_helpers/issuing/authorizations/{fare['id']}/reverse", {"reverse_amount": 340})
        wired.capture(fare, 1500)
        self.assertEqual(1500, wired.cards.complete("q-1")["amounts"]["charged_to_user"])

    def test_expired_authorization_is_not_charged(self):
        wired = Wired()
        record = wired.mint()
        fare = wired.authorize(record, 1840)
        wired.client.post(f"/v1/test_helpers/issuing/authorizations/{fare['id']}/expire", {})
        record = wired.cards.complete("q-1")
        self.assertEqual(("cancelled", 0), (record["state"], record["amounts"]["charged_to_user"]))
        self.assertEqual("canceled", wired.intents()[0]["status"])

    def test_cancel_with_nothing_spent_releases_the_hold(self):
        wired = Wired()
        wired.mint()
        record = wired.cards.cancel("q-1")
        self.assertEqual("cancelled", record["state"])
        self.assertEqual("canceled", wired.intents()[0]["status"])

    def test_cancel_with_a_fee_charges_only_the_fee_and_blocks_new_charges(self):
        wired = Wired()
        record = wired.mint()
        fee = wired.authorize(record, 500)
        wired.cards.cancel("q-1")
        self.assertFalse(wired.authorize(record, 1000)["approved"])
        wired.capture(fee)
        self.assertEqual(("settled", 500), (wired.record()["state"], wired.record()["amounts"]["charged_to_user"]))

    def test_over_capture_charges_at_most_the_cap_and_flags_review(self):
        wired = Wired()
        record = wired.mint()
        wired.capture(wired.authorize(record, 1840), 2600)
        record = wired.cards.complete("q-1")
        self.assertEqual(("needs_review", 2340), (record["state"], record["amounts"]["charged_to_user"]))
        self.assertTrue(record["review_reasons"])

    def test_refund_after_settlement_goes_back_to_the_user(self):
        wired = Wired()
        record = wired.mint()
        wired.capture(wired.authorize(record, 1840))
        wired.cards.complete("q-1")
        capture = next(o for o in wired.fake.objects.values() if o.get("object") == "issuing.transaction")
        wired.client.post(f"/v1/test_helpers/issuing/transactions/{capture['id']}/refund", {"refund_amount": 500})
        record = wired.record()
        self.assertEqual(500, record["amounts"]["refunded_to_user"])
        self.assertEqual(500, wired.intents()[0]["amount_refunded"])

    def test_force_capture_after_settlement_is_never_charged_to_the_user(self):
        wired = Wired()
        record = wired.mint()
        wired.capture(wired.authorize(record, 1840))
        wired.cards.complete("q-1")
        wired.client.post("/v1/test_helpers/issuing/transactions/create_force_capture",
                          {"card": record["stripe"]["card"], "amount": 700,
                           "merchant_data": {"category": "taxicabs_limousines"}})
        record = wired.record()
        self.assertEqual(("needs_review", 1840), (record["state"], record["amounts"]["charged_to_user"]))
        self.assertEqual(1840, wired.intents()[0]["amount_received"])


class FinalCharge(unittest.TestCase):
    def test_a_matching_final_charge_settles_cleanly(self):
        wired = Wired()
        record = wired.mint()
        wired.capture(wired.authorize(record, 1840))
        record = wired.cards.complete("q-1", finished(1840))
        self.assertEqual(("settled", 1840, 1840), (record["state"], record["amounts"]["charged_to_user"],
                                                   record["amounts"]["reported_by_ride_service"]))

    def test_a_lower_reported_total_caps_the_user_charge_and_flags_review(self):
        wired = Wired()
        record = wired.mint()
        wired.capture(wired.authorize(record, 1840))
        record = wired.cards.complete("q-1", finished(1500))
        self.assertEqual(("needs_review", 1500), (record["state"], record["amounts"]["charged_to_user"]))

    def test_an_open_booking_reports_nothing(self):
        wired = Wired()
        record = wired.mint()
        wired.capture(wired.authorize(record, 1840))
        record = wired.cards.complete("q-1", booking())
        self.assertIsNone(record["amounts"]["reported_by_ride_service"])


class Reconciliation(unittest.TestCase):
    def test_lost_webhooks_are_recovered_before_settling(self):
        wired = Wired(deliver=False)
        record = wired.mint()
        wired.capture(wired.authorize(record, 1840))
        self.assertEqual({}, wired.record()["transactions"])
        record = wired.cards.complete("q-1")
        self.assertEqual(("settled", 1840), (record["state"], record["amounts"]["charged_to_user"]))

    def test_duplicate_deliveries_count_once(self):
        wired = Wired()
        record = wired.mint()
        wired.capture(wired.authorize(record, 1840))
        for event in list(wired.fake.events):
            payload = json.dumps(event).encode()
            wired.cards.handle_webhook(payload, webhook.sign(SECRET, payload))
        self.assertEqual(1840, wired.record()["amounts"]["captured_by_card"])

    def test_a_late_pending_event_does_not_reopen_a_closed_authorization(self):
        wired = Wired()
        record = wired.mint()
        fare = wired.authorize(record, 1840)
        wired.capture(fare)
        created = next(e for e in wired.fake.events if e["type"] == "issuing_authorization.created")
        stale = dict(created, id="evt_replayed_late")
        stale["data"] = {"object": dict(stale["data"]["object"], status="pending")}
        payload = json.dumps(stale).encode()
        wired.cards.handle_webhook(payload, webhook.sign(SECRET, payload))
        self.assertEqual("closed", wired.record()["authorizations"][fare["id"]]["status"])

    def test_reconcile_reports_nothing_new_when_in_step(self):
        wired = Wired()
        record = wired.mint()
        wired.capture(wired.authorize(record, 1840))
        self.assertEqual(0, wired.cards.reconcile("q-1"))


class Statement(unittest.TestCase):
    def test_every_amount_sits_next_to_the_reason(self):
        wired = Wired()
        record = wired.mint()
        wired.capture(wired.authorize(record, 1840))
        text = R.statement(wired.cards.complete("q-1"))
        for expected in ("why: cheapest arriving on time", "$18.40", "tip allowed up to $5.00",
                         "held on your card at booking: $23.40", "charged to you: $18.40"):
            self.assertIn(expected, text)


class Demo(unittest.TestCase):
    def test_every_scenario_ends_where_it_should(self):
        with tempfile.TemporaryDirectory() as directory:
            harness = demo.run(directory, out=io.StringIO())
            states = {r["quote_id"]: (r["booking_id"], r["state"], r["amounts"]["charged_to_user"],
                                      r["amounts"]["refunded_to_user"]) for r in harness.store.all()}
        self.assertEqual({
            "qt_demo1": ("bk_demo1", "settled", 2140, 0),
            "qt_demo2": ("bk_demo2", "cancelled", 0, 0),
            "qt_demo3": ("bk_demo3", "settled", 1500, 0),
            "qt_demo4": ("bk_demo4", "settled", 500, 0),
            "qt_demo5": ("bk_demo5", "cancelled", 0, 0),
            "qt_demo6": ("bk_demo6", "settled", 1840, 500),
            "qt_demo7": ("bk_demo7", "needs_review", 2340, 0),
            "qt_demo9": ("bk_demo9", "settled", 1840, 0),
            "qt_demo10": (None, "cancelled", 0, 0),
        }, states)

    def test_test_mode_runs_get_fresh_quote_ids(self):
        first, second = (demo.sample_quote(1, run_tag=f"r{t}")[0]["quote_id"] for t in ("a", "b"))
        self.assertNotEqual(first, second)


if __name__ == "__main__":
    unittest.main()
