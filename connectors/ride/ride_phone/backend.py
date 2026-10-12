"""PhoneRideBackend: quote, book, cancel, and status by driving a ride app on the owner's iPhone.

how it finds its way: the semantic map the owner's onboarding built (sirven phone onboard,
lib/phone_map.py) says which installed app is which and where the destination field is on its
first screen. past that first screen, the backend reads the live screen and names each control
with the same roles the map uses (phone_map.classify), because the crawler never types and so
never maps the screens that only appear after a destination is entered.

the money path, which Jose chose: the agent drives the app as far as checkout. the request tap
is a money-bearing tap, so the bridge holds it until the owner runs sirven phone approve. then
the phone shows its own face recognition or Apple Pay prompt for that one purchase, and only the owner
answers it, on the phone. sirven never touches that prompt (the bridge refuses every touch while
it is up), never stores or replays a scan, and never lets one approval cover a later purchase.

what stays inside this backend: the app's bundle name, the product's row label, and the screen
text. the gateway sees plain records and the provider name, as the contract allows.
"""

import os
import re
import secrets
import sys
import time
from datetime import timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(HERE))), "lib"))

import phone_map  # noqa: E402
from ride_connector.backend import (BackendBooking, BackendCancellation, BackendError,  # noqa: E402
                                    BackendOption, BackendQuote, BackendStatus, RideBackend)
from ride_connector.gateway import RideConnector, system_clock  # noqa: E402

from .client import PhoneClient, PhoneRefusal  # noqa: E402

# the ride apps this backend knows, by the name on the home screen. the bundle names are the
# fallback when the map has not recorded one yet.
RIDE_APPS = {"Uber": "com.ubercab.UberClient", "Lyft": "com.zimride.instant"}

# product words to the contract's vehicle classes. anything unknown is standard.
VEHICLE_CLASSES = (
    (re.compile(r"\b(xl|xxl|suv|large)\b", re.IGNORECASE), "large"),
    (re.compile(r"\b(comfort|preferred|extra comfort)\b", re.IGNORECASE), "comfort"),
    (re.compile(r"\b(black|lux|premier|premium|select)\b", re.IGNORECASE), "premium"),
    (re.compile(r"\b(wav|assist|access)\b", re.IGNORECASE), "accessible"),
    (re.compile(r"\b(pool|shared|wait and save)\b", re.IGNORECASE), "shared"),
)

PRICE = re.compile(r"\$\s?(\d+)(?:\.(\d{2}))?")
PICKUP_MINUTES = re.compile(r"(\d+)\s*min(?:ute)?s?\s*away", re.IGNORECASE)
TRIP_MINUTES = re.compile(r"(\d+)\s*min(?:ute)?s?\s*trip", re.IGNORECASE)
PICKUP_IN = re.compile(r"pickup in\s*(\d+)\s*min", re.IGNORECASE)

ON_THE_WAY = re.compile(r"\b(on the way|on their way|arriving|is here|pickup in)\b", re.IGNORECASE)
IN_TRIP = re.compile(r"\b(heading to|on trip|en route to your destination)\b", re.IGNORECASE)
FINISHED = re.compile(r"\b(you have arrived|you've arrived|trip complete|rate your (driver|trip))\b", re.IGNORECASE)
CANCELLED = re.compile(r"\b(ride|trip) (was )?cancell?ed\b", re.IGNORECASE)
NO_FEE = re.compile(r"\bno (cancellation )?fee\b", re.IGNORECASE)

QUOTE_LIFETIME_MINUTES = 2
# assumed until checked against each service's published terms; see docs/ride-connector-contract.md
FREE_CANCELLATION_MINUTES = 2
LATE_CANCELLATION_FEE_MINOR = 500


def minor_units(label):
    found = PRICE.search(label or "")
    if not found:
        return None
    return int(found.group(1)) * 100 + int(found.group(2) or 0)


def vehicle_class(product):
    for pattern, name in VEHICLE_CLASSES:
        if pattern.search(product):
            return name
    return "standard"


def role(element):
    return phone_map.classify({"type": element.get("type", ""), "label": element.get("label") or ""})[0]


class PhoneRideBackend(RideBackend):
    """one owner, one phone, one ride app at a time.

    apps: names on the home screen to try, in order (default Uber, then Lyft).
    hold_wait_seconds: how long book waits for sirven phone approve before giving up.
    phone_wait_seconds: how long it waits for the owner to answer the phone's own prompt.
    """

    def __init__(self, client=None, clock=system_clock, apps=("Uber", "Lyft"), hold_wait_seconds=300,
                 phone_wait_seconds=120, poll_seconds=1.0, sleep=time.sleep, monotonic=time.monotonic):
        self.client = client or PhoneClient()
        self.clock = clock
        self.apps = tuple(apps)
        self.hold_wait_seconds = hold_wait_seconds
        self.phone_wait_seconds = phone_wait_seconds
        self.poll_seconds = poll_seconds
        self.sleep = sleep
        self.monotonic = monotonic
        self._options = {}
        self._bookings = {}
        self.private_log = []

    # the phone ------------------------------------------------------------------------------

    def _log(self, what, **details):
        self.private_log.append(dict(details, what=what))

    def _refused(self, refusal, during):
        """a bridge refusal in backend terms. the bridge's words go to the private log only."""
        self._log("phone refused", during=during, result=refusal.result, said=refusal.said)
        if refusal.result in ("no_consent", "no_phone", "not_trusted", "several_phones", "phone_locked",
                              "bridge_not_running", "no_usb_service", "webdriveragent_not_running", "unauthorized"):
            return BackendError("unavailable", "the phone is not ready: %s" % refusal.result)
        if refusal.result == "owner_approving_on_phone":
            return BackendError("unavailable", "the phone is waiting on the owner")
        return BackendError("down", "the phone bridge refused: %s" % refusal.result)

    def _screen(self, reason):
        try:
            return self.client.screen(reason)
        except PhoneRefusal as refusal:
            raise self._refused(refusal, "screen")

    def _tap(self, label, reason, money=False, approval=None):
        try:
            return self.client.tap(label, reason, money=money, approval=approval)
        except PhoneRefusal as refusal:
            if refusal.result == "held_for_approval":
                raise
            raise self._refused(refusal, "tap")

    def _mapped_apps(self):
        """the ride apps the owner's onboarding mapped, as (name, bundle, destination label)."""
        try:
            answer = self.client.phone_map()
        except PhoneRefusal as refusal:
            raise self._refused(refusal, "map")
        the_map = answer.get("map", answer)
        found = []
        for name in self.apps:
            for bundle, entry in sorted((the_map.get("apps") or {}).items()):
                if entry.get("name") != name:
                    continue
                fields = phone_map.find(the_map, bundle, "destination_field")
                if fields:
                    # the map also says which controls lead to that screen, so the backend can
                    # find its way back from wherever the app was left
                    ways_back = sorted({control["label"] for screen in entry.get("screens", {}).values()
                                        for control in screen.get("controls", [])
                                        if control.get("leads_to") == fields[0]["screen"] and control.get("label")})
                    found.append((name, bundle, fields[0]["label"], ways_back))
        if not found:
            raise BackendError("unavailable", "no ride app is in the phone's map; the owner runs sirven phone onboard")
        return found

    def _search(self, name, bundle, field_label, destination, ways_back=()):
        """open the app, enter the destination, and return the live options screen."""
        reason = "finding rides in %s to the requested destination" % name
        try:
            self.client.launch(bundle, reason)
        except PhoneRefusal as refusal:
            raise self._refused(refusal, "launch")
        # a running app resumes where it was, so step back until the destination field shows
        for _ in range(4):
            screen = self._screen(reason)
            if any(e.get("label") == field_label for e in screen.get("elements", [])):
                break
            labels = {e.get("label") for e in screen.get("elements", [])}
            back = next((label for label in ways_back if label in labels), None) or self._find_label(screen, "back_button")
            if back is None:
                raise BackendError("unavailable", "the app is not on a screen with the destination field")
            self._tap(back, reason)
        else:
            raise BackendError("unavailable", "could not get back to the destination field")
        self._tap(field_label, reason)
        text = destination.get("address") or destination.get("label")
        if not text:
            raise BackendError("no_service", "the destination has no address to type")
        try:
            self.client.type_text(text, reason)
        except PhoneRefusal as refusal:
            raise self._refused(refusal, "type")
        return self._screen(reason)

    def _priced_rows(self, screen):
        rows = []
        for element in screen.get("elements", []):
            if role(element) != "priced_option":
                continue
            label = element["label"]
            product = label.split(",")[0].strip()
            fare = minor_units(label)
            pickup = PICKUP_MINUTES.search(label)
            trip = TRIP_MINUTES.search(label)
            if not product or fare is None or not pickup or not trip:
                self._log("option skipped: could not read it", label_shape=phone_map.shape(label))
                continue
            rows.append({"label": label, "product": product, "fare": fare,
                         "pickup_minutes": int(pickup.group(1)), "trip_minutes": int(trip.group(1))})
        return rows

    # the contract ---------------------------------------------------------------------------

    def quote(self, request):
        options = []
        for name, bundle, field_label, ways_back in self._mapped_apps():
            screen = self._search(name, bundle, field_label, request.destination, ways_back)
            now = self.clock()
            for row in self._priced_rows(screen):
                pickup_at = now + timedelta(minutes=row["pickup_minutes"])
                reference = "phone-option-" + secrets.token_hex(4)
                self._options[reference] = dict(row, name=name, bundle=bundle, field_label=field_label,
                                                ways_back=ways_back, destination=request.destination)
                options.append(BackendOption(
                    reference=reference, provider=name, vehicle_class=vehicle_class(row["product"]),
                    price_kind="fixed", fare_minor=row["fare"], fare_maximum_minor=row["fare"],
                    currency=request.currency, pickup_at=pickup_at, trip_minutes=row["trip_minutes"],
                    expires_at=now + timedelta(minutes=QUOTE_LIFETIME_MINUTES),
                    cancellation_free_until=pickup_at - timedelta(minutes=FREE_CANCELLATION_MINUTES),
                    cancellation_fee_minor=LATE_CANCELLATION_FEE_MINOR))
        if not options:
            raise BackendError("unavailable", "the ride apps showed no options that could be read")
        return BackendQuote(options=options)

    def book(self, option_reference, payment_reference, authorization_cap_minor):
        # payment_reference is unused: nothing is paid through sirven. the owner approves this one
        # purchase live, twice: the money hold, then the phone's own prompt.
        option = self._options.get(option_reference)
        if option is None:
            raise BackendError("unavailable", "that option is no longer on the phone")
        name = option["name"]
        reason = "booking the %s %s the owner chose" % (name, option["product"])
        screen = self._search(name, option["bundle"], option["field_label"], option["destination"], option["ways_back"])
        live = [row for row in self._priced_rows(screen) if row["product"] == option["product"]]
        if not live:
            raise BackendError("unavailable", "the chosen ride is no longer offered")
        if live[0]["fare"] > option["fare"] or live[0]["fare"] > authorization_cap_minor:
            # the price on the phone rose since the quote: never book at a price nobody approved
            raise BackendError("price_changed", "the app now shows %d minor units" % live[0]["fare"])
        self._tap(live[0]["label"], reason)
        request_label = self._find_label(self._screen(reason), "request_button")
        if request_label is None:
            raise BackendError("down", "no request button after choosing the ride")
        hold = None
        try:
            self._tap(request_label, reason, money=True)
        except PhoneRefusal as refusal:
            hold = refusal.hold
        if hold is None:
            # the bridge always holds a money tap; if it did not, something is wrong, so stop
            raise BackendError("down", "the request tap was not held for the owner")
        self._wait_for_owner(hold)
        self._tap(request_label, reason, money=True, approval=hold)
        confirmation = self._wait_for_phone_approval(reason)
        pickup_minutes = PICKUP_IN.search(" ".join(e.get("label") or "" for e in confirmation["elements"]))
        now = self.clock()
        pickup_at = now + timedelta(minutes=int(pickup_minutes.group(1)) if pickup_minutes else option["pickup_minutes"])
        reference = "phone-booking-" + secrets.token_hex(4)
        self._bookings[reference] = dict(option, pickup_at=pickup_at, status="driver_assigned")
        return BackendBooking(reference=reference, confirmed=True, pickup_at=pickup_at,
                              dropoff_at=pickup_at + timedelta(minutes=option["trip_minutes"]),
                              vehicle_description=self._vehicle(confirmation))

    def status(self, booking_reference):
        booking = self._bookings.get(booking_reference)
        if booking is None:
            raise BackendError("unavailable", "no such booking on this phone")
        if booking["status"] in ("cancelled", "completed"):
            return self._status_record(booking)
        try:
            self.client.launch(booking["bundle"], "checking the %s ride the owner booked" % booking["name"])
        except PhoneRefusal as refusal:
            raise self._refused(refusal, "launch")
        screen = self._screen("checking the %s ride the owner booked" % booking["name"])
        text = " ".join(e.get("label") or "" for e in screen["elements"])
        if CANCELLED.search(text):
            booking["status"] = "cancelled"
        elif FINISHED.search(text):
            fare = minor_units(text)
            # finished but no fare on screen yet: still in progress until the receipt shows
            booking["status"] = "completed" if fare is not None else "in_progress"
            booking["final_fare"] = fare
        elif IN_TRIP.search(text):
            booking["status"] = "in_progress"
        elif ON_THE_WAY.search(text):
            booking["status"] = "driver_assigned"
            booking["vehicle"] = self._vehicle(screen) or booking.get("vehicle")
        return self._status_record(booking)

    def cancel(self, booking_reference, expected_fee_minor):
        booking = self._bookings.get(booking_reference)
        if booking is None:
            raise BackendError("unavailable", "no such booking on this phone")
        if booking["status"] in ("completed", "in_progress"):
            raise BackendError("not_cancellable", "the trip has started")
        reason = "cancelling the %s ride, as the owner asked" % booking["name"]
        try:
            self.client.launch(booking["bundle"], reason)
        except PhoneRefusal as refusal:
            raise self._refused(refusal, "launch")
        start = self._find_label(self._screen(reason), "cancel_ride_button")
        if start is None:
            raise BackendError("not_cancellable", "no cancel control on the trip screen")
        self._tap(start, reason)
        screen = self._screen(reason)
        confirm = self._find_label(screen, "confirm_cancel_button")
        if confirm is None:
            raise BackendError("down", "no confirmation after starting to cancel")
        text = " ".join(e.get("label") or "" for e in screen["elements"])
        fee = 0 if NO_FEE.search(text) else (minor_units(text) or expected_fee_minor)
        if fee > 0:
            # a cancellation fee is money: the owner approves it like a booking
            hold = None
            try:
                self._tap(confirm, reason, money=True)
            except PhoneRefusal as refusal:
                hold = refusal.hold
            if hold:
                self._wait_for_owner(hold)
                self._tap(confirm, reason, money=True, approval=hold)
        else:
            self._tap(confirm, reason)
        booking["status"] = "cancelled"
        return BackendCancellation(fee_minor=fee)

    # waiting on the owner -------------------------------------------------------------------

    def _wait_for_owner(self, hold):
        deadline = self.monotonic() + self.hold_wait_seconds
        while self.monotonic() < deadline:
            try:
                state = self.client.hold_state(hold)["state"]
            except PhoneRefusal as refusal:
                raise self._refused(refusal, "hold")
            if state == "approved":
                return
            if state in ("denied", "used"):
                raise BackendError("payment_declined", "the owner did not approve this purchase")
            self.sleep(self.poll_seconds)
        raise BackendError("payment_declined", "the owner did not answer the approval in time")

    def _wait_for_phone_approval(self, reason):
        """after the request tap, the phone shows its own face recognition or Apple Pay prompt. wait,
        touching nothing, until the owner answers it and the app shows the trip, or gives up."""
        deadline = self.monotonic() + self.phone_wait_seconds
        prompt_seen = False
        while self.monotonic() < deadline:
            screen = self._screen(reason)
            text = " ".join(e.get("label") or "" for e in screen["elements"])
            if screen.get("owner_approving_on_phone"):
                prompt_seen = True
            elif ON_THE_WAY.search(text):
                self._log("booked", phone_prompt_seen=prompt_seen)
                return screen
            elif prompt_seen:
                # the prompt went away and no trip appeared: the owner declined on the phone
                raise BackendError("payment_declined", "the phone's own payment approval was not given")
            self.sleep(self.poll_seconds)
        raise BackendError("payment_declined", "the phone's own payment approval was not answered in time")

    # reading screens ------------------------------------------------------------------------

    def _find_label(self, screen, wanted):
        for element in screen.get("elements", []):
            if role(element) == wanted:
                return element["label"]
        return None

    def _vehicle(self, screen):
        for element in screen.get("elements", []):
            label = element.get("label") or ""
            if element.get("type", "").endswith("StaticText") and label.count(",") >= 1 and not PRICE.search(label):
                return label
        return None

    def _status_record(self, booking):
        return BackendStatus(status=booking["status"], pickup_at=booking["pickup_at"],
                             dropoff_at=booking["pickup_at"] + timedelta(minutes=booking["trip_minutes"]),
                             vehicle_description=booking.get("vehicle"),
                             fare_minor=booking.get("final_fare"), tip_minor=0 if booking.get("final_fare") else None)


def build_connector(client=None, clock=system_clock, **options):
    """the ride connector over the iPhone backend. no payment reference is required: payment is a
    live approval on the phone, per purchase, not funds held through sirven."""
    backend = PhoneRideBackend(client=client, clock=clock, **options)
    return RideConnector({"phone": backend}, clock=clock, require_payment_reference=False), backend
