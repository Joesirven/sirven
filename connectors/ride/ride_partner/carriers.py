"""carrier adapters: Uber for Business and Lyft Business, through their partner interfaces.

each adapter turns one carrier's published partner interface into the same small shape, so
the backend above it never branches on carrier. what an adapter returns:

  estimates(...)    a list of options: vehicle_class, price_minor, currency,
                    price_is_upper_bound, surge, pickup_seconds, trip_seconds, expires_at,
                    and carrier_ref, the carrier's own tokens. carrier_ref stays inside the
                    backend; it never reaches the calling agent.
  create_trip(...)  the carrier's trip reference, also private.
  cancel_trip(...)  (settlement status, cancellation fee in minor units or None).

sirven is merchant of record: the user pays sirven, and every trip is billed to sirven's
corporate account with the carrier. the account is configured with CorporateAccount; the
adapters never see the user's payment details.

the paths and field names follow each carrier's public reference, read on 2026-10-11:
Uber's Guest Rides interface (/v1/guests/trips/estimates, /v1/guests/trips) and Lyft's
public interface (/cost, /eta, /rides, /rides/{id}/cancel). Lyft's business product is
Concierge; its paths below take the /v1/concierge prefix, which is assumed until partner
documentation arrives with approval. the fixtures were written from those references, not
recorded from a sandbox: re-record them once sandbox access exists (see README.md).
"""

from decimal import Decimal, ROUND_HALF_UP

from .transport import CarrierError, PartnerApprovalRequired, SandboxTransport


class CorporateAccount:
    """sirven's corporate account with one carrier. the organization reference comes from
    configuration (bb secret), never from the repository."""

    def __init__(self, organization_ref, expense_code="sirven-rides"):
        self.organization_ref = organization_ref
        self.expense_code = expense_code


def _to_minor(value):
    return int((Decimal(str(value)) * 100).quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def _raise_for(response, *ok):
    if response.status not in ok:
        raise CarrierError(response.status, response.body)


class UberForBusiness:
    name = "uber_for_business"
    provider = "Uber"
    sandbox_base_url = "https://sandbox-api.uber.com"
    sandbox_hosts = ("sandbox-api.uber.com",)
    token_variable = "SIRVEN_UBER_FOR_BUSINESS_SANDBOX_TOKEN"
    # Uber's published rider policy: free cancellation for two minutes after the request.
    # to confirm against the business terms once the partner agreement exists.
    free_cancel_seconds = 120
    product_classes = {
        "UberX": "standard",
        "Comfort": "comfort",
        "UberXL": "large",
        "Black": "premium",
        "WAV": "accessible",
    }

    def __init__(self, transport, account):
        self.transport = transport
        self.account = account

    def estimates(self, origin, destination, passengers, now):
        response = self.transport.request("POST", "/v1/guests/trips/estimates", body={
            "pickup": {"latitude": origin["latitude"], "longitude": origin["longitude"]},
            "dropoff": {"latitude": destination["latitude"], "longitude": destination["longitude"]},
        })
        _raise_for(response, 200)
        options = []
        for estimate in response.body.get("product_estimates", []):
            product = estimate["product"]
            info = estimate["estimate_info"]
            vehicle_class = self.product_classes.get(product["display_name"])
            fare = info.get("fare")
            if vehicle_class is None or fare is None or product.get("capacity", 0) < passengers:
                continue
            options.append({
                "vehicle_class": vehicle_class,
                "price_minor": _to_minor(fare["value"]),
                "currency": fare["currency_code"],
                "price_is_upper_bound": False,
                "surge": fare.get("surge_multiplier", 1) > 1,
                "pickup_seconds": int(info["pickup_estimate"]) * 60,
                "trip_seconds": int(info["trip"]["duration_estimate"]),
                "expires_at": int(fare["expires_at"]),
                "carrier_ref": {"product_id": product["product_id"], "fare_id": fare["fare_id"]},
            })
        return options

    def create_trip(self, carrier_ref, origin, destination, rider, memo):
        response = self.transport.request("POST", "/v1/guests/trips", body={
            "guest": {
                "first_name": rider["first_name"],
                "last_name": rider["last_name"],
                "phone_number": rider["phone_number"],
            },
            "pickup": {"latitude": origin["latitude"], "longitude": origin["longitude"]},
            "dropoff": {"latitude": destination["latitude"], "longitude": destination["longitude"]},
            "product_id": carrier_ref["product_id"],
            "fare_id": carrier_ref["fare_id"],
            "expense_code": self.account.expense_code,
            "expense_memo": memo,
        })
        _raise_for(response, 200, 201)
        return {"request_id": response.body["request_id"]}

    def cancel_trip(self, trip_ref, booked_at, now):
        response = self.transport.request("DELETE", "/v1/guests/trips/" + trip_ref["request_id"])
        _raise_for(response, 200, 204)
        if now - booked_at <= self.free_cancel_seconds:
            return "settled", 0
        # past the free window, Uber posts any fee on the trip receipt, which arrives later
        # by webhook. the receipt webhook is a seam: see README.md.
        return "pending_receipt", None


class LyftBusiness:
    name = "lyft_business"
    provider = "Lyft"
    sandbox_base_url = "https://api.lyft.com"
    # Lyft's sandbox is the production host with sandbox credentials, so the host check
    # alone cannot tell a sandbox ride from a live one. until partner documentation confirms
    # a separate sandbox host or a credential marker, sandbox mode quotes only: creating and
    # cancelling trips is BLOCKED ON PARTNER APPROVAL (see _refuse_unconfirmed_sandbox).
    sandbox_hosts = ("api.lyft.com",)
    token_variable = "SIRVEN_LYFT_BUSINESS_SANDBOX_TOKEN"
    free_cancel_seconds = 120
    # Lyft cost tokens carry no expiry in the public reference; five minutes until confirmed.
    cost_token_seconds = 300
    ride_type_classes = {
        "lyft": "standard",
        "lyft_preferred": "comfort",
        "lyft_xl": "large",
        "lyft_lux_black": "premium",
    }
    class_capacity = {"standard": 4, "comfort": 4, "large": 6, "premium": 4}

    def __init__(self, transport, account):
        self.transport = transport
        self.account = account

    def estimates(self, origin, destination, passengers, now):
        cost = self.transport.request("GET", "/v1/concierge/cost", query={
            "start_lat": origin["latitude"], "start_lng": origin["longitude"],
            "end_lat": destination["latitude"], "end_lng": destination["longitude"],
        })
        _raise_for(cost, 200)
        eta = self.transport.request("GET", "/v1/concierge/eta", query={
            "lat": origin["latitude"], "lng": origin["longitude"],
        })
        _raise_for(eta, 200)
        pickup = {item["ride_type"]: item["eta_seconds"]
                  for item in eta.body.get("eta_estimates", []) if item.get("is_valid_estimate")}
        options = []
        for estimate in cost.body.get("cost_estimates", []):
            ride_type = estimate["ride_type"]
            vehicle_class = self.ride_type_classes.get(ride_type)
            if (vehicle_class is None or not estimate.get("is_valid_estimate") or ride_type not in pickup
                    or self.class_capacity[vehicle_class] < passengers):
                continue
            low, high = estimate["estimated_cost_cents_min"], estimate["estimated_cost_cents_max"]
            options.append({
                "vehicle_class": vehicle_class,
                # a range is not a price. sirven quotes, and authorizes, the upper bound.
                "price_minor": int(high),
                "currency": estimate["currency"],
                "price_is_upper_bound": low != high,
                "surge": estimate.get("primetime_percentage", "0%") not in ("0%", ""),
                "pickup_seconds": int(pickup[ride_type]),
                "trip_seconds": int(estimate["estimated_duration_seconds"]),
                "expires_at": now + self.cost_token_seconds,
                "carrier_ref": {"ride_type": ride_type, "cost_token": estimate["cost_token"]},
            })
        return options

    def _refuse_unconfirmed_sandbox(self):
        if isinstance(self.transport, SandboxTransport):
            raise PartnerApprovalRequired(
                "Lyft's sandbox shares its production host; trips wait for partner documentation that tells them apart")

    def create_trip(self, carrier_ref, origin, destination, rider, memo):
        self._refuse_unconfirmed_sandbox()
        response = self.transport.request("POST", "/v1/concierge/rides", body={
            "ride_type": carrier_ref["ride_type"],
            "cost_token": carrier_ref["cost_token"],
            "origin": {"lat": origin["latitude"], "lng": origin["longitude"]},
            "destination": {"lat": destination["latitude"], "lng": destination["longitude"]},
            "passenger": {
                "first_name": rider["first_name"],
                "last_name": rider["last_name"],
                "phone_number": rider["phone_number"],
            },
            "organization_id": self.account.organization_ref,
            "expense_note": memo,
        })
        _raise_for(response, 200, 201)
        return {"ride_id": response.body["ride_id"]}

    def cancel_trip(self, trip_ref, booked_at, now):
        self._refuse_unconfirmed_sandbox()
        path = "/v1/concierge/rides/" + trip_ref["ride_id"] + "/cancel"
        response = self.transport.request("POST", path, body={})
        if response.status in (200, 204):
            return "settled", 0
        body = response.body or {}
        if response.status == 400 and body.get("error") == "cancel_confirmation_required":
            # Lyft names the fee up front and wants it confirmed with a short-lived token.
            confirmed = self.transport.request("POST", path, body={"cancel_confirmation_token": body["token"]})
            _raise_for(confirmed, 200, 204)
            return "settled", int(body["amount"])
        raise CarrierError(response.status, response.body)


CARRIERS = (UberForBusiness, LyftBusiness)
