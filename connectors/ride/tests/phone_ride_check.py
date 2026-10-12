"""the iPhone ride backend end to end: the real ride connector gateway, the real phone bridge, and
the fake phone in world mode. tests/unit/test_phone_ride.sh starts the phone and the bridge, then
runs this with a scenario name. it prints one line per step and exits 0 when the scenario held.

the test plays the owner from inside the backend's sleep: when a hold is waiting it runs
sirven phone approve (or deny), and when the phone shows its own payment sheet it creates the
fake's owner_approves (or owner_declines) file. nothing here touches the sheet through the bridge.

  phone_ride_check.py SCENARIO     approve, deny_hold, decline_on_phone, price_rose, cancel
"""

import json
import os
import subprocess
import sys

from helpers import HERE, VALIDATOR, quote_arguments, BARBER, ORIGIN  # noqa: F401

sys.path.insert(0, os.path.dirname(HERE))
from ride_connector.gateway import system_clock  # noqa: E402
from ride_phone import PhoneClient, build_connector  # noqa: E402

REPO_DIR = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
FAKE = os.environ["FAKE"]
SCENARIO = sys.argv[1]


def sirven(*arguments):
    return subprocess.run([os.path.join(REPO_DIR, "bin", "sirven"), "phone"] + list(arguments),
                          capture_output=True, text=True)


def waiting_holds():
    lines = sirven("holds").stdout.splitlines()
    return [line.split()[0] for line in lines if line and not line.startswith("nothing")]


def world_screen():
    with open(os.path.join(FAKE, "world-state.json")) as handle:
        return json.load(handle)["screen"]


class Owner:
    """the owner, acting between the backend's polls."""

    def __init__(self, scenario):
        self.scenario = scenario
        self.decisions = []

    def __call__(self, seconds):
        for hold in waiting_holds():
            verb = "deny" if self.scenario == "deny_hold" else "approve"
            sirven(verb, hold)
            self.decisions.append(verb)
            return
        if world_screen() == "pay_sheet":
            name = "owner_declines" if self.scenario == "decline_on_phone" else "owner_approves"
            open(os.path.join(FAKE, name), "w").close()
            self.decisions.append(name)


def call(connector, tool, arguments):
    is_error, payload = connector.call(tool, arguments)
    definition = "error_output" if is_error else tool + "_output"
    problems = VALIDATOR.validate(payload, definition)
    if problems:
        raise SystemExit("contract violation in %s: %s" % (tool, problems))
    return is_error, payload


def main():
    owner = Owner(SCENARIO)
    connector, backend = build_connector(client=PhoneClient(url=os.environ["BRIDGE"]), clock=system_clock,
                                         poll_seconds=0, sleep=owner, hold_wait_seconds=30, phone_wait_seconds=30)
    is_error, quotes = call(connector, "quote_ride", quote_arguments(system_clock, budget=2500))
    assert not is_error, (quotes, backend.private_log, connector.private_log)
    providers = sorted({option["provider"] for option in quotes["options"]})
    print("quoted:", ", ".join("%s %s" % (o["provider"], o["price"]["amount"]["amount_minor"]) for o in quotes["options"]))
    print("providers:", providers)
    uber = [o for o in quotes["options"] if o["provider"] == "Uber" and o["bookable"]]
    cheapest = min(uber, key=lambda o: o["price"]["amount"]["amount_minor"])
    if SCENARIO == "price_rose":
        world_path = os.path.join(FAKE, "world.json")
        with open(world_path) as handle:
            world = handle.read()
        with open(world_path, "w") as handle:
            handle.write(world.replace("$18.40", "$19.90"))
    is_error, booking = call(connector, "book_ride", {"quote_id": cheapest["quote_id"]})
    print("owner did:", owner.decisions)
    if SCENARIO in ("approve", "cancel"):
        assert not is_error, booking
        print("booked:", booking["booking"]["status"], booking["booking"]["tracking"]["vehicle_description"])
        assert owner.decisions == ["approve", "owner_approves"], owner.decisions
        is_error, ride = call(connector, "get_ride", {"booking_id": booking["booking"]["booking_id"]})
        assert not is_error, ride
        print("status:", ride["booking"]["status"])
        if SCENARIO == "cancel":
            is_error, cancelled = call(connector, "cancel_ride", {"booking_id": booking["booking"]["booking_id"]})
            assert not is_error, cancelled
            print("cancelled:", cancelled["booking"]["status"])
            assert world_screen() == "cancelled", world_screen()
    else:
        assert is_error, booking
        print("error:", booking["error"]["code"])
    log = sirven("log").stdout
    leaked = [word for word in ("com.ubercab", "phone-option", "phone-booking", "Request UberX")
              if word in json.dumps(quotes) + json.dumps(booking)]
    assert not leaked, leaked
    print("log lines:", len(log.splitlines()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
