"""the official-partner ride backend for sirven: a RideBackend over Uber for Business and Lyft
Business, served to agents through the ride connector's gateway. see ../README.md."""

import os

from ride_connector.gateway import RideConnector

from .backend import PartnerRideBackend
from .carriers import CARRIERS, CorporateAccount, LyftBusiness, UberForBusiness
from .transport import LiveCallsBlocked, PartnerApprovalRequired, transport_for

__all__ = [
    "CorporateAccount", "LiveCallsBlocked", "LyftBusiness", "PartnerApprovalRequired",
    "PartnerRideBackend", "UberForBusiness", "build_backend", "build_connector",
]


def build_backend(clock, rider, mode=None, scenarios=None, geocode=None):
    """a PartnerRideBackend wired to both carriers. mode is fixture, sandbox, or live (default:
    the SIRVEN_RIDE_PARTNER_MODE variable, else fixture). scenarios picks a recorded scenario
    per carrier name in fixture mode. outside fixture mode the corporate account references
    come from SIRVEN_<CARRIER>_ORGANIZATION; they are configuration, not code."""
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
    return PartnerRideBackend(carriers, clock, rider, geocode=geocode)


def build_connector(clock, rider, **options):
    """the contract gateway over this backend alone, with booking gated on held funds."""
    backend = build_backend(clock, rider, **options)
    return RideConnector({"partner": backend}, clock=clock, require_payment_reference=True), backend
