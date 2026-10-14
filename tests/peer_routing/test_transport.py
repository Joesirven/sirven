"""peer transport, end to end on loopback.

a mock origin server stands in for the site. the carrying machine runs the real carrier
(lib/peer_transport.py), with the real attestation layer, allowlist policy engine and
reciprocity ledger behind it (lib/peer_routing.py). the requesting process signs a real
envelope with the attestation command line and posts to the carrier over loopback.

the first test proves bytes move: the carrier returns the mock origin's response bytes to
the requester, the policy engine allows the carry, and the reciprocity ledger records the
transfer. the other tests cover the refusals the carrier is responsible for returning:
missing token, bad path, and a decision the policy engine refuses.

run with: python3 -m unittest discover -s tests/peer_routing
"""

import base64
import calendar
import hashlib
import http.server
import json
import os
import shutil
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from urllib import request as urllib_request

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "lib"))
import peer_routing  # noqa: E402
import peer_transport  # noqa: E402
import policy_engine as engine  # noqa: E402

ATTESTATION_COMMAND = os.path.join(REPO, "lib", "attestation", "cli.mjs")
REVIEW = os.path.join(REPO, "lib", "allowlist_review.py")
NOW = calendar.timegm((2026, 10, 20, 12, 0, 0))
RIDES = "rides.example.com"
ORIGIN_BODY = b"<html><body>schedule for rides, in body bytes the carrier is asked to move</body></html>"


def node(*arguments, now=NOW, data=None):
    answer = subprocess.run(["node", ATTESTATION_COMMAND] + list(arguments), input=data, capture_output=True,
                            env=dict(os.environ, SIRVEN_ATTESTATION_NOW=str(now)))
    if answer.returncode != 0:
        raise AssertionError("cli.mjs %s: %s" % (" ".join(arguments[:2]), answer.stderr.decode()))
    return json.loads(answer.stdout)


def review(root, *arguments):
    answer = subprocess.run([sys.executable, REVIEW, "--root", root] + list(arguments), capture_output=True, text=True)
    if answer.returncode != 0:
        raise AssertionError("allowlist_review.py %s: %s%s" % (arguments[0], answer.stdout, answer.stderr))
    return answer.stdout


class _OriginHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002
        return

    def do_GET(self):  # noqa: N802
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(ORIGIN_BODY)))
        self.end_headers()
        self.wfile.write(ORIGIN_BODY)


class _ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


@unittest.skipUnless(shutil.which("node"), "the attestation layer needs node 18 or newer")
class Transport(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.mkdtemp(prefix="sirven-peer-transport-")
        join = lambda *parts: os.path.join(cls.scratch, *parts)  # noqa: E731
        cls.issuer, cls.device, cls.state = join("issuer"), join("device"), join("node")
        os.makedirs(cls.state)

        # one issuer, one user, one carrying node, trusting the issuer.
        node("issuer", "init", "--dir", cls.issuer)
        node("user", "init", "--dir", cls.device, "--user", "alice")
        certificate = node("issuer", "certify", "--dir", cls.issuer,
                           "--request", os.path.join(cls.device, "certification-request.json"))
        with open(join("certificate.json"), "w") as handle:
            json.dump(certificate, handle)
        node("user", "install-certificate", "--dir", cls.device, "--certificate", join("certificate.json"))
        node("issuer", "publish", "--dir", cls.issuer)
        with open(join("empty-allowlist.txt"), "w"):
            pass
        cls.peer_id = node("peer", "init", "--dir", os.path.join(cls.state, "peer"),
                           "--issuer-public-key", os.path.join(cls.issuer, "issuer.pub"),
                           "--allowlist", join("empty-allowlist.txt"))["peer"]
        node("peer", "install-revocation-list", "--dir", os.path.join(cls.state, "peer"),
             "--list", os.path.join(cls.issuer, "revocation-list.json"))

        # one approved site, through the review workflow.
        cls.allowlist = join("allowlist")
        os.makedirs(cls.allowlist)
        shutil.copy(os.path.join(REPO, "allowlist", "policy.json"), cls.allowlist)
        review(cls.allowlist, "request", "--domain", RIDES, "--requested-by", "sirven_user",
               "--date", "2026-10-01",
               "--case", "a personal agent reads the schedule and books for its one user")
        name = "2026-10-01-%s-1" % RIDES
        review(cls.allowlist, "prepare", name, "--prepared-by", "transport test", "--date", "2026-10-01")
        decision = os.path.join(cls.allowlist, "decisions", name + ".json")
        with open(decision) as handle:
            record = json.load(handle)
        for question in record["rubric"]:
            record["rubric"][question] = {"rating": "pass", "finding": "test fixture"}
        record["recommendation"] = {"decision": "approve", "scope": ["public_pages"], "rationale": "test fixture"}
        with open(decision, "w") as handle:
            json.dump(record, handle, indent=2)
        review(cls.allowlist, "vote", name, "--reviewer", "Jose Sirven", "--decision", "approve",
               "--date", "2026-10-12", "--scope", "public_pages")
        review(cls.allowlist, "build")
        review(cls.allowlist, "validate")
        review(cls.allowlist, "publish", "--dest", join("published"), "--staging")
        signed = json.dumps(node("registry", "sign", "--dir", cls.issuer,
                                  "--registry", join("published", "registry.json"))).encode()
        peer_routing.refresh(cls.state, signed, NOW)

        # a mock origin on loopback. the carrier fetches it from its own connection.
        cls.origin = _ThreadedServer(("127.0.0.1", 0), _OriginHandler)
        cls.origin_thread = threading.Thread(target=cls.origin.serve_forever, daemon=True)
        cls.origin_thread.start()
        cls.origin_url = "http://%s:%d/schedule" % cls.origin.server_address

        # the carrier itself. pin the clock through the environment so attestation.verify agrees.
        cls.carrier = peer_transport.start_carrier(cls.state, 0, token="carrier-token-fixture")
        cls.carrier_thread = threading.Thread(target=cls.carrier.serve_forever, daemon=True)
        cls.carrier_thread.start()
        cls.carrier_url = "http://%s:%d" % cls.carrier.server_address

    @classmethod
    def tearDownClass(cls):
        cls.carrier.shutdown()
        cls.carrier.server_close()
        cls.origin.shutdown()
        cls.origin.server_close()
        shutil.rmtree(cls.scratch, ignore_errors=True)

    # the attestation command line reads SIRVEN_ATTESTATION_NOW; peer_routing.carry reads
    # the carrier's int(time.time()). pin both while the test runs so verification agrees.
    def setUp(self):
        self._old_env = os.environ.get("SIRVEN_ATTESTATION_NOW")
        os.environ["SIRVEN_ATTESTATION_NOW"] = str(NOW)
        self._old_time = time.time
        time.time = lambda: float(NOW)  # type: ignore[assignment]

    def tearDown(self):
        time.time = self._old_time  # type: ignore[assignment]
        if self._old_env is None:
            os.environ.pop("SIRVEN_ATTESTATION_NOW", None)
        else:
            os.environ["SIRVEN_ATTESTATION_NOW"] = self._old_env

    def envelope(self, request_bytes, domain=RIDES, cap_bytes=16384):
        digest = hashlib.sha256(request_bytes).hexdigest()
        return node("sign", "--dir", self.device, "--audience", self.peer_id, "--domain", domain,
                    "--bytes", str(cap_bytes), "--request-digest", digest)

    def test_bytes_move_from_the_origin_through_the_carrier_to_the_requester(self):
        request_bytes = b"GET /schedule HTTP/1.1\r\nHost: rides.example.com\r\n\r\n"
        envelope = self.envelope(request_bytes)
        answer = peer_transport.fetch_through_carrier(
            self.carrier_url, "carrier-token-fixture", RIDES, "neighborly",
            request_bytes, envelope, "session-move-1", self.origin_url)
        self.assertEqual("ok", answer["outcome"], answer)
        self.assertEqual(200, answer["status"])
        self.assertEqual(ORIGIN_BODY, base64.b64decode(answer["body_base64"]))
        self.assertEqual(len(ORIGIN_BODY), answer["bytes"])
        self.assertEqual(engine.ALLOW_PEER_CARRIER, answer["decision"]["action"])
        self.assertIsNotNone(answer["receipt"], "reciprocity ledger did not record the transfer")

    def test_a_site_the_review_workflow_never_approved_is_refused(self):
        request_bytes = b"GET /x HTTP/1.1\r\nHost: other.example.com\r\n\r\n"
        envelope = self.envelope(request_bytes, domain="other.example.com")
        with self.assertRaises(peer_transport.CarrierError) as caught:
            peer_transport.fetch_through_carrier(
                self.carrier_url, "carrier-token-fixture", "other.example.com", "neighborly",
                request_bytes, envelope, "session-refuse-1", self.origin_url)
        self.assertEqual(403, caught.exception.status)
        self.assertEqual("site_not_allowlisted", caught.exception.payload["decision"]["code"])

    def test_a_request_without_the_bearer_token_is_refused(self):
        request_bytes = b"GET /schedule HTTP/1.1\r\nHost: rides.example.com\r\n\r\n"
        envelope = self.envelope(request_bytes)
        with self.assertRaises(peer_transport.CarrierError) as caught:
            peer_transport.fetch_through_carrier(
                self.carrier_url, "wrong-token", RIDES, "neighborly",
                request_bytes, envelope, "session-noauth-1", self.origin_url)
        self.assertEqual(401, caught.exception.status)

    def test_a_wrong_path_is_a_404(self):
        req = urllib_request.Request(self.carrier_url + "/elsewhere", method="GET")
        from urllib.error import HTTPError
        try:
            urllib_request.urlopen(req, timeout=5)
            self.fail("the carrier accepted a wrong path")
        except HTTPError as error:
            self.assertEqual(404, error.code)


    def test_a_transfer_with_dash_leading_identifiers_gets_a_receipt(self):
        # record_transfer passes the peer identifier and the session as values. both may begin
        # with "-" (key identifiers are base64url), and the record must still be made.
        receipt = peer_transport.record_transfer(self.state, "Neighborly", RIDES, "-session-dash",
                                                 "-E-Wceyl3J9Xl5prQCYaww", 51, NOW)
        self.assertTrue(receipt["recorded"], receipt)
        self.assertEqual(51, receipt["bytes"])
        with open(os.path.join(self.state, "reciprocity.jsonl")) as handle:
            self.assertIn(receipt["transfer"], handle.read())

    def test_a_transfer_the_ledger_refuses_says_so(self):
        # a session with a line break is not an opaque reference, so the ledger refuses the record.
        # the carrier must report that, not return nothing.
        receipt = peer_transport.record_transfer(self.state, "Neighborly", RIDES, "bad\nsession",
                                                 self.peer_id, 51, NOW)
        self.assertFalse(receipt["recorded"], receipt)
        self.assertEqual("reciprocity_record_failed", receipt["reason"])
        self.assertEqual(51, receipt["bytes"])


if __name__ == "__main__":
    unittest.main()
