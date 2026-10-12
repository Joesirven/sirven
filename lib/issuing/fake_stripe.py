"""an in-memory stand-in for the slice of the Stripe API this package uses.

it is a transport for StripeClient, so the flow code runs unchanged against it. it follows the
documented test mode behavior closely enough to exercise every branch of the flow:

  spending controls run first and can decline before the real-time request is sent
  (docs.stripe.com/issuing/controls/spending-controls); the real-time request is signed and
  sent to the endpoint, whose JSON answer must carry a Stripe-Version header
  (docs.stripe.com/issuing/controls/real-time-authorizations); single-use lifecycle controls
  cancel the card after the payment count (docs.stripe.com/issuing/controls/lifecycle-controls);
  captures post negative Issuing transactions and refunds positive ones.

it is not Stripe. anything it gets wrong, a run against Stripe test mode (see demo.py) shows.
"""
import copy
import itertools
import json
import re
import urllib.parse

from . import webhook

STRIPE_SIGNATURE = "Stripe-Signature"


def decode_form(body):
    """turn a[b][0]=x form pairs back into nested dicts and lists."""
    root = {}
    for name, value in urllib.parse.parse_qsl(body or "", keep_blank_values=True):
        keys = re.findall(r"[^\[\]]+", name)
        node = root
        for index, key in enumerate(keys):
            last = index == len(keys) - 1
            if last:
                node[key] = value
            else:
                node = node.setdefault(key, {})
    return _listify(root)


def _listify(node):
    if not isinstance(node, dict):
        return node
    converted = {key: _listify(value) for key, value in node.items()}
    if converted and all(key.isdigit() for key in converted):
        return [converted[key] for key in sorted(converted, key=int)]
    return converted


class FakeStripe:
    def __init__(self, webhook_secret="whsec_test_fake", issuing_balance=0, clock=None):
        self.webhook_secret = webhook_secret
        self.issuing_balance = issuing_balance
        self.endpoint = None          # callable(payload bytes, signature header) -> (status, headers, body)
        self.objects = {}
        self.events = []
        self.idempotency = {}
        self.requests = []
        self._ids = itertools.count(1)
        self._last4 = itertools.count(4242)
        self.clock = clock

    # plumbing -------------------------------------------------------------------------------

    def _id(self, prefix):
        return f"{prefix}_test{next(self._ids):06d}"

    def _error(self, status, message, code=None):
        return status, json.dumps({"error": {"message": message, "code": code}}).encode()

    def _ok(self, obj):
        return 200, json.dumps(obj).encode()

    def _emit(self, kind, obj):
        event = {"id": self._id("evt"), "object": "event", "type": kind, "livemode": False,
                 "data": {"object": copy.deepcopy(obj)}}
        self.events.append(event)
        if self.endpoint is not None:
            payload = json.dumps(event).encode()
            return self.endpoint(payload, webhook.sign(self.webhook_secret, payload))
        return None

    def __call__(self, method, url, headers, body):
        if not headers.get("Authorization", "").startswith(("Bearer sk_test_", "Bearer rk_test_")):
            return self._error(401, "the stand-in only accepts test mode keys")
        parsed = urllib.parse.urlsplit(url)
        params = decode_form(parsed.query if method == "GET" else (body or b"").decode())
        self.requests.append((method, parsed.path, params))
        key = headers.get("Idempotency-Key")
        if method == "POST" and key and key in self.idempotency:
            return self.idempotency[key]
        response = self._route(method, parsed.path, params)
        if method == "POST" and key and response[0] < 500:
            self.idempotency[key] = response
        return response

    def _route(self, method, path, params):
        routes = [
            ("POST", r"/v1/customers", self._create_customer),
            ("POST", r"/v1/payment_intents", self._create_payment_intent),
            ("POST", r"/v1/payment_intents/(pi_\w+)/capture", self._capture_payment_intent),
            ("POST", r"/v1/payment_intents/(pi_\w+)/cancel", self._cancel_payment_intent),
            ("GET", r"/v1/payment_intents/(pi_\w+)", self._get),
            ("POST", r"/v1/refunds", self._create_refund),
            ("POST", r"/v1/topups", self._create_topup),
            ("POST", r"/v1/issuing/cardholders", self._create_cardholder),
            ("POST", r"/v1/issuing/cards", self._create_card),
            ("POST", r"/v1/issuing/cards/(ic_\w+)", self._update_card),
            ("GET", r"/v1/issuing/cards/(ic_\w+)", self._get),
            ("GET", r"/v1/issuing/authorizations", self._list_authorizations),
            ("GET", r"/v1/issuing/transactions", self._list_transactions),
            ("POST", r"/v1/test_helpers/issuing/authorizations", self._helper_authorize),
            ("POST", r"/v1/test_helpers/issuing/authorizations/(iauth_\w+)/capture", self._helper_capture),
            ("POST", r"/v1/test_helpers/issuing/authorizations/(iauth_\w+)/reverse", self._helper_reverse),
            ("POST", r"/v1/test_helpers/issuing/authorizations/(iauth_\w+)/expire", self._helper_expire),
            ("POST", r"/v1/test_helpers/issuing/transactions/create_force_capture", self._helper_force_capture),
            ("POST", r"/v1/test_helpers/issuing/transactions/(ipi_\w+)/refund", self._helper_refund),
        ]
        for verb, pattern, handler in routes:
            match = re.fullmatch(pattern, path)
            if verb == method and match:
                return handler(params, *match.groups())
        return self._error(404, f"the stand-in does not implement {method} {path}")

    def _get(self, params, object_id):
        if object_id not in self.objects:
            return self._error(404, f"no such object: {object_id}", "resource_missing")
        return self._ok(self.objects[object_id])

    def _store(self, obj):
        obj.setdefault("livemode", False)
        self.objects[obj["id"]] = obj
        return obj

    # payments on the user's card ---------------------------------------------------------------

    def _create_customer(self, params):
        return self._ok(self._store({"id": self._id("cus"), "object": "customer"}))

    def _create_payment_intent(self, params):
        amount = int(params["amount"])
        method = params.get("payment_method", "")
        if method == "pm_card_chargeDeclined":
            return self._error(402, "Your card was declined.", "card_declined")
        manual = params.get("capture_method") == "manual"
        confirmed = params.get("confirm") == "true"
        status = "requires_confirmation"
        if confirmed:
            status = "requires_capture" if manual else "succeeded"
        intent = self._store({
            "id": self._id("pi"), "object": "payment_intent", "amount": amount,
            "currency": params["currency"], "capture_method": params.get("capture_method", "automatic"),
            "status": status, "amount_capturable": amount if status == "requires_capture" else 0,
            "amount_received": amount if status == "succeeded" else 0, "amount_refunded": 0,
            "customer": params.get("customer"), "metadata": params.get("metadata", {}),
        })
        return self._ok(intent)

    def _capture_payment_intent(self, params, intent_id):
        intent = self.objects.get(intent_id)
        if not intent or intent["status"] != "requires_capture":
            return self._error(400, "This PaymentIntent could not be captured.", "payment_intent_unexpected_state")
        amount = int(params.get("amount_to_capture", intent["amount_capturable"]))
        if amount > intent["amount_capturable"]:
            return self._error(400, "amount_to_capture is greater than amount_capturable", "amount_too_large")
        intent.update(status="succeeded", amount_received=amount, amount_capturable=0)
        return self._ok(intent)

    def _cancel_payment_intent(self, params, intent_id):
        intent = self.objects.get(intent_id)
        if not intent or intent["status"] in ("succeeded", "canceled"):
            return self._error(400, "This PaymentIntent could not be canceled.", "payment_intent_unexpected_state")
        intent.update(status="canceled", amount_capturable=0)
        return self._ok(intent)

    def _create_refund(self, params):
        intent = self.objects.get(params.get("payment_intent"))
        if not intent or intent["status"] != "succeeded":
            return self._error(400, "nothing to refund", "charge_not_refundable")
        amount = int(params.get("amount", intent["amount_received"] - intent["amount_refunded"]))
        if amount > intent["amount_received"] - intent["amount_refunded"]:
            return self._error(400, "refund is greater than the unrefunded amount", "amount_too_large")
        intent["amount_refunded"] += amount
        return self._ok(self._store({"id": self._id("re"), "object": "refund", "amount": amount,
                                     "payment_intent": intent["id"], "status": "succeeded"}))

    def _create_topup(self, params):
        if params.get("destination_balance") != "issuing":
            return self._error(400, "the stand-in only tops up the issuing balance")
        self.issuing_balance += int(params["amount"])
        return self._ok(self._store({"id": self._id("tu"), "object": "topup", "amount": int(params["amount"]),
                                     "status": "succeeded"}))

    # Issuing --------------------------------------------------------------------------------------

    def _create_cardholder(self, params):
        if params.get("type") not in ("company", "individual") or not params.get("name"):
            return self._error(400, "cardholder needs a name and a type")
        return self._ok(self._store({"id": self._id("ich"), "object": "issuing.cardholder",
                                     "type": params["type"], "name": params["name"], "status": "active"}))

    def _create_card(self, params):
        if params.get("cardholder") not in self.objects:
            return self._error(400, "no such cardholder", "resource_missing")
        controls = params.get("spending_controls", {})
        for limit in controls.get("spending_limits", []):
            limit["amount"] = int(limit["amount"])
        lifecycle = params.get("lifecycle_controls")
        if lifecycle:
            lifecycle["cancel_after"]["payment_count"] = int(lifecycle["cancel_after"]["payment_count"])
        card = self._store({
            "id": self._id("ic"), "object": "issuing.card", "type": params.get("type"),
            "cardholder": params["cardholder"], "currency": params.get("currency"),
            "status": params.get("status", "inactive"), "last4": str(next(self._last4)),
            "spending_controls": controls, "lifecycle_controls": lifecycle,
            "metadata": params.get("metadata", {}), "_payment_count": 0,
        })
        return self._ok(self._public_card(card))

    def _public_card(self, card):
        return {k: v for k, v in card.items() if not k.startswith("_")}

    def _update_card(self, params, card_id):
        card = self.objects.get(card_id)
        if card is None:
            return self._error(404, "no such card", "resource_missing")
        if card["status"] == "canceled":
            return self._error(400, "This card has been canceled and cannot be updated.", "card_canceled")
        if "status" in params:
            card["status"] = params["status"]
        return self._ok(self._public_card(card))

    def _list(self, kind, card_id):
        data = [o for o in self.objects.values() if o.get("object") == kind and self._card_id(o) == card_id]
        return self._ok({"object": "list", "data": data, "has_more": False})

    def _card_id(self, obj):
        card = obj.get("card")
        return card.get("id") if isinstance(card, dict) else card

    def _list_authorizations(self, params):
        return self._list("issuing.authorization", params.get("card"))

    def _list_transactions(self, params):
        return self._list("issuing.transaction", params.get("card"))

    def _spent_on(self, card_id):
        held = sum(o["amount"] for o in self.objects.values() if o.get("object") == "issuing.authorization"
                   and self._card_id(o) == card_id and o["approved"] and o["status"] == "pending")
        posted = sum(-o["amount"] for o in self.objects.values() if o.get("object") == "issuing.transaction"
                     and self._card_id(o) == card_id)
        return held + posted

    def _controls_decline(self, card, amount, category):
        controls = card.get("spending_controls") or {}
        allowed = controls.get("allowed_categories")
        if allowed and category not in allowed:
            return "spending_controls"
        for limit in controls.get("spending_limits", []):
            if limit.get("categories") and category not in limit["categories"]:
                continue
            if limit["interval"] == "per_authorization" and amount > limit["amount"]:
                return "spending_controls"
            if limit["interval"] == "all_time" and self._spent_on(card["id"]) + amount > limit["amount"]:
                return "spending_controls"
        return None

    def _count_payment(self, card, amount):
        card["_payment_count"] += 1 if amount > 100 else 0
        lifecycle = card.get("lifecycle_controls")
        if lifecycle and card["_payment_count"] >= lifecycle["cancel_after"]["payment_count"]:
            card["status"] = "canceled"

    def _helper_authorize(self, params):
        card = self.objects.get(params.get("card"))
        if card is None:
            return self._error(404, "no such card", "resource_missing")
        amount = int(params["amount"])
        merchant = params.get("merchant_data", {})
        category = merchant.get("category", "miscellaneous")
        authorization = {
            "id": self._id("iauth"), "object": "issuing.authorization", "amount": 0, "approved": False,
            "currency": card["currency"], "status": "pending", "card": self._public_card(card),
            "merchant_data": merchant, "pending_request": {"amount": amount, "currency": card["currency"],
                                                            "is_amount_controllable": False},
            "request_history": [], "livemode": False,
        }
        reason = None
        if card["status"] != "active":
            reason = "card_inactive"
        if reason is None:
            reason = self._controls_decline(card, amount, category)
        if reason is None and amount > self.issuing_balance:
            reason = "insufficient_funds"
        if reason is None:
            approved, reason = self._ask_endpoint(authorization)
        else:
            approved = False
        authorization.update(approved=approved, amount=amount if approved else 0, pending_request=None,
                             status="pending" if approved else "closed")
        authorization["request_history"].append({"amount": amount, "approved": approved, "reason": reason})
        if approved:
            self.issuing_balance -= amount
            self._count_payment(card, amount)
        self._store(authorization)
        self._emit("issuing_authorization.created", authorization)
        return self._ok(authorization)

    def _ask_endpoint(self, authorization):
        if self.endpoint is None:
            return True, "webhook_approved"
        status, headers, body = self._emit("issuing_authorization.request", authorization)
        if status != 200 or "Stripe-Version" not in headers:
            # without autopilot configured, the test account's timeout setting declines.
            return False, "webhook_error"
        answer = json.loads(body)
        return bool(answer.get("approved")), "webhook_approved" if answer.get("approved") else "webhook_declined"

    def _transaction(self, card_id, kind, amount, authorization_id, merchant):
        transaction = self._store({
            "id": self._id("ipi"), "object": "issuing.transaction", "type": kind,
            "amount": -amount if kind == "capture" else amount, "currency": "usd",
            "card": card_id, "authorization": authorization_id, "merchant_data": merchant,
        })
        self._emit("issuing_transaction.created", transaction)
        return transaction

    def _helper_capture(self, params, authorization_id):
        authorization = self.objects.get(authorization_id)
        if not authorization or authorization["status"] != "pending" or not authorization["approved"]:
            return self._error(400, "authorization is not pending", "authorization_unexpected_state")
        amount = int(params.get("capture_amount", authorization["amount"]))
        # over-capture (a tip posted later) is allowed and can exceed spending limits.
        self.issuing_balance += authorization["amount"] - amount
        card_id = self._card_id(authorization)
        authorization["status"] = "closed"
        self._transaction(card_id, "capture", amount, authorization_id, authorization["merchant_data"])
        self._emit("issuing_authorization.updated", authorization)
        return self._ok(authorization)

    def _helper_reverse(self, params, authorization_id):
        authorization = self.objects.get(authorization_id)
        if not authorization or authorization["status"] != "pending":
            return self._error(400, "authorization is not pending", "authorization_unexpected_state")
        amount = int(params.get("reverse_amount", authorization["amount"]))
        amount = min(amount, authorization["amount"])
        authorization["amount"] -= amount
        self.issuing_balance += amount
        if authorization["amount"] == 0:
            authorization["status"] = "reversed"
        self._emit("issuing_authorization.updated", authorization)
        return self._ok(authorization)

    def _helper_expire(self, params, authorization_id):
        authorization = self.objects.get(authorization_id)
        if not authorization or authorization["status"] != "pending":
            return self._error(400, "authorization is not pending", "authorization_unexpected_state")
        self.issuing_balance += authorization["amount"]
        authorization.update(status="expired", amount=0)
        self._emit("issuing_authorization.updated", authorization)
        return self._ok(authorization)

    def _helper_force_capture(self, params):
        card = self.objects.get(params.get("card"))
        if card is None:
            return self._error(404, "no such card", "resource_missing")
        amount = int(params["amount"])
        # network rules: force posts are processed even on a cancelled card.
        self.issuing_balance -= amount
        self._count_payment(card, amount)
        return self._ok(self._transaction(card["id"], "capture", amount, None, params.get("merchant_data", {})))

    def _helper_refund(self, params, transaction_id):
        original = self.objects.get(transaction_id)
        if not original or original["type"] != "capture":
            return self._error(400, "only captures can be refunded", "transaction_unexpected_state")
        amount = int(params.get("refund_amount", -original["amount"]))
        self.issuing_balance += amount
        self._transaction(original["card"], "refund", amount, original["authorization"], original["merchant_data"])
        return self._ok(original)
