"""the official-partner ride backend: a RideBackend over the Uber for Business and Lyft
Business adapters.

the contract's gateway (ride_connector.gateway.RideConnector) is the only thing an agent talks
to. it mints identifiers, ranks, flags, writes error messages, and validates every result, so
this backend's job is to speak the plain backend records honestly:

  quote    asks every carrier and turns each usable product into a BackendOption.
  book     refuses unless the money layer has already held the user's funds (sirven is
           merchant of record and never fronts a fare), then requests the trip on sirven's
           corporate account with that carrier.
  status   reads the carrier's trip and, once it is done, the fare and tip it charged.
  cancel   cancels with the carrier and reports the fee it charged.

carrier tokens, carrier identifiers, carrier product names, and carrier error text stay in
this module and in log lines for sirven's operators.
"""

import logging
import threading
from datetime import timedelta

from ride_connector.backend import (BackendBooking, BackendCancellation, BackendError, BackendOption,
                                    BackendQuote, BackendStatus, RideBackend)

from .transport import CarrierError, LiveCallsBlocked, PartnerApprovalRequired

log = logging.getLogger("sirven.ride_partner")

BLOCKED_SEAMS = (PartnerApprovalRequired, LiveCallsBlocked)


def _reason(error):
    """a carrier or seam failure, as a BackendError reason."""
    if isinstance(error, CarrierError):
        if error.status == 429:
            return "rate_limited"
        if error.status in (409, 410, 422):
            return "unavailable"
        if 400 <= error.status < 500 and error.status not in (401, 403):
            return "unavailable"
    # authentication failures, approval seams, and server errors are sirven's problem or the
    # carrier's outage, never the rider's: the agent hears "service unavailable".
    return "down"


def _detail(carrier, error):
    if isinstance(error, CarrierError):
        return "%s answered %s" % (carrier.name, error.status)
    return "%s: %s" % (carrier.name, error)


class PartnerRideBackend(RideBackend):
    """carriers: carrier adapters. clock: returns an aware datetime (the gateway's clock).
    rider: the rider's first_name, last_name, and phone_number, which the carrier needs to find
    them at the curb; the contract's backend calls carry no rider identity, so one backend
    serves one person. geocode: turns an address into {"latitude", "longitude"}, or None when
    no geocoder is configured, in which case address-only places cannot be quoted.
    require_payment_reference: refuse to book without funds held by the money layer."""

    def __init__(self, carriers, clock, rider, geocode=None, require_payment_reference=True):
        self.carriers = list(carriers)
        self.clock = clock
        self.rider = rider
        self.geocode = geocode
        self.require_payment_reference = require_payment_reference
        # in memory for now. a durable store is a seam: options and bookings must survive a
        # restart before anything books a real ride.
        self.options = {}
        self.bookings = {}
        self.serial = 0
        self.lock = threading.Lock()

    def _next(self, prefix):
        self.serial += 1
        return "%s-%d" % (prefix, self.serial)

    def _point(self, place):
        if "coordinates" in place:
            return {"latitude": place["coordinates"]["latitude"], "longitude": place["coordinates"]["longitude"]}
        if self.geocode is None:
            raise BackendError("no_service", "address-only place and no geocoder configured")
        return self.geocode(place["address"])

    # quote

    def quote(self, request):
        origin, destination = self._point(request.origin), self._point(request.destination)
        now = self.clock()
        found, failures = [], []
        for carrier in self.carriers:
            try:
                estimates = carrier.estimates(origin, destination, now)
            except (CarrierError,) + BLOCKED_SEAMS as error:
                log.warning("quote failed: %s", _detail(carrier, error))
                failures.append(error)
                continue
            for estimate in estimates:
                found.append(self._option(carrier, estimate, origin, destination, now))
        if failures and len(failures) == len(self.carriers):
            reasons = {_reason(error) for error in failures}
            raise BackendError("rate_limited" if reasons == {"rate_limited"} else "down", "no carrier answered")
        # a carrier that failed while another answered is invisible to the gateway: the
        # contract has no partial-results signal from a single backend. reported to thread 08.
        return BackendQuote(options=found)

    def _option(self, carrier, estimate, origin, destination, now):
        with self.lock:
            reference = self._next("option")
        pickup_at = (now + timedelta(seconds=estimate["pickup_seconds"])).replace(microsecond=0)
        option = BackendOption(
            reference=reference,
            provider=carrier.provider,
            vehicle_class=estimate["vehicle_class"],
            price_kind=estimate["price_kind"],
            fare_minor=estimate["fare_minor"],
            fare_maximum_minor=estimate["fare_maximum_minor"],
            currency=estimate["currency"],
            pickup_at=pickup_at,
            trip_minutes=max(1, int(round(estimate["trip_seconds"] / 60))),
            expires_at=estimate["expires_at"].replace(microsecond=0),
            cancellation_free_until=(now + timedelta(seconds=carrier.free_cancel_seconds)).replace(microsecond=0),
            cancellation_fee_minor=carrier.cancellation_fee_minor,
            surge=estimate["surge"],
            accessibility=estimate["accessibility"],
        )
        self.options[reference] = {
            "option": option, "carrier": carrier, "carrier_ref": estimate["carrier_ref"],
            "origin": origin, "destination": destination, "booking": None,
        }
        return option

    # book

    def book(self, option_reference, payment_reference, authorization_cap_minor):
        with self.lock:
            entry = self.options.get(option_reference)
            if entry is None:
                raise BackendError("unavailable", "unknown option reference")
            if entry["booking"] is not None:
                return self.bookings[entry["booking"]]["made"]
            if self.require_payment_reference and not payment_reference:
                raise BackendError("payment_declined", "no funds held by the money layer; sirven never fronts a fare")
            carrier, option = entry["carrier"], entry["option"]
            reference = self._next("booking")
            try:
                trip_ref = carrier.create_trip(entry["carrier_ref"], entry["origin"], entry["destination"],
                                               self.rider, "sirven " + reference)
            except (CarrierError,) + BLOCKED_SEAMS as error:
                raise BackendError(_reason(error), _detail(carrier, error)) from None
            made = BackendBooking(
                reference=reference,
                confirmed=True,
                pickup_at=option.pickup_at,
                dropoff_at=option.pickup_at + timedelta(minutes=option.trip_minutes),
            )
            self.bookings[reference] = {
                "carrier": carrier, "trip_ref": trip_ref, "made": made,
                "payment_reference": payment_reference, "authorization_cap_minor": authorization_cap_minor,
            }
            entry["booking"] = reference
            return made

    # status and cancel

    def _booking(self, reference):
        booking = self.bookings.get(reference)
        if booking is None:
            raise BackendError("unavailable", "unknown booking reference")
        return booking

    def status(self, booking_reference):
        booking = self._booking(booking_reference)
        carrier, made = booking["carrier"], booking["made"]
        try:
            state, vehicle, fare, tip = carrier.trip_status(booking["trip_ref"])
        except (CarrierError,) + BLOCKED_SEAMS as error:
            raise BackendError(_reason(error), _detail(carrier, error)) from None
        if state == "requested":
            state = "confirmed"  # an automated carrier has accepted the request once it exists.
        return BackendStatus(status=state, pickup_at=made.pickup_at, dropoff_at=made.dropoff_at,
                             vehicle_description=vehicle, fare_minor=fare, tip_minor=tip)

    def cancel(self, booking_reference, expected_fee_minor):
        booking = self._booking(booking_reference)
        carrier = booking["carrier"]
        try:
            fee = carrier.cancel_trip(booking["trip_ref"], expected_fee_minor)
        except CarrierError as error:
            if error.status in (409, 422):
                raise BackendError("not_cancellable", _detail(carrier, error)) from None
            raise BackendError(_reason(error), _detail(carrier, error)) from None
        except BLOCKED_SEAMS as error:
            raise BackendError("down", _detail(carrier, error)) from None
        return BackendCancellation(fee_minor=fee)
