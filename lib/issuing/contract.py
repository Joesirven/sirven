"""the money fields this layer reads from the ride connector contract.

the connector contract (thread 08, docs/ride-connector-contract.md) owns these field names.
it had not been published when this was written, so the names below are the ones its brief
asks for (quoted amount, tip ceiling, currency on the quote; booking identifier on the book
result). this file is the single place to change if the published names differ; nothing
else in the package reads a quote or a booking directly.

amounts are integers in the currency's smallest unit (cents for usd), the same unit Stripe
uses, so no float ever touches money.
"""

SUPPORTED_CURRENCIES = ("usd",)


class ContractError(ValueError):
    pass


def _money(container, field):
    value = container.get(field)
    if not isinstance(value, dict):
        raise ContractError(f"{field} must be an object with amount_minor and currency")
    amount = value.get("amount_minor")
    currency = value.get("currency")
    if not isinstance(amount, int) or isinstance(amount, bool) or amount < 0:
        raise ContractError(f"{field}.amount_minor must be a whole number of minor units, zero or more")
    if not isinstance(currency, str) or currency.lower() not in SUPPORTED_CURRENCIES:
        raise ContractError(f"{field}.currency must be one of {', '.join(SUPPORTED_CURRENCIES)}")
    return amount, currency.lower()


def booking_terms(quote, booking):
    """return the money terms for one booking, or raise ContractError.

    quote is one ranked option from quote_ride; booking is the result of book_ride for it.
    """
    if not isinstance(quote, dict) or not isinstance(booking, dict):
        raise ContractError("quote and booking must both be objects")
    quote_id = quote.get("quote_id")
    booking_id = booking.get("booking_id")
    if not isinstance(quote_id, str) or not quote_id:
        raise ContractError("quote.quote_id is required")
    if not isinstance(booking_id, str) or not booking_id:
        raise ContractError("booking.booking_id is required")
    if booking.get("quote_id", quote_id) != quote_id:
        raise ContractError("booking.quote_id does not match the quote it claims to book")
    quoted, currency = _money(quote, "price")
    tip_ceiling, tip_currency = _money(quote, "tip_ceiling")
    if tip_currency != currency:
        raise ContractError("price and tip_ceiling must share a currency")
    if quoted == 0:
        raise ContractError("price.amount_minor must be more than zero")
    return {
        "quote_id": quote_id,
        "booking_id": booking_id,
        "currency": currency,
        "quoted": quoted,
        "tip_ceiling": tip_ceiling,
        "cap": quoted + tip_ceiling,
        # carried into the charge record so the user sees what was bought, never card details.
        "provider": quote.get("provider"),
        "estimated_arrival": quote.get("estimated_arrival"),
        "estimated_trip_time": quote.get("estimated_trip_time"),
        "cancellation_window": booking.get("cancellation_window"),
    }
