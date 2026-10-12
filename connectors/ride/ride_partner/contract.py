"""the ride connector contract, as this backend understands it.

PROVISIONAL. thread 08 owns the published contract (docs/ride-connector-contract.md plus
machine-readable schemas). until it lands, this module encodes the three-call shape from
thread 08's brief: quote_ride, book_ride, cancel_ride. everything a caller can observe
(field names, error codes, identifier format) lives here and nowhere else, so swapping in
the published schemas is a change to this one file.

backend blindness: the calling agent must not be able to tell which backend produced a
quote. the validators below are strict (no unknown keys, no missing keys), so any backend
whose output passes them has the same shape as every other backend. the provider, meaning
the company that sends the car, is an ordinary returned value; the backend never is.
"""

import secrets

CONTRACT_VERSION = "0.1.0-provisional"

# service levels are normalized so a carrier's own product name ("UberX", "Lyft XL") never
# reaches the agent; a different backend reaching the same carrier names products differently.
VEHICLE_CLASSES = ("standard", "comfort", "large", "premium", "accessible")
OPTIMIZE_FOR = ("price", "pickup", "arrival")

# constraint flags. the first two block booking; the rest are information for the agent.
BLOCKING_FLAGS = ("exceeds_budget", "pickup_outside_window")
INFORMATION_FLAGS = ("price_is_upper_bound", "surge_pricing")
CONSTRAINT_FLAGS = BLOCKING_FLAGS + INFORMATION_FLAGS

ERROR_CODES = {
    "invalid_request": "the request does not match the contract",
    "no_options": "no ride matches the request",
    "quote_not_found": "no quote has that identifier",
    "quote_expired": "the quote expired; ask for a new one",
    "constraint_not_met": "the quote breaks the budget or the departure window",
    "payment_declined": "the payment for this ride was declined",
    "provider_unavailable": "the ride service could not complete the request; try again",
    "booking_not_found": "no booking has that identifier",
    "not_cancellable": "the ride can no longer be cancelled",
}
RETRYABLE = ("provider_unavailable",)

BOOKING_STATUSES = ("requested", "cancelled")
SETTLEMENT_STATUSES = ("settled", "pending_receipt")


class RideConnectorError(Exception):
    """the only error a caller ever sees. the message is fixed per code, so carrier error
    text (which would name the backend's integration) can never pass through."""

    def __init__(self, code):
        if code not in ERROR_CODES:
            raise ValueError("unknown error code: " + code)
        super().__init__(ERROR_CODES[code])
        self.code = code

    def to_dict(self):
        return {"code": self.code, "message": ERROR_CODES[self.code], "retryable": self.code in RETRYABLE}


def new_quote_id():
    return "quote_" + secrets.token_hex(16)


def new_booking_id():
    return "booking_" + secrets.token_hex(16)


def money(amount_minor, currency):
    return {"amount_minor": int(amount_minor), "currency": currency}


# validation. each validator raises ValueError naming the first problem it finds.

def _keys(value, required, optional=(), where=""):
    if not isinstance(value, dict):
        raise ValueError(where + " must be an object")
    missing = [key for key in required if key not in value]
    extra = [key for key in value if key not in required and key not in optional]
    if missing:
        raise ValueError(where + " is missing " + ", ".join(missing))
    if extra:
        raise ValueError(where + " has unknown fields " + ", ".join(sorted(extra)))


def _money(value, where):
    _keys(value, ("amount_minor", "currency"), where=where)
    if not isinstance(value["amount_minor"], int) or value["amount_minor"] < 0:
        raise ValueError(where + ".amount_minor must be a whole number of minor units, zero or more")
    currency = value["currency"]
    if not (isinstance(currency, str) and len(currency) == 3 and currency.isalpha() and currency.isupper()):
        raise ValueError(where + ".currency must be a three letter currency code")


def _place(value, where):
    _keys(value, ("latitude", "longitude"), ("address",), where)
    for axis, limit in (("latitude", 90), ("longitude", 180)):
        number = value[axis]
        if isinstance(number, bool) or not isinstance(number, (int, float)) or abs(number) > limit:
            raise ValueError(where + "." + axis + " is out of range")


def validate_quote_request(origin, destination, departure_window, user_preferences, budget_ceiling):
    _place(origin, "origin")
    _place(destination, "destination")
    _keys(departure_window, ("earliest", "latest"), where="departure_window")
    for edge in ("earliest", "latest"):
        if not isinstance(departure_window[edge], int):
            raise ValueError("departure_window." + edge + " must be a unix timestamp in seconds")
    if departure_window["latest"] < departure_window["earliest"]:
        raise ValueError("departure_window.latest is before departure_window.earliest")
    _keys(user_preferences, (), ("optimize_for", "vehicle_classes", "passengers", "tip_ceiling"), "user_preferences")
    if user_preferences.get("optimize_for", "price") not in OPTIMIZE_FOR:
        raise ValueError("user_preferences.optimize_for must be one of " + ", ".join(OPTIMIZE_FOR))
    for vehicle_class in user_preferences.get("vehicle_classes", ()):
        if vehicle_class not in VEHICLE_CLASSES:
            raise ValueError("unknown vehicle class: " + str(vehicle_class))
    passengers = user_preferences.get("passengers", 1)
    if not isinstance(passengers, int) or not 1 <= passengers <= 8:
        raise ValueError("user_preferences.passengers must be between 1 and 8")
    if "tip_ceiling" in user_preferences:
        _money(user_preferences["tip_ceiling"], "user_preferences.tip_ceiling")
    _money(budget_ceiling, "budget_ceiling")


QUOTE_FIELDS = (
    "quote_id", "rank", "provider", "vehicle_class", "price", "tip_ceiling",
    "estimated_pickup_seconds", "estimated_trip_seconds", "estimated_arrival",
    "expires_at", "constraint_flags",
)


def validate_quote_response(response):
    _keys(response, ("contract_version", "quotes"), where="response")
    for index, quote in enumerate(response["quotes"]):
        where = "quotes[%d]" % index
        _keys(quote, QUOTE_FIELDS, where=where)
        if quote["rank"] != index + 1:
            raise ValueError(where + ".rank must follow list order")
        if quote["vehicle_class"] not in VEHICLE_CLASSES:
            raise ValueError(where + ".vehicle_class is unknown")
        _money(quote["price"], where + ".price")
        _money(quote["tip_ceiling"], where + ".tip_ceiling")
        for flag in quote["constraint_flags"]:
            if flag not in CONSTRAINT_FLAGS:
                raise ValueError(where + " has unknown constraint flag " + flag)


def validate_booking_response(response):
    _keys(response, ("contract_version", "booking_id", "quote_id", "status", "provider", "price",
                     "tip_ceiling", "tracking", "cancellation_window"), where="response")
    if response["status"] not in BOOKING_STATUSES:
        raise ValueError("response.status is unknown")
    _money(response["price"], "response.price")
    _money(response["tip_ceiling"], "response.tip_ceiling")
    _keys(response["tracking"], ("status_path",), where="response.tracking")
    _keys(response["cancellation_window"], ("free_until",), where="response.cancellation_window")


def validate_cancel_response(response):
    _keys(response, ("contract_version", "booking_id", "status", "settlement"), where="response")
    if response["status"] != "cancelled":
        raise ValueError("response.status must be cancelled")
    settlement = response["settlement"]
    _keys(settlement, ("status", "cancellation_fee"), where="response.settlement")
    if settlement["status"] not in SETTLEMENT_STATUSES:
        raise ValueError("response.settlement.status is unknown")
    if settlement["cancellation_fee"] is not None:
        _money(settlement["cancellation_fee"], "response.settlement.cancellation_fee")
