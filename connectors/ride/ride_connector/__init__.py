"""the sirven ride connector: contract schema, gateway, backend interface, and a fake backend.

the contract is docs/ride-connector-contract.md together with schemas/v1/ride-connector.schema.json.
"""

from .backend import (BackendBooking, BackendCancellation, BackendError, BackendOption, BackendQuote,
                      BackendStatus, QuoteRequest, RideBackend)
from .gateway import CONCIERGE_DISCLOSURE, ERRORS, ConnectorError, RideConnector
from .schema import Validator, bundle_tools, load_schema

__all__ = [
    "BackendBooking", "BackendCancellation", "BackendError", "BackendOption", "BackendQuote",
    "BackendStatus", "QuoteRequest", "RideBackend", "CONCIERGE_DISCLOSURE", "ERRORS",
    "ConnectorError", "RideConnector", "Validator", "bundle_tools", "load_schema",
]
