"""the two ship gates, checked on every run and printed with the result.

the rehearsal runs whatever the gates say: it demonstrates them, it does not waive them. a
live fire refuses to start unless the concierge gate is fully open.

  "Do not ship any peer routing of authenticated traffic until the attestation layer and the
  site-allowlist review workflow are both working end to end."
  "Do not ship the human-concierge tier until the service-level targets, the concierge trust
  and safety protocol, and the user-facing disclosure of concierge involvement are all in place."
"""

import os
import re

from . import service_levels


def _find(directory, words):
    if not os.path.isdir(directory):
        return []
    found = []
    for root, _, files in os.walk(directory):
        for name in files:
            if any(word in name.lower() for word in words):
                found.append(os.path.relpath(os.path.join(root, name), os.path.dirname(directory)))
    return sorted(found)


def copy_status(copy_path):
    with open(copy_path) as handle:
        match = re.search(r"^status: (.+)$", handle.read(), re.MULTILINE)
    return match.group(1).strip() if match else "missing"


def concierge_gate(repo_dir, copy_path):
    operations = os.path.join(repo_dir, "concierge-ops")
    monitoring = _find(operations, ("service-level", "service_level", "monitor"))
    protocol = _find(operations, ("trust",))
    status = copy_status(copy_path)
    items = [
        {
            "item": "service-level targets",
            "in_place": bool(monitoring),
            "detail": ("targets of %d seconds to quote and %d to book are enforced in this demo; thread 10's "
                       "monitoring: %s" % (service_levels.QUOTE_TARGET_SECONDS, service_levels.BOOKING_TARGET_SECONDS,
                                           ", ".join(monitoring) if monitoring else "not committed yet (thread 10)")),
        },
        {
            "item": "concierge trust and safety protocol",
            "in_place": bool(protocol),
            "detail": ", ".join(protocol) if protocol else "not committed yet (thread 10, under concierge-ops/)",
        },
        {
            "item": "user-facing disclosure of concierge involvement",
            "in_place": status == "approved",
            "detail": "%s is '%s'; it passes at 'approved', which is Jose's call" % (
                os.path.relpath(copy_path, repo_dir), status),
        },
    ]
    return {"gate": "human-concierge tier", "open": all(item["in_place"] for item in items), "items": items}


def peer_routing_gate():
    return {
        "gate": "peer routing of authenticated traffic",
        "open": False,
        "items": [{"item": "not exercised", "in_place": None,
                   "detail": "this run is Solo: every request leaves from the user's own connection, none through a peer"}],
    }


def describe(gate):
    lines = ["%s: %s" % (gate["gate"], "open" if gate["open"] else "CLOSED, not shippable")]
    for item in gate["items"]:
        mark = {True: "x", False: " ", None: "-"}[item["in_place"]]
        lines.append("  [%s] %s: %s" % (mark, item["item"], item["detail"]))
    return lines
