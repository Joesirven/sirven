"""the ride connector gateway: the only thing an agent talks to.

the gateway owns everything the agent can observe, which is how backend identity stays
invisible by construction:

  - identifiers are random tokens the gateway mints; a backend's own references stay inside.
  - ranking happens here, across all backends at once, with ties broken by the random quote_id.
  - every result is rebuilt field by field from backend records and validated against the
    strict contract schema; a field the contract does not name cannot get through.
  - error messages come from the table below; a backend's own text only reaches sirven's logs.
"""

import base64
import copy
import re
import secrets
import threading
from datetime import datetime, timedelta, timezone

from .backend import BackendError, QuoteRequest
from .schema import Validator, parse_timestamp

BLOCKING_FLAGS = ("over_budget", "outside_departure_window", "accessibility_not_met")

# code: (retryable, message). messages are plain sentences for a person.
ERRORS = {
    "invalid_argument": (False, "The request is missing something or has a value the contract does not allow."),
    "unsupported_contract_version": (False, "This connector does not speak that contract version."),
    "quote_not_found": (False, "That quote does not exist. Ask for new quotes."),
    "quote_expired": (False, "That quote has expired. Ask for new quotes."),
    "over_budget": (False, "That option costs more than the budget allows."),
    "option_not_bookable": (False, "That option does not meet the request, so it cannot be booked."),
    "option_unavailable": (False, "That ride is no longer available. Ask for new quotes."),
    "price_changed": (False, "The price went up after the quote. Ask for new quotes."),
    "idempotency_conflict": (False, "That quote was already booked with different payment details."),
    "payment_required": (False, "Booking needs funds held by the sirven money layer first."),
    "payment_declined": (False, "The held funds were declined for this ride."),
    "booking_not_found": (False, "That booking does not exist."),
    "not_cancellable": (False, "The trip has already started or ended, so it cannot be cancelled."),
    "no_service": (False, "No rides are offered between those places at that time."),
    "blocked": (False, "The ride services for this trip refused access to agents. Nothing was routed around that refusal."),
    "rate_limited": (True, "Too many requests just now. Try again shortly."),
    "service_unavailable": (True, "Rides cannot be reached right now. Try again shortly."),
    "internal_error": (True, "Something went wrong inside the connector. Try again shortly."),
}

NOTICES = {
    "blocked": "Some ride services refused access to agents, so their rides are not listed. Nothing was routed around that refusal.",
    "no_service": "Some ride services do not serve this trip.",
    "partial_results": "Some ride services could not be reached, so the list may be incomplete.",
}

CONCIERGE_DISCLOSURE = (
    "A person on the sirven concierge team books this ride for you using the details shown "
    "here. They see the pickup, drop-off, and time, and nothing else."
)

BACKEND_TO_CONTRACT = {
    "unavailable": "option_unavailable",
    "price_changed": "price_changed",
    "payment_declined": "payment_declined",
    "not_cancellable": "not_cancellable",
    "blocked": "blocked",
    "no_service": "no_service",
    "rate_limited": "rate_limited",
    "down": "service_unavailable",
}


class ConnectorError(Exception):
    def __init__(self, code, field=None, retry_after_seconds=None, booking=None):
        super().__init__(code)
        self.code = code
        self.field = field
        self.retry_after_seconds = retry_after_seconds
        self.booking = booking


def system_clock():
    return datetime.now(timezone.utc)


def random_token(prefix):
    return prefix + "_" + base64.b32encode(secrets.token_bytes(20)).decode("ascii").lower()[:26]


def _iso(moment):
    return moment.isoformat(timespec="seconds")


def _money(amount, currency):
    return {"amount_minor": int(amount), "currency": currency}


def _minutes(delta):
    return max(0, int(round(delta.total_seconds() / 60)))


class RideConnector:
    """serves the contract over any number of backends.

    backends: a mapping of private name to RideBackend. names never leave the gateway.
    clock: returns an aware datetime; tests pass a controllable one.
    token: mints identifiers; tests may pass a seeded one, production keeps random_token.
    require_payment_reference: production sets this so book_ride needs funds held first.
    share_url_base: a sirven-hosted relay for live tracking pages, or None.
    """

    def __init__(self, backends, clock=system_clock, token=random_token,
                 require_payment_reference=False, share_url_base=None, poll_interval_seconds=30,
                 validator=None):
        self.backends = dict(backends)
        self.clock = clock
        self.token = token
        self.require_payment_reference = require_payment_reference
        self.share_url_base = share_url_base
        self.poll_interval_seconds = poll_interval_seconds
        self.validator = validator or Validator()
        self.version = self.validator.schema["x-contract-version"]
        self.private_log = []  # backend detail for sirven's operators; never returned.
        self._quotes = {}
        self._bookings = {}
        self._lock = threading.Lock()

    # the tool surface ---------------------------------------------------------------------

    def call(self, tool, arguments):
        """run one tool. returns (is_error, payload); payload always validates."""
        handlers = {
            "quote_ride": self._quote_ride,
            "book_ride": self._book_ride,
            "cancel_ride": self._cancel_ride,
            "get_ride": self._get_ride,
        }
        try:
            if tool not in handlers:
                raise ConnectorError("invalid_argument", field="/")
            with self._lock:
                self._check_input(tool, arguments)
                payload = handlers[tool](arguments)
            payload = copy.deepcopy({"contract_version": self.version, **payload})
            problems = self.validator.validate(payload, tool + "_output")
            if problems:
                self._log("output failed the contract", tool=tool, problems=problems)
                raise ConnectorError("internal_error")
            return False, payload
        except ConnectorError as error:
            return True, self._error_payload(error)
        except Exception as error:  # a bug must not leak backend detail either.
            self._log("unexpected failure", tool=tool, detail=repr(error))
            return True, self._error_payload(ConnectorError("internal_error"))

    def quote_ride(self, **arguments):
        return self.call("quote_ride", arguments)

    def book_ride(self, **arguments):
        return self.call("book_ride", arguments)

    def cancel_ride(self, **arguments):
        return self.call("cancel_ride", arguments)

    def get_ride(self, **arguments):
        return self.call("get_ride", arguments)

    # checks -------------------------------------------------------------------------------

    def _check_input(self, tool, arguments):
        if not isinstance(arguments, dict):
            raise ConnectorError("invalid_argument", field="/")
        problems = self.validator.validate(arguments, tool + "_input")
        if problems:
            raise ConnectorError("invalid_argument", field=problems[0][0])
        reference = arguments.get("payment_reference") if tool == "book_ride" else None
        if reference is not None and re.search(r"[0-9]{12,}", reference.replace("-", "").replace("_", "")):
            # a long run of digits looks like a card number. card details never enter the contract.
            raise ConnectorError("invalid_argument", field="/payment_reference")
        requested = arguments.get("contract_version")
        if requested is not None and requested.split(".")[0] != self.version.split(".")[0]:
            raise ConnectorError("unsupported_contract_version", field="/contract_version")

    def _error_payload(self, error):
        retryable, message = ERRORS[error.code]
        body = {
            "code": error.code,
            "message": message,
            "retryable": retryable,
            "retry_after_seconds": error.retry_after_seconds,
            "field": error.field,
        }
        if error.booking is not None:
            body["booking"] = copy.deepcopy(error.booking)
        return {"contract_version": self.version, "error": body}

    def _log(self, event, **detail):
        self.private_log.append({"at": _iso(self.clock()), "event": event, **detail})

    # quote_ride ---------------------------------------------------------------------------

    def _quote_ride(self, arguments):
        now = self.clock()
        window = arguments["departure_window"]
        earliest = parse_timestamp(window["earliest"])
        latest = parse_timestamp(window["latest"])
        if latest < earliest:
            raise ConnectorError("invalid_argument", field="/departure_window/latest")
        if latest < now:
            raise ConnectorError("invalid_argument", field="/departure_window/latest")
        start = max(earliest, now)
        preferences = arguments.get("user_preferences", {})
        budget = arguments["budget_ceiling"]
        request = QuoteRequest(
            origin=arguments["origin"],
            destination=arguments["destination"],
            pickup_not_before=start,
            pickup_not_after=latest,
            currency=budget["currency"],
            vehicle_classes=frozenset(preferences.get("vehicle_classes", [])),
            accessibility_needs=frozenset(preferences.get("accessibility_needs", [])),
        )

        gathered, refusals = [], []
        for name, backend in sorted(self.backends.items()):
            try:
                result = backend.quote(request)
            except BackendError as error:
                self._log("quote refused", backend=name, reason=error.reason, detail=error.detail)
                refusals.append(error)
                continue
            except Exception as error:  # one broken backend must not sink the others.
                self._log("quote failed", backend=name, detail=repr(error))
                refusals.append(BackendError("down", repr(error)))
                continue
            for option in result.options:
                gathered.append((name, option))

        avoided = {provider.casefold() for provider in preferences.get("avoided_providers", [])}
        notices = set()
        built = []
        for name, option in gathered:
            if option.provider.casefold() in avoided:
                continue
            if option.currency != budget["currency"] or option.expires_at <= now:
                self._log("option dropped", backend=name, currency=option.currency)
                notices.add("partial_results")
                continue
            built.append((name, option, self._describe(option, start, latest, preferences, budget, now)))

        for error in refusals:
            notices.add({"blocked": "blocked", "no_service": "no_service"}.get(error.reason, "partial_results"))

        if not built:
            if not gathered and refusals:
                reasons = [error.reason for error in refusals]
                code = "blocked" if "blocked" in reasons else "no_service" if "no_service" in reasons else None
                if code is None:
                    limited = [error for error in refusals if error.reason == "rate_limited"]
                    if limited and len(limited) == len(refusals):
                        raise ConnectorError("rate_limited", retry_after_seconds=max(e.retry_after_seconds or 0 for e in limited))
                    code = "service_unavailable"
                raise ConnectorError(code)
            if not gathered:
                raise ConnectorError("no_service")

        ranked = self._rank(built, preferences)
        options = []
        for rank, (name, option, public) in enumerate(ranked, start=1):
            quote_id = self.token("qt")
            public = {"quote_id": quote_id, "rank": rank, **public}
            self._quotes[quote_id] = {
                "backend": name,
                "option": option,
                "public": public,
                "origin": arguments["origin"],
                "destination": arguments["destination"],
                "booking_id": None,
                "payment_reference": None,
            }
            options.append(public)

        return {
            "options": options,
            "notices": [{"code": code, "message": NOTICES[code]} for code in sorted(notices)],
            "quoted_at": _iso(now),
        }

    def _describe(self, option, start, latest, preferences, budget, now):
        currency = option.currency
        percent = preferences.get("tip_ceiling_percent", 20)
        tip_ceiling = (option.fare_maximum_minor * percent + 50) // 100 if option.tips_accepted else 0
        cap = option.fare_maximum_minor + tip_ceiling
        dropoff = option.pickup_at + timedelta(minutes=option.trip_minutes)
        wait = _minutes(option.pickup_at - start)

        flags = []
        if cap > budget["amount_minor"]:
            flags.append("over_budget")
        if option.pickup_at < start - timedelta(minutes=1) or option.pickup_at > latest:
            flags.append("outside_departure_window")
        if not set(preferences.get("accessibility_needs", [])) <= set(option.accessibility):
            flags.append("accessibility_not_met")
        preferred = {provider.casefold() for provider in preferences.get("preferred_providers", [])}
        if preferred and option.provider.casefold() not in preferred:
            flags.append("provider_not_preferred")
        classes = preferences.get("vehicle_classes", [])
        if classes and option.vehicle_class not in classes:
            flags.append("vehicle_class_not_requested")
        if "max_pickup_wait_minutes" in preferences and wait > preferences["max_pickup_wait_minutes"]:
            flags.append("long_pickup_wait")
        if option.price_kind == "estimate":
            flags.append("price_is_estimate")
        if option.surge:
            flags.append("surge_pricing")
        if option.vehicle_class == "shared":
            flags.append("shared_ride")
        if option.human_assisted:
            flags.append("human_assisted")

        return {
            "bookable": not any(flag in BLOCKING_FLAGS for flag in flags),
            "provider": option.provider,
            "vehicle_class": option.vehicle_class,
            "price": {
                "kind": option.price_kind,
                "amount": _money(option.fare_minor, currency),
                "maximum": _money(option.fare_maximum_minor, currency),
            },
            "charge_terms": {
                "quoted_amount": _money(option.fare_minor, currency),
                "fare_ceiling": _money(option.fare_maximum_minor, currency),
                "tip_ceiling": _money(tip_ceiling, currency),
                "authorization_cap": _money(cap, currency),
                "currency": currency,
            },
            "estimated_pickup_at": _iso(option.pickup_at),
            "estimated_dropoff_at": _iso(dropoff),
            "estimated_pickup_wait_minutes": wait,
            "estimated_trip_minutes": option.trip_minutes,
            "constraint_flags": flags,
            "fulfillment": self._fulfillment(option.human_assisted),
            "cancellation_policy": {
                "free_until": _iso(option.cancellation_free_until),
                "fee_after_free_period": _money(option.cancellation_fee_minor, currency),
            },
            "expires_at": _iso(option.expires_at),
        }

    @staticmethod
    def _fulfillment(human_assisted):
        if human_assisted:
            return {"method": "human_assisted", "disclosure": CONCIERGE_DISCLOSURE}
        return {"method": "automated", "disclosure": None}

    @staticmethod
    def _rank(built, preferences):
        ranking = preferences.get("ranking", "balanced")
        preferred = [provider.casefold() for provider in preferences.get("preferred_providers", [])]

        def key(entry):
            _, option, public = entry
            cap = public["charge_terms"]["authorization_cap"]["amount_minor"]
            dropoff = option.pickup_at + timedelta(minutes=option.trip_minutes)
            bookable = 0 if public["bookable"] else 1
            if ranking == "cheapest":
                order = (cap, dropoff)
            elif ranking == "fastest":
                order = (dropoff, cap)
            else:
                name = option.provider.casefold()
                order = (preferred.index(name) if name in preferred else len(preferred), cap, dropoff)
            return (bookable,) + order

        # the sort is stable, so shuffle first: equal options must not come out grouped by backend.
        shuffled = sorted(built, key=lambda entry: secrets.randbits(32))
        return sorted(shuffled, key=key)

    # book_ride ----------------------------------------------------------------------------

    def _book_ride(self, arguments):
        quote = self._quotes.get(arguments["quote_id"])
        if quote is None:
            raise ConnectorError("quote_not_found", field="/quote_id")
        reference = arguments.get("payment_reference")

        if quote["booking_id"] is not None:
            if reference != quote["payment_reference"]:
                raise ConnectorError("idempotency_conflict", field="/payment_reference")
            return {"booking": self._bookings[quote["booking_id"]]["public"], "replayed": True}

        public = quote["public"]
        now = self.clock()
        if parse_timestamp(public["expires_at"]) <= now:
            raise ConnectorError("quote_expired", field="/quote_id")
        if "over_budget" in public["constraint_flags"]:
            raise ConnectorError("over_budget", field="/quote_id")
        if not public["bookable"]:
            raise ConnectorError("option_not_bookable", field="/quote_id")
        if self.require_payment_reference and reference is None:
            raise ConnectorError("payment_required", field="/payment_reference")

        backend = self.backends[quote["backend"]]
        cap = public["charge_terms"]["authorization_cap"]["amount_minor"]
        try:
            made = backend.book(quote["option"].reference, reference, cap)
        except BackendError as error:
            self._log("book refused", backend=quote["backend"], reason=error.reason, detail=error.detail)
            raise ConnectorError(BACKEND_TO_CONTRACT[error.reason], retry_after_seconds=error.retry_after_seconds)

        booking_id = self.token("bk")
        record = {
            "backend": quote["backend"],
            "reference": made.reference,
            "public": {
                "booking_id": booking_id,
                "quote_id": arguments["quote_id"],
                "status": "confirmed" if made.confirmed else "requested",
                "provider": public["provider"],
                "vehicle_class": public["vehicle_class"],
                "origin": quote["origin"],
                "destination": quote["destination"],
                "price": public["price"],
                "charge_terms": public["charge_terms"],
                "fulfillment": public["fulfillment"],
                "estimated_pickup_at": _iso(made.pickup_at),
                "estimated_dropoff_at": _iso(made.dropoff_at),
                "confirm_by": None if made.confirmed or made.confirm_by is None else _iso(made.confirm_by),
                "cancellation_policy": public["cancellation_policy"],
                "tracking": self._tracking(booking_id, made.vehicle_description),
                "final_charge": None,
                "created_at": _iso(now),
                "updated_at": _iso(now),
            },
        }
        self._bookings[booking_id] = record
        quote["booking_id"] = booking_id
        quote["payment_reference"] = reference
        return {"booking": record["public"], "replayed": False}

    def _tracking(self, booking_id, vehicle_description):
        share_url = None
        if self.share_url_base:
            share_url = self.share_url_base.rstrip("/") + "/" + booking_id
        return {
            "status_call": "get_ride",
            "poll_interval_seconds": self.poll_interval_seconds,
            "share_url": share_url,
            "vehicle_description": vehicle_description,
        }

    # get_ride and cancel_ride -------------------------------------------------------------

    def _booking(self, booking_id):
        record = self._bookings.get(booking_id)
        if record is None:
            raise ConnectorError("booking_not_found", field="/booking_id")
        return record

    def _refresh(self, record):
        public = record["public"]
        if public["status"] in ("completed", "cancelled", "failed"):
            return
        try:
            state = self.backends[record["backend"]].status(record["reference"])
        except BackendError as error:
            self._log("status refused", backend=record["backend"], reason=error.reason, detail=error.detail)
            raise ConnectorError(BACKEND_TO_CONTRACT.get(error.reason, "service_unavailable"),
                                 retry_after_seconds=error.retry_after_seconds)
        public["status"] = state.status
        public["estimated_pickup_at"] = _iso(state.pickup_at)
        public["estimated_dropoff_at"] = _iso(state.dropoff_at)
        if state.status != "requested":
            public["confirm_by"] = None
        if state.vehicle_description is not None:
            public["tracking"]["vehicle_description"] = state.vehicle_description
        if state.status == "completed":
            terms = public["charge_terms"]
            fare = min(state.fare_minor or 0, terms["fare_ceiling"]["amount_minor"])
            tip = min(state.tip_minor or 0, terms["tip_ceiling"]["amount_minor"])
            if fare != (state.fare_minor or 0) or tip != (state.tip_minor or 0):
                self._log("final charge above ceiling, clamped", backend=record["backend"],
                          fare=state.fare_minor, tip=state.tip_minor)
            public["final_charge"] = self._final_charge(terms, fare, tip, 0)
        if state.status == "failed":
            public["final_charge"] = self._final_charge(public["charge_terms"], 0, 0, 0)
        public["updated_at"] = _iso(self.clock())

    @staticmethod
    def _final_charge(terms, fare, tip, fee):
        currency = terms["currency"]
        total = fare + tip + fee
        return {
            "fare": _money(fare, currency),
            "tip": _money(tip, currency),
            "cancellation_fee": _money(fee, currency),
            "total": _money(total, currency),
            "amount_to_release": _money(terms["authorization_cap"]["amount_minor"] - total, currency),
        }

    def _get_ride(self, arguments):
        record = self._booking(arguments["booking_id"])
        self._refresh(record)
        return {"booking": record["public"]}

    def _cancel_ride(self, arguments):
        record = self._booking(arguments["booking_id"])
        public = record["public"]
        if public["status"] == "cancelled":
            return {"booking": public, "already_cancelled": True}
        self._refresh(record)
        if public["status"] in ("in_progress", "completed", "failed"):
            raise ConnectorError("not_cancellable", field="/booking_id", booking=public)

        now = self.clock()
        policy = public["cancellation_policy"]
        fee = 0
        if now >= parse_timestamp(policy["free_until"]):
            fee = policy["fee_after_free_period"]["amount_minor"]
        try:
            result = self.backends[record["backend"]].cancel(record["reference"], fee)
        except BackendError as error:
            self._log("cancel refused", backend=record["backend"], reason=error.reason, detail=error.detail)
            if error.reason == "not_cancellable":
                raise ConnectorError("not_cancellable", field="/booking_id", booking=public)
            raise ConnectorError(BACKEND_TO_CONTRACT[error.reason], retry_after_seconds=error.retry_after_seconds)
        if result.fee_minor > fee:
            self._log("cancellation fee above policy, clamped", backend=record["backend"],
                      charged=result.fee_minor, policy=fee)
        public["status"] = "cancelled"
        public["confirm_by"] = None
        public["final_charge"] = self._final_charge(public["charge_terms"], 0, 0, min(fee, result.fee_minor))
        public["updated_at"] = _iso(now)
        return {"booking": public, "already_cancelled": False}
