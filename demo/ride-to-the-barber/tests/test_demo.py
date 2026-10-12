"""tests for the ride-to-the-barber rehearsal. run from the repo with make test, or alone:
    python3 -m unittest discover -s demo/ride-to-the-barber/tests
"""

import contextlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

DEMO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_DIR = os.path.dirname(os.path.dirname(DEMO_DIR))
sys.path.insert(0, DEMO_DIR)

import demo  # noqa: E402
from ride_demo import gates, request  # noqa: E402
from ride_demo.concierge_queue import ConciergeQueue, QueueError  # noqa: E402
from ride_demo.connector import Router, money  # noqa: E402
from ride_demo.partner_backend import FixturePartnerBackend  # noqa: E402
from ride_demo.payment import RIDE_CATEGORY, Declined, TestModeCards  # noqa: E402

FAST = "0.2,0.2,0.2,0.2"
WINDOW = {"earliest": "2026-10-13T14:50:00-07:00", "latest": "2026-10-13T15:05:00-07:00"}
PREFERENCES = {"preferred_providers": ["Waymo"], "arrive_by": "2026-10-13T15:25:00-07:00"}


class Temporary(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ride-demo-test.")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def run_demo(self, *extra, state=None):
        state = state or os.path.join(self.tmp, "state")
        record = os.path.join(self.tmp, "record")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            status = demo.main(["run", "--state", state, "--record", record, "--operator-delays", FAST] + list(extra))
        return status, out.getvalue(), state, record


class RequestTest(unittest.TestCase):
    def test_demo_sentence(self):
        intent = request.parse("book me a ride to the barber after my 2pm meeting, Waymo preferred, under $25")
        self.assertEqual(intent, {"destination_place": "barber", "after_meeting_at": (14, 0),
                                  "preferred_providers": ["Waymo"], "budget_ceiling_minor": 2500})

    def test_variation(self):
        intent = request.parse("get me a ride to my barber after my 11:30am meeting, prefer Lyft, under $18.50")
        self.assertEqual(intent["after_meeting_at"], (11, 30))
        self.assertEqual(intent["preferred_providers"], ["Lyft"])
        self.assertEqual(intent["budget_ceiling_minor"], 1850)

    def test_not_understood(self):
        with self.assertRaises(request.NotUnderstood):
            request.parse("take me somewhere nice")


class ConnectorTest(unittest.TestCase):
    def router(self):
        return Router([FixturePartnerBackend(os.path.join(DEMO_DIR, "fixtures", "partner-quotes.json"))])

    def test_budget_counts_the_tip_ceiling(self):
        quotes = self.router().quote_ride("a", "b", WINDOW, PREFERENCES, money(2100))
        flagged = {option["product"]: option["constraint_flags"] for option in quotes["options"]}
        # UberX is 18.90 plus a 3.00 tip ceiling: 21.90, over a 21.00 budget.
        self.assertIn("over_budget", flagged["UberX"])

    def test_quotes_never_name_a_backend(self):
        quotes = self.router().quote_ride("a", "b", WINDOW, PREFERENCES, money(2500))["options"]
        for option in quotes:
            self.assertNotIn("backend_reference", option)
            text = json.dumps(option).lower()
            for word in ("partner", "fixture", "concierge", "req_"):
                self.assertNotIn(word, text)

    def test_book_is_idempotent_and_cancel_reconciles(self):
        router = self.router()
        quote = router.quote_ride("a", "b", WINDOW, PREFERENCES, money(2500))["options"][0]
        first = router.book_ride(quote["quote_id"], idempotency_key="key-1")
        again = router.book_ride(quote["quote_id"], idempotency_key="key-1")
        self.assertEqual(first["booking_id"], again["booking_id"])
        self.assertEqual(router.cancel_ride(first["booking_id"])["status"], "cancelled")


class PaymentTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.cards = TestModeCards(os.path.join(self.tmp, "cards.json"))
        quote = {"quote_id": "q_1", "provider": "Waymo", "product": "Waymo One",
                 "price": money(2140), "tip_ceiling": money(0)}
        self.card = self.cards.hold(quote, "the reason")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_cap_and_category(self):
        self.assertEqual(self.card["spending_limit_minor"], 2140)
        with self.assertRaises(Declined):
            self.cards.authorize(self.card["card_id"], 2141, RIDE_CATEGORY)
        with self.assertRaises(Declined):
            self.cards.authorize(self.card["card_id"], 500, "restaurants")
        self.cards.authorize(self.card["card_id"], 2140, RIDE_CATEGORY)

    def test_release_charges_nothing(self):
        released = self.cards.release(self.card["card_id"], "booking failed")
        self.assertEqual((released["status"], released["authorized_minor"]), ("released", 0))
        with self.assertRaises(Declined):
            self.cards.authorize(self.card["card_id"], 100, RIDE_CATEGORY)


class QueueTest(Temporary):
    def test_a_late_answer_cannot_overwrite_a_withdrawal(self):
        queue = ConciergeQueue(self.tmp)
        request_id = queue.create({"provider": "Waymo"}, {"granted": True})["request_id"]
        queue.move(request_id, "waiting_quote", "quote_claimed", concierge={"name": "test"})
        queue.move(request_id, ("waiting_quote", "quote_claimed"), "withdrawn", withdrawn_because="late")
        with self.assertRaises(QueueError):
            queue.move(request_id, "quote_claimed", "quoted", quote={})


class GateTest(Temporary):
    def test_closed_until_all_three_are_in_place(self):
        copy = os.path.join(self.tmp, "copy.md")
        with open(copy, "w") as handle:
            handle.write("status: draft for Jose's review\n")
        os.makedirs(os.path.join(self.tmp, "concierge-ops"))
        self.assertFalse(gates.concierge_gate(self.tmp, copy)["open"])
        for name in ("service-level-monitoring.md", "trust-and-safety-protocol.md"):
            with open(os.path.join(self.tmp, "concierge-ops", name), "w") as handle:
                handle.write("status: draft for Jose's review\n")
        with open(copy, "w") as handle:
            handle.write("status: approved\n")
        gate = gates.concierge_gate(self.tmp, copy)
        self.assertFalse(gate["open"], "a draft protocol on disk must not open the gate")
        self.assertEqual([False, False, True], [item["in_place"] for item in gate["items"]])
        for name in ("service-level-monitoring.md", "trust-and-safety-protocol.md"):
            with open(os.path.join(self.tmp, "concierge-ops", name), "w") as handle:
                handle.write("status: approved\n")
        self.assertTrue(gates.concierge_gate(self.tmp, copy)["open"])

    def test_the_merged_concierge_drafts_do_not_count_as_in_place(self):
        gate = gates.concierge_gate(REPO_DIR, os.path.join(DEMO_DIR, "copy", "concierge-disclosure.md"))
        self.assertFalse(gate["open"])
        self.assertEqual([False, False, False], [item["in_place"] for item in gate["items"]])

    def test_the_repo_gate_is_closed_today(self):
        status = gates.copy_status(os.path.join(DEMO_DIR, "copy", "concierge-disclosure.md"))
        self.assertNotEqual(status, "approved", "only Jose approves the disclosure")


class EndToEndTest(Temporary):
    def test_waymo_through_the_concierge(self):
        status, out, state, record = self.run_demo("--yes", "--scripted-concierge")
        self.assertEqual(status, 0, out)
        self.assertIn("Booked by Jose (rehearsal), a sirven concierge", out)
        self.assertIn("human-concierge tier: CLOSED, not shippable", out)
        with open(os.path.join(state, "calendar.json")) as handle:
            ride = json.load(handle)["events"][-1]
        self.assertEqual(ride["title"], "Ride to Mission Street Barbers (Waymo)")
        for needed in ("tracking: https://example.invalid/", "free cancellation until", "booking: b_"):
            self.assertIn(needed, ride["description"])
        with open(os.path.join(state, "ride.ics"), newline="") as handle:
            ics = handle.read()
        self.assertTrue(all(len(line.encode()) <= 75 for line in ics.split("\r\n")))
        with open(os.path.join(state, "charge-records.json")) as handle:
            card = json.load(handle)[0]
        self.assertEqual((card["spending_limit_minor"], card["authorized_minor"]), (2140, 2140))
        self.assertTrue(card["charge_record"]["booking_id"].startswith("b_"))
        self.assertIn("preferred service", card["charge_record"]["rationale"])
        with open(os.path.join(state, "service-levels.jsonl")) as handle:
            levels = [json.loads(line) for line in handle]
        self.assertEqual([(entry["leg"], entry["met"]) for entry in levels], [("quote", True), ("booking", True)])
        for name in ("transcript.txt", "run.cast", "events.jsonl"):
            self.assertTrue(os.path.getsize(os.path.join(record, name)) > 0)
        # the agent's own lines never show which backend answered; the backend's are labeled.
        self.assertNotIn("\n    request req_", out)
        self.assertIn("backend   | request req_", out)

    def test_the_concierge_sees_only_what_the_disclosure_says(self):
        status, out, state, _ = self.run_demo("--yes", "--scripted-concierge")
        self.assertEqual(status, 0, out)
        request = ConciergeQueue(os.path.join(state, "concierge-queue")).list(("booked",))[0]
        self.assertEqual(sorted(request["trip"]), ["departure_window", "destination", "origin", "provider"])
        self.assertEqual(sorted(request["payment"]),
                         ["allowed_categories", "card_id", "last4", "mode", "spending_limit_minor"])

    def test_a_second_run_on_the_same_state_still_finds_the_barber(self):
        state = os.path.join(self.tmp, "shared")
        for _ in range(2):
            status, out, _, _ = self.run_demo("--yes", "--scripted-concierge", state=state)
            self.assertEqual(status, 0, out)
            self.assertIn("next: Haircut at 3:30pm", out)

    def test_late_quote_is_surfaced_not_routed_around(self):
        status, out, state, _ = self.run_demo("--yes", "--scripted-concierge", "--scenario", "late_quote",
                                              "--quote-wait", "1")
        self.assertEqual(status, 0, out)
        self.assertIn("Waymo  unavailable: quote_target_missed", out)
        self.assertIn("I am not going to keep trying behind your back", out)
        self.assertIn("Ride to Mission Street Barbers (Uber)", out)
        self.assertIn("agent: Jose (rehearsal), a sirven concierge, saw this trip request.", out)

    def test_fare_over_the_limit_releases_the_card(self):
        status, out, state, _ = self.run_demo("--yes", "--scripted-concierge", "--scenario", "fare_over_cap")
        self.assertEqual(status, 4, out)
        with open(os.path.join(state, "charge-records.json")) as handle:
            card = json.load(handle)[0]
        self.assertEqual((card["status"], card["authorized_minor"]), ("released", 0))
        withdrawn = ConciergeQueue(os.path.join(state, "concierge-queue")).list(("withdrawn",))
        self.assertIn("cancel this ride", withdrawn[0]["withdrawn_because"])
        self.assertIn("agent: Jose (rehearsal), a sirven concierge, saw this trip request.", out)

    def test_no_answer_means_no(self):
        status, out, state, _ = self.run_demo("--scripted-concierge")
        self.assertEqual(status, 3, out)
        self.assertIn("no (no terminal to ask and no --yes)", out)
        self.assertFalse(os.path.exists(os.path.join(state, "charge-records.json")))

    def test_declining_the_concierge_keeps_the_trip_from_any_person(self):
        status, out, state, _ = self.run_demo("--yes", "--no-concierge", "--scripted-concierge")
        self.assertEqual(status, 0, out)
        self.assertEqual(os.listdir(os.path.join(state, "concierge-queue")), [])

    def test_live_fire_is_refused(self):
        status, out, _, _ = self.run_demo("--yes", "--live")
        self.assertEqual(status, 2)
        self.assertIn("refusing a live fire", out)


class ConsoleTest(Temporary):
    def test_a_person_at_the_console_books_the_ride(self):
        state = os.path.join(self.tmp, "state")
        script = os.path.join(DEMO_DIR, "demo.py")
        agent = subprocess.Popen([sys.executable, "-B", script, "run", "--yes", "--state", state],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        # a person claims, accepts the shown price, pickup, and trip time, then claims and
        # accepts the confirmation, fare, and link: four lines for each leg.
        operator = subprocess.run([sys.executable, "-B", script, "console", "--state", state, "--once",
                                   "--name", "Test Concierge"],
                                  input="y\n\n\n\ny\n\n\n\n", capture_output=True, text=True, timeout=120)
        out = agent.communicate(timeout=120)[0]
        self.assertEqual(operator.returncode, 0, operator.stdout + operator.stderr)
        self.assertIn("never: contact the user yourself", operator.stdout)
        self.assertEqual(agent.returncode, 0, out)
        self.assertIn("Booked by Test Concierge, a sirven concierge", out)


class LanguageTest(unittest.TestCase):
    """Jose's language rules on every file in the demo: no em or en dashes, terms spelled out."""

    PATTERN = re.compile(r"\b(ACLs?|OS|CLI|UID|PID|TODO|FIXME|IP|DNS|UTC|ISO|VPN|CPU|YAML|CI|UI|IDs?|OK|"
                         r"MCP|PA|SLA|SLO|ETA|PR|KB|ADR|WIP|MCC|PII)\b|\be\.g\.|\bi\.e\.")

    def test_language(self):
        hits = []
        for root, dirs, files in os.walk(DEMO_DIR):
            dirs[:] = [name for name in dirs if name != "__pycache__"]
            for name in files:
                path = os.path.join(root, name)
                # this file names the patterns; a .ics file's property names are fixed by its format.
                if name == "test_demo.py" or name.endswith(".ics"):
                    continue
                with open(path, encoding="utf-8") as handle:
                    for number, line in enumerate(handle, start=1):
                        # a line marked "# literal:" holds a name a file format or library fixes.
                        named = self.PATTERN.search(line) and "# literal:" not in line
                        if "\u2014" in line or "\u2013" in line or named:
                            hits.append("%s:%d: %s" % (os.path.relpath(path, DEMO_DIR), number, line.strip()))
        self.assertEqual(hits, [])


if __name__ == "__main__":
    unittest.main()
