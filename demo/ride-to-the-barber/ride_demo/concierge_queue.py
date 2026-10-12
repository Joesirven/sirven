"""concierge queue: a stand-in for thread 10's queue tooling.

SUBSTITUTION. thread 10 (human-concierge operations for San Francisco) owns how ride
requests reach a concierge, how they are claimed, timed, and handed back. it had committed
nothing when this demo was built, so this is the smallest queue that lets a person operate
the concierge leg in rehearsal: one JSON file per request in a directory both processes can
read, every change made under a lock and written atomically.

a request moves through these states. the agent side writes the ones marked agent, the
concierge console writes the ones marked concierge, and each side only moves a request out
of a state it is waiting on, so a late answer can never overwrite a timeout.

  waiting_quote      agent       the trip, the user's consent, and the time it was asked
  quote_claimed      concierge   a named concierge took it; the name is shown to the user
  quoted             concierge   the price, pickup, and trip time the concierge saw
  waiting_booking    agent       the user approved; the capped test card is attached
  booking_claimed    concierge   the concierge is booking
  booked             concierge   the confirmation code and the fare actually charged
  declined           concierge   the concierge could not do it, with a reason
  withdrawn          agent       the agent stopped waiting (a missed target) or the user cancelled
"""

import fcntl
import json
import os
import secrets
from contextlib import contextmanager
from datetime import datetime

AGENT_STATES = ("waiting_quote", "waiting_booking", "withdrawn")
CONCIERGE_STATES = ("quote_claimed", "quoted", "booking_claimed", "booked", "declined")
OPEN_STATES = ("waiting_quote", "quote_claimed", "waiting_booking", "booking_claimed")


def now():
    return datetime.now().astimezone()


def stamp():
    return now().isoformat(timespec="milliseconds")


class QueueError(Exception):
    pass


class ConciergeQueue:
    def __init__(self, directory):
        self.directory = directory
        os.makedirs(directory, exist_ok=True)

    def _path(self, request_id):
        return os.path.join(self.directory, request_id + ".json")

    @contextmanager
    def _locked(self, request_id):
        with open(os.path.join(self.directory, request_id + ".lock"), "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)

    def _write(self, request):
        path = self._path(request["request_id"])
        temporary = path + ".tmp"
        with open(temporary, "w") as handle:
            json.dump(request, handle, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(temporary, path)

    def read(self, request_id):
        with open(self._path(request_id)) as handle:
            return json.load(handle)

    def create(self, trip, consent):
        request_id = "req_" + secrets.token_hex(4)
        request = {
            "request_id": request_id,
            "state": "waiting_quote",
            "trip": trip,
            "consent": consent,
            "history": [{"state": "waiting_quote", "at": stamp()}],
        }
        with self._locked(request_id):
            self._write(request)
        return request

    def move(self, request_id, expected, new_state, **fields):
        """move a request from one of the expected states to new_state, adding fields.
        raises QueueError when the request is in any other state."""
        if isinstance(expected, str):
            expected = (expected,)
        with self._locked(request_id):
            request = self.read(request_id)
            if request["state"] not in expected:
                raise QueueError("request %s is %s, not %s" % (request_id, request["state"], " or ".join(expected)))
            request.update(fields)
            request["state"] = new_state
            request["history"].append({"state": new_state, "at": stamp()})
            self._write(request)
            return request

    def list(self, states=OPEN_STATES):
        found = []
        for name in sorted(os.listdir(self.directory)):
            if name.endswith(".json"):
                request = self.read(name[: -len(".json")])
                if request["state"] in states:
                    found.append(request)
        return found

    @staticmethod
    def entered(request, state):
        """when the request entered a state, as a datetime, or None."""
        for entry in request["history"]:
            if entry["state"] == state:
                return datetime.fromisoformat(entry["at"])
        return None
