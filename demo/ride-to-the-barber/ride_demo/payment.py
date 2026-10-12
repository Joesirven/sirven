"""per-booking virtual cards: a stand-in for thread 11.

SUBSTITUTION. thread 11 (Stripe Issuing in test mode) had committed nothing when this demo
was built. this module makes no network call and touches no Stripe account, test or live. it
keeps the shape thread 11 is building:

  hold      mint one card for one booking, capped at the quoted amount plus the tip ceiling,
            restricted to ride services (Stripe's taxicabs_limousines merchant category)
  authorize the ride service charges the card; over the cap or outside the category declines
  settle    the ride finished: the charge stands at what was actually authorized
  release   the booking never happened: the hold goes away and nothing is charged

every hold carries a charge record that pairs the amount with the reason: the quote, the
booking, and a summary of the agent's reasoning. sirven holds no balance in any of this.
"""

import json
import os
import secrets
from datetime import datetime

RIDE_CATEGORY = "taxicabs_limousines"


class Declined(Exception):
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


class TestModeCards:
    def __init__(self, record_path):
        self.record_path = record_path
        self._cards = {}
        self._by_quote = {}

    def hold(self, quote, rationale):
        cap = quote["price"]["amount_minor"] + quote["tip_ceiling"]["amount_minor"]
        card = {
            "card_id": "ic_test_" + secrets.token_hex(6),
            "mode": "test",
            "last4": "4242",
            "currency": quote["price"]["currency"],
            "spending_limit_minor": cap,
            "allowed_categories": [RIDE_CATEGORY],
            "status": "held",
            "authorized_minor": 0,
            "charge_record": {
                "quote_id": quote["quote_id"],
                "provider": quote["provider"],
                "product": quote["product"],
                "quoted_minor": quote["price"]["amount_minor"],
                "tip_ceiling_minor": quote["tip_ceiling"]["amount_minor"],
                "booking_id": None,
                "rationale": rationale,
                "held_at": datetime.now().astimezone().isoformat(timespec="seconds"),
            },
        }
        self._cards[card["card_id"]] = card
        self._by_quote[quote["quote_id"]] = card["card_id"]
        self._save()
        return card

    def card_for_quote(self, quote_id):
        card_id = self._by_quote.get(quote_id)
        return self._cards.get(card_id) if card_id else None

    def authorize(self, card_id, amount_minor, category):
        card = self._cards[card_id]
        if card["status"] != "held":
            raise Declined("card is %s" % card["status"])
        if category != RIDE_CATEGORY:
            raise Declined("merchant category %s is not a ride service" % category)
        if card["authorized_minor"] + amount_minor > card["spending_limit_minor"]:
            raise Declined("amount is over the card's limit")
        card["authorized_minor"] += amount_minor
        self._save()
        return card

    def attach_booking(self, card_id, booking_id):
        self._cards[card_id]["charge_record"]["booking_id"] = booking_id
        self._save()

    def settle(self, card_id):
        card = self._cards[card_id]
        card["status"] = "settled"
        card["charge_record"]["settled_minor"] = card["authorized_minor"]
        self._save()
        return card

    def release(self, card_id, reason):
        card = self._cards[card_id]
        card["status"] = "released"
        card["authorized_minor"] = 0
        card["charge_record"]["released_because"] = reason
        self._save()
        return card

    def _save(self):
        os.makedirs(os.path.dirname(self.record_path), exist_ok=True)
        with open(self.record_path, "w") as handle:
            json.dump(list(self._cards.values()), handle, indent=2, sort_keys=True)
            handle.write("\n")
