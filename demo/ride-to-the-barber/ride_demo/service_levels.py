"""service-level targets for the concierge leg, and the per-request timings against them.

the targets come from Jose's scope as carried in the thread 10 instructions: a quote in under
30 seconds, a booking in under 90 seconds. thread 10 owns monitoring and breach alerts; until
it lands, every measurement is appended to service-levels.jsonl in the run's state directory
and printed in the run, so a breach is never silent.
"""

import json
import os

QUOTE_TARGET_SECONDS = 30
BOOKING_TARGET_SECONDS = 90


def measure(log_path, request_id, leg, started, finished, target_seconds):
    seconds = round((finished - started).total_seconds(), 1)
    entry = {
        "request_id": request_id,
        "leg": leg,
        "seconds": seconds,
        "target_seconds": target_seconds,
        "met": seconds < target_seconds,
        "started": started.isoformat(timespec="milliseconds"),
        "finished": finished.isoformat(timespec="milliseconds"),
    }
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, "a") as handle:
        handle.write(json.dumps(entry, sort_keys=True) + "\n")
    return entry


def missed(log_path, request_id, leg, started, target_seconds):
    """record a leg that never finished inside its target."""
    entry = {
        "request_id": request_id,
        "leg": leg,
        "seconds": None,
        "target_seconds": target_seconds,
        "met": False,
        "started": started.isoformat(timespec="milliseconds"),
        "finished": None,
    }
    with open(log_path, "a") as handle:
        handle.write(json.dumps(entry, sort_keys=True) + "\n")
    return entry


def describe(entry):
    if entry["seconds"] is None:
        return "%s: no answer inside the %d second target (missed)" % (entry["leg"], entry["target_seconds"])
    verdict = "met" if entry["met"] else "MISSED"
    return "%s: %.1f seconds against a %d second target (%s)" % (
        entry["leg"], entry["seconds"], entry["target_seconds"], verdict)
