#!/usr/bin/env python3
"""peer transport, version 1: the carrier side of peer routing.

one carrying machine runs a loopback HTTP server. one requesting process posts a signed
envelope and the exact request bytes. the carrier runs lib/peer_routing.py carry() over
every decision, the attestation layer and the allowlist policy engine and the reciprocity
ledger, and only on an allow does it fetch the URL from its own connection and return the
site's answer. the bytes actually moved are then recorded in the reciprocity ledger so the
reservation is settled.

what this ship builds:
  - a carrier HTTP endpoint on loopback, POST /v1/carry.
  - a requester client that posts the envelope and reads the answer.
  - a command line for each role.

what this ship does not build:
  - the user-side wiring in the sirven runtime seam. a user asking the runtime for a peer
    route is still refused by lib/sirven_runtime/seam.py, by design, until that wiring is
    reviewed and shipped on its own.
  - any inter-machine authentication of the carrier endpoint itself. the carrier listens
    on 127.0.0.1 and takes a bearer token for the requester process on the same host. in
    production the link between two machines rides Tailscale, which supplies the host
    authentication and the encryption. that wiring is open.
  - any opening of the authenticated-traffic ship gate. the policy engine refuses
    authenticated peer requests while SHIP_GATE_AUTHENTICATED_PEER_TRAFFIC stays closed.

command line:
  peer_transport.py carrier --state DIR --port N [--token-file FILE]
  peer_transport.py request --carrier URL --token-file FILE --host H --tier T \
                            --session S --url URL --envelope FILE --request FILE \
                            [--authenticated]
"""

import argparse
import base64
import hashlib
import hmac
import http.server
import json
import os
import socket
import socketserver
import subprocess
import sys
import threading
import time
import uuid
from urllib import request as urllib_request
from urllib.error import HTTPError, URLError

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import peer_routing  # noqa: E402
import policy_engine as engine  # noqa: E402

RECIPROCITY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "reciprocity.py")

CARRIER_PATH = "/v1/carry"
MAX_BODY_BYTES = 2 * 1024 * 1024
FETCH_TIMEOUT = 30


def read_token(token_file):
    with open(token_file, "r", encoding="utf-8") as handle:
        return handle.read().strip()


def write_token(token_file):
    """Create a token file with mode 0600 if it does not exist, and return its contents."""
    if os.path.exists(token_file):
        return read_token(token_file)
    token = uuid.uuid4().hex + uuid.uuid4().hex
    old_umask = os.umask(0o077)
    try:
        with open(token_file, "w", encoding="utf-8") as handle:
            handle.write(token + "\n")
    finally:
        os.umask(old_umask)
    try:
        os.chmod(token_file, 0o600)
    except OSError:
        pass
    return token


def constant_time_equal(one, other):
    if not isinstance(one, str) or not isinstance(other, str):
        return False
    return hmac.compare_digest(one.encode("utf-8"), other.encode("utf-8"))


def record_transfer(state, tier_name, domain, session, peer_id, bytes_moved, now):
    """Append a settled transfer to the reciprocity ledger. Returns a receipt dict on success,
    or None if the ledger refused the record. A failure here does not change what the carrier
    returned to the requester: the bytes already moved."""
    ledger = peer_routing.paths(state)["ledger"]
    transfer_id = uuid.uuid4().hex
    completed = subprocess.run(
        [sys.executable, RECIPROCITY, "record", "--ledger", ledger, "--now", str(now),
         "--direction", "carried", "--bytes", str(bytes_moved),
         # the = form, as in peer_routing.carry: identifiers may begin with "-".
         "--domain=" + domain, "--session=" + session, "--transfer=" + transfer_id,
         "--peer=" + peer_id],
        capture_output=True, timeout=30)
    if completed.returncode != 0:
        return None
    return {"recorded": True, "transfer": transfer_id, "bytes": bytes_moved,
            "direction": "carried", "at": now}


# the carrier


class _Carrier(http.server.BaseHTTPRequestHandler):
    """One POST /v1/carry endpoint. Any other path or method is a 404 or 405.

    The handler never prints the bearer token. Access-log lines are suppressed, so the request
    path and the host it names never leave the process on standard error.
    """

    server_version = "sirven-peer-carrier/1"

    def log_message(self, format, *args):  # noqa: A002
        return

    def _reply(self, status, body):
        payload = json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _unauthorized(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", "Bearer")
        self.send_header("Content-Type", "application/json")
        body = json.dumps({"outcome": "unauthorized"}).encode("utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        self._reply(404, {"outcome": "not_found"})

    def do_POST(self):  # noqa: N802
        if self.path != CARRIER_PATH:
            return self._reply(404, {"outcome": "not_found"})

        header = self.headers.get("Authorization", "")
        expected = "Bearer " + self.server.carrier_token  # type: ignore[attr-defined]
        if not constant_time_equal(header, expected):
            return self._unauthorized()

        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            return self._reply(400, {"outcome": "invalid_request", "reason": "bad_length"})
        if length <= 0 or length > MAX_BODY_BYTES:
            return self._reply(400, {"outcome": "invalid_request", "reason": "bad_length"})
        raw = self.rfile.read(length)
        try:
            request = json.loads(raw)
        except ValueError:
            return self._reply(400, {"outcome": "invalid_request", "reason": "bad_json"})

        try:
            host = request["host"]
            tier = request["tier"]
            session = request["session"]
            request_bytes = base64.b64decode(request["request_base64"], validate=True)
            envelope = request.get("envelope")
            url = request["url"]
            authenticated = bool(request.get("authenticated", False))
        except (KeyError, ValueError, TypeError):
            return self._reply(400, {"outcome": "invalid_request", "reason": "bad_fields"})

        now = int(time.time())
        decision = peer_routing.carry(self.server.state, host, tier, authenticated,  # type: ignore[attr-defined]
                                       request_bytes, envelope, session, now)
        if decision["action"] != engine.ALLOW_PEER_CARRIER:
            return self._reply(403, {"outcome": "refused_by_policy", "decision": decision})

        maximum_bytes = int(decision["details"]["maximum_bytes"])
        tier_name = peer_routing.TIER_NAMES.get(str(tier).lower(), tier)

        try:
            status, headers, body = self._fetch(url, request_bytes, maximum_bytes)
        except _FetchError as error:
            return self._reply(502, {"outcome": "network_error", "kind": error.kind,
                                      "message": error.message, "decision": decision})

        bytes_moved = len(body)
        receipt = record_transfer(self.server.state, tier_name,  # type: ignore[attr-defined]
                                   host, session, decision["details"]["key_id"], bytes_moved, now)
        return self._reply(200, {
            "outcome": "ok",
            "status": status,
            "headers": headers,
            "body_base64": base64.b64encode(body).decode("ascii"),
            "bytes": bytes_moved,
            "decision": decision,
            "receipt": receipt,
        })

    def _fetch(self, url, request_bytes, maximum_bytes):
        """Fetch url from the carrier's own connection, read at most maximum_bytes.

        The carrier is the mover, not the shaper, of the request: method and body come from
        the request_bytes line, and nothing else about them is interpreted here. For version
        one only GET is supported; a different method is reported as unsupported and no bytes
        leave the carrier.
        """
        method = request_bytes.split(b" ", 1)[0].decode("ascii", "replace") if request_bytes else "GET"
        if method != "GET":
            raise _FetchError("unsupported_method", "Only GET is carried in version one.")
        req = urllib_request.Request(url, method="GET")
        try:
            with urllib_request.urlopen(req, timeout=FETCH_TIMEOUT) as response:
                body = response.read(maximum_bytes + 1)
                truncated = len(body) > maximum_bytes
                body = body[:maximum_bytes]
                headers = {name.lower(): value for name, value in response.headers.items()}
                if truncated:
                    headers["x-sirven-truncated"] = "true"
                return response.status, headers, body
        except HTTPError as error:
            body = b""
            try:
                body = error.read(maximum_bytes)
            except Exception:  # noqa: BLE001
                pass
            headers = {name.lower(): value for name, value in (error.headers or {}).items()}
            return error.code, headers, body
        except URLError as error:
            raise _FetchError("network_error", str(error.reason))
        except socket.timeout:
            raise _FetchError("timeout", "The site did not answer in time.")


class _FetchError(Exception):
    def __init__(self, kind, message):
        Exception.__init__(self, message)
        self.kind = kind
        self.message = message


class _ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def start_carrier(state, port, token):
    """Start a carrier bound to 127.0.0.1 on port (0 picks a free port). Returns the server;
    the caller runs server.serve_forever() in a thread and shuts it down with server.shutdown()
    + server.server_close()."""
    server = _ThreadingHTTPServer(("127.0.0.1", port), _Carrier)
    server.state = state  # type: ignore[attr-defined]
    server.carrier_token = token  # type: ignore[attr-defined]
    return server


def serve(state, port, token_file):
    token = write_token(token_file)
    server = start_carrier(state, port, token)
    address, bound_port = server.server_address
    print(json.dumps({"address": address, "port": bound_port, "state": state,
                      "token_file": os.path.abspath(token_file)}))
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


# the requester


class CarrierError(Exception):
    def __init__(self, status, payload):
        Exception.__init__(self, "carrier returned %d" % status)
        self.status = status
        self.payload = payload


def fetch_through_carrier(carrier_url, token, host, tier, request_bytes, envelope, session,
                          url, authenticated=False, timeout=FETCH_TIMEOUT):
    """Post a signed request to the carrier and return its answer as a dict.

    carrier_url is the base URL the carrier printed on start, for example
    http://127.0.0.1:47301. The /v1/carry path is appended here.
    """
    body = json.dumps({
        "host": host, "tier": tier, "session": session,
        "request_base64": base64.b64encode(request_bytes).decode("ascii"),
        "envelope": envelope, "url": url, "authenticated": bool(authenticated),
    }).encode("utf-8")
    req = urllib_request.Request(carrier_url.rstrip("/") + CARRIER_PATH, data=body, method="POST")
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib_request.urlopen(req, timeout=timeout) as answer:
            return json.loads(answer.read().decode("utf-8"))
    except HTTPError as error:
        try:
            payload = json.loads(error.read().decode("utf-8"))
        except Exception:  # noqa: BLE001
            payload = None
        raise CarrierError(error.code, payload)


# command line


def _carrier(args):
    serve(args.state, args.port, args.token_file or os.path.join(args.state, "carrier-token"))
    return 0


def _request(args):
    with open(args.envelope, "r", encoding="utf-8") as handle:
        envelope = json.load(handle)
    with open(args.request, "rb") as handle:
        request_bytes = handle.read()
    token = read_token(args.token_file)
    try:
        result = fetch_through_carrier(args.carrier, token, args.host, args.tier, request_bytes,
                                       envelope, args.session, args.url,
                                       authenticated=args.authenticated)
    except CarrierError as error:
        print(json.dumps({"outcome": "refused", "status": error.status, "payload": error.payload},
                         indent=2, sort_keys=True))
        return 3
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result.get("outcome") == "ok" else 3


def main(argv=None):
    parser = argparse.ArgumentParser(prog="peer_transport", description=__doc__.split("\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)

    carrier = commands.add_parser("carrier", help="run the loopback carrier server")
    carrier.add_argument("--state", required=True)
    carrier.add_argument("--port", type=int, default=0)
    carrier.add_argument("--token-file", default=None)
    carrier.set_defaults(func=_carrier)

    request_cmd = commands.add_parser("request", help="send one request through a carrier")
    request_cmd.add_argument("--carrier", required=True)
    request_cmd.add_argument("--token-file", required=True)
    request_cmd.add_argument("--host", required=True)
    request_cmd.add_argument("--tier", required=True)
    request_cmd.add_argument("--session", required=True)
    request_cmd.add_argument("--url", required=True)
    request_cmd.add_argument("--envelope", required=True)
    request_cmd.add_argument("--request", required=True)
    request_cmd.add_argument("--authenticated", action="store_true")
    request_cmd.set_defaults(func=_request)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
