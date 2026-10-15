#!/usr/bin/env python3
"""a fake Cloudflare API that keeps real state, for the tests of lib/cloudflare_tunnel.sh and lib/cloudflare_api.py.

  python3 api_server.py DIR --token TOKEN --account ACCOUNT --zone-name NAME --zone ZONE [--port-file FILE]

it listens on 127.0.0.1 on a free port, writes the port to DIR/port, and keeps its whole state in DIR/state.json (tunnels,
records) and every request in DIR/calls.log: "METHOD PATH authorized|unauthorized", never a token. it answers only to the
one token it was started with. the shapes follow the documented API: a locally managed tunnel needs config_src "local" and a
tunnel_secret of at least 32 bytes in base64, a tunnel with connections cannot be deleted until they are ended, deleting a
tunnel keeps it visible with deleted_at set, and a record is an alias to TUNNEL.cfargotunnel.com.
knobs (a file in DIR, read on every request): refuse-records, fail-tunnel-delete, connections-stay (the tunnel reports
connections that the cleanup call does not end, so delete fails).
"""
import argparse
import base64
import json
import os
import re
import sys
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

parser = argparse.ArgumentParser()
parser.add_argument("directory")
parser.add_argument("--token", required=True)
parser.add_argument("--account", required=True)
parser.add_argument("--zone", required=True)
parser.add_argument("--zone-name", required=True)
options = parser.parse_args()
DIR = options.directory
STATE = {"tunnels": {}, "records": {}}
STATE_FILE = os.path.join(DIR, "state.json")
if os.path.exists(STATE_FILE):
    with open(STATE_FILE) as handle:
        STATE = json.load(handle)


def knob(name):
    return os.path.exists(os.path.join(DIR, name))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, status, result=None, errors=None):
        body = json.dumps({"success": not errors, "errors": errors or [], "messages": [], "result": result}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def fail(self, status, code, message):
        self.send(status, None, [{"code": code, "message": message}])

    def payload(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length).decode() or "{}") if length else {}

    def handle_any(self, method):
        url = urlsplit(self.path)
        path, query = url.path, {k: v[0] for k, v in parse_qs(url.query).items()}
        authorized = self.headers.get("Authorization") == "Bearer " + options.token
        with open(os.path.join(DIR, "calls.log"), "a") as log:
            log.write("%s %s %s\n" % (method, self.path, "authorized" if authorized else "unauthorized"))
        body = self.payload() if method in ("POST", "PUT") else {}
        # a test may change the state file between two requests (the owner editing a record in the dashboard): read it again
        if os.path.exists(STATE_FILE):
            with open(STATE_FILE) as handle:
                STATE.clear()
                STATE.update(json.load(handle))
        if not authorized:
            return self.fail(403, 9109, "Invalid access token")
        try:
            self.route(method, path, query, body)
        finally:
            with open(STATE_FILE, "w") as handle:
                json.dump(STATE, handle, sort_keys=True)

    def route(self, method, path, query, body):
        tunnels, records = STATE["tunnels"], STATE["records"]
        base = "/accounts/%s/cfd_tunnel" % options.account
        if path == base and method == "GET":
            found = [t for t in tunnels.values()
                     if (query.get("name") is None or t["name"] == query["name"])
                     and not (query.get("is_deleted") == "false" and t.get("deleted_at"))]
            return self.send(200, found)
        if path == base and method == "POST":
            secret = body.get("tunnel_secret", "")
            try:
                enough = len(base64.b64decode(secret, validate=True)) >= 32
            except ValueError:
                enough = False
            if body.get("config_src") != "local" or not enough or not body.get("name"):
                return self.fail(400, 1001, "a locally managed tunnel needs config_src local and a 32 byte base64 tunnel_secret")
            if any(t["name"] == body["name"] and not t.get("deleted_at") for t in tunnels.values()):
                return self.fail(409, 1013, "a tunnel with that name already exists")
            made = str(uuid.uuid4())
            tunnels[made] = {"id": made, "name": body["name"], "account_tag": options.account, "config_src": "local",
                             "deleted_at": None, "connected": True}
            return self.send(200, tunnels[made])
        match = re.match(r"^" + re.escape(base) + r"/([0-9a-f-]{36})(/connections)?$", path)
        if match:
            tunnel = tunnels.get(match.group(1))
            if tunnel is None:
                return self.fail(404, 1003, "tunnel not found")
            if match.group(2) and method == "DELETE":
                if not knob("connections-stay"):
                    tunnel["connected"] = False
                return self.send(200, [])
            if method == "GET":
                return self.send(200, tunnel)
            if method == "DELETE":
                if knob("fail-tunnel-delete"):
                    return self.fail(500, 1000, "internal error")
                if tunnel["connected"] and knob("connections-stay"):
                    return self.fail(400, 1022, "cannot delete a tunnel with active connections")
                tunnel["deleted_at"] = "2026-01-01T00:00:00Z"
                return self.send(200, tunnel)
        if path == "/zones" and method == "GET":
            found = [{"id": options.zone, "name": options.zone_name}] if query.get("name") == options.zone_name else []
            return self.send(200, found)
        zone_base = "/zones/%s/dns_records" % options.zone
        if path == zone_base and method == "GET":
            return self.send(200, [r for r in records.values() if query.get("name") in (None, r["name"])])
        if path == zone_base and method == "POST":
            if knob("refuse-records"):
                return self.fail(403, 10000, "Authentication error")
            if any(r["name"] == body.get("name") for r in records.values()):
                return self.fail(400, 81053, "a record with that host already exists")
            made = uuid.uuid4().hex
            records[made] = {"id": made, "type": body.get("type"), "name": body.get("name"), "content": body.get("content"),
                             "proxied": body.get("proxied")}
            return self.send(200, records[made])
        match = re.match(r"^" + re.escape(zone_base) + r"/([0-9a-f]{32})$", path)
        if match:
            record = records.get(match.group(1))
            if record is None:
                return self.fail(404, 81044, "record not found")
            if method == "GET":
                return self.send(200, record)
            if method == "DELETE":
                del records[match.group(1)]
                return self.send(200, {"id": match.group(1)})
        return self.fail(404, 7003, "no route for %s %s" % (method, path))

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_DELETE(self):
        self.handle_any("DELETE")

    def do_PUT(self):
        self.handle_any("PUT")


os.makedirs(DIR, exist_ok=True)
server = HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(DIR, "port.new"), "w") as handle:
    handle.write(str(server.server_address[1]))
os.rename(os.path.join(DIR, "port.new"), os.path.join(DIR, "port"))
sys.stdout.flush()
server.serve_forever()
