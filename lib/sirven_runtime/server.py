"""The runtime: one listener on 127.0.0.1 that serves two things.

- The control interface, at /v1/...: the agent's fetch call, the seam's dry run, status, the
  tier, and the decision log. Other components plug in here. Defined in docs/runtime-interface.md.
- An HTTP proxy, for agents whose HTTP client already speaks proxies (HTTPS_PROXY): CONNECT for
  https, absolute URLs for plain http.

Both paths go through the same seam. Both require the runtime's token, which lives in a file
only the owner can read. The listener never binds anything but the loopback address.
"""

import base64
import binascii
import hmac
import json
import os
import platform
import secrets
import select
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

from . import fetch, seam
from .decision_log import DecisionLog
from .policy import SoloPolicy, load_settings

VERSION = 1
LISTEN_ADDRESS = "127.0.0.1"
DEFAULT_PORT = 47290
MAX_CONTROL_BODY = 10000000
TUNNEL_IDLE_SECONDS = 300
HOP_BY_HOP = ("connection", "keep-alive", "proxy-authorization", "proxy-authenticate", "proxy-connection",
              "te", "trailer", "transfer-encoding", "upgrade", "x-sirven-approval",
              # the fetcher negotiates compression itself and hands back the decoded page
              "accept-encoding")
SIRVEN_FORWARD_HEADERS = ("content-length", "content-encoding", "transfer-encoding", "connection")


def default_state_dir():
    home = os.path.expanduser("~")
    if sys.platform == "darwin":
        return os.path.join(home, "Library", "Application Support", "sirven", "runtime")
    return os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(home, ".local", "state"), "sirven", "runtime")


def default_helper_path():
    if os.environ.get("SIRVEN_FETCH_HELPER"):
        return os.environ["SIRVEN_FETCH_HELPER"]
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(here, "..", "..", "dist", "runtime", "sirven-fetch")


def choose_fetcher(kind, helper_path):
    if kind == "python":
        return fetch.PythonFetcher()
    usable = sys.platform == "darwin" and os.access(helper_path, os.X_OK)
    if kind == "helper" and not usable:
        raise SystemExit("error: the fetch helper is not built at %s. run: make runtime" % helper_path)
    return fetch.HelperFetcher(os.path.abspath(helper_path)) if usable else fetch.PythonFetcher()


def read_or_create_token(state_dir):
    path = os.path.join(state_dir, "token")
    os.makedirs(state_dir, mode=0o700, exist_ok=True)
    try:
        with open(path, encoding="ascii") as handle:
            token = handle.read().strip()
        if token:
            return token, path
    except FileNotFoundError:
        pass
    token = secrets.token_urlsafe(32)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="ascii") as handle:
        handle.write(token + "\n")
    return token, path


class Runtime:
    """Everything the handlers share. Built once, then read by every request thread."""

    def __init__(self, state_dir, settings, fetcher, policy=None, port=DEFAULT_PORT):
        self.state_dir = state_dir
        self.settings = settings
        self.fetcher = fetcher
        self.policy = policy or SoloPolicy(settings)
        self.port = port
        self.tier = "solo"
        self.token, self.token_path = read_or_create_token(state_dir)
        self.log = DecisionLog(os.path.join(state_dir, "decisions.jsonl"))
        self.started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    def status(self):
        return {
            "version": VERSION,
            "tier": self.tier,
            "tiers_available": ["solo"],
            "peer_routing": "not_built",
            "egress": "own_connection",
            "fingerprint": self.fetcher.fingerprint,
            "policy": self.policy.name,
            "listening": {"address": LISTEN_ADDRESS, "port": self.port},
            "started_at": self.started_at,
            "decision_log": self.log.path,
            "outcomes": self.log.counts(),
            "platform": "%s %s" % (platform.system(), platform.machine()),
        }


def json_body(data):
    return (json.dumps(data, indent=2, sort_keys=True) + "\n").encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    server_version = "sirven-runtime/1"
    protocol_version = "HTTP/1.1"

    @property
    def runtime(self):
        return self.server.runtime

    def log_message(self, format, *args):  # the decision log is the record; keep standard error quiet
        pass

    # replies ------------------------------------------------------------------------------

    def reply(self, code, data, extra_headers=None):
        body = json_body(data)
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for name, value in (extra_headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def problem(self, code, reason, message, extra_headers=None):
        self.reply(code, {"version": VERSION, "outcome": "invalid_request" if code < 500 else "runtime_error",
                          "error": {"kind": reason, "message": message}}, extra_headers)

    def refusal(self, request, decision, proxy):
        """A policy refusal is a first-class result: a 403 with the reason, in words and as a code."""
        self.runtime.log.record(request, decision, "refused_by_policy")
        record = {"version": VERSION, "outcome": "refused_by_policy", "attempts": 1,
                  "decision": fetch.decision_record(decision)}
        headers = {"X-Sirven-Outcome": "refused_by_policy", "X-Sirven-Reason": decision.reason}
        if proxy:
            headers["Connection"] = "close"
            self.close_connection = True
        self.reply(403, record, headers)

    # authentication -----------------------------------------------------------------------

    def token_matches(self, offered):
        return bool(offered) and hmac.compare_digest(offered.encode("utf-8"), self.runtime.token.encode("utf-8"))

    def control_allowed(self):
        if self.headers.get("Origin"):
            # a web page in a browser never gets to drive the runtime
            self.problem(403, "browser_origin_refused", "The runtime does not take requests from web pages.")
            return False
        host = (self.headers.get("Host") or "").lower()
        if host not in ("127.0.0.1:%d" % self.runtime.port, "localhost:%d" % self.runtime.port):
            self.problem(403, "wrong_host", "Address the runtime as 127.0.0.1:%d." % self.runtime.port)
            return False
        scheme, _, credential = (self.headers.get("Authorization") or "").partition(" ")
        if scheme.lower() != "bearer" or not self.token_matches(credential.strip()):
            self.problem(401, "token_required", "Send the runtime token as: Authorization: Bearer <token>. "
                         "It is in %s." % self.runtime.token_path,
                         {"WWW-Authenticate": 'Bearer realm="sirven-runtime"'})
            return False
        return True

    def proxy_allowed(self):
        scheme, _, credential = (self.headers.get("Proxy-Authorization") or "").partition(" ")
        password = ""
        if scheme.lower() == "basic":
            try:
                password = base64.b64decode(credential.strip()).decode("utf-8").partition(":")[2]
            except (binascii.Error, UnicodeDecodeError):
                password = ""
        if not self.token_matches(password):
            self.close_connection = True
            self.problem(407, "token_required", "Use the proxy as http://sirven:<token>@127.0.0.1:%d. "
                         "The token is in %s." % (self.runtime.port, self.runtime.token_path),
                         {"Proxy-Authenticate": 'Basic realm="sirven-runtime"', "Connection": "close"})
            return False
        return True

    # dispatch -----------------------------------------------------------------------------

    def do_CONNECT(self):
        if self.proxy_allowed():
            self.tunnel()

    def do_GET(self):
        self.dispatch()

    def do_HEAD(self):
        self.dispatch()

    def do_POST(self):
        self.dispatch()

    def do_PUT(self):
        self.dispatch()

    def do_PATCH(self):
        self.dispatch()

    def do_DELETE(self):
        self.dispatch()

    def do_OPTIONS(self):
        self.dispatch()

    def dispatch(self):
        if self.path.startswith("http://") or self.path.startswith("https://"):
            if self.proxy_allowed():
                self.forward()
            return
        if not self.control_allowed():
            return
        route = urlsplit(self.path).path
        handlers = {
            ("GET", "/v1/status"): self.control_status,
            ("POST", "/v1/fetch"): self.control_fetch,
            ("POST", "/v1/classify"): self.control_classify,
            ("GET", "/v1/decisions"): self.control_decisions,
            ("GET", "/v1/tier"): self.control_tier,
            ("PUT", "/v1/tier"): self.control_set_tier,
        }
        handler = handlers.get((self.command, route))
        if handler is None:
            self.problem(404, "no_such_endpoint", "%s %s is not part of the runtime interface." % (self.command, route))
            return
        handler()

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_CONTROL_BODY:
            self.problem(413, "too_large", "The request body is larger than the runtime accepts.")
            return None
        try:
            data = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        except (ValueError, UnicodeDecodeError):
            self.problem(400, "invalid_json", "The request body is not valid JSON.")
            return None
        if not isinstance(data, dict):
            self.problem(400, "invalid_json", "The request body must be a JSON object.")
            return None
        return data

    # control interface --------------------------------------------------------------------

    def control_status(self):
        self.reply(200, self.runtime.status())

    def control_tier(self):
        self.reply(200, {"version": VERSION, "tier": self.runtime.tier, "tiers_available": ["solo"]})

    def control_set_tier(self):
        data = self.read_json()
        if data is None:
            return
        wanted = data.get("tier")
        if wanted == "solo":
            self.reply(200, {"version": VERSION, "tier": "solo", "tiers_available": ["solo"]})
            return
        self.reply(409, {"version": VERSION, "tier": self.runtime.tier, "tiers_available": ["solo"],
                         "error": {"kind": "tier_not_available",
                                   "message": "Only Solo is available. Neighborly and Co-op need the attestation "
                                              "layer and the site-allowlist review workflow working end to end first."}})

    def control_decisions(self):
        query = parse_qs(urlsplit(self.path).query)
        try:
            after = int(query.get("after", ["0"])[0])
            limit = max(1, min(int(query.get("limit", ["100"])[0]), 1000))
        except ValueError:
            self.problem(400, "invalid_query", "after and limit must be whole numbers.")
            return
        entries = self.runtime.log.after(after, limit)
        last = entries[-1]["sequence"] if entries else after
        self.reply(200, {"version": VERSION, "decisions": entries, "next_after": last})

    def control_classify(self):
        data = self.read_json()
        if data is None:
            return
        url = data.get("url")
        if not isinstance(url, str):
            self.problem(400, "url_required", "Send the url to classify.")
            return
        try:
            request = fetch.request_for(url, data.get("method", "GET"), data.get("channel", "fetch"),
                                        self.runtime.tier, data.get("approval"), None, 0)
        except ValueError:
            self.problem(400, "invalid_url", "The URL could not be read.")
            return
        decision = seam.decide(request, self.runtime.policy)
        self.reply(200, {"version": VERSION, "decision": fetch.decision_record(decision), "sent": False})

    def control_fetch(self):
        data = self.read_json()
        if data is None:
            return
        url = data.get("url")
        if not isinstance(url, str) or not url:
            self.problem(400, "url_required", "Send the url to fetch.")
            return
        headers = data.get("headers") or {}
        if not isinstance(headers, dict) or not all(isinstance(v, str) for v in headers.values()):
            self.problem(400, "invalid_headers", "headers must be an object of strings.")
            return
        body = None
        if data.get("body_base64") is not None:
            try:
                body = base64.b64decode(data["body_base64"], validate=True)
            except (binascii.Error, TypeError):
                self.problem(400, "invalid_body", "body_base64 is not valid base64.")
                return
        try:
            timeout = min(float(data.get("timeout_seconds") or fetch.DEFAULT_TIMEOUT), 120)
            max_bytes = min(int(data.get("max_bytes") or fetch.DEFAULT_MAX_BYTES), fetch.DEFAULT_MAX_BYTES)
        except (TypeError, ValueError):
            self.problem(400, "invalid_limits", "timeout_seconds and max_bytes must be numbers.")
            return
        if timeout <= 0 or max_bytes <= 0:
            self.problem(400, "invalid_limits", "timeout_seconds and max_bytes must be above zero.")
            return
        hops = []
        record = fetch.perform(
            url, self.runtime.policy, self.runtime.fetcher, method=data.get("method", "GET"), headers=headers,
            body=body, channel="fetch", tier=self.runtime.tier, approval=data.get("approval"),
            allow_private_hosts=self.runtime.settings["allow_private_hosts"],
            timeout=timeout, max_bytes=max_bytes,
            follow_redirects=data.get("follow_redirects", True) is not False,
            on_decision=lambda request, decision: hops.append((request, decision)))
        for index, (request, decision) in enumerate(hops):
            last = index == len(hops) - 1
            received = len(base64.b64decode(record["body_base64"])) if last and record["body_base64"] else 0
            self.runtime.log.record(request, decision, record["outcome"] if last else "redirected",
                                    status=record["status"] if last else record["redirects"][index]["status"],
                                    bytes_sent=len(body or b"") if decision.route == "local" else 0,
                                    bytes_received=received,
                                    block_kind=(record["block"] or {}).get("kind") if last else None,
                                    approval=data.get("approval"))
        self.reply(200, record, {"X-Sirven-Outcome": record["outcome"]})

    # proxy --------------------------------------------------------------------------------

    def tunnel(self):
        host, _, port_text = self.path.rpartition(":")
        try:
            port = int(port_text)
        except ValueError:
            self.close_connection = True
            self.problem(400, "invalid_target", "CONNECT needs host:port.", {"Connection": "close"})
            return
        request = seam.EgressRequest(host=seam.normalize_host(host), port=port, scheme="https", channel="tunnel",
                                     tier=self.runtime.tier)
        decision = seam.decide(request, self.runtime.policy)
        if decision.route == "local" and fetch.resolves_to_local_network(request.host, port,
                                                                          self.runtime.settings["allow_private_hosts"]):
            decision = seam.refuse("local_network", "The site's name points into your local network, so the runtime refused it.",
                                   policy="connect_guard")
        if decision.route != "local":
            self.refusal(request, decision, proxy=True)
            return
        try:
            upstream = socket.create_connection((request.host, port), timeout=fetch.DEFAULT_TIMEOUT)
        except OSError as error:
            kind = "name_not_found" if isinstance(error, socket.gaierror) else "network_error"
            self.runtime.log.record(request, decision, "network_error")
            self.close_connection = True
            self.reply(502, {"version": VERSION, "outcome": "network_error", "attempts": 1,
                             "decision": fetch.decision_record(decision),
                             "error": {"kind": kind, "message": "The runtime could not reach %s." % request.host}},
                       {"X-Sirven-Outcome": "network_error", "Connection": "close"})
            return
        self.send_response(200, "Connection Established")
        self.send_header("X-Sirven-Outcome", "tunnel_open")
        self.end_headers()
        self.wfile.flush()
        sent, received = self.pipe(self.connection, upstream)
        self.close_connection = True
        # the runtime cannot see inside the encrypted tunnel, so it cannot tell a page from a block
        self.runtime.log.record(request, decision, "tunnel_closed", bytes_sent=sent, bytes_received=received)

    def pipe(self, client, upstream):
        sent = received = 0
        sockets = [client, upstream]
        try:
            while True:
                readable, _, broken = select.select(sockets, [], sockets, TUNNEL_IDLE_SECONDS)
                if broken or not readable:
                    break
                for source in readable:
                    data = source.recv(65536)
                    if not data:
                        return sent, received
                    if source is client:
                        upstream.sendall(data)
                        sent += len(data)
                    else:
                        client.sendall(data)
                        received += len(data)
        except OSError:
            pass
        finally:
            upstream.close()
        return sent, received

    def forward(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        headers = {name: value for name, value in self.headers.items() if name.lower() not in HOP_BY_HOP + ("host",)}
        hops = []
        record = fetch.perform(self.path, self.runtime.policy, self.runtime.fetcher, method=self.command,
                               headers=headers, body=body, channel="forward", tier=self.runtime.tier,
                               approval=self.headers.get("X-Sirven-Approval"),
                               allow_private_hosts=self.runtime.settings["allow_private_hosts"],
                               follow_redirects=False, on_decision=lambda r, d: hops.append((r, d)))
        request, decision = hops[-1] if hops else (None, None)
        if record["outcome"] == "refused_by_policy":
            self.refusal(request, decision, proxy=True)
            return
        if record["outcome"] not in ("ok", "blocked_by_site"):
            if request is not None:
                self.runtime.log.record(request, decision, record["outcome"])
            self.close_connection = True
            self.reply(502, record, {"X-Sirven-Outcome": record["outcome"], "Connection": "close"})
            return
        data = base64.b64decode(record["body_base64"] or "")
        block = record["block"]
        self.runtime.log.record(request, decision, record["outcome"], status=record["status"],
                                bytes_sent=len(body or b""), bytes_received=len(data),
                                block_kind=block["kind"] if block else None,
                                approval=self.headers.get("X-Sirven-Approval"))
        self.send_response(record["status"])
        for name, value in record["headers"].items():
            if name.lower() not in SIRVEN_FORWARD_HEADERS:
                self.send_header(name, value)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Sirven-Outcome", record["outcome"])
        if block:
            self.send_header("X-Sirven-Block-Kind", block["kind"])
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, runtime):
        self.runtime = runtime
        ThreadingHTTPServer.__init__(self, (LISTEN_ADDRESS, runtime.port), Handler)
        runtime.port = self.server_address[1]


def write_discovery(runtime):
    """runtime.json tells clients where the runtime listens and where its token is."""
    path = os.path.join(runtime.state_dir, "runtime.json")
    data = {"version": VERSION, "address": LISTEN_ADDRESS, "port": runtime.port, "pid": os.getpid(),
            "token_file": runtime.token_path, "started_at": runtime.started_at}
    descriptor = os.open(path + ".new", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
    os.replace(path + ".new", path)
    return path


def build(state_dir=None, port=DEFAULT_PORT, settings_path=None, fetcher_kind="auto", helper_path=None, policy=None):
    state_dir = state_dir or default_state_dir()
    settings = load_settings(settings_path)
    fetcher = choose_fetcher(fetcher_kind, helper_path or default_helper_path())
    runtime = Runtime(state_dir, settings, fetcher, policy=policy, port=port)
    return Server(runtime)


def serve_in_thread(server):
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return thread
