#!/usr/bin/env python3
"""Serve the tier dial, consent moment, site list, and usage meter on this Mac only.

Reads the runtime state (thread 01), the reciprocity ledger (thread 04), and the site
registry (thread 05) from the fakes in app/fakes until those interfaces land. The shapes
are documented in docs/app-interfaces.md. Listens on the loopback address only.
"""
import argparse
import copy
import json
import posixpath
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

APP_DIR = Path(__file__).resolve().parent
REPO_DIR = APP_DIR.parent
FAKES = APP_DIR / "fakes"
TIERS = ("solo", "neighborly", "coop")
OPEN_TIERS = ("solo", "neighborly")
# how the consent moment ended: a choice either way, closed without choosing, or shown while
# Neighborly was not open yet. any of these means sirven does not ask again on later blocks.
DECISIONS = ("solo", "neighborly", "dismissed", "not_open")

# each scenario picks one fake per interface, so every surface can be shown in each state.
SCENARIOS = {
    "first-block": ("solo-blocked", "solo-empty", "sample"),
    "first-block-gated": ("solo-blocked", "solo-empty", "empty"),
    "solo": ("solo-quiet", "solo-empty", "sample"),
    "neighborly": ("neighborly", "under", "sample"),
    "near-cap": ("neighborly", "near", "sample"),
    "over-cap": ("neighborly", "over", "sample"),
    "empty-list": ("solo-quiet", "solo-empty", "empty"),
}


def load(kind, name):
    return json.loads((FAKES / kind / f"{name}.json").read_text())


class Fake:
    """In-memory stand-in for the three interfaces. Nothing is written to disk."""

    def __init__(self, scenario, peer_preview, growth):
        runtime, ledger, registry = SCENARIOS[scenario]
        self.lock = threading.Lock()
        self.runtime = load("runtime", runtime)
        self.ledger = load("ledger", ledger)
        self.registry = load("registry", registry)
        if peer_preview:
            self.runtime["peer_routing_available"] = True
        self.growth = growth
        self.started = time.monotonic()

    def state(self):
        with self.lock:
            return copy.deepcopy(self.runtime)

    def usage(self):
        with self.lock:
            ledger = copy.deepcopy(self.ledger)
            tier = self.runtime["tier"]
        if tier == "solo" or not self.growth:
            return ledger
        # an open session keeps carrying while the page is open, so the meter moves the way
        # the real ledger will, and stops at the cap the way enforcement will.
        room = ledger["cap_bytes"] - ledger["used_bytes"]
        grown = min(room, int((time.monotonic() - self.started) * self.growth))
        live = next((s for s in ledger["sessions"] if s["ended_at"] is None), None)
        if grown > 0 and live:
            live["bytes"] += grown
            ledger[f"{live['direction']}_bytes"] += grown
            ledger["used_bytes"] += grown
        if ledger["used_bytes"] >= ledger["cap_bytes"]:
            ledger["state"] = "over"
        return ledger

    def set_tier(self, tier):
        with self.lock:
            if tier not in TIERS:
                return 400, {"error": "unknown_tier"}
            if tier not in OPEN_TIERS:
                return 409, {"error": "tier_not_open"}
            # the first ship gate: no peer routing until signing and site review both work.
            if tier != "solo" and not self.runtime["peer_routing_available"]:
                return 409, {"error": "peer_routing_unavailable"}
            self.runtime["tier"] = tier
            return 200, copy.deepcopy(self.runtime)

    def record_consent(self, decision):
        with self.lock:
            if decision not in DECISIONS:
                return 400, {"error": "unknown_decision"}
            self.runtime["consent"] = {"prompted": True, "decision": decision}
            return 200, copy.deepcopy(self.runtime)


class Handler(SimpleHTTPRequestHandler):
    fake = None

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(REPO_DIR), **kwargs)

    def log_message(self, *args):
        pass

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = posixpath.normpath(unquote(self.path.split("?", 1)[0]))
        routes = {"/api/state": self.fake.state, "/api/ledger": self.fake.usage,
                  "/api/registry": lambda: copy.deepcopy(self.fake.registry)}
        if path in routes:
            return self.send_json(200, routes[path]())
        if path == "/":
            path = "/app/index.html"
        # only the app and the copy files are served; the rest of the repository is not.
        if not (path.startswith("/app/") or path.startswith("/copy/")) or path.startswith("/app/serve"):
            return self.send_error(404)
        self.path = path
        return super().do_GET()

    def do_POST(self):
        try:
            length = min(int(self.headers.get("Content-Length", 0)), 4096)
            body = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, TypeError):
            return self.send_json(400, {"error": "invalid_request"})
        if not isinstance(body, dict):
            return self.send_json(400, {"error": "invalid_request"})
        if self.path == "/api/tier":
            return self.send_json(*self.fake.set_tier(body.get("tier")))
        if self.path == "/api/consent":
            return self.send_json(*self.fake.record_consent(body.get("decision")))
        return self.send_error(404)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=7420)
    parser.add_argument("--scenario", choices=sorted(SCENARIOS), default="first-block")
    parser.add_argument("--peer-preview", action="store_true",
                        help="pretend signing and site review are live, so the consent moment can finish (fakes only)")
    parser.add_argument("--growth", type=int, default=400000,
                        help="bytes per second an open fake session grows by; 0 holds the meter still")
    args = parser.parse_args()
    Handler.fake = Fake(args.scenario, args.peer_preview, args.growth)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"sirven app: http://127.0.0.1:{args.port}/  scenario {args.scenario}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
