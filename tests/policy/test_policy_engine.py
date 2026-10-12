"""decision table tests for lib/policy_engine.py: every tier, direction, and envelope state.

run with: python3 -m unittest discover -s tests/policy
"""

import base64
import hashlib
import itertools
import json
import os
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
import policy_engine as engine  # noqa: E402

NOW = 1_800_000_000
DIGEST = hashlib.sha256(b"GET / HTTP/1.1").hexdigest()


def snapshot(entries=None, **overrides):
    data = {"schema_version": 1, "status": "published", "serial": 3, "reviewer": "Jose Sirven",
            "published_at": NOW - 100, "expires_at": NOW + 3600,
            "entries": entries if entries is not None else [
                {"domain": "public.example.org", "tiers": ["Neighborly", "Co-op"]},
                {"domain": "coop.example.org", "tiers": ["Co-op"]},
                {"domain": "signin.example.org", "tiers": ["Neighborly", "Co-op"], "authenticated_sessions": True},
            ]}
    data.update(overrides)
    return data


def current(data=None):
    return engine.refresh_registry(lambda: b"bytes", lambda _: data or snapshot(), NOW)


def envelope(domain="public.example.org", posture="identity", issued=NOW - 10,
             expires=NOW + 200, digest=DIGEST):
    """an envelope in the lib/attestation shape. the signature is not real: the engine's own
    checks are structural, and signatures are the verifier's job (tests/peer_routing)."""
    payload = {"version": 1, "type": "request", "posture": posture, "agent": "personal",
               "user": "requester", "key": "a" * 22, "audience": "carrier-peer",
               "domain": domain, "request_digest": digest,
               "cap": {"period": "2027-01", "limit_bytes": 5_000_000_000, "used_bytes": 0, "request_bytes": 4096},
               "issued_at": issued, "expires_at": expires, "nonce": "b" * 22}
    encoded = base64.urlsafe_b64encode(json.dumps(payload).encode("utf-8")).decode("ascii").rstrip("=")
    return {"sirven_attestation": 1, "type": "request", "payload": encoded, "signature": "c" * 86}


def peer(domain="public.example.org", tier="Neighborly", authenticated=False, env="default"):
    return engine.Request(domain, tier, "peer", authenticated, DIGEST,
                          envelope(domain) if env == "default" else env)


def verifier_returning(state):
    calls = []

    def verify(envelope_, request, now):
        calls.append((envelope_, request, now))
        if state == "valid":
            return engine.Attestation("valid", "identity", request.domain, request.request_digest,
                                      "a" * 64, "b" * 64, 4096)
        return engine.Attestation(state)
    verify.calls = calls
    return verify


class DecisionTable(unittest.TestCase):

    def test_own_traffic_is_allowed_locally_in_every_tier_and_registry_state(self):
        for tier, state in itertools.product(engine.TIERS, (None, current(), {"status": "unavailable"})):
            for domain in ("public.example.org", "never-reviewed.example.com"):
                decision = engine.classify(engine.Request(domain, tier, "own"), state, NOW)
                self.assertEqual((engine.ALLOW_LOCAL, "own_egress"), decision[:2], (tier, domain))

    def test_solo_refuses_every_peer_request_whatever_the_envelope(self):
        verify = verifier_returning("valid")
        for authenticated, domain in itertools.product((False, True), ("public.example.org", "signin.example.org")):
            decision = engine.classify(peer(domain, "Solo", authenticated), current(), NOW, verify, ship_gate="open")
            self.assertEqual((engine.REFUSE, "solo_never_carries"), decision[:2])
        self.assertEqual([], verify.calls, "Solo must never reach the attestation verifier")

    def test_a_fresh_install_carries_nothing_for_anyone(self):
        verify = verifier_returning("valid")
        for tier in engine.CARRYING_TIERS:
            decision = engine.classify(peer(tier=tier), None, NOW, verify, ship_gate="open")
            self.assertEqual((engine.REFUSE, "registry_unavailable"), decision[:2])
        self.assertEqual([], verify.calls)

    def test_non_allowlisted_domains_are_never_carried_whatever_else_is_true(self):
        verify = verifier_returning("valid")
        for tier, authenticated, gate in itertools.product(engine.CARRYING_TIERS, (False, True), ("open", "closed")):
            decision = engine.classify(peer("unlisted.example.com", tier, authenticated), current(), NOW, verify, ship_gate=gate)
            self.assertEqual((engine.REFUSE, "site_not_allowlisted"), decision[:2])
        self.assertEqual([], verify.calls)

    def test_subdomains_and_parents_of_a_listed_domain_are_not_listed(self):
        for domain in ("www.public.example.org", "example.org", "public.example.org.evil.com"):
            self.assertEqual("site_not_allowlisted", engine.classify(peer(domain), current(), NOW, verifier_returning("valid")).code)

    def test_tier_must_be_reviewed_for_the_site(self):
        verify = verifier_returning("valid")
        self.assertEqual("tier_not_reviewed", engine.classify(peer("coop.example.org", "Neighborly"), current(), NOW, verify).code)
        self.assertEqual(engine.ALLOW_PEER_CARRIER, engine.classify(peer("coop.example.org", "Co-op"), current(), NOW, verify).action)

    def test_every_envelope_state_in_every_carrying_tier(self):
        for tier, state in itertools.product(engine.CARRYING_TIERS, engine.ENVELOPE_STATES):
            if state == "missing":
                continue
            decision = engine.classify(peer(tier=tier), current(), NOW, verifier_returning(state))
            if state == "valid":
                self.assertEqual((engine.ALLOW_PEER_CARRIER, "reviewed_peer_request"), decision[:2])
                self.assertEqual(4096, decision.details["maximum_bytes"])
                self.assertEqual(3, decision.details["registry_serial"])
            else:
                self.assertEqual((engine.REFUSE, "attestation_" + state), decision[:2], (tier, state))
                self.assertIn(decision.code, engine.REASONS)

    def test_structural_envelope_states_are_caught_before_the_verifier(self):
        cases = {
            "missing": None,
            "malformed": {"payload": "nope"},
            "unsupported_posture": envelope(posture="pseudonymous"),
            "expired": envelope(expires=NOW),
            "wrong_domain": envelope(domain="coop.example.org"),
            "wrong_request": envelope(digest="d" * 64),
        }
        for state, env in cases.items():
            verify = verifier_returning("valid")
            self.assertEqual("attestation_" + state, engine.classify(peer(env=env), current(), NOW, verify).code)
            self.assertEqual([], verify.calls, state)
        unknown_posture = envelope(posture="anonymous")
        self.assertEqual("attestation_malformed", engine.classify(peer(env=unknown_posture), current(), NOW, verifier_returning("valid")).code)
        future = envelope(issued=NOW + 5)
        self.assertEqual("attestation_expired", engine.classify(peer(env=future), current(), NOW, verifier_returning("valid")).code)

    def test_no_verifier_means_no_carrying(self):
        self.assertEqual("attestation_verifier_unavailable", engine.classify(peer(), current(), NOW).code)

    def test_a_verifier_that_raises_or_answers_nonsense_refuses(self):
        def raises(*_):
            raise RuntimeError("boom")
        for verify in (raises, lambda *_: {"state": "valid"}, lambda *_: engine.Attestation("sure")):
            self.assertEqual("attestation_verifier_unavailable", engine.classify(peer(), current(), NOW, verify).code)

    def test_the_verifier_must_vouch_for_this_exact_request(self):
        def verifier(**overrides):
            fields = dict(state="valid", posture="identity", domain="public.example.org",
                          request_digest=DIGEST, key_id="a" * 64, nonce="b" * 64, maximum_bytes=4096)
            fields.update(overrides)
            return lambda *_: engine.Attestation(**fields)
        expectations = {
            "attestation_unsupported_posture": verifier(posture="pseudonymous"),
            "attestation_wrong_domain": verifier(domain="coop.example.org"),
            "attestation_wrong_request": verifier(request_digest="e" * 64),
            "attestation_malformed": verifier(maximum_bytes=0),
        }
        for code, verify in expectations.items():
            self.assertEqual(code, engine.classify(peer(), current(), NOW, verify).code)

    def test_the_verifier_runs_only_after_the_registry_checks_pass(self):
        verify = verifier_returning("valid")
        engine.classify(peer(), current(), NOW, verify)
        self.assertEqual(1, len(verify.calls))

    def test_domains_are_matched_case_insensitively_and_only_as_plain_names(self):
        verify = verifier_returning("valid")
        self.assertEqual(engine.ALLOW_PEER_CARRIER, engine.classify(
            engine.Request("Public.Example.ORG.", "Neighborly", "peer", False, DIGEST, envelope()), current(), NOW, verify).action)
        for domain in ("https://public.example.org/", "public.example.org:443", "*.example.org", "10.0.0.1",
                       "localhost", "", "bücher.example", None):
            decision = engine.classify(engine.Request(domain, "Neighborly", "peer", False, DIGEST, envelope()), current(), NOW, verify)
            self.assertEqual((engine.REFUSE, "invalid_domain"), decision[:2], domain)

    def test_malformed_requests_are_refused(self):
        for request in (None, {"domain": "public.example.org"},
                        engine.Request("public.example.org", "Premium", "peer"),
                        engine.Request("public.example.org", "Neighborly", "sideways"),
                        engine.Request("public.example.org", "Neighborly", "peer", "yes")):
            self.assertEqual("invalid_request", engine.classify(request, current(), NOW).code)
        self.assertEqual("invalid_request", engine.classify(peer(), current(), -1).code)
        self.assertEqual("invalid_request", engine.classify(peer(), current(), 1.5).code)


class ShipGate(unittest.TestCase):

    def test_the_gate_ships_closed(self):
        self.assertEqual("closed", engine.SHIP_GATE_AUTHENTICATED_PEER_TRAFFIC)

    def test_authenticated_peer_traffic_is_refused_while_the_gate_is_closed(self):
        verify = verifier_returning("valid")
        for tier in engine.CARRYING_TIERS:
            decision = engine.classify(peer("signin.example.org", tier, True), current(), NOW, verify)
            self.assertEqual((engine.REFUSE, "ship_gate_closed"), decision[:2])
        self.assertEqual([], verify.calls)

    def test_only_the_exact_word_open_opens_it(self):
        for gate in ("Open", "yes", True, 1, None, ""):
            self.assertEqual("ship_gate_closed", engine.classify(
                peer("signin.example.org", authenticated=True), current(), NOW, verifier_returning("valid"), ship_gate=gate).code)

    def test_with_the_gate_open_both_review_and_attestation_are_load_bearing(self):
        allowed = engine.classify(peer("signin.example.org", authenticated=True), current(), NOW,
                                  verifier_returning("valid"), ship_gate="open")
        self.assertEqual(engine.ALLOW_PEER_CARRIER, allowed.action)
        not_reviewed = engine.classify(peer("public.example.org", authenticated=True), current(), NOW,
                                       verifier_returning("valid"), ship_gate="open")
        self.assertEqual("authenticated_not_reviewed", not_reviewed.code)
        for state in engine.ENVELOPE_STATES:
            if state in ("valid", "missing"):
                continue
            decision = engine.classify(peer("signin.example.org", authenticated=True), current(), NOW,
                                       verifier_returning(state), ship_gate="open")
            self.assertEqual("attestation_" + state, decision.code)
        no_registry = engine.classify(peer("signin.example.org", authenticated=True), None, NOW,
                                      verifier_returning("valid"), ship_gate="open")
        self.assertEqual("registry_unavailable", no_registry.code)

    def test_gate_status_reports_what_is_missing(self):
        status = engine.ship_gate_status(None, NOW)
        self.assertEqual("registry_unavailable", status["registry"])
        self.assertFalse(status["authenticated_peer_traffic_possible"])
        status = engine.ship_gate_status(current(), NOW)
        self.assertEqual(["signin.example.org"], status["sites_reviewed_for_signed_in_sessions"])
        self.assertFalse(status["authenticated_peer_traffic_possible"])
        self.assertTrue(engine.ship_gate_status(current(), NOW, ship_gate="open")["authenticated_peer_traffic_possible"])


class RegistryRefresh(unittest.TestCase):

    def test_offline_refresh_stops_carrying_and_leaves_own_egress_alone(self):
        def offline():
            raise OSError("network is unreachable")
        state = engine.refresh_registry(offline, json.loads, NOW)
        self.assertEqual("unavailable", state["status"])
        self.assertNotIn("snapshot", state)
        self.assertEqual("OSError", state["reason"])
        verify = verifier_returning("valid")
        self.assertEqual("registry_unavailable", engine.classify(peer(), state, NOW, verify).code)
        for tier in engine.TIERS:
            self.assertEqual(engine.ALLOW_LOCAL, engine.classify(engine.Request("anything.example.com", tier, "own"), state, NOW).action)

    def test_a_failed_signature_check_is_the_same_as_offline(self):
        def bad_signature(_):
            raise ValueError("signature mismatch")
        self.assertEqual("unavailable", engine.refresh_registry(lambda: b"x", bad_signature, NOW)["status"])

    def test_refresh_errors_never_echo_their_text(self):
        def leaky():
            raise OSError("https://user:secret-token@registry.example.org failed")
        self.assertNotIn("secret-token", json.dumps(engine.refresh_registry(leaky, json.loads, NOW)))

    def test_snapshots_that_are_not_reviewed_and_current_are_rejected(self):
        bad = [
            snapshot(reviewer="someone else"),
            snapshot(status="draft"),
            snapshot(schema_version=2),
            snapshot(published_at=NOW + 10),
            snapshot(expires_at=NOW),
            snapshot(entries=[{"domain": "a.example.org", "tiers": ["Solo"]}]),
            snapshot(entries=[{"domain": "a.example.org", "tiers": []}]),
            snapshot(entries=[{"domain": "*.example.org", "tiers": ["Co-op"]}]),
            snapshot(entries=[{"domain": "a.example.org", "tiers": ["Co-op"], "wildcard": True}]),
            snapshot(entries=[{"domain": "a.example.org", "tiers": ["Co-op"]}, {"domain": "A.example.org", "tiers": ["Co-op"]}]),
            snapshot(entries=[{"domain": "a.example.org", "tiers": ["Co-op"], "authenticated_sessions": "yes"}]),
            ["not", "an", "object"],
        ]
        for data in bad:
            self.assertEqual("unavailable", engine.refresh_registry(lambda: b"x", lambda _, d=data: d, NOW)["status"], data)

    def test_an_empty_published_registry_carries_nothing(self):
        state = current(snapshot(entries=[]))
        self.assertEqual("current", state["status"])
        self.assertEqual("site_not_allowlisted", engine.classify(peer(), state, NOW, verifier_returning("valid")).code)

    def test_a_snapshot_that_expires_after_refresh_stops_carrying(self):
        state = current()
        later = state["snapshot"]["expires_at"]
        self.assertEqual("registry_expired", engine.classify(peer(), state, later, verifier_returning("valid")).code)
        self.assertEqual(engine.ALLOW_LOCAL, engine.classify(engine.Request("public.example.org", "Co-op", "own"), state, later).action)

    def test_a_tampered_state_file_is_rechecked_at_decision_time(self):
        state = current()
        state["snapshot"]["entries"].append({"domain": "unlisted.example.com", "tiers": ["Neighborly"], "extra": 1})
        self.assertEqual("registry_unavailable", engine.classify(peer("unlisted.example.com"), state, NOW, verifier_returning("valid")).code)


class DecisionLog(unittest.TestCase):

    def setUp(self):
        self.directory = tempfile.mkdtemp()
        self.path = os.path.join(self.directory, "decisions.jsonl")

    def test_every_decision_is_logged_for_the_meter_and_the_interface(self):
        engine.classify_and_log(engine.Request("private.example.com", "Solo", "own"), None, NOW, self.path)
        engine.classify_and_log(peer(), current(), NOW, self.path, verifier_returning("valid"))
        engine.classify_and_log(peer("unlisted.example.com"), current(), NOW, self.path, verifier_returning("valid"))
        records = engine.read_log(self.path)
        self.assertEqual(["own_egress", "reviewed_peer_request", "site_not_allowlisted"], [r["code"] for r in records])
        own, carried, refused = records
        self.assertNotIn("domain", own, "own traffic must not build a browsing history")
        self.assertEqual("public.example.org", carried["domain"])
        self.assertEqual(4096, carried["maximum_bytes"])
        self.assertEqual("a" * 64, carried["key_id"])
        self.assertEqual(engine.REASONS["site_not_allowlisted"], refused["reason"])
        for record in records:
            self.assertEqual(1, record["schema_version"])
            self.assertEqual(NOW, record["time"])
            self.assertEqual(32, len(record["decision_id"]))
        self.assertEqual(0o600, stat.S_IMODE(os.stat(self.path).st_mode))

    def test_the_envelope_and_nonce_never_reach_the_log(self):
        engine.classify_and_log(peer(), current(), NOW, self.path, verifier_returning("valid"))
        with open(self.path) as handle:
            text = handle.read()
        self.assertNotIn("c" * 86, text)
        self.assertNotIn('"' + "b" * 64 + '"', text)
        self.assertNotIn("requester", text)

    def test_an_unwritable_log_raises_so_the_runtime_refuses(self):
        os.symlink(os.path.join(self.directory, "elsewhere"), self.path)
        with self.assertRaises(OSError):
            engine.classify_and_log(peer(), current(), NOW, self.path, verifier_returning("valid"))

    def test_a_shared_log_file_is_refused(self):
        with open(self.path, "w"):
            pass
        os.chmod(self.path, 0o644)
        with self.assertRaises(PermissionError):
            engine.classify_and_log(peer(), current(), NOW, self.path)

    def test_a_torn_last_line_is_skipped_when_reading(self):
        engine.classify_and_log(peer(), None, NOW, self.path)
        with open(self.path, "a") as handle:
            handle.write('{"schema_version": 1, "act')
        self.assertEqual(1, len(engine.read_log(self.path)))


class Determinism(unittest.TestCase):

    def test_the_same_inputs_give_the_same_decision(self):
        state = current()
        first = [engine.classify(peer(d, t, a), state, NOW, verifier_returning("valid"), ship_gate=g)
                 for d, t, a, g in itertools.product(("public.example.org", "signin.example.org", "x.example.com"),
                                                     engine.TIERS, (False, True), ("open", "closed"))]
        second = [engine.classify(peer(d, t, a), state, NOW, verifier_returning("valid"), ship_gate=g)
                  for d, t, a, g in itertools.product(("public.example.org", "signin.example.org", "x.example.com"),
                                                      engine.TIERS, (False, True), ("open", "closed"))]
        self.assertEqual(first, second)

    def test_every_refusal_has_a_plain_reason(self):
        for code, reason in engine.REASONS.items():
            self.assertTrue(reason.endswith("."), code)
        for state in engine.ENVELOPE_STATES:
            if state != "valid":
                self.assertIn("attestation_" + state, engine.REASONS)
        for state in set(engine.ATTESTATION_ERROR_STATES.values()):
            self.assertIn(state, engine.ENVELOPE_STATES)


if __name__ == "__main__":
    unittest.main()
