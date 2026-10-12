"""the money fields this layer reads from the ride connector contract.

the contract is thread 08's docs/ride-connector-contract.md, version 1 ("What the money layer
reads"). everything comes from charge_terms on the quoted option, the booking returned by
book_ride, and final_charge once get_ride or cancel_ride reports one. this file is the only
place in the package that reads a quote or a booking, so a contract change lands here.

money in the contract is {"amount_minor": int, "currency": "USD"}: whole minor units (cents
for United States dollars), the same unit Stripe uses, so no float ever touches money. Stripe
wants the currency in lower case; the contract sends it in upper case.
"""

SUPPORTED_CURRENCIES = ("usd",)


class ContractError(ValueError):
    pass


def _money(container, field, currency):
    value = (container or {}).get(field)
    if not isinstance(value, dict):
        raise ContractError(f"{field} must be an object with amount_minor and currency")
    amount = value.get("amount_minor")
    if not isinstance(amount, int) or isinstance(amount, bool) or amount < 0:
        raise ContractError(f"{field}.amount_minor must be a whole number of minor units, zero or more")
    if not isinstance(value.get("currency"), str) or value["currency"].lower() != currency:
        raise ContractError(f"{field}.currency must match charge_terms.currency")
    return amount


def quote_terms(option):
    """return the money terms of one ranked option from quote_ride, or raise ContractError.

    this is all the reservation needs, so it runs before book_ride commits.
    """
    if not isinstance(option, dict):
        raise ContractError("the quoted option must be an object")
    quote_id = option.get("quote_id")
    if not isinstance(quote_id, str) or not quote_id:
        raise ContractError("quote_id is required")
    if option.get("bookable") is False:
        raise ContractError("the option is not bookable; nothing is held for it")
    terms = option.get("charge_terms")
    if not isinstance(terms, dict):
        raise ContractError("charge_terms is required")
    currency = terms.get("currency")
    if not isinstance(currency, str) or currency.lower() not in SUPPORTED_CURRENCIES:
        raise ContractError(f"charge_terms.currency must be one of {', '.join(c.upper() for c in SUPPORTED_CURRENCIES)}")
    currency = currency.lower()
    quoted = _money(terms, "quoted_amount", currency)
    fare_ceiling = _money(terms, "fare_ceiling", currency)
    tip_ceiling = _money(terms, "tip_ceiling", currency)
    cap = _money(terms, "authorization_cap", currency)
    if cap != fare_ceiling + tip_ceiling:
        raise ContractError("authorization_cap must equal fare_ceiling plus tip_ceiling")
    if not 0 < quoted <= fare_ceiling:
        raise ContractError("quoted_amount must be more than zero and no more than fare_ceiling")
    price = option.get("price") or {}
    return {
        "quote_id": quote_id,
        "currency": currency,
        "quoted": quoted,
        "fare_ceiling": fare_ceiling,
        "tip_ceiling": tip_ceiling,
        "cap": cap,
        # carried into the charge record so the user sees what was bought and why it ranked
        # where it did, never card details.
        "provider": option.get("provider"),
        "rank": option.get("rank"),
        "price_kind": price.get("kind"),
        "constraint_flags": option.get("constraint_flags") or [],
        "estimated_pickup_at": option.get("estimated_pickup_at"),
        "estimated_trip_minutes": option.get("estimated_trip_minutes"),
    }


def booking_details(quote_id, booking):
    """return what the charge record keeps from a book_ride result, or raise ContractError."""
    if not isinstance(booking, dict):
        raise ContractError("booking must be an object")
    booking_id = booking.get("booking_id")
    if not isinstance(booking_id, str) or not booking_id:
        raise ContractError("booking.booking_id is required")
    if booking.get("quote_id", quote_id) != quote_id:
        raise ContractError("booking.quote_id does not match the quote it claims to book")
    return {"booking_id": booking_id, "status": booking.get("status"),
            "cancellation_policy": booking.get("cancellation_policy")}


def final_charge_total(booking, currency):
    """the total the gateway reports in final_charge, or None while the booking is open."""
    final = (booking or {}).get("final_charge")
    if final is None:
        return None
    return _money(final, "total", currency)
