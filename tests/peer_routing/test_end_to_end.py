"""peer routing, end to end: the ship gate's two components, through the real code of each piece.

nothing here is a fake. the identity issuer, the user's device, and the carrying peer are the
attestation command line (lib/attestation/cli.mjs) in separate folders. the registry comes out
of the site-allowlist review workflow (lib/allowlist_review.py: request, prepare, vote, build,
validate, publish), is signed by the issuer, and is verified on the peer. every carrying
decision runs the allowlist policy engine, the attestation peer verifier on the exact request
bytes, and the reciprocity ledger, through lib/peer_routing.py.

run with: python3 -m unittest discover -s tests/peer_routing
"""

import base64
import calendar
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import unittest.mock

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "lib"))
import peer_routing  # noqa: E402
import policy_engine as engine  # noqa: E402
from sirven_runtime import seam  # noqa: E402

ATTESTATION_COMMAND = os.path.join(REPO, "lib", "attestation", "cli.mjs")
REVIEW = os.path.join(REPO, "lib", "allowlist_review.py")
RECIPROCITY = os.path.join(REPO, "lib", "reciprocity.py")
NOW = calendar.timegm((2026, 10, 20, 12, 0, 0))
RIDES = "rides.example.com"          # approved for public pages and signed-in sessions
NEWS = "news.example.com"            # approved for public pages only
REQUEST = b"GET /schedule HTTP/1.1\r\nHost: rides.example.com\r\n\r\n"


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


@unittest.skipUnless(shutil.which("node"), "the attestation layer needs node 18 or newer")
class EndToEnd(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.mkdtemp(prefix="sirven-peer-routing-")
        join = lambda *parts: os.path.join(cls.scratch, *parts)  # noqa: E731
        cls.issuer, cls.device, cls.state = join("issuer"), join("device"), join("node")
        os.makedirs(cls.state)

        # the identity issuer certifies one user's device key.
        node("issuer", "init", "--dir", cls.issuer)
        node("user", "init", "--dir", cls.device, "--user", "alice")
        certificate = node("issuer", "certify", "--dir", cls.issuer, "--request", os.path.join(cls.device, "certification-request.json"))
        with open(join("certificate.json"), "w") as handle:
            json.dump(certificate, handle)
        node("user", "install-certificate", "--dir", cls.device, "--certificate", join("certificate.json"))
        node("issuer", "publish", "--dir", cls.issuer)

        # the carrying node trusts that issuer and installs its revocation list.
        with open(join("empty-allowlist.txt"), "w"):
            pass
        cls.peer_id = node("peer", "init", "--dir", os.path.join(cls.state, "peer"),
                           "--issuer-public-key", os.path.join(cls.issuer, "issuer.pub"),
                           "--allowlist", join("empty-allowlist.txt"))["peer"]
        node("peer", "install-revocation-list", "--dir", os.path.join(cls.state, "peer"),
             "--list", os.path.join(cls.issuer, "revocation-list.json"))

        # the site-allowlist review workflow approves two sites, start to finish.
        cls.allowlist = join("allowlist")
        os.makedirs(cls.allowlist)
        shutil.copy(os.path.join(REPO, "allowlist", "policy.json"), cls.allowlist)
        for domain, scopes in ((RIDES, ["public_pages", "authenticated_sessions"]), (NEWS, ["public_pages"])):
            review(cls.allowlist, "request", "--domain", domain, "--requested-by", "sirven_user", "--date", "2026-10-01",
                   "--case", "a personal agent reads the schedule and books for its one user")
            name = "2026-10-01-%s-1" % domain
            review(cls.allowlist, "prepare", name, "--prepared-by", "end-to-end test", "--date", "2026-10-01")
            decision = os.path.join(cls.allowlist, "decisions", name + ".json")
            with open(decision) as handle:
                record = json.load(handle)
            for question in record["rubric"]:
                record["rubric"][question] = {"rating": "pass", "finding": "test fixture, read 2026-10-01 at the primary source"}
            record["recommendation"] = {"decision": "approve", "scope": scopes, "rationale": "test fixture"}
            with open(decision, "w") as handle:
                json.dump(record, handle, indent=2)
            vote = ["vote", name, "--reviewer", "Jose Sirven", "--decision", "approve", "--date", "2026-10-12"]
            for scope in scopes:
                vote += ["--scope", scope]
            review(cls.allowlist, *vote)
        review(cls.allowlist, "build")
        review(cls.allowlist, "validate")
        review(cls.allowlist, "publish", "--dest", join("published"), "--staging")

        # the issuer signs that registry version; the node verifies and installs it.
        cls.signed = json.dumps(node("registry", "sign", "--dir", cls.issuer,
                                     "--registry", join("published", "registry.json"))).encode()
        cls.registry_state = peer_routing.refresh(cls.state, cls.signed, NOW)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.scratch, ignore_errors=True)

    def envelope(self, domain=RIDES, request=REQUEST, audience=None, now=NOW, size=None):
        digest = __import__("hashlib").sha256(request).hexdigest()
        return node("sign", "--dir", self.device, "--audience", audience or self.peer_id, "--domain", domain,
                    "--bytes", str(size or len(request)), "--request-digest", digest, now=now)

    def carry(self, envelope, host=RIDES, request=REQUEST, tier="neighborly", authenticated=False,
              now=NOW, state=None, **options):
        return peer_routing.carry(state or self.state, host, tier, authenticated, request, envelope,
                                  "session-1", now, **options)

    # the path that works

    def test_the_registry_from_the_review_workflow_verifies_and_installs(self):
        self.assertEqual("current", self.registry_state["status"])
        domains = sorted(entry["domain"] for entry in self.registry_state["snapshot"]["entries"])
        self.assertEqual([NEWS, RIDES], domains)

    def test_a_reviewed_site_with_a_valid_attestation_is_carried_and_reserved(self):
        decision = self.carry(self.envelope())
        self.assertEqual(engine.ALLOW_PEER_CARRIER, decision["action"], decision)
        self.assertEqual("reviewed_peer_request", decision["code"])
        self.assertEqual(len(REQUEST), decision["details"]["maximum_bytes"])
        self.assertTrue(decision["details"]["reciprocity"]["within_cap"])
        self.assertEqual(5_000_000_000, decision["details"]["reciprocity"]["cap_bytes"])

    def test_www_matches_the_registry_entry(self):
        decision = self.carry(self.envelope(), host="www." + RIDES)
        self.assertEqual(engine.ALLOW_PEER_CARRIER, decision["action"], decision)

    # the ship gate: authenticated traffic

    def test_signed_in_traffic_is_refused_while_the_gate_is_closed(self):
        self.assertEqual("closed", engine.SHIP_GATE_AUTHENTICATED_PEER_TRAFFIC)
        self.assertEqual("ship_gate_closed", self.carry(self.envelope(), authenticated=True)["code"])

    def test_with_the_gate_open_signed_in_traffic_needs_a_site_reviewed_for_it(self):
        allowed = self.carry(self.envelope(), authenticated=True, ship_gate="open")
        self.assertEqual(engine.ALLOW_PEER_CARRIER, allowed["action"], allowed)
        news = self.carry(self.envelope(domain=NEWS), host=NEWS, authenticated=True, ship_gate="open")
        self.assertEqual("authenticated_not_reviewed", news["code"])

    # refusals, one per component

    def test_a_site_that_was_never_reviewed_is_refused(self):
        self.assertEqual("site_not_allowlisted", self.carry(self.envelope(domain="other.example.com"), host="other.example.com")["code"])

    def test_solo_never_carries(self):
        self.assertEqual("solo_never_carries", self.carry(self.envelope(), tier="solo")["code"])

    def test_a_tampered_registry_leaves_the_node_carrying_nothing(self):
        state = tempfile.mkdtemp(dir=self.scratch)
        shutil.copytree(os.path.join(self.state, "peer"), os.path.join(state, "peer"))
        signed = json.loads(self.signed)
        payload = json.loads(base64.urlsafe_b64decode(signed["payload"] + "=="))
        payload["expires_at"] += 86400
        signed["payload"] = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
        self.assertEqual("unavailable", peer_routing.refresh(state, json.dumps(signed).encode(), NOW)["status"])
        self.assertEqual("registry_unavailable", self.carry(self.envelope(), state=state)["code"])

    def test_a_registry_signed_by_an_untrusted_key_is_refused(self):
        stranger = os.path.join(self.scratch, "stranger")
        node("issuer", "init", "--dir", stranger)
        signed = json.dumps(node("registry", "sign", "--dir", stranger, "--registry",
                                 os.path.join(self.scratch, "published", "registry.json"))).encode()
        state = tempfile.mkdtemp(dir=self.scratch)
        shutil.copytree(os.path.join(self.state, "peer"), os.path.join(state, "peer"))
        self.assertEqual("unavailable", peer_routing.refresh(state, signed, NOW)["status"])

    def test_an_expired_registry_stops_carrying(self):
        self.assertEqual("registry_expired", self.carry(self.envelope(now=NOW + 8 * 86400), now=NOW + 8 * 86400)["code"])

    def test_an_envelope_for_another_peer_is_refused(self):
        other = node("peer", "init", "--dir", os.path.join(self.scratch, "other-peer"),
                     "--issuer-public-key", os.path.join(self.issuer, "issuer.pub"),
                     "--allowlist", os.path.join(self.scratch, "empty-allowlist.txt"))["peer"]
        self.assertEqual("attestation_wrong_peer", self.carry(self.envelope(audience=other))["code"])

    def test_an_envelope_for_different_bytes_is_refused(self):
        other = b"POST /book HTTP/1.1\r\nHost: rides.example.com\r\n\r\n"
        self.assertEqual("attestation_wrong_request", self.carry(self.envelope(request=other))["code"])

    def test_an_expired_envelope_is_refused(self):
        self.assertEqual("attestation_expired", self.carry(self.envelope(now=NOW - 600))["code"])

    def test_a_replayed_envelope_is_refused(self):
        envelope = self.envelope()
        self.assertEqual(engine.ALLOW_PEER_CARRIER, self.carry(envelope)["action"])
        self.assertEqual("attestation_replayed", self.carry(envelope)["code"])

    def test_a_replay_arriving_during_the_first_verify_is_refused(self):
        # the first verify holds the peer's verify lock after it has read the nonce memory
        # (SIRVEN_ATTESTATION_TEST_HOLD_MS). the second verify of the same envelope starts only
        # once the first is inside that step. with the lock it waits, sees the nonce, and is
        # refused. without the lock it reads the memory before the first writes it and is accepted.
        state = tempfile.mkdtemp(dir=self.scratch)
        peer = os.path.join(state, "peer")
        domains = os.path.join(state, "registry-domains.txt")
        shutil.copytree(os.path.join(self.state, "peer"), peer)
        shutil.copy(os.path.join(self.state, "registry-domains.txt"), domains)
        data = json.dumps(self.envelope()).encode("utf-8")
        command = ["node", ATTESTATION_COMMAND, "peer", "verify", "--dir", peer, "--host", RIDES,
                   "--bytes", str(len(REQUEST)), "--request-digest", hashlib.sha256(REQUEST).hexdigest(),
                   "--allowlist", domains]
        clock = dict(os.environ, SIRVEN_ATTESTATION_NOW=str(NOW))
        first = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 env=dict(clock, SIRVEN_ATTESTATION_TEST_HOLD_MS="2000"))
        first.stdin.write(data)
        first.stdin.close()
        marker = os.path.join(peer, "verify.paused")
        deadline = time.time() + 20
        while not os.path.exists(marker) and time.time() < deadline:
            time.sleep(0.01)
        self.assertTrue(os.path.exists(marker), "the first verify never reached its locked step")
        second = subprocess.run(command, input=data, capture_output=True, env=clock, timeout=60)
        first_err = first.stderr.read()
        first.wait(timeout=60)
        first.stdout.close()
        first.stderr.close()
        self.assertEqual(0, first.returncode, first_err.decode())
        self.assertEqual(3, second.returncode, second.stdout.decode())
        self.assertEqual("replayed", json.loads(second.stdout)["reason"])

    def test_a_key_identifier_that_begins_with_a_dash_is_carried(self):
        # key identifiers are base64url, so about one in 64 begins with "-". the ledger check
        # must take it as a value, not as an option, or a valid carry is refused. the verifier is
        # stubbed to name that key, so the case is hit every run rather than one run in 64.
        dash_key = "-E-Wceyl3J9Xl5prQCYaww"
        def verifier(state):
            def verify(envelope, request, now):
                return engine.Attestation("valid", "identity", request.domain, request.request_digest,
                                          dash_key, "n" * 22, len(REQUEST))
            return verify
        with unittest.mock.patch.object(peer_routing, "attestation_verifier", verifier):
            decision = self.carry(self.envelope())
        self.assertEqual(engine.ALLOW_PEER_CARRIER, decision["action"], decision)
        self.assertTrue(decision["details"]["reciprocity"]["within_cap"])

    def test_an_envelope_with_a_forged_signature_is_refused(self):
        envelope = dict(self.envelope())
        envelope["signature"] = envelope["signature"][:-4] + ("AAAA" if not envelope["signature"].endswith("AAAA") else "BBBB")
        self.assertEqual("attestation_invalid_signature", self.carry(envelope)["code"])

    def test_the_reciprocity_cap_refuses_past_5_gigabytes(self):
        state = tempfile.mkdtemp(dir=self.scratch)
        shutil.copytree(os.path.join(self.state, "peer"), os.path.join(state, "peer"))
        for name in ("registry-state.json", "registry-domains.txt"):
            shutil.copy(os.path.join(self.state, name), state)
        subprocess.run([sys.executable, RECIPROCITY, "record", "--ledger", os.path.join(state, "reciprocity.jsonl"),
                        "--now", str(NOW), "--direction", "carried", "--bytes", str(5_000_000_000 - 10),
                        "--domain", RIDES, "--session", "earlier", "--transfer", "t-1", "--peer", "someone"], check=True)
        decision = self.carry(self.envelope(), state=state)
        self.assertEqual("reciprocity_over_cap", decision["code"], decision)

    def test_a_revoked_user_is_refused(self):
        state = tempfile.mkdtemp(dir=self.scratch)
        shutil.copytree(os.path.join(self.state, "peer"), os.path.join(state, "peer"))
        for name in ("registry-state.json", "registry-domains.txt"):
            shutil.copy(os.path.join(self.state, name), state)
        issuer = os.path.join(self.scratch, "issuer-revoking")
        shutil.copytree(self.issuer, issuer)
        node("issuer", "revoke", "--dir", issuer, "--user", "alice", "--reason", "test")
        node("issuer", "publish", "--dir", issuer)
        node("peer", "install-revocation-list", "--dir", os.path.join(state, "peer"),
             "--list", os.path.join(issuer, "revocation-list.json"))
        self.assertEqual("attestation_revoked", self.carry(self.envelope(), state=state)["code"])

    # what the runtime and the tier dial see

    def test_readiness_sees_both_components_and_the_built_transport(self):
        report = peer_routing.readiness(self.state, NOW)
        self.assertEqual("ready", report["attestation"])
        self.assertEqual("current", report["registry"])
        self.assertTrue(report["components_ready"])
        self.assertEqual("built", report["transport"])
        self.assertTrue(report["peer_routing_available"])

    def test_a_fresh_node_is_not_ready(self):
        report = peer_routing.readiness(tempfile.mkdtemp(dir=self.scratch), NOW)
        self.assertEqual("no_peer_identity", report["attestation"])
        self.assertEqual("registry_unavailable", report["registry"])
        self.assertFalse(report["components_ready"])
        self.assertFalse(report["peer_routing_available"])

    def test_the_runtime_seam_still_refuses_to_carry(self):
        request = seam.EgressRequest(RIDES, 443, "https", "fetch", method="GET", signed_envelope=self.envelope())
        decision = seam.decide(request, None)
        self.assertEqual("refuse", decision.route)


if __name__ == "__main__":
    unittest.main()
