"""charge records: what the agent meant to pay, and why, written before every booking.

there is no card here, and nothing from Stripe. a record pairs the quote and the cap the user
approved with the agent's reasoning, then says how the ride was paid once it is booked, or
that it was not booked. on the phone path the owner pays in the ride app, approving that one
purchase live; on the concierge path this build has no payment method at all, which is a
decision left for Jose. sirven holds no balance and no payment details in any of this.
"""

import json
import os
import secrets
from datetime import datetime


def stamp():
    return datetime.now().astimezone().isoformat(timespec="seconds")


class ChargeRecords:
    def __init__(self, record_path):
        self.record_path = record_path
        self._records = {}

    def write(self, quote, cap_minor, rationale):
        """one record, before the booking is attempted. returns it."""
        record = {
            "record_id": "c_" + secrets.token_hex(6),
            "quote_id": quote["quote_id"],
            "provider": quote["provider"],
            "product": quote["product"],
            "quoted_minor": quote["price"]["amount_minor"],
            "tip_ceiling_minor": quote["tip_ceiling"]["amount_minor"],
            "cap_minor": cap_minor,
            "currency": quote["price"]["currency"],
            "rationale": rationale,
            "status": "about_to_book",
            "booking_id": None,
            "paid_how": None,
            "written_at": stamp(),
        }
        self._records[record["record_id"]] = record
        self._save()
        return record

    def booked(self, record_id, booking):
        record = self._records[record_id]
        record.update(status="booked", booking_id=booking["booking_id"], booked_at=stamp(),
                      booked_minor=booking["price"]["amount_minor"],
                      paid_how=booking["confirmation"].get("paid_by", "not stated by the booking"))
        self._save()
        return record

    def not_booked(self, record_id, code):
        record = self._records[record_id]
        record.update(status="not_booked", not_booked_because=code, paid_how="nothing was paid")
        self._save()
        return record

    def _save(self):
        os.makedirs(os.path.dirname(self.record_path), exist_ok=True)
        with open(self.record_path, "w") as handle:
            json.dump(list(self._records.values()), handle, indent=2, sort_keys=True)
            handle.write("\n")
