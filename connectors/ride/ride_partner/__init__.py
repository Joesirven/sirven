"""the official-partner ride backend for sirven: the ride connector's three calls over
Uber for Business and Lyft Business. see ../README.md."""

import os

from .backend import PartnerRideBackend, PaymentDeclined
from .carriers import CARRIERS, CorporateAccount, LyftBusiness, UberForBusiness
from .contract import RideConnectorError
from .transport import LiveCallsBlocked, PartnerApprovalRequired, transport_for

__all__ = [
    "CorporateAccount", "LiveCallsBlocked", "LyftBusiness", "PartnerApprovalRequired",
    "PartnerRideBackend", "PaymentDeclined", "RideConnectorError", "UberForBusiness", "build_backend",
]


def build_backend(payments, rider_contact, mode=None, scenarios=None, clock=None):
    """a backend wired to both carriers. mode is fixture, sandbox, or live (default: the
    SIRVEN_RIDE_PARTNER_MODE variable, else fixture). scenarios picks a recorded scenario
    per carrier name in fixture mode. the corporate account references come from
    SIRVEN_<CARRIER>_ORGANIZATION outside fixture mode; they are configuration, not code."""
    mode = mode or os.environ.get("SIRVEN_RIDE_PARTNER_MODE", "fixture")
    scenarios = scenarios or {}
    carriers = []
    for carrier in CARRIERS:
        if mode == "fixture":
            organization = "fixture-organization"
        else:
            organization = os.environ.get("SIRVEN_%s_ORGANIZATION" % carrier.name.upper(), "")
        transport = transport_for(carrier, mode, scenarios.get(carrier.name, "standard"))
        carriers.append(carrier(transport, CorporateAccount(organization)))
    extra = {} if clock is None else {"clock": clock}
    return PartnerRideBackend(carriers, payments, rider_contact, **extra)
