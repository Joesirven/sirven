"""The decision log: one JSON line per request the runtime decided on.

Usage metadata only, never content: the host and port, the channel, the method when it is
visible, the decision, the outcome, and byte counts. No path, no query, no headers, no body.
The usage meter and the tier dial read it through GET /v1/decisions or from the file itself.
"""

import json
import os
import threading
import time

KEEP_IN_MEMORY = 1000


class DecisionLog:
    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.sequence = 0
        self.recent = []
        self.totals = {}
        if path:
            directory = os.path.dirname(path)
            if directory:
                os.makedirs(directory, mode=0o700, exist_ok=True)

    def record(self, request, decision, outcome, status=None, bytes_sent=0, bytes_received=0, block_kind=None,
               approval=None):
        now = time.time()
        with self.lock:
            self.sequence += 1
            entry = {
                "sequence": self.sequence,
                "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
                "channel": request.channel,
                "host": request.host,
                "port": request.port,
                "method": request.method,
                "tier": request.tier,
                "redirect_hop": request.redirect_hop,
                "route": decision.route,
                "reason": decision.reason,
                "policy": decision.policy,
                "outcome": outcome,
                "status": status,
                "block_kind": block_kind,
                "approval": approval,
                "bytes_sent": bytes_sent,
                "bytes_received": bytes_received,
            }
            self.totals[outcome] = self.totals.get(outcome, 0) + 1
            self.recent.append(entry)
            del self.recent[:-KEEP_IN_MEMORY]
            if self.path:
                descriptor = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
                with os.fdopen(descriptor, "a", encoding="utf-8") as handle:
                    handle.write(json.dumps(entry, sort_keys=True) + "\n")
            return entry

    def after(self, sequence, limit=100):
        with self.lock:
            entries = [entry for entry in self.recent if entry["sequence"] > sequence]
        return entries[:limit]

    def counts(self):
        """Outcomes since the runtime started."""
        with self.lock:
            return dict(self.totals)
