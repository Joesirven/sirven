"""what a ride backend implements so the gateway can serve it through the contract.

a backend is any route to a ride: a partner integration, a human concierge desk, a test fake.
backends speak these plain records to the gateway and never to the agent. the gateway mints the
identifiers, writes the messages, ranks the options, and projects every result onto the contract
schema, so nothing a backend returns can tell the agent which backend it was.
"""

from dataclasses import dataclass, field
from datetime import datetime
from typing import FrozenSet, List, Optional


@dataclass(frozen=True)
class QuoteRequest:
    """what a backend sees of a quote_ride call. preferences stay with the gateway."""

    origin: dict
    destination: dict
    pickup_not_before: datetime
    pickup_not_after: datetime
    currency: str
    vehicle_classes: FrozenSet[str]
    accessibility_needs: FrozenSet[str]


@dataclass(frozen=True)
class BackendOption:
    reference: str  # the backend's own handle for this option. never shown to the agent.
    provider: str  # display name of the ride service, for example the brand on the car.
    vehicle_class: str
    price_kind: str  # "fixed" or "estimate"
    fare_minor: int
    fare_maximum_minor: int
    currency: str
    pickup_at: datetime
    trip_minutes: int
    expires_at: datetime
    cancellation_free_until: datetime
    cancellation_fee_minor: int
    tips_accepted: bool = True
    surge: bool = False
    accessibility: FrozenSet[str] = frozenset()
    human_assisted: bool = False


@dataclass(frozen=True)
class BackendQuote:
    options: List[BackendOption] = field(default_factory=list)


@dataclass(frozen=True)
class BackendBooking:
    reference: str
    confirmed: bool  # False while a person still has to confirm it (human_assisted).
    pickup_at: datetime
    dropoff_at: datetime
    confirm_by: Optional[datetime] = None
    vehicle_description: Optional[str] = None


@dataclass(frozen=True)
class BackendStatus:
    status: str  # one of the contract's booking_status values.
    pickup_at: datetime
    dropoff_at: datetime
    vehicle_description: Optional[str] = None
    fare_minor: Optional[int] = None  # set once completed.
    tip_minor: Optional[int] = None  # set once completed.


@dataclass(frozen=True)
class BackendCancellation:
    fee_minor: int


class BackendError(Exception):
    """a backend failure, in backend terms. the gateway maps it onto the contract's error codes.

    reason is one of: blocked, no_service, unavailable, price_changed, payment_declined,
    not_cancellable, rate_limited, down. detail is for sirven's own logs and never reaches
    the agent.
    """

    REASONS = (
        "blocked", "no_service", "unavailable", "price_changed", "payment_declined",
        "not_cancellable", "rate_limited", "down",
    )

    def __init__(self, reason, detail="", retry_after_seconds=None):
        if reason not in self.REASONS:
            raise ValueError("unknown backend error reason %r" % reason)
        super().__init__("%s: %s" % (reason, detail))
        self.reason = reason
        self.detail = detail
        self.retry_after_seconds = retry_after_seconds


class RideBackend:
    """the four operations a backend implements. every method may raise BackendError."""

    def quote(self, request: QuoteRequest) -> BackendQuote:
        raise NotImplementedError

    def book(self, option_reference: str, payment_reference: Optional[str], authorization_cap_minor: int) -> BackendBooking:
        raise NotImplementedError

    def cancel(self, booking_reference: str, expected_fee_minor: int) -> BackendCancellation:
        raise NotImplementedError

    def status(self, booking_reference: str) -> BackendStatus:
        raise NotImplementedError
