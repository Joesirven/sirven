"""the charge-with-rationale record: every amount, paired with why the agent spent it.

one JSON file per booking. the record never holds card numbers, security codes, or expiry
dates; the card appears only as its Stripe object reference and last four digits.

states
  reserved      the user's card holds the cap and the booking card is live
  settled       the user was charged exactly what the card spent; the card is closed
  cancelled     nothing was spent; the hold is released and the card is closed
  needs_review  something happened the flow will not resolve on its own (spend above the cap,
                spend after settlement); a person looks before any more money moves
"""
import contextlib
import fcntl
import json
import os
import tempfile
import time

RECORD_VERSION = 1
OPEN_STATES = ("reserved",)


def now_iso(clock=time.time):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(clock()))


def new_record(terms, rationale, user_reference, clock=time.time):
    return {
        "record_version": RECORD_VERSION,
        "booking_id": terms["booking_id"],
        "quote_id": terms["quote_id"],
        "user": user_reference,
        "state": "reserved",
        "amounts": {
            "currency": terms["currency"],
            "quoted": terms["quoted"],
            "tip_ceiling": terms["tip_ceiling"],
            "cap": terms["cap"],
            "reserved_on_user_card": 0,
            "captured_by_card": 0,
            "refunded_to_card": 0,
            "charged_to_user": 0,
            "refunded_to_user": 0,
        },
        "rationale": {
            "quote": {
                "quote_id": terms["quote_id"],
                "provider": terms.get("provider"),
                "price_minor": terms["quoted"],
                "estimated_arrival": terms.get("estimated_arrival"),
                "estimated_trip_time": terms.get("estimated_trip_time"),
            },
            "booking": {
                "booking_id": terms["booking_id"],
                "cancellation_window": terms.get("cancellation_window"),
            },
            "reasoning_summary": rationale.get("reasoning_summary", ""),
            "user_request": rationale.get("user_request", ""),
        },
        "stripe": {"payment_intent": None, "card": None, "card_last4": None, "cardholder": None},
        "authorizations": {},
        "transactions": {},
        "processed_events": [],
        "review_reasons": [],
        "timeline": [{"at": now_iso(clock), "kind": "created", "detail": "charge record opened"}],
    }


def add_timeline(record, kind, detail, amount=None, clock=time.time):
    entry = {"at": now_iso(clock), "kind": kind, "detail": detail}
    if amount is not None:
        entry["amount"] = amount
    record["timeline"].append(entry)


def pending_authorized(record):
    return sum(a["amount"] for a in record["authorizations"].values()
               if a.get("approved") and a.get("status") == "pending")


def net_card_spend(record):
    amounts = record["amounts"]
    return amounts["captured_by_card"] - amounts["refunded_to_card"]


def recompute_card_totals(record):
    captured = refunded = 0
    for transaction in record["transactions"].values():
        if transaction["type"] == "capture":
            captured += transaction["amount"]
        elif transaction["type"] == "refund":
            refunded += transaction["amount"]
    record["amounts"]["captured_by_card"] = captured
    record["amounts"]["refunded_to_card"] = refunded


def format_money(amount_minor, currency):
    symbol = "$" if currency == "usd" else ""
    suffix = "" if symbol else f" {currency}"
    return f"{symbol}{amount_minor // 100}.{amount_minor % 100:02d}{suffix}"


def statement(record):
    """the user-facing line items: each amount next to the reason it was spent."""
    amounts = record["amounts"]
    currency = amounts["currency"]
    money = lambda value: format_money(value, currency)  # noqa: E731
    quote = record["rationale"]["quote"]
    lines = [
        f"booking {record['booking_id']} ({record['state']})",
        f"  why: {record['rationale']['reasoning_summary'] or 'no reason recorded'}",
    ]
    if record["rationale"].get("user_request"):
        lines.append(f"  you asked: {record['rationale']['user_request']}")
    lines.append(f"  quote {quote['quote_id']} from {quote.get('provider') or 'the ride service'}: "
                 f"{money(amounts['quoted'])}, tip allowed up to {money(amounts['tip_ceiling'])}")
    lines.append(f"  held on your card at booking: {money(amounts['reserved_on_user_card'])}")
    lines.append(f"  paid to the ride service: {money(net_card_spend(record))}")
    lines.append(f"  charged to you: {money(amounts['charged_to_user'])}")
    if amounts["refunded_to_user"]:
        lines.append(f"  refunded to you: {money(amounts['refunded_to_user'])}")
    for reason in record["review_reasons"]:
        lines.append(f"  under review: {reason}")
    return "\n".join(lines)


class RecordStore:
    """a directory of charge records, one file per booking, written atomically."""

    def __init__(self, directory):
        self.directory = directory
        os.makedirs(directory, mode=0o700, exist_ok=True)

    def _path(self, booking_id):
        safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in booking_id)
        return os.path.join(self.directory, f"{safe}.json")

    @contextlib.contextmanager
    def locked(self, booking_id):
        """hold an exclusive lock on one booking's record. webhook deliveries, settlement, and
        reconciliation all read, change, and write the same file; the lock keeps them from
        overwriting each other."""
        with open(self._path(booking_id) + ".lock", "a", encoding="utf-8") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle, fcntl.LOCK_UN)

    def get(self, booking_id):
        try:
            with open(self._path(booking_id), encoding="utf-8") as handle:
                return json.load(handle)
        except FileNotFoundError:
            return None

    def put(self, record):
        path = self._path(record["booking_id"])
        fd, temp = tempfile.mkstemp(dir=self.directory, prefix=".record.")
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(record, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temp, path)

    def _card_index_path(self, card_id):
        safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in card_id)
        return os.path.join(self.directory, "cards", safe)

    def index_card(self, card_id, booking_id):
        """transactions name their card but carry none of its metadata, so keep the way back."""
        os.makedirs(os.path.join(self.directory, "cards"), mode=0o700, exist_ok=True)
        with open(self._card_index_path(card_id), "w", encoding="utf-8") as handle:
            handle.write(booking_id + "\n")

    def booking_for_card(self, card_id):
        try:
            with open(self._card_index_path(card_id), encoding="utf-8") as handle:
                return handle.read().strip() or None
        except FileNotFoundError:
            return None

    def all(self):
        records = []
        for name in sorted(os.listdir(self.directory)):
            if name.endswith(".json"):
                with open(os.path.join(self.directory, name), encoding="utf-8") as handle:
                    records.append(json.load(handle))
        return records
