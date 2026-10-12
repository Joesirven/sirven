"""a fake ride backend and a controllable clock, for tests, examples, and rehearsals.

no network, no money. prices come from straight-line distance (or, without coordinates, from a
stable hash of the two addresses), so the same request always gets the same prices.

FakeRideBackend can act as an automated partner or as a human concierge desk. in concierge mode a
booking stays requested until someone calls confirm() or decline(), which is the seam a rehearsal
console drives.
"""

import hashlib
import math
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import FrozenSet, Optional

from .backend import (BackendBooking, BackendCancellation, BackendError, BackendOption,
                      BackendQuote, BackendStatus, RideBackend)
from .gateway import RideConnector


class FakeClock:
    def __init__(self, start=None):
        self.moment = start or datetime(2026, 10, 12, 13, 0, tzinfo=timezone(timedelta(hours=-7)))

    def __call__(self):
        return self.moment

    def advance(self, minutes=0, seconds=0):
        self.moment += timedelta(minutes=minutes, seconds=seconds)
        return self.moment


@dataclass(frozen=True)
class FakeProduct:
    provider: str
    vehicle_class: str
    base_minor: int
    per_km_minor: int
    price_kind: str = "fixed"
    estimate_spread_percent: int = 25
    pickup_minutes: int = 6
    tips_accepted: bool = True
    surge: bool = False
    accessibility: FrozenSet[str] = frozenset()
    cancellation_fee_minor: int = 500
    currency: str = "USD"


def _distance_km(origin, destination):
    a, b = origin.get("coordinates"), destination.get("coordinates")
    if a and b:
        lat1, lon1, lat2, lon2 = map(math.radians, (a["latitude"], a["longitude"], b["latitude"], b["longitude"]))
        h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
        return max(0.5, 2 * 6371 * math.asin(math.sqrt(h)))
    text = (origin.get("address", "") + "|" + destination.get("address", "")).encode("utf-8")
    return 2 + int(hashlib.sha256(text).hexdigest()[:4], 16) % 1500 / 100.0


@dataclass
class _Booking:
    option: BackendOption
    confirmed: bool
    pickup_at: datetime
    dropoff_at: datetime
    confirm_by: Optional[datetime]
    vehicle_description: Optional[str]
    cancelled: bool = False
    declined: bool = False
    payment_reference: Optional[str] = None
    authorization_cap_minor: int = 0


@dataclass
class FakeRideBackend(RideBackend):
    products: list
    clock: FakeClock
    human_assisted: bool = False
    confirm_within_minutes: int = 15
    quote_lifetime_minutes: int = 10
    free_cancellation_minutes: int = 2
    refuse: Optional[str] = None  # a BackendError reason every quote raises, for refusal tests.
    fail_next_book: Optional[str] = None  # a BackendError reason the next book raises, once.
    final_fare_delta_percent: int = 0  # how far an estimate's final fare lands from the quote.
    tip_percent: int = 15  # what the rider tips on completion, when tips are accepted.
    serial: int = 0
    options: dict = field(default_factory=dict)
    bookings: dict = field(default_factory=dict)

    def _next(self, prefix):
        self.serial += 1
        return "%s-%d" % (prefix, self.serial)

    def quote(self, request):
        if self.refuse:
            raise BackendError(self.refuse, "fake refusal", retry_after_seconds=30 if self.refuse == "rate_limited" else None)
        now = self.clock()
        km = _distance_km(request.origin, request.destination)
        found = []
        for product in self.products:
            if product.currency != request.currency:
                continue
            fare = product.base_minor + int(round(product.per_km_minor * km))
            maximum = fare if product.price_kind == "fixed" else fare + fare * product.estimate_spread_percent // 100
            pickup = max(request.pickup_not_before, now + timedelta(minutes=product.pickup_minutes))
            reference = self._next("option")
            option = BackendOption(
                reference=reference,
                provider=product.provider,
                vehicle_class=product.vehicle_class,
                price_kind=product.price_kind,
                fare_minor=fare,
                fare_maximum_minor=maximum,
                currency=product.currency,
                pickup_at=pickup.replace(microsecond=0),
                trip_minutes=max(3, int(round(km * 2.4))),
                expires_at=(now + timedelta(minutes=self.quote_lifetime_minutes)).replace(microsecond=0),
                cancellation_free_until=(now + timedelta(minutes=self.free_cancellation_minutes)).replace(microsecond=0)
                if pickup - now < timedelta(minutes=30)
                else (pickup - timedelta(minutes=30)).replace(microsecond=0),
                cancellation_fee_minor=product.cancellation_fee_minor,
                tips_accepted=product.tips_accepted,
                surge=product.surge,
                accessibility=product.accessibility,
                human_assisted=self.human_assisted,
            )
            self.options[reference] = option
            found.append(option)
        return BackendQuote(options=found)

    def book(self, option_reference, payment_reference, authorization_cap_minor):
        if self.fail_next_book:
            reason, self.fail_next_book = self.fail_next_book, None
            raise BackendError(reason, "fake booking failure")
        option = self.options[option_reference]
        now = self.clock()
        reference = self._next("booking")
        dropoff = option.pickup_at + timedelta(minutes=option.trip_minutes)
        self.bookings[reference] = _Booking(
            option=option,
            confirmed=not self.human_assisted,
            pickup_at=option.pickup_at,
            dropoff_at=dropoff,
            confirm_by=(now + timedelta(minutes=self.confirm_within_minutes)).replace(microsecond=0) if self.human_assisted else None,
            vehicle_description=None if self.human_assisted else "Gray sedan, plate 7ABC123",
            payment_reference=payment_reference,
            authorization_cap_minor=authorization_cap_minor,
        )
        return BackendBooking(
            reference=reference,
            confirmed=not self.human_assisted,
            pickup_at=option.pickup_at,
            dropoff_at=dropoff,
            confirm_by=self.bookings[reference].confirm_by,
            vehicle_description=self.bookings[reference].vehicle_description,
        )

    # the concierge seam: a person confirms or declines a requested booking.

    def pending(self):
        return sorted(reference for reference, booking in self.bookings.items()
                      if not booking.confirmed and not booking.cancelled and not booking.declined)

    def confirm(self, reference, vehicle_description="White electric vehicle, no driver"):
        booking = self.bookings[reference]
        booking.confirmed = True
        booking.vehicle_description = vehicle_description

    def decline(self, reference):
        self.bookings[reference].declined = True

    def status(self, booking_reference):
        booking = self.bookings[booking_reference]
        now = self.clock()
        fare = tip = None
        if booking.cancelled:
            state = "cancelled"
        elif booking.declined or (not booking.confirmed and booking.confirm_by and now > booking.confirm_by):
            state = "failed"
        elif not booking.confirmed:
            state = "requested"
        elif now >= booking.dropoff_at:
            state = "completed"
            option = booking.option
            fare = option.fare_minor
            if option.price_kind == "estimate":
                fare = option.fare_minor + option.fare_minor * self.final_fare_delta_percent // 100
            tip = fare * self.tip_percent // 100 if option.tips_accepted else 0
        elif now >= booking.pickup_at:
            state = "in_progress"
        elif now >= booking.pickup_at - timedelta(minutes=5):
            state = "driver_assigned"
        else:
            state = "confirmed"
        return BackendStatus(status=state, pickup_at=booking.pickup_at, dropoff_at=booking.dropoff_at,
                             vehicle_description=booking.vehicle_description, fare_minor=fare, tip_minor=tip)

    def cancel(self, booking_reference, expected_fee_minor):
        booking = self.bookings[booking_reference]
        if self.clock() >= booking.pickup_at and booking.confirmed:
            raise BackendError("not_cancellable", "trip already started")
        booking.cancelled = True
        return BackendCancellation(fee_minor=expected_fee_minor)


def demo_backends(clock):
    """two fake backends: an automated partner with two providers and a concierge desk with one."""
    partner = FakeRideBackend(
        clock=clock,
        products=[
            FakeProduct("Uber", "standard", base_minor=350, per_km_minor=140, price_kind="estimate"),
            FakeProduct("Uber", "comfort", base_minor=500, per_km_minor=190, price_kind="estimate"),
            FakeProduct("Lyft", "standard", base_minor=300, per_km_minor=145),
            FakeProduct("Lyft", "accessible", base_minor=300, per_km_minor=145, pickup_minutes=14,
                        accessibility=frozenset({"wheelchair_accessible", "service_animal", "assistance_boarding"})),
        ],
    )
    concierge = FakeRideBackend(
        clock=clock,
        human_assisted=True,
        products=[FakeProduct("Waymo", "autonomous", base_minor=400, per_km_minor=150, pickup_minutes=9,
                              tips_accepted=False, cancellation_fee_minor=300)],
    )
    return {"partner": partner, "concierge": concierge}


def demo_connector(clock=None, **options):
    """a gateway over demo_backends, with human-assisted options on for rehearsal.

    returns (connector, clock, backends).
    """
    clock = clock or FakeClock()
    options.setdefault("allow_human_assisted", True)
    backends = demo_backends(clock)
    return RideConnector(backends, clock=clock, **options), clock, backends
