"""the official-partner ride backend: the three contract calls over the carrier adapters.

quote_ride   asks every carrier, normalizes the answers, flags and ranks them, and keeps the
             carrier tokens private behind an opaque quote identifier.
book_ride    authorizes the user's payment to sirven first (sirven is merchant of record),
             then requests the trip on sirven's corporate account with the carrier. if the
             carrier fails, the authorization is released. booking twice is safe: the same
             quote always returns the same booking.
cancel_ride  cancels with the carrier and reconciles the user's authorization: release it
             when there is no fee, capture only the fee when there is one, and hold it when
             the carrier names the fee later on a receipt.

nothing a caller sees names this backend. errors are contract codes with fixed messages;
carrier tokens, carrier identifiers, carrier product names, and carrier hosts stay inside.
"""

import logging
import threading
import time

from . import contract
from .contract import RideConnectorError, money
from .transport import CarrierError, LiveCallsBlocked, PartnerApprovalRequired

log = logging.getLogger("sirven.ride_partner")

# every backend caps quote lifetime the same way, so a quote's lifetime says nothing about
# which backend made it.
QUOTE_LIFETIME_SECONDS = 120
UNREACHABLE = (CarrierError, PartnerApprovalRequired, LiveCallsBlocked, OSError, KeyError, TypeError, ValueError)


class PaymentDeclined(Exception):
    pass


class PartnerRideBackend:
    """carriers: carrier adapters. payments: the money layer (thread 11), with
    authorize(reference, amount_minor, currency) returning a handle, capture(handle,
    amount_minor), and release(handle). rider_contact: user_ref to the rider's first_name,
    last_name, and phone_number, which the carrier needs to find them at the curb.
    service_fee_minor: what sirven adds to the carrier fare; Jose's pricing decision, zero
    until he sets it."""

    def __init__(self, carriers, payments, rider_contact, clock=time.time, service_fee_minor=0):
        self.carriers = list(carriers)
        self.payments = payments
        self.rider_contact = rider_contact
        self.clock = clock
        self.service_fee_minor = service_fee_minor
        # in memory for now. a durable store is a seam: quotes and bookings must survive a
        # restart before anything books a real ride.
        self.quotes = {}
        self.bookings = {}
        self.lock = threading.Lock()

    def _now(self):
        return int(self.clock())

    # quote_ride

    def quote_ride(self, origin, destination, departure_window, user_preferences, budget_ceiling, user_ref):
        """user_ref comes from the runtime's session, never from the agent's arguments."""
        try:
            contract.validate_quote_request(origin, destination, departure_window, user_preferences, budget_ceiling)
        except ValueError:
            raise RideConnectorError("invalid_request") from None
        now = self._now()
        passengers = user_preferences.get("passengers", 1)
        wanted = set(user_preferences.get("vehicle_classes") or contract.VEHICLE_CLASSES)
        currency = budget_ceiling["currency"]
        tip_ceiling = user_preferences.get("tip_ceiling", money(0, currency))
        if tip_ceiling["currency"] != currency:
            raise RideConnectorError("invalid_request")

        candidates, reachable = [], 0
        for carrier in self.carriers:
            try:
                options = carrier.estimates(origin, destination, passengers, now)
            except UNREACHABLE as error:
                log.warning("%s estimates failed: %s", carrier.name, type(error).__name__)
                continue
            reachable += 1
            for option in options:
                if option["vehicle_class"] in wanted and option["currency"] == currency:
                    candidates.append((carrier, option))
        if not reachable:
            raise RideConnectorError("provider_unavailable")
        if not candidates:
            raise RideConnectorError("no_options")

        entries = []
        for carrier, option in candidates:
            price = option["price_minor"] + self.service_fee_minor
            pickup_at = now + option["pickup_seconds"]
            flags = []
            if price + tip_ceiling["amount_minor"] > budget_ceiling["amount_minor"]:
                flags.append("exceeds_budget")
            if not departure_window["earliest"] <= pickup_at <= departure_window["latest"]:
                flags.append("pickup_outside_window")
            if option["price_is_upper_bound"]:
                flags.append("price_is_upper_bound")
            if option["surge"]:
                flags.append("surge_pricing")
            entries.append({
                "carrier": carrier,
                "option": option,
                "price": price,
                "pickup_at": pickup_at,
                "arrival": pickup_at + option["trip_seconds"],
                "flags": flags,
            })

        optimize = user_preferences.get("optimize_for", "price")
        primary = {"price": "price", "pickup": "pickup_at", "arrival": "arrival"}[optimize]
        entries.sort(key=lambda entry: (
            any(flag in contract.BLOCKING_FLAGS for flag in entry["flags"]),
            entry[primary], entry["price"], entry["arrival"], entry["carrier"].provider,
        ))

        quotes = []
        for rank, entry in enumerate(entries, start=1):
            quote_id = contract.new_quote_id()
            expires_at = min(entry["option"]["expires_at"], now + QUOTE_LIFETIME_SECONDS)
            public = {
                "quote_id": quote_id,
                "rank": rank,
                "provider": entry["carrier"].provider,
                "vehicle_class": entry["option"]["vehicle_class"],
                "price": money(entry["price"], currency),
                "tip_ceiling": dict(tip_ceiling),
                "estimated_pickup_seconds": entry["option"]["pickup_seconds"],
                "estimated_trip_seconds": entry["option"]["trip_seconds"],
                "estimated_arrival": entry["arrival"],
                "expires_at": expires_at,
                "constraint_flags": entry["flags"],
            }
            self.quotes[quote_id] = {
                "public": public,
                "carrier": entry["carrier"],
                "carrier_ref": entry["option"]["carrier_ref"],
                "origin": origin,
                "destination": destination,
                "user_ref": user_ref,
                "booking_id": None,
            }
            quotes.append(dict(public, constraint_flags=list(entry["flags"])))
        response = {"contract_version": contract.CONTRACT_VERSION, "quotes": quotes}
        contract.validate_quote_response(response)
        return response

    # book_ride

    def book_ride(self, quote_id):
        with self.lock:
            quote = self.quotes.get(quote_id)
            if quote is None:
                raise RideConnectorError("quote_not_found")
            if quote["booking_id"] is not None:
                return self._booking_response(self.bookings[quote["booking_id"]])
            public = quote["public"]
            if any(flag in contract.BLOCKING_FLAGS for flag in public["constraint_flags"]):
                raise RideConnectorError("constraint_not_met")
            now = self._now()
            if now > public["expires_at"]:
                raise RideConnectorError("quote_expired")

            booking_id = contract.new_booking_id()
            currency = public["price"]["currency"]
            hold = public["price"]["amount_minor"] + public["tip_ceiling"]["amount_minor"]
            try:
                authorization = self.payments.authorize(booking_id, hold, currency)
            except PaymentDeclined:
                raise RideConnectorError("payment_declined") from None

            carrier = quote["carrier"]
            try:
                rider = self.rider_contact(quote["user_ref"])
                trip_ref = carrier.create_trip(quote["carrier_ref"], quote["origin"], quote["destination"],
                                               rider, "sirven " + booking_id)
            except UNREACHABLE as error:
                log.warning("%s create_trip failed: %s", carrier.name, type(error).__name__)
                self.payments.release(authorization)
                raise RideConnectorError("provider_unavailable") from None

            booking = {
                "booking_id": booking_id,
                "quote": quote,
                "carrier": carrier,
                "trip_ref": trip_ref,
                "authorization": authorization,
                "booked_at": now,
                "status": "requested",
                "settlement": None,
            }
            self.bookings[booking_id] = booking
            quote["booking_id"] = booking_id
            return self._booking_response(booking)

    def _booking_response(self, booking):
        public = booking["quote"]["public"]
        response = {
            "contract_version": contract.CONTRACT_VERSION,
            "booking_id": booking["booking_id"],
            "quote_id": public["quote_id"],
            "status": booking["status"],
            "provider": public["provider"],
            "price": dict(public["price"]),
            "tip_ceiling": dict(public["tip_ceiling"]),
            "tracking": {"status_path": "/rides/" + booking["booking_id"]},
            "cancellation_window": {"free_until": booking["booked_at"] + booking["carrier"].free_cancel_seconds},
        }
        contract.validate_booking_response(response)
        return response

    # cancel_ride

    def cancel_ride(self, booking_id):
        with self.lock:
            booking = self.bookings.get(booking_id)
            if booking is None:
                raise RideConnectorError("booking_not_found")
            if booking["status"] != "cancelled":
                carrier = booking["carrier"]
                try:
                    status, fee = carrier.cancel_trip(booking["trip_ref"], booking["booked_at"], self._now())
                except CarrierError as error:
                    if error.status in (409, 422):
                        raise RideConnectorError("not_cancellable") from None
                    log.warning("%s cancel_trip failed: %s", carrier.name, error.status)
                    raise RideConnectorError("provider_unavailable") from None
                except UNREACHABLE as error:
                    log.warning("%s cancel_trip failed: %s", carrier.name, type(error).__name__)
                    raise RideConnectorError("provider_unavailable") from None
                booking["status"] = "cancelled"
                self._reconcile(booking, status, fee)
            return self._cancel_response(booking)

    def _reconcile(self, booking, status, fee):
        if status == "settled" and fee:
            self.payments.capture(booking["authorization"], fee)
        elif status == "settled":
            self.payments.release(booking["authorization"])
        # pending_receipt keeps the authorization open until settle_receipt.
        booking["settlement"] = {"status": status, "fee": fee}

    def settle_receipt(self, booking_id, fee_minor):
        """the carrier's receipt named the cancellation fee. called by the receipt webhook
        handler, which is a seam: it waits on sandbox access to see real receipts."""
        with self.lock:
            booking = self.bookings[booking_id]
            if booking["settlement"] and booking["settlement"]["status"] == "pending_receipt":
                self._reconcile(booking, "settled", fee_minor)

    def _cancel_response(self, booking):
        settlement = booking["settlement"]
        currency = booking["quote"]["public"]["price"]["currency"]
        fee = None if settlement["fee"] is None else money(settlement["fee"], currency)
        response = {
            "contract_version": contract.CONTRACT_VERSION,
            "booking_id": booking["booking_id"],
            "status": "cancelled",
            "settlement": {"status": settlement["status"], "cancellation_fee": fee},
        }
        contract.validate_cancel_response(response)
        return response
