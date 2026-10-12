"""the tier dial's live adapters (app/serve.py --live) answer in the shapes of app/fakes.

the page was built against the fakes. this starts a real runtime, writes a real ledger entry
and a registry in the published format, and checks that every key the page could read from a
fake is there in the live answer, with nothing extra.

run with: python3 -m unittest discover -s tests/app
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
sys.path.insert(0, os.path.join(REPO, "lib"))
sys.path.insert(0, os.path.join(REPO, "app"))
import serve  # noqa: E402
from sirven_runtime import server  # noqa: E402

FAKES = os.path.join(REPO, "app", "fakes")


def fake(kind, name):
    with open(os.path.join(FAKES, kind, name + ".json")) as handle:
        return json.load(handle)


class LiveShapes(unittest.TestCase):

    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="sirven-app-live.")
        self.addCleanup(shutil.rmtree, self.folder, True)
        self.state = os.path.join(self.folder, "state")
        runtime = server.build(state_dir=self.state, port=0, fetcher_kind="python")
        server.write_discovery(runtime.runtime)
        server.serve_in_thread(runtime)
        self.addCleanup(runtime.server_close)
        self.addCleanup(runtime.shutdown)
        os.makedirs(os.path.join(self.state, "peer-routing"))
        subprocess.run([sys.executable, os.path.join(REPO, "lib", "reciprocity.py"), "record",
                        "--ledger", os.path.join(self.state, "peer-routing", "reciprocity.jsonl"),
                        "--direction", "carried", "--bytes", "84000000", "--domain", "rides.example.com",
                        "--session", "s-0007", "--transfer", "t-1", "--peer", "key"], check=True)
        self.registry = os.path.join(self.folder, "registry.json")
        with open(self.registry, "w") as handle:
            json.dump({"format": "sirven-allowlist-registry/1", "version": 3, "updated": "2026-10-12",
                       "reviewers": ["Jose Sirven"], "quorum": 1, "pending": [], "declined": [], "history": [],
                       "approved": [{"domain": "rides.example.com", "includes_subdomains": False,
                                     "decision_record": "decisions/x.json", "requested": "2026-10-01",
                                     "rationale": "why", "scope": ["public_pages"], "reviewed": "2026-10-12",
                                     "reviewers": ["Jose Sirven"]}]}, handle)
        self.live = serve.Live(self.state, self.registry)

    def test_runtime_state_has_the_fake_shape(self):
        self.assertEqual(set(fake("runtime", "solo-blocked")), set(self.live.state()))
        self.assertIs(False, self.live.state()["peer_routing_available"])

    def test_ledger_has_the_fake_shape(self):
        usage, sample = self.live.usage(), fake("ledger", "under")
        self.assertEqual(set(sample), set(usage))
        self.assertEqual(set(sample["sessions"][0]), set(usage["sessions"][0]))
        self.assertEqual(set(sample["period"]), set(usage["period"]))
        self.assertEqual(5_000_000_000, usage["cap_bytes"])
        self.assertEqual(84_000_000, usage["carried_bytes"])

    def test_registry_has_the_fake_shape(self):
        registry, sample = self.live.registry, fake("registry", "sample")
        self.assertEqual(set(sample), set(registry))
        self.assertEqual(set(sample["entries"][0]), set(registry["entries"][0]))
        self.assertEqual(("rides.example.com", "read"), (registry["entries"][0]["domain"], registry["entries"][0]["scope"]))

    def test_neighborly_is_refused_while_peer_routing_is_unavailable(self):
        self.assertEqual((409, {"error": "peer_routing_unavailable"}), self.live.set_tier("neighborly"))
        self.assertEqual((409, {"error": "tier_not_open"}), self.live.set_tier("coop"))
        self.assertEqual(200, self.live.set_tier("solo")[0])

    def test_the_consent_moment_is_remembered(self):
        self.assertEqual(200, self.live.record_consent("not_open")[0])
        self.assertEqual({"prompted": True, "decision": "not_open"}, self.live.state()["consent"])


if __name__ == "__main__":
    unittest.main()
