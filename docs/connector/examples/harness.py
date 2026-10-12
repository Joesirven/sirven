#!/usr/bin/env python3
"""a client harness for the sirven ride connector, run against the fake demo backends.

    python3 docs/connector/examples/harness.py              every scenario, in order
    python3 docs/connector/examples/harness.py barber       one scenario (barber, budget, cancel, blocked)
    python3 docs/connector/examples/harness.py --json ...   also print every raw tool result

it starts the connector's model context protocol server as a child process and talks to it over
standard input and output, one JSON message per line, exactly as an agent would. nothing here
imports the connector's internals except fake_blocked_server.py, which starts the same server with
every fake backend set to refuse agents. no network, no money: the fake backends price rides from
straight-line distance, and the server runs on the real clock, so every scenario asks for a pickup
tomorrow between 3:00 and 3:20 pm in this machine's time zone.

needs python 3.8 or newer and nothing else. the connector lives in connectors/ride; set
SIRVEN_RIDE_CONNECTOR_DIR to point somewhere else.

every scenario checks what it expects and the harness exits 1 if any check fails, so it doubles
as a smoke test of the published contract.
"""

import json
import os
import subprocess
import sys
from datetime import datetime, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
CONNECTOR_DIR = os.environ.get("SIRVEN_RIDE_CONNECTOR_DIR", os.path.join(REPO, "connectors", "ride"))

SHOW_JSON = False


class Connector:
    """a minimal model context protocol client for the ride connector's server over standard input and output."""

    def __init__(self, command):
        if not os.path.isdir(os.path.join(CONNECTOR_DIR, "ride_connector")):
            sys.exit("harness: no ride connector at %s. set SIRVEN_RIDE_CONNECTOR_DIR." % CONNECTOR_DIR)
        environment = dict(os.environ, PYTHONPATH=CONNECTOR_DIR, PYTHONDONTWRITEBYTECODE="1")
        self.process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        env=environment, universal_newlines=True)
        self.next_id = 0
        self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                    "clientInfo": {"name": "sirven-ride-harness", "version": "1"}})
        self.notify("notifications/initialized")
        self.tools = [tool["name"] for tool in self.request("tools/list")["tools"]]

    def request(self, method, params=None):
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            message["params"] = params
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()
        reply = json.loads(self.process.stdout.readline())
        if "error" in reply:
            raise RuntimeError("%s failed: %s" % (method, reply["error"]))
        return reply["result"]

    def notify(self, method):
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method}) + "\n")
        self.process.stdin.flush()

    def call(self, tool, arguments):
        """returns the structured result. an error result has an "error" key instead of data."""
        result = self.request("tools/call", {"name": tool, "arguments": arguments})
        payload = result["structuredContent"]
        if SHOW_JSON:
            print("    %s -> %s" % (tool, json.dumps(payload, indent=2, sort_keys=True).replace("\n", "\n    ")))
        return payload

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)


def demo_server():
    return Connector([sys.executable, "-m", "ride_connector.server"])


def blocked_server():
    return Connector([sys.executable, os.path.join(HERE, "fake_blocked_server.py")])


# what a person hears --------------------------------------------------------------------

def dollars(money):
    return "%d.%02d %s" % (money["amount_minor"] // 100, money["amount_minor"] % 100,
                           "dollars" if money["currency"] == "USD" else money["currency"])


def clock(timestamp):
    hour, minute = int(timestamp[11:13]), timestamp[14:16]
    return "%d:%s" % (hour % 12 or 12, minute)


def describe(option):
    """one option in plain words: who, how much, pickup, arrival, and any flag worth saying."""
    price = option["price"]
    if price["kind"] == "estimate":
        cost = "about %s, at most %s" % (dollars(price["amount"]), dollars(price["maximum"]))
    else:
        cost = dollars(price["amount"])
    line = "%s (%s), %s, picks up around %s, arrives around %s" % (
        option["provider"], option["vehicle_class"], cost,
        clock(option["estimated_pickup_at"]), clock(option["estimated_dropoff_at"]))
    said = {
        "over_budget": "over your limit once the tip allowance is counted",
        "outside_departure_window": "outside the time you asked for",
        "accessibility_not_met": "does not meet your accessibility needs",
        "surge_pricing": "busy-time pricing",
    }
    notes = [said[flag] for flag in option["constraint_flags"] if flag in said]
    return line + ("; " + "; ".join(notes) if notes else "")


def say(text):
    print("  agent to person: " + text)


def step(text):
    print("  " + text)


# checks ---------------------------------------------------------------------------------

FAILURES = []


def expect(condition, what):
    if not condition:
        FAILURES.append(what)
        print("  CHECK FAILED: " + what)


# the scenarios ----------------------------------------------------------------------------

OFFICE = {"label": "office", "address": "1 Ferry Building, San Francisco",
          "coordinates": {"latitude": 37.7955, "longitude": -122.3937}}
BARBER = {"label": "barber", "address": "Valencia Street and 18th Street, San Francisco",
          "coordinates": {"latitude": 37.7617, "longitude": -122.4216}}


def after_meeting():
    """the 2pm meeting ends at 3pm tomorrow; the person wants a pickup from 3:00 to 3:20."""
    tomorrow = (datetime.now().astimezone() + timedelta(days=1)).replace(second=0, microsecond=0)
    earliest = tomorrow.replace(hour=15, minute=0)
    return {"earliest": earliest.isoformat(), "latest": (earliest + timedelta(minutes=20)).isoformat()}


AFTER_MEETING = after_meeting()


def barber():
    """book a ride after the 2pm meeting, Waymo preferred, under 25 dollars."""
    connector = demo_server()
    step("quote_ride: office to barber, pickup 3:00 to 3:20, Waymo preferred, at most 25 dollars")
    quote = connector.call("quote_ride", {
        "origin": OFFICE,
        "destination": BARBER,
        "departure_window": AFTER_MEETING,
        "user_preferences": {"preferred_providers": ["Waymo"]},
        "budget_ceiling": {"amount_minor": 2500, "currency": "USD"},
    })
    options = quote["options"]
    expect(options and options[0]["provider"] == "Waymo", "the preferred provider ranks first")
    best = options[0]
    say("The best match is " + describe(best) + ".")
    if len(options) > 1:
        say("Also available: " + "; ".join(describe(option) for option in options[1:3]) + ".")
    if best["fulfillment"]["method"] == "human_assisted":
        say(best["fulfillment"]["disclosure"])
    say("Book the %s for %s? You can cancel free until %s." % (
        best["provider"], dollars(best["charge_terms"]["authorization_cap"]),
        clock(best["cancellation_policy"]["free_until"])))
    step("the person says yes")

    step("book_ride with the top quote_id")
    booked = connector.call("book_ride", {"quote_id": best["quote_id"]})
    booking = booked["booking"]
    expect(booking["status"] in ("requested", "confirmed"), "a fresh booking is requested or confirmed")
    if booking["status"] == "requested":
        expect(booking["confirm_by"] is not None, "a requested booking says when it will be confirmed by")
        say("Requested. The %s is not confirmed yet; I will tell you by %s, and I will look for "
            "another ride if it is not." % (booking["provider"], clock(booking["confirm_by"])))
    else:
        say("Booked. Pickup around %s." % clock(booking["estimated_pickup_at"]))

    step("book_ride again with the same quote_id, as if the first reply had been lost")
    again = connector.call("book_ride", {"quote_id": best["quote_id"]})
    expect(again.get("replayed") is True, "a repeated book_ride replays instead of booking twice")
    expect(again["booking"]["booking_id"] == booking["booking_id"], "the replay returns the same booking")
    step("replayed: true, same booking_id %s. one ride, not two." % booking["booking_id"])

    step("get_ride to follow it")
    status = connector.call("get_ride", {"booking_id": booking["booking_id"]})
    step("status: %s (poll every %d seconds)" % (status["booking"]["status"],
                                                  status["booking"]["tracking"]["poll_interval_seconds"]))
    connector.close()


def budget():
    """a quote where the budget ceiling, tip allowance included, rules out most options."""
    connector = demo_server()
    step("quote_ride: same trip, cheapest first, at most 11 dollars all in")
    quote = connector.call("quote_ride", {
        "origin": OFFICE,
        "destination": BARBER,
        "departure_window": AFTER_MEETING,
        "user_preferences": {"ranking": "cheapest"},
        "budget_ceiling": {"amount_minor": 1100, "currency": "USD"},
    })
    options = quote["options"]
    bookable = [option for option in options if option["bookable"]]
    over = [option for option in options if "over_budget" in option["constraint_flags"]]
    expect(bookable and over, "some options fit the budget and some do not")
    expect(all(not option["bookable"] for option in options[len(bookable):]), "bookable options rank first")
    say("Within 11 dollars: " + "; ".join(describe(option) for option in bookable) + ".")
    say("Over the limit once a tip is allowed for: " + "; ".join(
        "%s (%s), up to %s with tip" % (option["provider"], option["vehicle_class"],
                                         dollars(option["charge_terms"]["authorization_cap"]))
        for option in over) + ".")
    if bookable and bookable[0]["fulfillment"]["method"] == "human_assisted":
        say(bookable[0]["fulfillment"]["disclosure"])

    step("book_ride on an over-budget option, to show the connector refuses it")
    refused = connector.call("book_ride", {"quote_id": over[0]["quote_id"]})
    expect(refused.get("error", {}).get("code") == "over_budget", "booking an over-budget option fails with over_budget")
    step("error %s: %s" % (refused["error"]["code"], refused["error"]["message"]))
    say("That one costs more than your 11 dollar limit once a tip is allowed for. "
        "Do you want to raise the limit, or take the %s?" % bookable[0]["provider"])
    connector.close()


def cancel():
    """book an automated ride, cancel it inside the free window, and cancel it again."""
    connector = demo_server()
    step("quote_ride: same trip, Lyft preferred, at most 25 dollars")
    quote = connector.call("quote_ride", {
        "origin": OFFICE,
        "destination": BARBER,
        "departure_window": AFTER_MEETING,
        "user_preferences": {"preferred_providers": ["Lyft"], "vehicle_classes": ["standard"]},
        "budget_ceiling": {"amount_minor": 2500, "currency": "USD"},
    })
    # equal options tie at random, so take the first one that is the class the person asked for.
    option = next(option for option in quote["options"]
                  if "vehicle_class_not_requested" not in option["constraint_flags"])
    step("book_ride: " + describe(option))
    booking = connector.call("book_ride", {"quote_id": option["quote_id"]})["booking"]
    expect(booking["status"] == "confirmed", "an automated booking is confirmed straight away")
    say("Booked. %s picks you up around %s. Free cancellation until %s." % (
        booking["provider"], clock(booking["estimated_pickup_at"]), clock(booking["cancellation_policy"]["free_until"])))

    step("the person's meeting runs long. the agent asks, the person says cancel.")
    step("cancel_ride with reason plans_changed")
    cancelled = connector.call("cancel_ride", {"booking_id": booking["booking_id"], "reason": "plans_changed"})
    charge = cancelled["booking"]["final_charge"]
    expect(cancelled["booking"]["status"] == "cancelled", "the booking is cancelled")
    expect(charge["cancellation_fee"]["amount_minor"] == 0, "cancelling inside the free window costs nothing")
    say("Cancelled. No fee; the %s held for it is released." % dollars(charge["amount_to_release"]))

    step("cancel_ride again, as if the first reply had been lost")
    again = connector.call("cancel_ride", {"booking_id": booking["booking_id"]})
    expect(again.get("already_cancelled") is True, "a repeated cancel_ride reports already_cancelled")
    step("already_cancelled: true. nothing else happens.")
    connector.close()


def blocked():
    """every ride service refuses agents. the connector says so and does not route around it."""
    connector = blocked_server()
    step("quote_ride against fake backends that all refuse agents")
    quote = connector.call("quote_ride", {
        "origin": OFFICE,
        "destination": BARBER,
        "departure_window": AFTER_MEETING,
        "budget_ceiling": {"amount_minor": 2500, "currency": "USD"},
    })
    error = quote.get("error", {})
    expect(error.get("code") == "blocked", "an all-refusing quote fails with blocked")
    expect(error.get("retryable") is False, "blocked is not retryable")
    step("error %s, retryable %s: %s" % (error.get("code"), error.get("retryable"), error.get("message")))
    say("I could not get you a ride: the ride services for this trip refuse requests from agents, "
        "and I do not work around that. You can still book it yourself in the ride service's own app.")
    connector.close()


SCENARIOS = [
    ("barber", barber),
    ("budget", budget),
    ("cancel", cancel),
    ("blocked", blocked),
]


def main(argv):
    global SHOW_JSON
    if "--json" in argv:
        SHOW_JSON = True
        argv = [arg for arg in argv if arg != "--json"]
    known = dict(SCENARIOS)
    chosen = argv or [name for name, _ in SCENARIOS]
    for name in chosen:
        if name not in known:
            sys.exit("harness: unknown scenario %r. pick from: %s" % (name, ", ".join(known)))
    for name in chosen:
        print("\n== %s: %s" % (name, known[name].__doc__.strip()))
        known[name]()
    print()
    if FAILURES:
        print("harness: %d check(s) failed" % len(FAILURES))
        return 1
    print("harness: every check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
