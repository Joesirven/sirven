"""the crawler, lib/phone_crawler.py, against an in-memory phone that plays
tests/lib/phone_world.json (tests/phone/fake_driver.py). the crawler maps by looking and by
tapping through menus by label; it never types, never taps anything that could spend money,
commit, send, delete, or sign out, and stops at once when the phone shows its own payment
approval. run with python3 -B, so no bytecode is left behind."""

import copy
import json
import os
import sys
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
REPOSITORY = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPOSITORY, "lib"))
sys.path.insert(0, HERE)

import phone_crawler  # noqa: E402
import phone_map  # noqa: E402
from fake_driver import WorldDriver, load_world  # noqa: E402

NOW = "2026-10-11T14:00:00Z"
UBER = "com.ubercab.UberClient"
LYFT = "com.zimride.instant"
BANK = "com.example.bank"
NEVER_TAPPED = ("Request UberX", "Request Comfort", "Request UberXL", "Reserve", "Rent", "Wallet", "Sign out",
                "Cancel ride", "Yes, cancel", "Cancel", "Compose")
NEVER_IN_THE_MAP = ("Jose", "hunter2", "Mom", "jose.sirven", "Sign in", "screenshot", "iVBORw0KGgo")
HOME_SCREEN_NAMES = ["Uber", "Lyft", "Messages", "Maps", "First Neighborhood Bank", "Settings"]


def world_where(change):
    world = copy.deepcopy(load_world())
    change(world)
    return world


def element_labeled(world, app, screen, label):
    return [e for e in world["apps"][app]["screens"][screen]["elements"] if e["label"] == label][0]


def bank_on_the_first_page(world):
    pages = world["apps"]["com.apple.springboard"]["screens"]
    bank = [e for e in pages["page2"]["elements"] if e["label"] == "First Neighborhood Bank"][0]
    pages["page2"]["elements"].remove(bank)
    pages["page1"]["elements"].append(dict(bank, frame=[24, 170, 64, 64]))


def where_to_opens_the_options(world):
    element_labeled(world, UBER, "home", "Where to?")["goto"] = "options"


def ride_opens_the_payment_sheet(world):
    element_labeled(world, UBER, "services", "Ride")["goto"] = "pay_sheet"


class CrawlerTestCase(unittest.TestCase):
    def assert_safe(self, driver):
        for label in NEVER_TAPPED:
            self.assertNotIn(label, driver.taps, "the crawler tapped %r" % label)
        for body in driver.tap_bodies:
            self.assertIn("label", body, "taps go by label, not by point")
            self.assertFalse(phone_crawler.NEVER_TAP.search(str(body["label"])),
                             "the crawler even asked to tap %r" % body["label"])
        self.assertEqual([], driver.missing_reasons, "every call passes a reason")
        self.assertEqual([], driver.point_taps)
        self.assertFalse(hasattr(driver, "type_text"))

    def assert_private(self, the_map):
        phone_map.validate(the_map)
        text = json.dumps(the_map)
        for gone in NEVER_IN_THE_MAP:
            self.assertNotIn(gone, text)


class NeverTap(unittest.TestCase):
    def test_the_dangerous_labels_match(self):
        for label in ("Request UberX", "Reserve", "Rent", "Wallet", "Sign out", "Log out", "Cancel ride", "Cancel",
                      "Yes, cancel", "Compose", "Delete", "Remove", "Send", "Call driver", "Share trip", "Post",
                      "Reply", "Allow", "Report", "Block", "Unsubscribe", "Emergency", "Pay", "Book", "Confirm pickup",
                      "Order"):
            self.assertTrue(phone_crawler.NEVER_TAP.search(label), label)

    def test_the_ordinary_labels_do_not(self):
        for label in ("Where to?", "Services", "Account", "Home", "Back", "Ride", "Rides", "Profile", "General",
                      "UberX, # min away, # min trip, $#.#"):
            self.assertFalse(phone_crawler.NEVER_TAP.search(label), label)

    def test_default_apps_are_the_ride_apps(self):
        self.assertEqual(("Uber", "Lyft"), tuple(phone_crawler.DEFAULT_APPS))

    def test_crawl_stopped_carries_plain_words(self):
        stopped = phone_crawler.CrawlStopped("the owner is approving a payment on the phone")
        self.assertIsInstance(stopped, Exception)


class HomeScreens(CrawlerTestCase):
    def test_walk_lists_every_icon_in_order_and_ends_at_home(self):
        driver = WorldDriver()
        driver.app, driver.screen_name = UBER, "account"
        names = phone_crawler.walk_home_screens(driver)
        self.assertEqual(HOME_SCREEN_NAMES, names)
        self.assertEqual(("com.apple.springboard", "page1"), (driver.app, driver.screen_name))
        self.assertTrue(any(method == "swipe" for method, _ in driver.calls))
        self.assert_safe(driver)
        self.assertEqual([], driver.taps, "walking the home screens taps nothing")

    def test_walk_stops_at_max_pages(self):
        driver = WorldDriver()
        names = phone_crawler.walk_home_screens(driver, max_pages=1)
        self.assertEqual(HOME_SCREEN_NAMES[:4], names)


class CrawlApp(CrawlerTestCase):
    def test_uber_is_mapped_by_looking_and_tapping_menus(self):
        driver = WorldDriver()
        the_map = phone_map.empty_map()
        summary = phone_crawler.crawl_app(driver, the_map, "Uber", NOW)
        self.assertEqual({"app": UBER, "name": "Uber", "screens": summary["screens"], "login_screens_skipped": 0},
                         summary)
        # home, search, services, and account are each one safe tap from home
        self.assertGreaterEqual(summary["screens"], 4)
        self.assertLessEqual(summary["screens"], 12)
        app = the_map["apps"][UBER]
        self.assertEqual("Uber", app["name"])
        self.assertEqual(summary["screens"], len(app["screens"]))
        self.assertIn("Uber", driver.taps, "the app is opened from its icon")
        for label in ("Where to?", "Services", "Account"):
            self.assertIn(label, driver.taps)
        self.assert_safe(driver)
        self.assert_private(the_map)
        text = json.dumps(the_map)
        for gone in ("Good afternoon", "Jose S."):
            self.assertNotIn(gone, text)

    def test_the_map_links_the_destination_field_to_the_search_screen(self):
        driver = WorldDriver()
        the_map = phone_map.empty_map()
        phone_crawler.crawl_app(driver, the_map, "Uber", NOW)
        found = [f for f in phone_map.find(the_map, UBER, "destination_field") if f["label"] == "Where to?"]
        self.assertTrue(found)
        target = found[0]["leads_to"]
        self.assertIn(target, the_map["apps"][UBER]["screens"])
        labels = [c["label"] for c in the_map["apps"][UBER]["screens"][target]["controls"]]
        self.assertIn("Search destination", labels)
        self.assertTrue(phone_map.find(the_map, UBER, "tab"))

    def test_the_unsafe_buttons_are_mapped_but_never_tapped(self):
        driver = WorldDriver()
        the_map = phone_map.empty_map()
        phone_crawler.crawl_app(driver, the_map, "Uber", NOW)
        stored = {c["label"]: c for screen in the_map["apps"][UBER]["screens"].values() for c in screen["controls"]}
        for label in ("Reserve", "Rent"):
            self.assertIn(label, stored)
            self.assertTrue(stored[label]["money"])
            self.assertIsNone(stored[label]["leads_to"])
        self.assert_safe(driver)

    def test_priced_rows_are_stored_as_shapes_and_request_is_never_tapped(self):
        driver = WorldDriver(world_where(where_to_opens_the_options))
        the_map = phone_map.empty_map()
        phone_crawler.crawl_app(driver, the_map, "Uber", NOW)
        priced = phone_map.find(the_map, UBER, "priced_option")
        self.assertTrue(priced)
        self.assertIn("UberX, # min away, # min trip, $#.#", [p["label"] for p in priced])
        requests = phone_map.find(the_map, UBER, "request_button")
        self.assertTrue(requests, "the request button is mapped, so the agent knows where it is")
        for request in requests:
            self.assertTrue(request["money"])
        text = json.dumps(the_map)
        for gone in ("18.40", "24.10", "31.75", "Apple Pay"):
            self.assertNotIn(gone, text)
        self.assert_safe(driver)
        self.assert_private(the_map)

    def test_lyft_profile_keeps_no_name(self):
        driver = WorldDriver()
        the_map = phone_map.empty_map()
        summary = phone_crawler.crawl_app(driver, the_map, "Lyft", NOW)
        self.assertEqual(LYFT, summary["app"])
        self.assertEqual(2, summary["screens"])
        self.assert_safe(driver)
        self.assert_private(the_map)

    def test_messages_rows_lose_their_words_and_compose_is_never_tapped(self):
        driver = WorldDriver()
        the_map = phone_map.empty_map()
        phone_crawler.crawl_app(driver, the_map, "Messages", NOW)
        self.assertNotIn("Compose", driver.taps)
        text = json.dumps(the_map)
        for gone in ("Mom", "Barber", "Sunday", "confirmed"):
            self.assertNotIn(gone, text)
        self.assert_safe(driver)
        self.assert_private(the_map)

    def test_a_login_screen_leaves_only_a_count(self):
        driver = WorldDriver(world_where(bank_on_the_first_page))
        the_map = phone_map.empty_map()
        summary = phone_crawler.crawl_app(driver, the_map, "First Neighborhood Bank", NOW)
        self.assertEqual(BANK, summary["app"])
        self.assertEqual(0, summary["screens"])
        self.assertEqual(1, summary["login_screens_skipped"])
        entry = the_map["apps"][BANK]
        self.assertEqual(1, entry["login_screens_skipped"])
        self.assertFalse(entry.get("screens"))
        self.assertNotIn("Log in", driver.taps)
        self.assertNotIn("Username", driver.taps)
        text = json.dumps(the_map)
        for gone in ("Username", "Password", "Log in", "Sign in", "jose.sirven", "hunter2"):
            self.assertNotIn(gone, text)
        self.assert_safe(driver)

    def test_an_app_that_is_not_there(self):
        driver = WorldDriver()
        the_map = phone_map.empty_map()
        summary = phone_crawler.crawl_app(driver, the_map, "Nonexistent Rides", NOW)
        self.assertEqual({"name": "Nonexistent Rides", "result": "not_installed"}, summary)
        self.assertEqual({}, the_map["apps"])
        self.assert_safe(driver)

    def test_max_screens_is_a_ceiling(self):
        driver = WorldDriver()
        the_map = phone_map.empty_map()
        summary = phone_crawler.crawl_app(driver, the_map, "Uber", NOW, max_screens=2)
        self.assertLessEqual(summary["screens"], 2)
        self.assertLessEqual(len(the_map["apps"][UBER]["screens"]), 2)

    def test_a_control_that_is_not_found_is_skipped_not_fatal(self):
        driver = WorldDriver()
        driver.missing_labels.add("Services")
        the_map = phone_map.empty_map()
        summary = phone_crawler.crawl_app(driver, the_map, "Uber", NOW)
        self.assertGreaterEqual(summary["screens"], 3)
        self.assertIn("Account", driver.taps)

    def test_the_crawl_stops_at_once_on_the_phones_own_payment_approval(self):
        driver = WorldDriver(world_where(ride_opens_the_payment_sheet))
        the_map = phone_map.empty_map()
        with self.assertRaises(phone_crawler.CrawlStopped) as stopped:
            phone_crawler.crawl_app(driver, the_map, "Uber", NOW)
        self.assertIsInstance(stopped.exception.said, str)
        self.assertTrue(stopped.exception.said.strip())
        self.assertEqual(("com.ubercab.UberClient", "pay_sheet"), (driver.app, driver.screen_name))
        self.assertEqual(0, driver.touches_during_sheet, "nothing is touched while the owner is approving")
        self.assertNotIn("Cancel", driver.taps)
        self.assert_private(the_map)

    def test_a_locked_phone_stops_the_crawl(self):
        class LocksAfterAFewCalls(WorldDriver):
            def _note(self, method, body):
                if len(self.calls) >= 4:
                    self.locked = True
                return WorldDriver._note(self, method, body)

        driver = LocksAfterAFewCalls()
        with self.assertRaises(phone_crawler.CrawlStopped):
            phone_crawler.crawl_app(driver, phone_map.empty_map(), "Uber", NOW)


class Onboard(CrawlerTestCase):
    def test_onboard_takes_the_inventory_crawls_each_app_and_marks_the_day(self):
        driver = WorldDriver()
        the_map = phone_map.empty_map()
        summaries = phone_crawler.onboard(driver, the_map, ["Uber", "Lyft"], NOW)
        self.assertEqual(["Uber", "Lyft"], [s["name"] for s in summaries])
        self.assertEqual([UBER, LYFT], [s["app"] for s in summaries])
        self.assertEqual(HOME_SCREEN_NAMES, the_map["inventory"]["names"])
        self.assertEqual("2026-10-11", the_map["onboarded_day"])
        self.assertFalse(phone_map.onboarding_due(the_map, "2026-10-11"))
        self.assertEqual({UBER, LYFT}, set(the_map["apps"]))
        self.assertEqual(("com.apple.springboard", "page1"), (driver.app, driver.screen_name))
        self.assert_safe(driver)
        self.assert_private(the_map)

    def test_refresh_forgets_the_old_screens_first(self):
        the_map = phone_map.empty_map()
        stale = [{"role": "button", "type": "XCUIElementTypeButton", "label": "Old screen", "frame": [1, 1, 1, 1],
                  "does": "a button", "money": False, "leads_to": None}]
        old = phone_map.record_screen(the_map, UBER, "Uber", stale, [], "2026-10-01T09:00:00Z")
        phone_crawler.onboard(WorldDriver(), the_map, ["Uber"], NOW, refresh=True)
        self.assertNotIn(old, the_map["apps"][UBER]["screens"])
        self.assertTrue(the_map["apps"][UBER]["screens"])

    def test_onboard_reports_an_app_that_is_not_installed(self):
        driver = WorldDriver()
        the_map = phone_map.empty_map()
        summaries = phone_crawler.onboard(driver, the_map, ["Uber", "Nonexistent Rides"], NOW)
        self.assertEqual({"name": "Nonexistent Rides", "result": "not_installed"}, summaries[1])


if __name__ == "__main__":
    unittest.main()
