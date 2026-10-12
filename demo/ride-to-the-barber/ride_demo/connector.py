"""ride connector: a stand-in for thread 08's contract.

SUBSTITUTION. thread 08 (docs/ride-connector-contract.md and its machine-readable schemas)
had published nothing when this demo was built. this module implements the three-call shape
from the thread 08 instructions and nothing more:

  quote_ride(origin, destination, departure_window, user_preferences, budget_ceiling)
      ranked options with price, provider, estimated arrival, estimated trip time, and
      constraint flags.
  book_ride(quote_id)
      commits one option: booking identifier, tracking surface, cancellation window.
  cancel_ride(booking_id)
      cancels and reconciles.

when thread 08 lands, replace the field checks in validate_quote and validate_booking with
its schemas, and rename any field that differs. the demo reads only the fields listed in
QUOTE_FIELDS and BOOKING_FIELDS.

backend blindness: the router hands out opaque quote and booking identifiers and keeps the
backend behind each one in a private table. nothing returned to the agent names a backend;
the provider (Waymo, Uber, Lyft) is only ever an attribute value.
"""

import secrets
from datetime import datetime, timedelta

QUOTE_FIELDS = (
    "quote_id",
    "rank",
    "provider",
    "product",
    "price",
    "tip_ceiling",
    "estimated_pickup",
    "estimated_trip_minutes",
    "constraint_flags",
    "expires_at",
)
BOOKING_FIELDS = (
    "booking_id",
    "quote_id",
    "status",
    "provider",
    "price",
    "tip_ceiling",
    "tracking_url",
    "cancellation_window",
    "confirmation",
)


class ConnectorError(Exception):
    """an error from the error taxonomy: code is the stable part, message is for people."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def money(amount_minor, currency="USD"):
    return {"amount_minor": int(amount_minor), "currency": currency}


def dollars(value):
    return "$%d.%02d" % divmod(value["amount_minor"], 100)


def option_for(backend_reference, provider, product, price_minor, tip_ceiling_minor, pickup_minutes,
               trip_minutes, departure_window, user_preferences, quote_lifetime_minutes=5):
    """build one option the way every backend must: the same fields, whichever backend."""
    earliest = datetime.fromisoformat(departure_window["earliest"])
    pickup = earliest + timedelta(minutes=pickup_minutes)
    arrival = pickup + timedelta(minutes=trip_minutes)
    flags = []
    arrive_by = user_preferences.get("arrive_by")
    if arrive_by and arrival > datetime.fromisoformat(arrive_by):
        flags.append("arrives_late")
    if pickup > datetime.fromisoformat(departure_window["latest"]):
        flags.append("outside_departure_window")
    expires = datetime.now().astimezone() + timedelta(minutes=quote_lifetime_minutes)
    return {
        "backend_reference": backend_reference,
        "provider": provider,
        "product": product,
        "price": money(price_minor),
        "tip_ceiling": money(tip_ceiling_minor),
        "estimated_pickup": pickup.isoformat(),
        "estimated_trip_minutes": trip_minutes,
        "constraint_flags": flags,
        "expires_at": expires.isoformat(timespec="seconds"),
    }


def validate_quote(quote):
    missing = [field for field in QUOTE_FIELDS if field not in quote]
    if missing:
        raise ConnectorError("invalid_quote", "quote is missing %s" % ", ".join(missing))
    return quote


def validate_booking(booking):
    missing = [field for field in BOOKING_FIELDS if field not in booking]
    if missing:
        raise ConnectorError("invalid_booking", "booking is missing %s" % ", ".join(missing))
    return booking


def rank_options(options, user_preferences, budget_ceiling):
    """order options the way the contract stand-in promises: options that break no hard
    constraint first, then preferred providers, then price. ranks start at 1."""
    preferred = [name.lower() for name in user_preferences.get("preferred_providers", [])]

    def hard_flags(option):
        return [flag for flag in option["constraint_flags"] if flag in ("over_budget", "arrives_late")]

    def key(option):
        provider = option["provider"].lower()
        preference = preferred.index(provider) if provider in preferred else len(preferred)
        return (len(hard_flags(option)) > 0, preference, option["price"]["amount_minor"])

    for option in options:
        total = option["price"]["amount_minor"] + option["tip_ceiling"]["amount_minor"]
        if total > budget_ceiling["amount_minor"] and "over_budget" not in option["constraint_flags"]:
            option["constraint_flags"].append("over_budget")
        if option["provider"].lower() in preferred and "preferred_provider" not in option["constraint_flags"]:
            option["constraint_flags"].append("preferred_provider")
    ordered = sorted(options, key=key)
    for rank, option in enumerate(ordered, start=1):
        option["rank"] = rank
    return ordered


class Router:
    """the connector surface the agent calls. backends implement quote, book, and cancel
    with the same arguments; the router merges, ranks, and hides which backend answered."""

    def __init__(self, backends):
        self._backends = backends
        self._quote_owner = {}
        self._booking_owner = {}
        self._bookings_by_key = {}

    def quote_ride(self, origin, destination, departure_window, user_preferences, budget_ceiling):
        options = []
        unavailable = []
        for backend in self._backends:
            result = backend.quote(origin, destination, departure_window, user_preferences, budget_ceiling)
            unavailable.extend(result.get("unavailable", []))
            for option in result.get("options", []):
                quote_id = "q_" + secrets.token_hex(6)
                self._quote_owner[quote_id] = (backend, option["backend_reference"])
                public = {key: value for key, value in option.items() if key != "backend_reference"}
                public["quote_id"] = quote_id
                public.setdefault("rank", 0)
                options.append(public)
        ranked = rank_options(options, user_preferences, budget_ceiling)
        return {"options": [validate_quote(option) for option in ranked], "unavailable": unavailable}

    def book_ride(self, quote_id, idempotency_key):
        if idempotency_key in self._bookings_by_key:
            return self._bookings_by_key[idempotency_key]
        if quote_id not in self._quote_owner:
            raise ConnectorError("unknown_quote", "no quote %s" % quote_id)
        backend, reference = self._quote_owner[quote_id]
        booking = backend.book(reference, quote_id)
        booking_id = "b_" + secrets.token_hex(6)
        self._booking_owner[booking_id] = (backend, booking.pop("backend_reference"))
        booking["booking_id"] = booking_id
        booking["quote_id"] = quote_id
        booking = validate_booking(booking)
        self._bookings_by_key[idempotency_key] = booking
        return booking

    def cancel_ride(self, booking_id):
        if booking_id not in self._booking_owner:
            raise ConnectorError("unknown_booking", "no booking %s" % booking_id)
        backend, reference = self._booking_owner[booking_id]
        return backend.cancel(reference)
