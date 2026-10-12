"""the per-booking card flow: reserve and mint, attach the booking, authorize, reconcile,
settle, cancel.

order matters. the orchestrator calls reserve_and_mint when the user picks a quote, and only
calls book_ride if that succeeds; then attach_booking, or release if book_ride fails. so a
card that refuses the hold stops the booking before anything is committed. the reservation
is keyed by quote_id until a booking exists.

money moves in two places and sirven holds a balance in neither:

  the user's side    a payment intent with manual capture reserves the cap on the user's card at
                     booking. at settlement sirven captures exactly what the booking card spent
                     (never more than the cap) or cancels the hold if nothing was spent.
  the ride side      a virtual card from sirven's own Issuing balance, minted for one booking,
                     limited to ride services and to the cap, closed at settlement.

every decision lands in the charge record with its reason, so the user can see why each
amount moved.
"""
import json

from . import records as R
from .contract import booking_details, final_charge_total
from .stripe_api import STRIPE_VERSION, StripeError
from .webhook import SignatureError, verify

# ride services settle under merchant category code 4121, which Stripe names
# taxicabs_limousines (docs.stripe.com/issuing/testing uses it for a ride service).
ALLOWED_CATEGORIES = ("taxicabs_limousines",)
# the reservation is keyed by quote: it exists before book_ride commits, so it can gate it.
METADATA_QUOTE = "sirven_quote_id"
TERMINAL_AUTHORIZATION_STATUSES = ("closed", "reversed", "expired")
# an online card hold lasts 7 days (docs.stripe.com/payments/place-a-hold-on-a-payment-method).
# a reservation still open after 6 days settles what the card has paid, so the user's hold
# never lapses with money owed, and a person reviews the rest.
SETTLE_DEADLINE_SECONDS = 6 * 24 * 3600


class FlowError(Exception):
    pass


class ReservationFailed(FlowError):
    pass


class SettlementNotReady(FlowError):
    pass


def card_parameters(terms, cardholder_id, single_use=True):
    """the Stripe create-card parameters for one booking. kept apart so tests can pin them."""
    params = {
        "cardholder": cardholder_id,
        "type": "virtual",
        "currency": terms["currency"],
        "status": "active",
        "spending_controls": {
            "allowed_categories": list(ALLOWED_CATEGORIES),
            "spending_limits": [
                {"amount": terms["cap"], "interval": "per_authorization"},
                {"amount": terms["cap"], "interval": "all_time"},
            ],
        },
        "metadata": {METADATA_QUOTE: terms["quote_id"]},
    }
    if single_use:
        # one payment for the fare, and one more when a tip ceiling allows a separate tip charge.
        params["lifecycle_controls"] = {"cancel_after": {"payment_count": 2 if terms["tip_ceiling"] else 1}}
    return params


class BookingCards:
    def __init__(self, client, store, cardholder_id, webhook_secret=None, single_use=True, clock=None):
        self.client = client
        self.store = store
        self.cardholder_id = cardholder_id
        self.webhook_secret = webhook_secret
        self.single_use = single_use
        self.clock = clock or R.time.time

    # booking time ------------------------------------------------------------------------

    def reserve_and_mint(self, terms, rationale, user):
        """hold the cap on the user's card, then mint the booking card. call it after the user
        picks a quote and before book_ride; book only if it succeeds. idempotent per quote.

        user is {"reference": opaque user reference, "customer": Stripe customer,
        "payment_method": the user's saved card}. returns the charge record.
        """
        quote_id = terms["quote_id"]
        with self.store.locked(quote_id):
            record = self.store.get(quote_id)
            if record is not None:
                return record
            record = R.new_record(terms, rationale, user.get("reference"), self.clock)
            try:
                intent = self.client.post("/v1/payment_intents", {
                    "amount": terms["cap"],
                    "currency": terms["currency"],
                    "customer": user["customer"],
                    "payment_method": user["payment_method"],
                    "payment_method_types": ["card"],
                    "capture_method": "manual",
                    "confirm": True,
                    "description": f"sirven ride, quote {quote_id}",
                    "metadata": {METADATA_QUOTE: quote_id},
                }, idempotency_key=f"sirven-reserve-{quote_id}")
            except StripeError as error:
                raise ReservationFailed(f"the user's card did not accept the hold: {error}") from error
            if intent.get("status") != "requires_capture":
                raise ReservationFailed(f"the hold on the user's card is {intent.get('status')}, not requires_capture")
            try:
                card = self.client.post("/v1/issuing/cards", card_parameters(terms, self.cardholder_id, self.single_use),
                                        idempotency_key=f"sirven-card-{quote_id}")
            except StripeError as error:
                # no card means no booking can be paid; release the user's hold right away.
                self.client.post(f"/v1/payment_intents/{intent['id']}/cancel",
                                 idempotency_key=f"sirven-release-{quote_id}")
                raise ReservationFailed(f"the booking card could not be minted, hold released: {error}") from error
            record["stripe"].update(payment_intent=intent["id"], card=card["id"],
                                    card_last4=card.get("last4"), cardholder=self.cardholder_id)
            record["amounts"]["reserved_on_user_card"] = intent.get("amount_capturable", terms["cap"])
            record["reserved_at"] = self.clock()
            record["accepting_authorizations"] = True
            record["ride_completed"] = False
            R.add_timeline(record, "reserved", "held on the user's card", terms["cap"], self.clock)
            R.add_timeline(record, "card_minted",
                           f"virtual card ending {card.get('last4')} limited to ride services and the cap",
                           terms["cap"], self.clock)
            self.store.index_card(card["id"], quote_id)
            self.store.index_reference(record["payment_reference"], quote_id)
            self.store.put(record)
            return record

    def attach_booking(self, quote_id, booking):
        """book_ride returned: record which booking this reservation pays for."""
        details = booking_details(quote_id, booking)
        with self.store.locked(quote_id):
            record = self._require(quote_id)
            if record.get("booking_id") not in (None, details["booking_id"]):
                raise FlowError(f"quote {quote_id} already pays for booking {record['booking_id']}")
            if record["state"] not in R.OPEN_STATES:
                raise FlowError(f"the reservation for quote {quote_id} is already {record['state']}")
            if record.get("booking_id") is None:
                record["booking_id"] = details["booking_id"]
                record["rationale"]["booking"] = details
                R.add_timeline(record, "booked", f"booking {details['booking_id']} confirmed", clock=self.clock)
                self.store.put(record)
            return record

    def card_for_payment_reference(self, reference, authorization_cap_minor):
        """the backend's lookup: RideBackend.book receives the payment_reference and the
        booking's authorization cap, and this returns the Stripe card reference to pay the ride
        service with. the cap must match what was held, so a reference held for one quote
        cannot pay for a different one. server side only."""
        quote_id = self.store.quote_for_reference(reference)
        if quote_id is None:
            raise FlowError("no funds are held under that payment reference")
        record = self._require(quote_id)
        if record["amounts"]["cap"] != authorization_cap_minor:
            raise FlowError("that payment reference holds funds for a different amount")
        return self.card_for_quote(quote_id)

    def card_for_quote(self, quote_id):
        """the Stripe card reference for the backend that pays the ride service. server side
        only: it never goes back through the agent-facing connector contract."""
        record = self._require(quote_id)
        if record["state"] not in R.OPEN_STATES:
            raise FlowError(f"the reservation for quote {quote_id} is {record['state']}")
        return record["stripe"]["card"]

    # real-time authorization --------------------------------------------------------------

    def _quote_for_authorization(self, authorization):
        card = authorization.get("card")
        if isinstance(card, dict):
            quote_id = (card.get("metadata") or {}).get(METADATA_QUOTE)
            if quote_id:
                return quote_id
            card = card.get("id")
        return self.store.quote_for_card(card) if card else None

    def decide(self, record, authorization):
        """return (approved, reason). pure: reads the record, changes nothing."""
        if record is None:
            return False, "unknown_card"
        if record["state"] not in R.OPEN_STATES:
            return False, "booking_closed"
        limit, over = record["amounts"]["cap"], "over_cap"
        if not record.get("accepting_authorizations", True):
            # after a cancellation only the reported cancellation fee may still be charged.
            reported = record["amounts"].get("reported_by_ride_service")
            if reported is None:
                return False, "booking_closed"
            limit, over = min(limit, reported), "over_reported_total"
        pending = authorization.get("pending_request") or {}
        requested = pending.get("amount", authorization.get("amount", 0))
        currency = (pending.get("currency") or authorization.get("currency") or "").lower()
        if currency != record["amounts"]["currency"]:
            return False, "currency_mismatch"
        category = (authorization.get("merchant_data") or {}).get("category")
        if category not in ALLOWED_CATEGORIES:
            return False, "merchant_category_not_allowed"
        committed = R.pending_authorized(record) + R.net_card_spend(record)
        if committed + requested > limit:
            return False, over
        return True, "within_cap"

    def authorize(self, authorization):
        quote_id = self._quote_for_authorization(authorization)
        if quote_id is None:
            return False, "unknown_card"
        with self.store.locked(quote_id):
            record = self.store.get(quote_id)
            approved, reason = self.decide(record, authorization)
            if record is not None:
                requested = (authorization.get("pending_request") or {}).get("amount", 0)
                merchant = (authorization.get("merchant_data") or {}).get("name") or "a merchant"
                R.add_timeline(record, "authorization_decision",
                               f"{'approved' if approved else 'declined'} {merchant}: {reason}", requested, self.clock)
                self.store.put(record)
            return approved, reason

    # webhooks ------------------------------------------------------------------------------

    def handle_webhook(self, payload, signature_header):
        """one entry point for both endpoints. returns (status, headers, body bytes)."""
        try:
            event = verify(self.webhook_secret, payload, signature_header)
        except SignatureError as error:
            return 400, {"Content-Type": "application/json"}, json.dumps({"error": str(error)}).encode()
        if event.get("livemode") is True:
            return 400, {"Content-Type": "application/json"}, b'{"error": "live mode events are refused"}'
        if event.get("type") == "issuing_authorization.request":
            approved, reason = self.authorize(event["data"]["object"])
            body = {"approved": approved, "metadata": {"sirven_reason": reason}}
            return 200, {"Content-Type": "application/json", "Stripe-Version": STRIPE_VERSION}, json.dumps(body).encode()
        self.apply_event(event)
        return 200, {"Content-Type": "application/json"}, b'{"received": true}'

    def apply_event(self, event):
        kind = event.get("type", "")
        obj = (event.get("data") or {}).get("object") or {}
        if kind.startswith("issuing_authorization."):
            quote_id = self._quote_for_authorization(obj)
        elif kind.startswith("issuing_transaction."):
            card = obj.get("card")
            quote_id = self.store.quote_for_card(card.get("id") if isinstance(card, dict) else card)
        else:
            return None
        if quote_id is None:
            return None
        with self.store.locked(quote_id):
            record = self.store.get(quote_id)
            if record is None or event.get("id") in record["processed_events"]:
                return record
            if kind.startswith("issuing_authorization."):
                self._upsert_authorization(record, obj)
            else:
                self._upsert_transaction(record, obj)
            record["processed_events"].append(event.get("id"))
            self.store.put(record)
            ready = record["state"] in R.OPEN_STATES and record.get("ride_completed")
        if ready:
            # an event may be the last one, but webhooks can be lost or reordered: settle only
            # after pulling the card's full history from Stripe.
            self.reconcile(quote_id)
        return self.store.get(quote_id)

    def _upsert_authorization(self, record, obj):
        known = record["authorizations"].get(obj["id"], {})
        status = obj.get("status")
        # events can arrive out of order; never move an authorization back out of a final state.
        if known.get("status") in TERMINAL_AUTHORIZATION_STATUSES and status == "pending":
            return
        history = obj.get("request_history") or []
        record["authorizations"][obj["id"]] = {
            "amount": obj.get("amount", 0),
            "approved": bool(obj.get("approved")),
            "status": status,
            "merchant": (obj.get("merchant_data") or {}).get("name"),
            "category": (obj.get("merchant_data") or {}).get("category"),
            "stripe_reason": history[-1].get("reason") if history else None,
        }
        if not known:
            R.add_timeline(record, "authorization",
                           f"{'approved' if obj.get('approved') else 'declined'} at "
                           f"{(obj.get('merchant_data') or {}).get('name') or 'a merchant'}",
                           obj.get("amount", 0), self.clock)
        elif known.get("status") != status:
            R.add_timeline(record, "authorization", f"authorization is now {status}", obj.get("amount", 0), self.clock)

    def _upsert_transaction(self, record, obj):
        if obj["id"] in record["transactions"]:
            return
        kind = obj.get("type")
        amount = abs(obj.get("amount", 0))
        record["transactions"][obj["id"]] = {
            "type": kind,
            "amount": amount,
            "authorization": obj.get("authorization"),
            "merchant": (obj.get("merchant_data") or {}).get("name"),
        }
        R.recompute_card_totals(record)
        R.add_timeline(record, "card_" + (kind or "transaction"),
                       f"{kind} at {(obj.get('merchant_data') or {}).get('name') or 'a merchant'}", amount, self.clock)
        if record["state"] in R.OPEN_STATES:
            if R.net_card_spend(record) > record["amounts"]["cap"]:
                self._review(record, "the ride service took more than the cap; the user is charged at most the cap")
            return
        # the record already closed: money moved on the card after the user was settled.
        if kind == "refund":
            self._refund_user(record, amount)
        else:
            self._review(record, f"card spend of {amount} after settlement; sirven absorbed it and did not charge the user")

    def _review(self, record, reason):
        if reason not in record["review_reasons"]:
            record["review_reasons"].append(reason)
            R.add_timeline(record, "needs_review", reason, clock=self.clock)
        if record["state"] != "reserved":
            record["state"] = "needs_review"

    def _refund_user(self, record, amount):
        refundable = record["amounts"]["charged_to_user"] - record["amounts"]["refunded_to_user"]
        amount = min(amount, refundable)
        if amount <= 0:
            return
        count = sum(1 for e in record["timeline"] if e["kind"] == "refunded_to_user")
        self.client.post("/v1/refunds", {"payment_intent": record["stripe"]["payment_intent"], "amount": amount,
                                         "metadata": {METADATA_QUOTE: record["quote_id"]}},
                         idempotency_key=f"sirven-refund-{record['quote_id']}-{count}")
        record["amounts"]["refunded_to_user"] += amount
        R.add_timeline(record, "refunded_to_user", "the ride service refunded the card; passed on to the user",
                       amount, self.clock)

    # completion, settlement, cancellation ----------------------------------------------------

    def _note_final_charge(self, record, booking):
        if booking is None:
            return
        total = final_charge_total(booking, record["amounts"]["currency"])
        if total is not None and record["amounts"]["reported_by_ride_service"] != total:
            record["amounts"]["reported_by_ride_service"] = total
            R.add_timeline(record, "final_charge_reported", "the ride connector reported the final charge",
                           total, self.clock)

    def complete(self, quote_id, booking=None):
        """the ride finished (get_ride reports completed). settle now if nothing is still
        waiting to be captured. pass the booking so its final_charge is checked against what
        the card actually paid."""
        with self.store.locked(quote_id):
            record = self._require(quote_id)
            self._note_final_charge(record, booking)
            if not record.get("ride_completed"):
                record["ride_completed"] = True
                R.add_timeline(record, "ride_completed", "the ride service reported the trip complete", clock=self.clock)
                self.store.put(record)
        self.reconcile(quote_id)
        return self.store.get(quote_id)

    def release(self, quote_id):
        """book_ride failed or was abandoned after the reservation: give everything back."""
        return self.cancel(quote_id, detail="book_ride did not complete; the reservation is released")

    def cancel(self, quote_id, booking=None, detail="the booking was cancelled"):
        """the booking was cancelled (cancel_ride returned). release everything if nothing was
        spent; otherwise settle the cancellation fee once it is captured. no new
        authorizations either way."""
        with self.store.locked(quote_id):
            record = self._require(quote_id)
            self._note_final_charge(record, booking)
            if record["state"] not in R.OPEN_STATES:
                return record
            record["accepting_authorizations"] = False
            record["ride_completed"] = True
            R.add_timeline(record, "ride_cancelled", detail, clock=self.clock)
            self.store.put(record)
        self.reconcile(quote_id)
        return self.store.get(quote_id)

    def _settle_if_ready(self, record):
        """settle a record that the caller has just refreshed from Stripe, under its lock.

        waits while an authorization is pending, and while the ride connector reports a total
        the card has not paid yet (a tip or a cancellation fee still to come). the card stays
        live meanwhile, still bounded by the cap and by the real-time decision. the wait ends
        at the settlement deadline, before the user's hold can lapse."""
        if record["state"] not in R.OPEN_STATES:
            return
        if self.clock() - record.get("reserved_at", self.clock()) >= SETTLE_DEADLINE_SECONDS:
            self._review(record, "settled at the deadline before the user's hold lapses; anything still owed "
                                 "to or by the ride service is reconciled by a person")
            self._settle(record)
            return
        if not record.get("ride_completed") or R.pending_authorized(record) > 0:
            return
        reported = record["amounts"].get("reported_by_ride_service")
        if reported is not None and R.net_card_spend(record) < reported:
            return
        self._settle(record)

    def _settle(self, record):
        quote_id = record["quote_id"]
        amounts = record["amounts"]
        spent = max(R.net_card_spend(record), 0)
        charge = min(spent, amounts["reserved_on_user_card"])
        reported = amounts.get("reported_by_ride_service")
        if reported is not None and reported != spent:
            # the user pays the lower of what the card paid and what the ride connector reported;
            # a person reconciles the difference with the ride service.
            self._review(record, f"the card paid {spent} but the ride connector reported {reported}")
            charge = min(charge, reported)
        intent = record["stripe"]["payment_intent"]
        if charge > 0:
            self.client.post(f"/v1/payment_intents/{intent}/capture", {"amount_to_capture": charge},
                             idempotency_key=f"sirven-settle-{quote_id}")
            R.add_timeline(record, "charged_to_user", "captured exactly what the booking card spent", charge, self.clock)
        else:
            self.client.post(f"/v1/payment_intents/{intent}/cancel", idempotency_key=f"sirven-release-{quote_id}")
            R.add_timeline(record, "hold_released", "nothing was spent; the hold on the user's card is released",
                           clock=self.clock)
        card = record["stripe"]["card"]
        try:
            self.client.post(f"/v1/issuing/cards/{card}", {"status": "canceled"},
                             idempotency_key=f"sirven-close-card-{quote_id}")
        except StripeError:
            # single-use lifecycle controls may have cancelled it already; that is the goal.
            if self.client.get(f"/v1/issuing/cards/{card}").get("status") != "canceled":
                raise
        R.add_timeline(record, "card_closed", "the booking card is cancelled for good", clock=self.clock)
        amounts["charged_to_user"] = charge
        record["accepting_authorizations"] = False
        if record["review_reasons"]:
            record["state"] = "needs_review"
        else:
            record["state"] = "settled" if charge > 0 else "cancelled"

    # reconciliation --------------------------------------------------------------------------

    def reconcile(self, quote_id):
        """pull the card's authorizations and transactions from Stripe, fold in anything the
        webhooks missed, and settle if the ride is done. settlement only ever happens here, so
        no one is charged or released on webhook state alone. returns the number of objects
        that changed the record."""
        card = self._require(quote_id)["stripe"]["card"]
        authorizations = self.client.get("/v1/issuing/authorizations", {"card": card, "limit": 100})["data"]
        transactions = self.client.get("/v1/issuing/transactions", {"card": card, "limit": 100})["data"]
        changed = 0
        with self.store.locked(quote_id):
            record = self._require(quote_id)
            for obj in authorizations:
                before = json.dumps(record["authorizations"].get(obj["id"]), sort_keys=True)
                self._upsert_authorization(record, obj)
                changed += before != json.dumps(record["authorizations"].get(obj["id"]), sort_keys=True)
            for obj in transactions:
                if obj["id"] not in record["transactions"]:
                    self._upsert_transaction(record, obj)
                    changed += 1
            if changed:
                R.add_timeline(record, "reconciled", f"{changed} change(s) pulled from Stripe", clock=self.clock)
            self._settle_if_ready(record)
            self.store.put(record)
        return changed

    def sweep(self):
        """reconcile every open reservation. run it on a schedule (a bb automation, say, every
        hour): it is what settles a reservation whose webhooks never came, and what enforces
        the settlement deadline. returns the quote identifiers it looked at."""
        open_quotes = [r["quote_id"] for r in self.store.all() if r["state"] in R.OPEN_STATES]
        for quote_id in open_quotes:
            self.reconcile(quote_id)
        return open_quotes

    def _require(self, quote_id):
        record = self.store.get(quote_id)
        if record is None:
            raise FlowError(f"no charge record for quote {quote_id}")
        return record
