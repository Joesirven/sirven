"""regressions for what the checker review of the semantic map found: a priced row that is really
a message or a trip history row, destructive labels the crawler must never press, digits and at
signs from other scripts, a refresh that stops halfway, and the onboarding session being the
crawl's alone. run with python3 -B."""

import copy
import os
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
REPOSITORY = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPOSITORY, "lib"))
sys.path.insert(0, HERE)

import phone_crawler  # noqa: E402
import phone_map  # noqa: E402
from fake_driver import WorldDriver  # noqa: E402

NOW = "2026-10-11T14:00:00Z"


def cell(label):
    return {"type": "XCUIElementTypeCell", "label": label, "value": "", "frame": [20, 200, 350, 64]}


def button(label, y=200):
    return {"type": "XCUIElementTypeButton", "label": label, "value": "", "frame": [20, y, 350, 50]}


class PricedRows(unittest.TestCase):
    def test_a_message_with_a_price_is_not_kept(self):
        controls = phone_map.sanitize([cell("Mom: can you send $20 for dinner tonight?")])
        self.assertEqual([None], [control["label"] for control in controls])
        self.assertEqual("list_row", controls[0]["role"])

    def test_a_trip_history_row_with_an_address_is_not_kept(self):
        controls = phone_map.sanitize([cell("Trip to 1600 Valencia St, Oct 3, $18.40")])
        self.assertEqual(None, controls[0]["label"])

    def test_a_ride_offer_is_kept_as_its_shape(self):
        controls = phone_map.sanitize([cell("UberX, 4 min away, 14 min trip, $18.40")])
        self.assertEqual(("priced_option", "UberX, # min away, # min trip, $#.#"),
                         (controls[0]["role"], controls[0]["label"]))


class NeverPressed(unittest.TestCase):
    LABELS = ("Close account", "Clear trip history", "Submit rating", "Accept and continue",
              "Turn off location", "Resend code", "Add to cart, $12.99", "Reset settings")

    def test_destructive_labels_are_never_tapped_by_the_crawler(self):
        for label in self.LABELS:
            self.assertTrue(phone_crawler.NEVER_TAP.search(label), label)

    def test_close_account_is_not_a_back_button(self):
        self.assertNotEqual("back_button", phone_map.classify(button("Close account"))[0])
        self.assertEqual("back_button", phone_map.classify(button("Close"))[0])


class OtherScripts(unittest.TestCase):
    def test_digits_from_any_script_are_shaped(self):
        self.assertEqual("Call #", phone_map.shape("Call ٠١٢٣"))

    def test_a_full_width_at_sign_drops_the_label(self):
        self.assertEqual([], phone_map.sanitize([button("jose＠example.com")]))

    def test_code_screens_count_as_login_screens(self):
        for label in ("Enter the 4-digit code sent to your phone", "Continue with Google", "Sign up"):
            self.assertTrue(phone_map.is_login_screen([button(label)]), label)


class StoppedRefresh(unittest.TestCase):
    def test_a_refresh_that_stops_keeps_the_old_screens(self):
        driver = WorldDriver()
        the_map = phone_map.empty_map()
        phone_crawler.onboard(driver, the_map, ["Uber"], NOW)
        before = copy.deepcopy(the_map["apps"]["com.ubercab.UberClient"])
        self.assertTrue(before["screens"])
        stopping = WorldDriver()
        stopping.locked = True
        with self.assertRaises(phone_crawler.CrawlStopped):
            phone_crawler.onboard(stopping, the_map, ["Uber"], NOW, refresh=True)
        self.assertEqual(before, the_map["apps"]["com.ubercab.UberClient"])


class OnboardingSession(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp()
        os.environ["SIRVEN_PHONE_DIR"] = self.folder
        os.environ["SIRVEN_USBMUX_SOCKET"] = os.path.join(self.folder, "fake-usbmuxd")
        import phone_bridge
        self.bridge = phone_bridge

    def test_the_agent_cannot_use_a_session_opened_for_onboarding(self):
        bridge = self.bridge
        opened = bridge.now()
        session = {"session": "abcd1234", "opened": bridge.stamp(opened), "purpose": "onboarding",
                   "expires": bridge.stamp(opened + bridge.datetime.timedelta(minutes=10)),
                   "allow_submit": False, "test_only": True}
        bridge.write_private(bridge.state_file("session.json"), bridge.json.dumps(session))
        with self.assertRaises(bridge.Refusal) as refused:
            bridge.require_session()
        self.assertEqual("no_consent", refused.exception.result)
        self.assertEqual("abcd1234", bridge.require_session(onboarding=True)["session"])


if __name__ == "__main__":
    unittest.main()
