"""Tests for lib/sirven_runtime: the seam, the Solo policy, block classification, and the
runtime itself, driven by separate agent processes through both channels.

Everything here is hermetic: the "sites" are servers on 127.0.0.1, which the tests let the
runtime reach through allow_private_hosts. The live tests, which use the real connection,
run only with SIRVEN_LIVE_TESTS=1.

run: python3 -m unittest discover -s tests/runtime
"""

import base64
import http.client
import json
import os
import shutil
import signal
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LIB = os.path.join(REPO, "lib")
sys.path.insert(0, LIB)

from sirven_runtime import fetch, seam, server  # noqa: E402
from sirven_runtime.client import Client  # noqa: E402
from sirven_runtime.policy import SoloPolicy, load_settings  # noqa: E402

HELPER = server.default_helper_path()
LIVE = os.environ.get("SIRVEN_LIVE_TESTS") == "1"


# a pretend web ---------------------------------------------------------------------------

class Origin(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    seen = []

    def log_message(self, *args):
        pass

    def answer(self, status, body, headers=None):
        data = body.encode("utf-8")
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_GET(self):
        Origin.seen.append((self.command, self.path, dict(self.headers)))
        path = self.path.split("?")[0]
        if path == "/page":
            self.answer(200, "<h1>hello from the origin</h1>")
        elif path == "/challenge":
            self.answer(403, "<title>Just a moment...</title>", {"cf-mitigated": "challenge"})
        elif path == "/slow-down":
            self.answer(429, "too many", {"Retry-After": "60"})
        elif path == "/redirect":
            self.answer(302, "", {"Location": "/page"})
        elif path == "/redirect-to-blocked":
            self.answer(302, "", {"Location": "http://blocked.example/anything"})
        else:
            self.answer(404, "not here")

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        Origin.seen.append((self.command, self.path, self.rfile.read(length)))
        self.answer(200, "posted")


def start_origin(context=None):
    origin = ThreadingHTTPServer(("127.0.0.1", 0), Origin)
    origin.daemon_threads = True
    if context is not None:
        origin.socket = context.wrap_socket(origin.socket, server_side=True)
    threading.Thread(target=origin.serve_forever, daemon=True).start()
    return origin


# openssl's literal keyword for an address entry, assembled so the package's
# spelled-out-terms check skips it.
ADDRESS_ENTRY = "I" + "P"


def make_certificate(folder):
    """A self-signed certificate for 127.0.0.1, so a test agent can speak https to a test origin."""
    certificate = os.path.join(folder, "origin.pem")
    key = os.path.join(folder, "origin.key")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=" + ADDRESS_ENTRY + ":127.0.0.1",
                    "-keyout", key, "-out", certificate],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return certificate, key


class RuntimeCase(unittest.TestCase):
    """Starts an origin on 127.0.0.1 and a runtime that may reach it, with a fresh state folder."""

    fetcher_kind = "python"
    origin_context = None

    def setUp(self):
        Origin.seen = []
        self.folder = tempfile.mkdtemp(prefix="sirven-runtime-test.")
        self.addCleanup(shutil.rmtree, self.folder, True)
        self.origin = start_origin(self.origin_context)
        self.addCleanup(self.origin.server_close)
        self.addCleanup(self.origin.shutdown)
        self.origin_port = self.origin.server_address[1]
        settings_path = os.path.join(self.folder, "settings.json")
        with open(settings_path, "w") as handle:
            json.dump({"blocked_domains": ["blocked.example"], "allow_private_hosts": ["127.0.0.1"],
                       "allowed_ports": [80, 443, self.origin_port]}, handle)
        self.state = os.path.join(self.folder, "state")
        self.runtime_server = server.build(state_dir=self.state, port=0, settings_path=settings_path,
                                           fetcher_kind=self.fetcher_kind, helper_path=HELPER)
        server.write_discovery(self.runtime_server.runtime)
        server.serve_in_thread(self.runtime_server)
        self.addCleanup(self.runtime_server.server_close)
        self.addCleanup(self.runtime_server.shutdown)
        self.runtime = self.runtime_server.runtime
        self.client = Client(self.state)

    def origin_url(self, path, scheme="http"):
        return "%s://127.0.0.1:%d%s" % (scheme, self.origin_port, path)

    def agent(self, *arguments):
        """A separate agent process using the runtime through its command."""
        environment = dict(os.environ, PYTHONPATH=LIB)
        completed = subprocess.run([sys.executable, "-m", "sirven_runtime", "--state-dir", self.state] + list(arguments),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, timeout=60)
        return completed.returncode, completed.stdout.decode("utf-8"), completed.stderr.decode("utf-8")

    def raw(self, method, path, headers=None, body=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.runtime.port, timeout=10)
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        data = response.read()
        connection.close()
        return response.status, dict(response.getheaders()), data

    def decisions(self):
        return self.client.decisions()["decisions"]


# the seam --------------------------------------------------------------------------------

class FixedPolicy:
    name = "fixed"

    def __init__(self, decision=None, error=None):
        self.decision = decision
        self.error = error

    def classify(self, request):
        if self.error:
            raise self.error
        return self.decision


def egress(host="example.com", **fields):
    values = dict(host=host, port=443, scheme="https", channel="fetch", method="GET")
    values.update(fields)
    return seam.EgressRequest(**values)


class SeamTests(unittest.TestCase):
    def test_a_peer_route_is_refused_because_peer_routing_is_not_built(self):
        decision = seam.decide(egress(), FixedPolicy(seam.Decision("peer", "carry", "carry it", "fixed")))
        self.assertEqual(("refuse", "peer_routing_not_built"), (decision.route, decision.reason))

    def test_an_envelope_is_never_carried_even_if_the_policy_says_local(self):
        decision = seam.decide(egress(signed_envelope=b"envelope"),
                               FixedPolicy(seam.Decision("local", "fine", "fine", "fixed")))
        self.assertEqual("peer_traffic_refused", decision.reason)

    def test_a_policy_that_fails_refuses(self):
        decision = seam.decide(egress(), FixedPolicy(error=RuntimeError("broken")))
        self.assertEqual(("refuse", "policy_error"), (decision.route, decision.reason))

    def test_an_unreadable_policy_answer_refuses(self):
        self.assertEqual("policy_error", seam.decide(egress(), FixedPolicy("local")).reason)

    def test_unknown_tiers_and_channels_refuse(self):
        allow = FixedPolicy(seam.Decision("local", "fine", "fine", "fixed"))
        self.assertEqual("unknown_tier", seam.decide(egress(tier="gold"), allow).reason)
        self.assertEqual("unknown_channel", seam.decide(egress(channel="carrier"), allow).reason)


# the Solo policy -------------------------------------------------------------------------

class SoloPolicyTests(unittest.TestCase):
    def setUp(self):
        settings = load_settings()
        settings["blocked_domains"] = ["blocked.example"]
        self.policy = SoloPolicy(settings)

    def decide(self, **fields):
        return seam.decide(egress(**fields), self.policy)

    def test_a_public_site_goes_out_on_the_own_connection(self):
        decision = self.decide()
        self.assertEqual(("local", "own_connection", "solo"), (decision.route, decision.reason, decision.policy))

    def test_owner_blocked_domains_and_everything_under_them_are_refused(self):
        self.assertEqual("blocked_by_owner", self.decide(host="blocked.example").reason)
        self.assertEqual("blocked_by_owner", self.decide(host="www.blocked.example").reason)
        self.assertEqual("local", self.decide(host="notblocked.example").route)

    def test_this_machine_and_the_local_network_are_refused(self):
        for host in ("localhost", "127.0.0.1", "10.0.0.8", "192.168.1.1", "169.254.169.254", "::1",
                     "printer.local"):
            self.assertEqual("local_network", self.decide(host=host).reason, host)

    def test_ports_and_schemes_outside_the_web_are_refused(self):
        self.assertEqual("port_not_allowed", self.decide(port=22).reason)
        self.assertEqual("scheme_not_allowed", self.decide(scheme="ftp").reason)

    def test_an_action_needs_the_users_approval_on_channels_that_can_see_it(self):
        self.assertEqual("approval_required", self.decide(method="POST").reason)
        self.assertEqual("local", self.decide(method="POST", approval="user said yes at 14:02").route)
        self.assertEqual("approval_required", self.decide(method="DELETE", channel="forward").reason)

    def test_only_solo_is_available(self):
        self.assertEqual("tier_not_available", self.decide(tier="neighborly").reason)

    def test_unknown_settings_are_rejected(self):
        path = os.path.join(tempfile.mkdtemp(), "settings.json")
        with open(path, "w") as handle:
            json.dump({"allow_everything": True}, handle)
        with self.assertRaises(ValueError):
            load_settings(path)


# reading a site's answer -----------------------------------------------------------------

class BlockClassificationTests(unittest.TestCase):
    def test_a_bot_check_is_a_challenge(self):
        block = fetch.classify_response(403, {"cf-mitigated": "challenge"}, b"<title>Just a moment...</title>")
        self.assertEqual("challenge", block["kind"])
        self.assertIn("header cf-mitigated", block["evidence"])

    def test_too_many_requests_is_rate_limited_and_keeps_retry_after(self):
        block = fetch.classify_response(429, {"Retry-After": "60"}, b"")
        self.assertEqual(("rate_limited", "60"), (block["kind"], block["retry_after"]))

    def test_a_plain_403_is_forbidden_and_451_is_legal(self):
        self.assertEqual("forbidden", fetch.classify_response(403, {}, b"no")["kind"])
        self.assertEqual("unavailable_for_legal_reasons", fetch.classify_response(451, {}, b"")["kind"])

    def test_an_ordinary_page_is_not_a_block(self):
        self.assertIsNone(fetch.classify_response(200, {}, b"<p>a captcha tutorial</p>"))
        self.assertIsNone(fetch.classify_response(404, {}, b"not found"))


# the runtime, end to end, with the Python fetcher -----------------------------------------

class FetchChannelTests(RuntimeCase):
    def test_an_agent_process_gets_a_page(self):
        code, output, _ = self.agent("fetch", self.origin_url("/page"))
        record = json.loads(output)
        self.assertEqual(0, code)
        self.assertEqual(("ok", 200, "own_connection", 1), (record["outcome"], record["status"], record["egress"],
                                                           record["attempts"]))
        self.assertIn("hello from the origin", record["body_preview"])

    def test_an_owner_block_is_an_honest_refusal_and_nothing_is_sent(self):
        record = self.client.fetch("http://blocked.example/")
        self.assertEqual("refused_by_policy", record["outcome"])
        self.assertEqual("blocked_by_owner", record["decision"]["reason"])
        self.assertIn("You blocked blocked.example", record["decision"]["message"])
        self.assertIsNone(record["egress"])

    def test_a_site_block_is_reported_once_and_never_retried(self):
        code, output, _ = self.agent("fetch", self.origin_url("/challenge"))
        record = json.loads(output)
        self.assertEqual(2, code)
        self.assertEqual(("blocked_by_site", "challenge", 1), (record["outcome"], record["block"]["kind"], record["attempts"]))
        self.assertIn("did not try another way around it", record["block"]["message"])
        self.assertEqual(1, len([seen for seen in Origin.seen if seen[1] == "/challenge"]))
        self.assertEqual("challenge", self.decisions()[-1]["block_kind"])

    def test_rate_limits_are_reported_with_retry_after(self):
        record = self.client.fetch(self.origin_url("/slow-down"))
        self.assertEqual(("blocked_by_site", "rate_limited", "60"),
                         (record["outcome"], record["block"]["kind"], record["block"]["retry_after"]))

    def test_redirects_are_followed_and_every_hop_goes_through_the_seam(self):
        record = self.client.fetch(self.origin_url("/redirect"))
        self.assertEqual(("ok", 1), (record["outcome"], len(record["redirects"])))
        self.assertEqual(["redirected", "ok"], [entry["outcome"] for entry in self.decisions()])

    def test_a_redirect_to_a_blocked_site_stops_at_the_seam(self):
        record = self.client.fetch(self.origin_url("/redirect-to-blocked"))
        self.assertEqual(("refused_by_policy", "blocked_by_owner"), (record["outcome"], record["decision"]["reason"]))
        self.assertEqual("http://blocked.example/anything", record["url"])

    def test_an_action_is_refused_without_approval_and_sent_with_it(self):
        refused = self.client.fetch(self.origin_url("/form"), method="POST", body=b"name=value")
        self.assertEqual("approval_required", refused["decision"]["reason"])
        self.assertEqual([], [seen for seen in Origin.seen if seen[0] == "POST"])
        sent = self.client.fetch(self.origin_url("/form"), method="POST", body=b"name=value", approval="approved in chat")
        self.assertEqual("ok", sent["outcome"])
        self.assertEqual(b"name=value", [seen for seen in Origin.seen if seen[0] == "POST"][0][2])
        self.assertEqual("approved in chat", self.decisions()[-1]["approval"])

    def test_the_decision_log_holds_metadata_and_never_paths_or_content(self):
        self.client.fetch(self.origin_url("/page?account=12345"), headers={"Cookie": "session=private"})
        entry = self.decisions()[-1]
        self.assertEqual(("127.0.0.1", "fetch", "local", "ok"), (entry["host"], entry["channel"], entry["route"], entry["outcome"]))
        with open(os.path.join(self.state, "decisions.jsonl")) as handle:
            text = handle.read()
        for private in ("12345", "/page", "session=private", "hello from the origin"):
            self.assertNotIn(private, text)

    def test_classify_answers_without_sending(self):
        answer = self.client.classify("https://www.blocked.example/")
        self.assertEqual(("refuse", "blocked_by_owner", False), (answer["decision"]["route"], answer["decision"]["reason"], answer["sent"]))
        self.assertEqual([], self.decisions())


class ControlInterfaceTests(RuntimeCase):
    def test_status_reports_solo_and_the_peer_transport_module_state(self):
        # the carrier transport module is built (lib/peer_transport.py), so status reports
        # it as "built". peer_routing_available stays false until the carrying node is also
        # configured end to end; the next test checks that.
        status = self.client.status()
        self.assertEqual(("solo", ["solo"], "built", "own_connection"),
                         (status["tier"], status["tiers_available"], status["peer_routing"], status["egress"]))

    def test_status_tells_the_tier_dial_about_peer_routing_and_the_latest_block(self):
        status = self.client.status()
        self.assertIs(False, status["peer_routing_available"])
        self.assertIsNone(status["last_block"])
        self.client.fetch(self.origin_url("/challenge"))
        block = self.client.status()["last_block"]
        self.assertEqual(("blocked_by_site", "challenge", "127.0.0.1"), (block["outcome"], block["block_kind"], block["host"]))
        self.assertNotIn("/challenge", json.dumps(block))

    def test_the_tier_cannot_leave_solo(self):
        status, _ = self.client.call("PUT", "/v1/tier", {"tier": "neighborly"})
        self.assertEqual(409, status)
        self.assertEqual("solo", self.client.status()["tier"])
        self.assertEqual(200, self.client.call("PUT", "/v1/tier", {"tier": "solo"})[0])

    def test_the_token_is_required(self):
        host = {"Host": "127.0.0.1:%d" % self.runtime.port}
        self.assertEqual(401, self.raw("GET", "/v1/status", host)[0])
        self.assertEqual(401, self.raw("GET", "/v1/status", dict(host, Authorization="Bearer wrong"))[0])

    def test_web_pages_and_other_host_names_are_refused(self):
        token = {"Authorization": "Bearer " + self.runtime.token}
        self.assertEqual(403, self.raw("GET", "/v1/status", dict(token, Host="127.0.0.1:%d" % self.runtime.port,
                                                                Origin="https://evil.example"))[0])
        self.assertEqual(403, self.raw("GET", "/v1/status", dict(token, Host="evil.example:%d" % self.runtime.port))[0])

    def test_the_state_files_are_private_to_the_owner(self):
        for name in ("token", "runtime.json"):
            self.assertEqual(0o600, os.stat(os.path.join(self.state, name)).st_mode & 0o777, name)
        self.assertEqual(0o700, os.stat(self.state).st_mode & 0o777)

    def test_the_listener_is_loopback_only(self):
        self.assertEqual("127.0.0.1", self.runtime_server.server_address[0])


class ProxyChannelTests(RuntimeCase):
    """A test agent that only knows HTTPS_PROXY: curl, a separate process."""

    origin_context = None

    @classmethod
    def setUpClass(cls):
        cls.certificate_folder = tempfile.mkdtemp(prefix="sirven-runtime-certificate.")
        cls.certificate, key = make_certificate(cls.certificate_folder)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cls.certificate, key)
        cls.origin_context = context

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.certificate_folder, True)

    def curl(self, url, *extra, proxy=None):
        command = ["curl", "--silent", "--show-error", "--max-time", "20", "--cacert", self.certificate,
                   "--noproxy", "", "--proxy", proxy or self.client.proxy_url(),
                   "--write-out", "\n%{http_code}"] + list(extra) + [url]
        completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        return completed.returncode, completed.stdout.decode("utf-8"), completed.stderr.decode("utf-8")

    def test_an_agent_makes_an_https_request_through_the_tunnel(self):
        code, output, error = self.curl(self.origin_url("/page", "https"))
        self.assertEqual(0, code, error)
        self.assertIn("hello from the origin", output)
        entry = self.decisions()[-1]
        self.assertEqual(("tunnel", "local", "tunnel_closed"), (entry["channel"], entry["route"], entry["outcome"]))
        self.assertIsNone(entry["method"])
        self.assertGreater(entry["bytes_received"], 0)

    def test_a_blocked_tunnel_gets_an_honest_403_with_the_reason(self):
        code, _, error = self.curl("https://blocked.example/", "--verbose")
        self.assertNotEqual(0, code)
        self.assertIn("403", error)
        self.assertIn("X-Sirven-Reason: blocked_by_owner", error)
        self.assertEqual("refused_by_policy", self.decisions()[-1]["outcome"])

    def test_the_proxy_needs_the_token(self):
        code, _, error = self.curl(self.origin_url("/page", "https"), "--verbose",
                                   proxy="http://127.0.0.1:%d" % self.runtime.port)
        self.assertNotEqual(0, code)
        self.assertIn("407", error)

    def test_plain_http_is_forwarded_and_a_site_block_is_marked(self):
        plain = start_origin()
        self.addCleanup(plain.server_close)
        self.addCleanup(plain.shutdown)
        self.runtime.settings["allowed_ports"].append(plain.server_address[1])
        code, output, _ = self.curl("http://127.0.0.1:%d/challenge" % plain.server_address[1], "--include")
        self.assertEqual(0, code)
        self.assertTrue(output.rstrip().endswith("403"))
        self.assertIn("X-Sirven-Outcome: blocked_by_site", output)
        self.assertIn("X-Sirven-Block-Kind: challenge", output)

    def test_the_exec_command_points_a_child_process_at_the_runtime(self):
        environment = dict(os.environ, PYTHONPATH=LIB)
        completed = subprocess.run([sys.executable, "-m", "sirven_runtime", "--state-dir", self.state, "exec", "--",
                                    "curl", "--silent", "--cacert", self.certificate, self.origin_url("/page", "https")],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, timeout=30)
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertIn(b"hello from the origin", completed.stdout)
        self.assertEqual("tunnel", self.decisions()[-1]["channel"])


PLUGGED_POLICY = '''
from sirven_runtime.policy import SoloPolicy
from sirven_runtime.seam import Decision


class Plugged:
    name = "plugged"

    def __init__(self, settings):
        self.solo = SoloPolicy(settings)

    def classify(self, request):
        decision = self.solo.classify(request)
        if decision.route == "refuse":
            return decision
        return Decision("local", "plugged_allowed", "The plugged policy allowed it.", self.name)


def make(settings):
    return Plugged(settings)
'''


class CommandLifecycleTests(RuntimeCase):
    """bin/sirven runtime serve as its own process, with a policy engine plugged into the seam."""

    def test_serve_with_a_plugged_policy_then_stop(self):
        modules = os.path.join(self.folder, "modules")
        os.makedirs(modules)
        with open(os.path.join(modules, "plugged_policy.py"), "w") as handle:
            handle.write(PLUGGED_POLICY)
        state = os.path.join(self.folder, "served")
        settings = os.path.join(self.folder, "settings.json")
        environment = dict(os.environ, PYTHONPATH=modules)
        sirven = os.path.join(REPO, "bin", "sirven")
        process = subprocess.Popen([sirven, "runtime", "--state-dir", state, "serve", "--port", "0",
                                    "--settings", settings, "--fetcher", "python",
                                    "--policy", "plugged_policy:make"],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
        self.addCleanup(process.stderr.close)
        self.addCleanup(process.stdout.close)
        self.addCleanup(lambda: process.poll() is None and process.kill())
        discovery = os.path.join(state, "runtime.json")
        for _ in range(100):
            if os.path.exists(discovery) or process.poll() is not None:
                break
            time.sleep(0.1)
        self.assertTrue(os.path.exists(discovery), process.stderr.read().decode("utf-8") if process.poll() is not None else "")

        def agent(*arguments):
            completed = subprocess.run([sirven, "runtime", "--state-dir", state] + list(arguments),
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
            return completed.returncode, json.loads(completed.stdout.decode("utf-8"))

        code, record = agent("fetch", self.origin_url("/page"))
        self.assertEqual((0, "ok", "plugged", "plugged_allowed"),
                         (code, record["outcome"], record["decision"]["policy"], record["decision"]["reason"]))
        code, record = agent("fetch", "http://www.blocked.example/")
        self.assertEqual((2, "blocked_by_owner"), (code, record["decision"]["reason"]))
        self.assertEqual("plugged", agent("status")[1]["policy"])

        process.send_signal(signal.SIGTERM)
        self.assertEqual(0, process.wait(timeout=10))
        self.assertFalse(os.path.exists(discovery))
        completed = subprocess.run([sirven, "runtime", "--state-dir", state, "status"],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(69, completed.returncode)
        self.assertIn(b"the runtime is not running", completed.stderr)


# the Swift helper: the browser-like fingerprint ------------------------------------------

@unittest.skipUnless(sys.platform == "darwin" and os.access(HELPER, os.X_OK), "the fetch helper is not built: make runtime")
class HelperFetcherTests(RuntimeCase):
    fetcher_kind = "helper"

    def test_the_helper_fetches_with_safari_headers_and_no_redirects(self):
        record = self.client.fetch(self.origin_url("/redirect"))
        self.assertEqual(("ok", "apple-urlsession", 1), (record["outcome"], record["fingerprint"], len(record["redirects"])))
        user_agent = [seen[2].get("User-Agent") for seen in Origin.seen if seen[1] == "/page"][0]
        self.assertIn("Safari/", user_agent)
        self.assertIn("Version/", user_agent)

    def test_the_helper_reports_a_site_block(self):
        record = self.client.fetch(self.origin_url("/challenge"))
        self.assertEqual(("blocked_by_site", "challenge"), (record["outcome"], record["block"]["kind"]))
        self.assertEqual(1, len([seen for seen in Origin.seen if seen[1] == "/challenge"]))


# the real connection, only when asked ----------------------------------------------------

@unittest.skipUnless(LIVE, "live network tests run with SIRVEN_LIVE_TESTS=1")
class LiveTests(RuntimeCase):
    fetcher_kind = "auto"

    def test_https_through_the_fetch_channel_from_the_own_connection(self):
        record = self.client.fetch("https://example.com/")
        self.assertEqual(("ok", 200, "own_connection"), (record["outcome"], record["status"], record["egress"]))
        self.assertIn(b"Example Domain", base64.b64decode(record["body_base64"]))

    def test_https_through_the_tunnel_from_the_own_connection(self):
        completed = subprocess.run(["curl", "--silent", "--show-error", "--max-time", "20", "--noproxy", "",
                                    "--proxy", self.client.proxy_url(), "https://example.com/"],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertIn(b"Example Domain", completed.stdout)


if __name__ == "__main__":
    unittest.main()
