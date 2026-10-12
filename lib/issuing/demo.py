"""run the per-booking card flow end to end and print what the user would see.

  python3 -m issuing.demo                      against the in-memory stand-in (no key, no network)
  python3 -m issuing.demo --stripe-test-mode   against Stripe test mode; needs STRIPE_TEST_SECRET_KEY
  python3 -m issuing.demo serve --port 4242    the webhook endpoint, for stripe listen --forward-to

run from the lib directory, or with lib on PYTHONPATH. records land in --records (a temporary
directory by default). in test mode the key is read from the environment and never printed;
a key that is not a test mode key is refused before any request is built.

against Stripe test mode the demo does not need webhooks: after every step it reconciles from
the API, which is also how the flow recovers from a missed delivery. real-time decisions need
the authorization endpoint set in the test mode Issuing settings and reachable (stripe listen).
"""
import argparse
import http.server
import json
import os
import sys
import tempfile

from . import records as R
from .booking_cards import BookingCards, ReservationFailed
from .contract import booking_terms
from .fake_stripe import FakeStripe
from .stripe_api import StripeClient, urllib_transport

# test mode placeholders only. the real company address is one of the gaps for Jose.
TEST_CARDHOLDER = {
    "type": "company",
    "name": "Sirven ride bookings",
    "status": "active",
    "billing": {"address": {"line1": "510 Townsend Street", "city": "San Francisco", "state": "CA",
                            "postal_code": "94103", "country": "US"}},
}


def sample_booking(number, price=1840, tip_ceiling=500):
    quote = {
        "quote_id": f"quote-demo-{number}",
        "provider": "a ride service",
        "price": {"amount_minor": price, "currency": "usd"},
        "tip_ceiling": {"amount_minor": tip_ceiling, "currency": "usd"},
        "estimated_arrival": "4 minutes",
        "estimated_trip_time": "12 minutes",
    }
    booking = {"booking_id": f"booking-demo-{number}", "quote_id": quote["quote_id"],
               "cancellation_window": "free until the car is 2 minutes away"}
    rationale = {
        "user_request": "book me a ride to the barber after my 2pm meeting, under $25",
        "reasoning_summary": "cheapest option arriving before the 3pm appointment; under the $25 budget "
                             "even with the full tip allowance",
    }
    return booking_terms(quote, booking), rationale


RIDE_MERCHANT = {"category": "taxicabs_limousines", "name": "Demo Ride Service", "city": "San Francisco",
                 "country": "US", "postal_code": "94107", "state": "CA", "network_id": "1234567890"}
FOOD_MERCHANT = dict(RIDE_MERCHANT, category="fast_food_restaurants", name="Demo Burger")


class Harness:
    """the pieces a scenario needs, wired for either the stand-in or Stripe test mode."""

    def __init__(self, records_dir, test_mode_key=None, out=sys.stdout):
        self.out = out
        self.fake = None
        secret = os.environ.get("STRIPE_WEBHOOK_SECRET")
        if test_mode_key:
            self.client = StripeClient(test_mode_key, urllib_transport)
            self.webhooks = False
        else:
            self.fake = FakeStripe()
            secret = self.fake.webhook_secret
            self.client = StripeClient("sk_test_stand_in", self.fake)
            self.webhooks = True
        cardholder = self.client.post("/v1/issuing/cardholders", TEST_CARDHOLDER,
                                      idempotency_key="sirven-demo-cardholder-v1")
        self.client.post("/v1/topups", {"amount": 50000, "currency": "usd", "destination_balance": "issuing",
                                        "description": "sirven demo test top-up"})
        self.customer = self.client.post("/v1/customers", {"description": "sirven demo test customer"})["id"]
        self.store = R.RecordStore(records_dir)
        self.cards = BookingCards(self.client, self.store, cardholder["id"], webhook_secret=secret)
        if self.fake is not None:
            self.fake.endpoint = self.cards.handle_webhook

    def user(self, payment_method="pm_card_visa"):
        return {"reference": "demo-user", "customer": self.customer, "payment_method": payment_method}

    def sync(self, booking_id):
        if not self.webhooks:
            self.cards.reconcile(booking_id)

    def authorize(self, record, amount, merchant=RIDE_MERCHANT):
        authorization = self.client.post("/v1/test_helpers/issuing/authorizations", {
            "card": record["stripe"]["card"], "amount": amount, "authorization_method": "online",
            "merchant_data": merchant})
        self.sync(record["booking_id"])
        verdict = "approved" if authorization["approved"] else "declined"
        reason = (authorization.get("request_history") or [{}])[-1].get("reason")
        if reason == "webhook_declined":
            decisions = [e for e in self.store.get(record["booking_id"])["timeline"] if e["kind"] == "authorization_decision"]
            reason = f"sirven declined: {decisions[-1]['detail'].rsplit(': ', 1)[-1]}" if decisions else reason
        self.say(f"  authorization of {R.format_money(amount, 'usd')} at {merchant['name']}: {verdict} ({reason})")
        return authorization

    def capture(self, record, authorization, amount=None):
        params = {"capture_amount": amount} if amount is not None else {}
        self.client.post(f"/v1/test_helpers/issuing/authorizations/{authorization['id']}/capture", params)
        self.sync(record["booking_id"])

    def reverse(self, record, authorization, amount):
        self.client.post(f"/v1/test_helpers/issuing/authorizations/{authorization['id']}/reverse",
                         {"reverse_amount": amount})
        self.sync(record["booking_id"])

    def say(self, text):
        print(text, file=self.out)

    def show(self, booking_id):
        self.say(R.statement(self.store.get(booking_id)))


def scenario_completed_ride_with_tip(h):
    terms, rationale = sample_booking(1)
    record = h.cards.reserve_and_mint(terms, rationale, h.user())
    h.say(f"booking 1: held {R.format_money(terms['cap'], 'usd')} (fare plus tip ceiling), minted card ending {record['stripe']['card_last4']}")
    fare = h.authorize(record, 1840)
    h.capture(record, fare)
    tip = h.authorize(record, 300)
    h.capture(record, tip)
    h.cards.complete(terms["booking_id"])
    return terms["booking_id"]


def scenario_controls_decline(h):
    terms, rationale = sample_booking(2)
    record = h.cards.reserve_and_mint(terms, rationale, h.user())
    h.say("booking 2: the card refuses anything but ride services and anything over the cap")
    h.authorize(record, 1200, FOOD_MERCHANT)
    h.authorize(record, 3000)
    h.cards.cancel(terms["booking_id"])
    return terms["booking_id"]


def scenario_partial_reversal(h):
    terms, rationale = sample_booking(3)
    record = h.cards.reserve_and_mint(terms, rationale, h.user())
    h.say("booking 3: the ride service holds the fare, releases part of it, then captures the rest")
    fare = h.authorize(record, 1840)
    h.reverse(record, fare, 340)
    h.capture(record, fare, 1500)
    h.cards.complete(terms["booking_id"])
    return terms["booking_id"]


def scenario_cancelled_with_fee(h):
    terms, rationale = sample_booking(4)
    record = h.cards.reserve_and_mint(terms, rationale, h.user())
    h.say("booking 4: cancelled late; the ride service charges a fee, and nothing else gets through")
    fee = h.authorize(record, 500)
    h.cards.cancel(terms["booking_id"])
    h.authorize(record, 1000)
    h.capture(record, fee)
    return terms["booking_id"]


def scenario_cancelled_unspent(h):
    terms, rationale = sample_booking(5)
    h.cards.reserve_and_mint(terms, rationale, h.user())
    h.say("booking 5: cancelled before any charge; the hold is released and the card closed")
    h.cards.cancel(terms["booking_id"])
    return terms["booking_id"]


def scenario_refund_after_settlement(h):
    terms, rationale = sample_booking(6)
    record = h.cards.reserve_and_mint(terms, rationale, h.user())
    h.say("booking 6: the ride service refunds part of the fare after the user was charged")
    fare = h.authorize(record, 1840)
    h.capture(record, fare)
    h.cards.complete(terms["booking_id"])
    capture = next(t for t in h.client.get("/v1/issuing/transactions", {"card": record["stripe"]["card"]})["data"]
                   if t["type"] == "capture")
    h.client.post(f"/v1/test_helpers/issuing/transactions/{capture['id']}/refund", {"refund_amount": 500})
    h.sync(terms["booking_id"])
    return terms["booking_id"]


def scenario_over_capture(h):
    terms, rationale = sample_booking(7)
    record = h.cards.reserve_and_mint(terms, rationale, h.user())
    h.say("booking 7: the ride service captures more than the cap; the user still pays at most the cap")
    fare = h.authorize(record, 1840)
    h.capture(record, fare, 2600)
    h.cards.complete(terms["booking_id"])
    return terms["booking_id"]


def scenario_declined_user_card(h):
    terms, rationale = sample_booking(8)
    h.say("booking 8: the user's card refuses the hold, so no booking card is minted")
    try:
        h.cards.reserve_and_mint(terms, rationale, h.user("pm_card_chargeDeclined"))
    except ReservationFailed as error:
        h.say(f"  refused: {error}")
    return None


def scenario_missed_webhooks(h):
    terms, rationale = sample_booking(9)
    record = h.cards.reserve_and_mint(terms, rationale, h.user())
    h.say("booking 9: webhooks are lost; settlement pulls the card's history before charging anyone")
    endpoint = h.fake.endpoint if h.fake else None
    if h.fake:
        h.fake.endpoint = None
    fare = h.authorize(record, 1840)
    h.capture(record, fare)
    if h.fake:
        h.fake.endpoint = endpoint
    before = h.store.get(terms["booking_id"])
    h.say(f"  the record had seen {len(before['transactions'])} card transaction(s) when the ride completed")
    h.cards.complete(terms["booking_id"])
    return terms["booking_id"]


SCENARIOS = [
    scenario_completed_ride_with_tip,
    scenario_controls_decline,
    scenario_partial_reversal,
    scenario_cancelled_with_fee,
    scenario_cancelled_unspent,
    scenario_refund_after_settlement,
    scenario_over_capture,
    scenario_declined_user_card,
    scenario_missed_webhooks,
]


def run(records_dir, test_mode_key=None, out=sys.stdout):
    harness = Harness(records_dir, test_mode_key, out)
    harness.say(f"mode: {'Stripe test mode' if test_mode_key else 'in-memory stand-in for Stripe test mode'}")
    for scenario in SCENARIOS:
        harness.say("")
        booking_id = scenario(harness)
        if booking_id:
            harness.show(booking_id)
    return harness


def serve(records_dir, port, cardholder_id):
    key = os.environ.get("STRIPE_TEST_SECRET_KEY", "")
    cards = BookingCards(StripeClient(key), R.RecordStore(records_dir), cardholder_id,
                         webhook_secret=os.environ.get("STRIPE_WEBHOOK_SECRET"))

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802 (the standard library names it)
            if self.path != "/stripe/webhook":
                self.send_error(404)
                return
            payload = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            status, headers, body = cards.handle_webhook(payload, self.headers.get("Stripe-Signature"))
            self.send_response(status)
            for name, value in headers.items():
                self.send_header(name, value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"listening on 127.0.0.1:{port}/stripe/webhook", file=sys.stderr)
    server.serve_forever()


def main(argv=None):
    parser = argparse.ArgumentParser(prog="python3 -m issuing.demo")
    parser.add_argument("command", nargs="?", default="run", choices=["run", "serve"])
    parser.add_argument("--stripe-test-mode", action="store_true")
    parser.add_argument("--records", default=None)
    parser.add_argument("--port", type=int, default=4242)
    parser.add_argument("--cardholder", default=None)
    args = parser.parse_args(argv)
    records_dir = args.records or tempfile.mkdtemp(prefix="sirven-charge-records.")
    if args.command == "serve":
        serve(records_dir, args.port, args.cardholder)
        return 0
    key = None
    if args.stripe_test_mode:
        key = os.environ.get("STRIPE_TEST_SECRET_KEY")
        if not key:
            print("set STRIPE_TEST_SECRET_KEY to a Stripe test mode key first", file=sys.stderr)
            return 2
    run(records_dir, key)
    print(f"\ncharge records: {records_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
