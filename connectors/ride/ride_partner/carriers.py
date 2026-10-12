"""carrier adapters: Uber for Business and Lyft Business, through their partner interfaces.

each adapter turns one carrier's partner interface into the same small shape, so the backend
above it never branches on carrier:

  estimates(origin, destination, now)   a list of option dicts: vehicle_class, accessibility,
        price_kind, fare_minor, fare_maximum_minor, currency, pickup_seconds, trip_seconds,
        expires_at, surge, and carrier_ref (the carrier's own tokens, which stay private).
  create_trip(carrier_ref, origin, destination, rider, memo)   the carrier's trip reference.
  trip_status(trip_ref)   (contract booking status, vehicle description, fare_minor, tip_minor).
  cancel_trip(trip_ref, expected_fee_minor)   the cancellation fee in minor units.

origin and destination here are always {"latitude", "longitude"}. sirven is merchant of
record: every trip is billed to sirven's corporate account with the carrier (CorporateAccount),
and the adapters never see the user's payment details.

the paths and field names follow each carrier's public reference, read on 2026-10-11: Uber's
Guest Rides interface (/v1/guests/trips/estimates, /v1/guests/trips) and Lyft's public
interface (/cost, /eta, /rides, /rides/{id}/cancel). Lyft's business product is Concierge; its
/v1/concierge prefix, the receipt fields, and the status names are assumed until partner
documentation arrives with approval. the fixtures were written from those references, not
recorded from a sandbox: re-record them once sandbox access exists (see README.md).
"""

from datetime import datetime, timedelta, timezone
from decimal import ROUND_HALF_UP, Decimal

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


def _vehicle(vehicle):
    if not vehicle:
        return None
    words = " ".join(part for part in (vehicle.get("color"), vehicle.get("make"), vehicle.get("model")) if part)
    plate = vehicle.get("license_plate")
    return (words + (", plate " + plate if plate else "")).strip(", ") or None


class UberForBusiness:
    name = "uber_for_business"
    provider = "Uber"
    sandbox_base_url = "https://sandbox-api.uber.com"
    sandbox_hosts = ("sandbox-api.uber.com",)
    token_variable = "SIRVEN_UBER_FOR_BUSINESS_SANDBOX_TOKEN"
    # Uber's published rider policy: free cancellation for two minutes after the request, then
    # a fee that varies by city. both to confirm under the business agreement.
    free_cancel_seconds = 120
    cancellation_fee_minor = 500
    product_classes = {
        "UberX": ("standard", frozenset()),
        "Comfort": ("comfort", frozenset()),
        "UberXL": ("large", frozenset()),
        "Black": ("premium", frozenset()),
        "WAV": ("accessible", frozenset({"wheelchair_accessible", "assistance_boarding"})),
    }
    statuses = {
        "processing": "requested",
        "accepted": "driver_assigned",
        "arriving": "driver_assigned",
        "in_progress": "in_progress",
        "completed": "completed",
        "rider_canceled": "cancelled",
        "driver_canceled": "failed",
        "no_drivers_available": "failed",
    }

    def __init__(self, transport, account):
        self.transport = transport
        self.account = account

    def estimates(self, origin, destination, now):
        response = self.transport.request("POST", "/v1/guests/trips/estimates", body={
            "pickup": dict(origin), "dropoff": dict(destination)})
        _raise_for(response, 200)
        options = []
        for estimate in response.body.get("product_estimates", []):
            product, info = estimate["product"], estimate["estimate_info"]
            known = self.product_classes.get(product["display_name"])
            fare = info.get("fare")
            if known is None or fare is None:
                continue
            price = _to_minor(fare["value"])
            options.append({
                "vehicle_class": known[0],
                "accessibility": known[1],
                "price_kind": "fixed",  # Guest Rides fares are upfront.
                "fare_minor": price,
                "fare_maximum_minor": price,
                "currency": fare["currency_code"],
                "surge": fare.get("surge_multiplier", 1) > 1,
                "pickup_seconds": int(info["pickup_estimate"]) * 60,
                "trip_seconds": int(info["trip"]["duration_estimate"]),
                "expires_at": datetime.fromtimestamp(int(fare["expires_at"]), timezone.utc),
                "carrier_ref": {"product_id": product["product_id"], "fare_id": fare["fare_id"]},
            })
        return options

    def create_trip(self, carrier_ref, origin, destination, rider, memo):
        response = self.transport.request("POST", "/v1/guests/trips", body={
            "guest": {key: rider[key] for key in ("first_name", "last_name", "phone_number")},
            "pickup": dict(origin),
            "dropoff": dict(destination),
            "product_id": carrier_ref["product_id"],
            "fare_id": carrier_ref["fare_id"],
            "expense_code": self.account.expense_code,
            "expense_memo": memo,
        })
        _raise_for(response, 200, 201)
        return {"request_id": response.body["request_id"]}

    def trip_status(self, trip_ref):
        path = "/v1/guests/trips/" + trip_ref["request_id"]
        response = self.transport.request("GET", path)
        _raise_for(response, 200)
        status = self.statuses.get(response.body["status"], "requested")
        vehicle = _vehicle(response.body.get("vehicle"))
        if status != "completed":
            return status, vehicle, None, None
        # the fare is on the receipt, which Uber posts some time after drop-off. until it
        # exists the trip reads as in progress, so the gateway never settles a zero fare.
        receipt = self.transport.request("GET", path + "/receipt")
        if receipt.status == 404:
            return "in_progress", vehicle, None, None
        _raise_for(receipt, 200)
        return "completed", vehicle, _to_minor(receipt.body["total_fare"]), _to_minor(receipt.body.get("tip", 0))

    def cancel_trip(self, trip_ref, expected_fee_minor):
        response = self.transport.request("DELETE", "/v1/guests/trips/" + trip_ref["request_id"])
        _raise_for(response, 200, 204)
        # Uber names any fee on the receipt later. sirven charges the policy fee the gateway
        # expects; the receipt reconciliation that would catch a mismatch is a seam.
        return expected_fee_minor


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
    cancellation_fee_minor = 500
    # Lyft cost tokens carry no expiry in the public reference; five minutes until confirmed.
    cost_token_seconds = 300
    ride_type_classes = {
        "lyft": "standard",
        "lyft_preferred": "comfort",
        "lyft_xl": "large",
        "lyft_lux_black": "premium",
    }
    statuses = {
        "pending": "requested",
        "accepted": "driver_assigned",
        "arrived": "driver_assigned",
        "pickedUp": "in_progress",
        "droppedOff": "completed",
        "canceled": "cancelled",
    }

    def __init__(self, transport, account):
        self.transport = transport
        self.account = account

    def _refuse_unconfirmed_sandbox(self):
        if isinstance(self.transport, SandboxTransport):
            raise PartnerApprovalRequired(
                "Lyft's sandbox shares its production host; trips wait for partner documentation that tells them apart")

    def estimates(self, origin, destination, now):
        cost = self.transport.request("GET", "/v1/concierge/cost", query={
            "start_lat": origin["latitude"], "start_lng": origin["longitude"],
            "end_lat": destination["latitude"], "end_lng": destination["longitude"],
        })
        _raise_for(cost, 200)
        eta = self.transport.request("GET", "/v1/concierge/eta", query={
            "lat": origin["latitude"], "lng": origin["longitude"]})
        _raise_for(eta, 200)
        pickup = {item["ride_type"]: item["eta_seconds"]
                  for item in eta.body.get("eta_estimates", []) if item.get("is_valid_estimate")}
        options = []
        for estimate in cost.body.get("cost_estimates", []):
            ride_type = estimate["ride_type"]
            vehicle_class = self.ride_type_classes.get(ride_type)
            if vehicle_class is None or not estimate.get("is_valid_estimate") or ride_type not in pickup:
                continue
            low, high = int(estimate["estimated_cost_cents_min"]), int(estimate["estimated_cost_cents_max"])
            options.append({
                "vehicle_class": vehicle_class,
                "accessibility": frozenset(),
                "price_kind": "fixed" if low == high else "estimate",
                "fare_minor": low,
                "fare_maximum_minor": high,
                "currency": estimate["currency"],
                "surge": estimate.get("primetime_percentage", "0%") not in ("0%", ""),
                "pickup_seconds": int(pickup[ride_type]),
                "trip_seconds": int(estimate["estimated_duration_seconds"]),
                "expires_at": now + timedelta(seconds=self.cost_token_seconds),
                "carrier_ref": {"ride_type": ride_type, "cost_token": estimate["cost_token"]},
            })
        return options

    def create_trip(self, carrier_ref, origin, destination, rider, memo):
        self._refuse_unconfirmed_sandbox()
        response = self.transport.request("POST", "/v1/concierge/rides", body={
            "ride_type": carrier_ref["ride_type"],
            "cost_token": carrier_ref["cost_token"],
            "origin": {"lat": origin["latitude"], "lng": origin["longitude"]},
            "destination": {"lat": destination["latitude"], "lng": destination["longitude"]},
            "passenger": {key: rider[key] for key in ("first_name", "last_name", "phone_number")},
            "organization_id": self.account.organization_ref,
            "expense_note": memo,
        })
        _raise_for(response, 200, 201)
        return {"ride_id": response.body["ride_id"]}

    def trip_status(self, trip_ref):
        response = self.transport.request("GET", "/v1/concierge/rides/" + trip_ref["ride_id"])
        _raise_for(response, 200)
        status = self.statuses.get(response.body["status"], "requested")
        vehicle = _vehicle(response.body.get("vehicle"))
        if status != "completed":
            return status, vehicle, None, None
        price = response.body.get("price")
        if not price:
            return "in_progress", vehicle, None, None
        tip = (response.body.get("tip") or {}).get("amount", 0)
        return "completed", vehicle, int(price["amount"]), int(tip)

    def cancel_trip(self, trip_ref, expected_fee_minor):
        self._refuse_unconfirmed_sandbox()
        path = "/v1/concierge/rides/" + trip_ref["ride_id"] + "/cancel"
        response = self.transport.request("POST", path, body={})
        if response.status in (200, 204):
            return 0
        body = response.body or {}
        if response.status == 400 and body.get("error") == "cancel_confirmation_required":
            # Lyft names the fee up front and wants it confirmed with a short-lived token.
            confirmed = self.transport.request("POST", path, body={"cancel_confirmation_token": body["token"]})
            _raise_for(confirmed, 200, 204)
            return int(body["amount"])
        raise CarrierError(response.status, response.body)


CARRIERS = (UberForBusiness, LyftBusiness)
