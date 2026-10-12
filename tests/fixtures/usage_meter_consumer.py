#!/usr/bin/env python3
"""a test consumer of the reciprocity read-out, standing in for the usage meter.

it reads the JSON that `lib/reciprocity.py read` prints from standard input and knows nothing
else about the ledger: if a field it relies on goes missing or changes type, it fails loudly,
which is the point. it prints a meter line, the summary, and one line per session and refusal.
"""

import json
import sys

REQUIRED = {
    "schema_version": int, "tier": str, "period": dict, "cap_bytes": int, "used_bytes": int,
    "carried_bytes": int, "sent_bytes": int, "reserved_bytes": int, "remaining_bytes": int,
    "percent_used": int, "summary": str, "sessions": list, "refusals": list, "disagreements": list,
    "stop_pairing_with": list,
}
PERIOD = {"label": str, "starts_at": int, "resets_at": int, "resets_on": str}
SESSION = {"session": str, "direction": str, "domain": str, "bytes": int, "first_at": int,
           "last_at": int, "summary": str}
REFUSAL = {"session": str, "direction": str, "domain": str, "requested_bytes": int, "at": int,
           "reason": str}


def require(record, shape, where):
    for field, kind in shape.items():
        if not isinstance(record.get(field), kind) or isinstance(record.get(field), bool):
            sys.exit("contract broken: %s.%s should be %s, got %r" % (where, field, kind.__name__, record.get(field)))


def main():
    readout = json.load(sys.stdin)
    require(readout, REQUIRED, "readout")
    if readout["schema_version"] != 1:
        sys.exit("contract broken: unknown schema_version %r" % readout["schema_version"])
    require(readout["period"], PERIOD, "period")
    for session in readout["sessions"]:
        require(session, SESSION, "session")
    for refusal in readout["refusals"]:
        require(refusal, REFUSAL, "refusal")
    if readout["carried_bytes"] + readout["sent_bytes"] != readout["used_bytes"]:
        sys.exit("contract broken: carried plus sent is not used")

    width = 20
    filled = readout["percent_used"] * width // 100
    print("meter [%s%s] %d%% of the cap, %s" % (
        "#" * filled, "." * (width - filled), readout["percent_used"], readout["period"]["label"]))
    print("summary %s" % readout["summary"])
    for session in readout["sessions"]:
        print("session %s" % session["summary"])
    for refusal in readout["refusals"]:
        print("refused %s" % refusal["reason"])
    for peer in readout["stop_pairing_with"]:
        print("stop pairing with %s" % peer)


if __name__ == "__main__":
    main()
