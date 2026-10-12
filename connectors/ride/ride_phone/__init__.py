"""the iPhone ride backend: the owner's own ride app, on the owner's own plugged-in iPhone.

PhoneRideBackend implements the gateway's RideBackend interface by driving the Uber or Lyft app
through the phone bridge. booking and any charge wait for two approvals from the owner, both
live and both for that one purchase: the bridge's money hold (sirven phone approve), then the
phone's own face recognition or Apple Pay prompt, which only the owner answers, on the phone.
"""

from .backend import RIDE_APPS, PhoneRideBackend, build_connector
from .client import PhoneClient, PhoneRefusal

__all__ = ["RIDE_APPS", "PhoneClient", "PhoneRefusal", "PhoneRideBackend", "build_connector"]
