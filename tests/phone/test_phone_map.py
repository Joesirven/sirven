"""the semantic map store, lib/phone_map.py, against the shared spec: the map shape, the roles,
and above all the privacy rules (no screenshot, no value, no static text, nothing from a login
screen, priced rows only as shapes). run with python3 -B, so no bytecode is left behind."""

import json
import os
import re
import stat
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
REPOSITORY = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPOSITORY, "lib"))
sys.path.insert(0, HERE)

import phone_map  # noqa: E402
import fake_driver  # noqa: E402

NOW = "2026-10-11T14:00:00Z"
UBER = "com.ubercab.UberClient"
NEVER_IN_THE_MAP = ("Jose", "hunter2", "Mom", "jose.sirven", "Sign in", "screenshot", "iVBORw0KGgo")


def element(kind, label, frame=(20, 120, 350, 44), value=""):
    return {"type": "XCUIElementType" + kind, "label": label, "value": value, "frame": [float(n) for n in frame]}


def world_elements(app, screen):
    """the elements of one world screen, as phone_bridge.elements_from_source returns them."""
    world = fake_driver.load_world()
    found = [element("Application", world["apps"][app]["name"], (0, 0, 390, 844))]
    for item in world["apps"][app]["screens"][screen]["elements"]:
        found.append(element(item["type"], item["label"], item["frame"], item.get("value", "")))
    return found


def walk(value):
    """every key and every string anywhere in a JSON value."""
    if isinstance(value, dict):
        for key, inner in value.items():
            yield key
            yield from walk(inner)
    elif isinstance(value, list):
        for inner in value:
            yield from walk(inner)
    elif isinstance(value, str):
        yield value


class ShapeAndSignature(unittest.TestCase):
    def test_shape_collapses_each_digit_run_to_one_mark(self):
        self.assertEqual("UberX, # min away, # min trip, $#.#", phone_map.shape("UberX, 4 min away, 14 min trip, $18.40"))
        self.assertEqual("Where to?", phone_map.shape("Where to?"))
        self.assertEqual("Pickup in # min", phone_map.shape("Pickup in 4 min"))

    def test_signature_is_twelve_hex_characters_stable_and_order_free(self):
        controls = phone_map.sanitize(world_elements(UBER, "home"))
        first = phone_map.signature(UBER, controls)
        self.assertRegex(first, r"^[0-9a-f]{12}$")
        self.assertEqual(first, phone_map.signature(UBER, list(reversed(controls))))
        self.assertNotEqual(first, phone_map.signature("com.zimride.instant", controls))
        other = phone_map.sanitize(world_elements(UBER, "services"))
        self.assertNotEqual(first, phone_map.signature(UBER, other))


class Classify(unittest.TestCase):
    def role(self, kind, label, frame=(20, 120, 350, 44)):
        return phone_map.classify(element(kind, label, frame))[0]

    def test_each_role_in_the_table(self):
        self.assertEqual("app_icon", self.role("Icon", "Uber", (24, 80, 64, 64)))
        self.assertEqual("destination_field", self.role("TextField", "Where to?"))
        self.assertEqual("destination_field", self.role("TextField", "Search destination"))
        self.assertEqual("destination_field", self.role("SearchField", "Enter destination"))
        self.assertEqual("search_field", self.role("TextField", "Search Maps"))
        self.assertEqual("priced_option", self.role("Cell", "UberX, 4 min away, 14 min trip, $18.40", (20, 200, 350, 64)))
        self.assertEqual("request_button", self.role("Button", "Request UberX", (20, 740, 350, 50)))
        self.assertEqual("request_button", self.role("Button", "Confirm pickup"))
        self.assertEqual("cancel_ride_button", self.role("Button", "Cancel ride", (20, 700, 350, 50)))
        self.assertEqual("confirm_cancel_button", self.role("Button", "Yes, cancel", (20, 600, 350, 50)))
        self.assertEqual("back_button", self.role("Button", "Back", (10, 40, 60, 40)))
        self.assertEqual("back_button", self.role("Button", "Done", (10, 40, 60, 40)))
        self.assertEqual("tab", self.role("Button", "Services", (130, 780, 130, 64)))
        self.assertEqual("tab", self.role("Button", "Rides", (20, 760, 170, 64)))
        self.assertEqual("list_row", self.role("Cell", "Mom, See you Sunday at 4?", (20, 120, 350, 64)))
        self.assertEqual("button", self.role("Button", "General", (20, 120, 350, 50)))

    def test_matching_ignores_case(self):
        self.assertEqual("back_button", self.role("Button", "BACK", (10, 40, 60, 40)))
        self.assertEqual("cancel_ride_button", self.role("Button", "cancel RIDE", (20, 700, 350, 50)))

    def test_every_role_says_what_it_does_in_words(self):
        for kind, label, frame in (("Icon", "Uber", (24, 80, 64, 64)), ("TextField", "Where to?", (20, 120, 350, 44)),
                                   ("Button", "Request UberX", (20, 740, 350, 50)), ("Cell", "Row", (20, 120, 350, 64))):
            role, does = phone_map.classify(element(kind, label, frame))
            self.assertIsInstance(does, str)
            self.assertTrue(does.strip(), role)
        self.assertEqual("commits the choice; can spend money", phone_map.classify(element("Button", "Request UberX"))[1])
        self.assertEqual("goes back", phone_map.classify(element("Button", "Back", (10, 40, 60, 40)))[1])

    def test_money_words_are_a_copy_of_the_bridge(self):
        import phone_bridge
        self.assertEqual(phone_bridge.MONEY_WORDS.pattern, phone_map.MONEY_WORDS.pattern)
        self.assertEqual(phone_bridge.MONEY_WORDS.flags, phone_map.MONEY_WORDS.flags)

    def test_control_types_are_the_full_names(self):
        for name in ("Button", "TextField", "SearchField", "Cell", "Icon", "Switch", "Link", "SegmentedControl", "Tab"):
            self.assertIn("XCUIElementType" + name, phone_map.CONTROL_TYPES)
        self.assertNotIn("XCUIElementTypeStaticText", phone_map.CONTROL_TYPES)
        self.assertNotIn("XCUIElementTypeSecureTextField", phone_map.CONTROL_TYPES)


class Sanitize(unittest.TestCase):
    def test_controls_have_the_spec_keys_and_never_a_value(self):
        controls = phone_map.sanitize(world_elements(UBER, "home"))
        self.assertTrue(controls)
        for control in controls:
            self.assertEqual({"role", "type", "label", "frame", "does", "money", "leads_to"}, set(control))
            self.assertIn(control["type"], phone_map.CONTROL_TYPES)
            self.assertIsNone(control["leads_to"])
        where = [c for c in controls if c["label"] == "Where to?"]
        self.assertEqual(1, len(where))
        self.assertEqual("destination_field", where[0]["role"])
        self.assertFalse(where[0]["money"])

    def test_static_text_is_never_kept(self):
        for screen in ("home", "account", "on_the_way", "options", "pay_sheet"):
            text = json.dumps(phone_map.sanitize(world_elements(UBER, screen)))
            for gone in ("Good afternoon", "Jose", "Your driver", "Toyota", "7ABC123", "Apple Pay", "Double Click to Pay"):
                self.assertNotIn(gone, text, screen)
            self.assertNotIn("XCUIElementTypeStaticText", text)
            self.assertNotIn("XCUIElementTypeApplication", text)

    def test_values_never_survive_even_on_controls(self):
        controls = phone_map.sanitize([element("TextField", "Where to?", value="1 Main Street, Jose's house"),
                                       element("Button", "General", (20, 200, 350, 50), value="on")])
        text = json.dumps(controls)
        self.assertNotIn("Main Street", text)
        self.assertNotIn("Jose", text)
        for control in controls:
            self.assertNotIn("value", control)

    def test_priced_rows_are_stored_only_as_shapes(self):
        controls = phone_map.sanitize(world_elements(UBER, "options"))
        priced = [c for c in controls if c["role"] == "priced_option"]
        self.assertEqual(3, len(priced))
        labels = sorted(c["label"] for c in priced)
        self.assertIn("UberX, # min away, # min trip, $#.#", labels)
        self.assertIn("Comfort, # min away, # min trip, $#.#", labels)
        text = json.dumps(controls)
        for digits in ("18.40", "24.10", "31.75", "$18", "4 min"):
            self.assertNotIn(digits, text)

    def test_plain_list_rows_lose_their_label(self):
        controls = phone_map.sanitize(world_elements("com.apple.MobileSMS", "list"))
        rows = [c for c in controls if c["role"] == "list_row"]
        self.assertEqual(2, len(rows))
        for row in rows:
            self.assertIsNone(row["label"])
        text = json.dumps(controls)
        self.assertNotIn("Mom", text)
        self.assertNotIn("Barber", text)
        self.assertNotIn("Sunday", text)

    def test_long_labels_and_addresses_are_not_kept_and_digits_are_shaped(self):
        long_label = "Ride to 1234 Valencia Street with the family on Sunday morning"
        controls = phone_map.sanitize([element("Button", long_label, (20, 200, 350, 50)),
                                       element("Button", "Email jose.sirven@example.com", (20, 300, 350, 50)),
                                       element("Button", "Gate 12 pickup", (20, 400, 350, 50))])
        text = json.dumps(controls)
        self.assertNotIn("Valencia", text)
        self.assertNotIn("@", text)
        self.assertNotIn("jose.sirven", text)
        self.assertIn("Gate # pickup", text)
        self.assertNotIn("12", text)

    def test_money_is_true_for_money_words_and_committing_roles(self):
        by_label = {c["label"]: c for c in phone_map.sanitize(world_elements(UBER, "services"))}
        self.assertTrue(by_label["Reserve"]["money"])
        self.assertTrue(by_label["Rent"]["money"])
        self.assertFalse(by_label["Ride"]["money"])
        by_label = {c["label"]: c for c in phone_map.sanitize(world_elements(UBER, "cancel_confirm"))}
        self.assertTrue(by_label["Yes, cancel"]["money"])
        by_label = {c["label"]: c for c in phone_map.sanitize(world_elements(UBER, "options_x"))}
        self.assertTrue(by_label["Request UberX"]["money"])


class LoginScreens(unittest.TestCase):
    def test_a_secure_field_or_a_login_label_makes_a_login_screen(self):
        self.assertTrue(phone_map.is_login_screen(world_elements("com.example.bank", "login")))
        self.assertTrue(phone_map.is_login_screen([element("Button", "Log in", (20, 300, 350, 50))]))
        self.assertTrue(phone_map.is_login_screen([element("TextField", "Verification code")]))
        self.assertTrue(phone_map.is_login_screen([element("TextField", "Enter your passcode")]))
        self.assertTrue(phone_map.is_login_screen([element("SecureTextField", "Anything")]))

    def test_ordinary_screens_are_not_login_screens(self):
        self.assertFalse(phone_map.is_login_screen(world_elements(UBER, "home")))
        self.assertFalse(phone_map.is_login_screen(world_elements(UBER, "options")))
        self.assertFalse(phone_map.is_login_screen(world_elements("com.zimride.instant", "profile")))

    def test_a_skipped_login_screen_leaves_only_a_count(self):
        the_map = phone_map.empty_map()
        phone_map.note_login_skipped(the_map, "com.example.bank", "First Neighborhood Bank")
        phone_map.note_login_skipped(the_map, "com.example.bank", "First Neighborhood Bank")
        entry = the_map["apps"]["com.example.bank"]
        self.assertEqual(2, entry["login_screens_skipped"])
        self.assertEqual("First Neighborhood Bank", entry["name"])
        self.assertFalse(entry.get("screens"))
        text = json.dumps(the_map)
        for gone in ("jose.sirven", "hunter2", "Sign in", "Password", "Username"):
            self.assertNotIn(gone, text)


class MapShape(unittest.TestCase):
    def build(self):
        the_map = phone_map.empty_map()
        home = phone_map.sanitize(world_elements(UBER, "home"))
        search = phone_map.sanitize(world_elements(UBER, "search"))
        home_signature = phone_map.record_screen(the_map, UBER, "Uber", home, [], NOW)
        search_signature = phone_map.record_screen(the_map, UBER, "Uber", search, ["Where to?"], NOW)
        phone_map.link(the_map, UBER, home_signature, "Where to?", search_signature)
        return the_map, home_signature, search_signature

    def test_empty_map(self):
        the_map = phone_map.empty_map()
        self.assertEqual(1, phone_map.SCHEMA_VERSION)
        self.assertEqual(1, the_map["schema_version"])
        self.assertEqual({}, the_map["apps"])
        phone_map.validate(the_map)

    def test_record_screen_and_link(self):
        the_map, home_signature, search_signature = self.build()
        app = the_map["apps"][UBER]
        self.assertEqual("Uber", app["name"])
        self.assertEqual(0, app["login_screens_skipped"])
        self.assertEqual({home_signature, search_signature}, set(app["screens"]))
        search = app["screens"][search_signature]
        self.assertEqual(NOW, search["first_seen"])
        self.assertEqual(["Where to?"], search["reached_by"])
        where = [c for c in app["screens"][home_signature]["controls"] if c["label"] == "Where to?"][0]
        self.assertEqual(search_signature, where["leads_to"])
        self.assertEqual(home_signature, phone_map.signature(UBER, phone_map.sanitize(world_elements(UBER, "home"))))
        phone_map.validate(the_map)

    def test_recording_the_same_screen_twice_keeps_one(self):
        the_map, home_signature, _ = self.build()
        again = phone_map.record_screen(the_map, UBER, "Uber", phone_map.sanitize(world_elements(UBER, "home")), [], NOW)
        self.assertEqual(home_signature, again)
        self.assertEqual(2, len(the_map["apps"][UBER]["screens"]))

    def test_find_by_role(self):
        the_map, home_signature, search_signature = self.build()
        found = phone_map.find(the_map, UBER, "destination_field")
        self.assertEqual(2, len(found))
        screens = {item["screen"] for item in found}
        self.assertEqual({home_signature, search_signature}, screens)
        self.assertEqual("Where to?", [f for f in found if f["screen"] == home_signature][0]["label"])
        self.assertEqual([], phone_map.find(the_map, UBER, "request_button"))
        self.assertEqual([], phone_map.find(the_map, "com.example.nothing", "tab"))

    def test_inventory_and_onboarding_day(self):
        the_map = phone_map.empty_map()
        self.assertTrue(phone_map.onboarding_due(the_map, "2026-10-11"))
        phone_map.set_inventory(the_map, ["Uber", "Lyft", "Messages"], NOW)
        self.assertEqual(["Uber", "Lyft", "Messages"], the_map["inventory"]["names"])
        self.assertEqual(NOW, the_map["inventory"]["taken_at"])
        phone_map.mark_onboarded(the_map, NOW)
        self.assertEqual(NOW, the_map["onboarded_at"])
        self.assertEqual("2026-10-11", the_map["onboarded_day"])
        self.assertFalse(phone_map.onboarding_due(the_map, "2026-10-11"))
        self.assertTrue(phone_map.onboarding_due(the_map, "2026-10-12"))

    def test_prune_an_app_or_one_screen(self):
        the_map, home_signature, search_signature = self.build()
        phone_map.record_screen(the_map, "com.zimride.instant", "Lyft",
                                phone_map.sanitize(world_elements("com.zimride.instant", "home")), [], NOW)
        self.assertEqual(1, phone_map.prune(the_map, UBER, search_signature))
        self.assertEqual({home_signature}, set(the_map["apps"][UBER]["screens"]))
        self.assertEqual(0, phone_map.prune(the_map, UBER, "000000000000"))
        self.assertGreaterEqual(phone_map.prune(the_map, "com.zimride.instant"), 1)
        self.assertNotIn("com.zimride.instant", the_map["apps"])
        self.assertIn(UBER, the_map["apps"])
        self.assertEqual(0, phone_map.prune(the_map, "com.example.nothing"))

    def test_forget_app_screens(self):
        the_map, _, _ = self.build()
        phone_map.forget_app_screens(the_map, UBER)
        self.assertFalse(the_map["apps"].get(UBER, {}).get("screens"))

    def test_describe_is_plain_lines_without_private_text(self):
        the_map, _, _ = self.build()
        phone_map.set_inventory(the_map, ["Uber", "Lyft"], NOW)
        lines = phone_map.describe(the_map)
        self.assertIsInstance(lines, list)
        self.assertTrue(lines)
        for line in lines:
            self.assertIsInstance(line, str)
        self.assertIn("Uber", "\n".join(lines))
        self.assertIsInstance(phone_map.describe(phone_map.empty_map()), list)


class Validate(unittest.TestCase):
    def test_forbidden_keys_anywhere_are_refused(self):
        for key in ("value", "screenshot", "screenshot_png_base64", "elements"):
            the_map = phone_map.empty_map()
            the_map["apps"]["com.example.app"] = {"name": "App", "login_screens_skipped": 0, "mapped_at": NOW,
                                                  "screens": {"abcdefabcdef": {"first_seen": NOW, "reached_by": [],
                                                                               "controls": [{key: "x"}]}}}
            with self.assertRaises(ValueError, msg=key):
                phone_map.validate(the_map)
        top = phone_map.empty_map()
        top["screenshot"] = "iVBORw0KGgo="
        with self.assertRaises(ValueError):
            phone_map.validate(top)

    def test_a_wrong_schema_version_is_refused(self):
        the_map = phone_map.empty_map()
        the_map["schema_version"] = 2
        with self.assertRaises(ValueError):
            phone_map.validate(the_map)


class Storage(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.mkdtemp(prefix="sirven-phone-map.")

    def tearDown(self):
        for name in os.listdir(self.folder):
            os.remove(os.path.join(self.folder, name))
        os.rmdir(self.folder)

    def test_map_path(self):
        self.assertEqual(os.path.join(self.folder, "map.json"), phone_map.map_path(self.folder))

    def test_load_is_an_empty_map_when_missing_or_unreadable(self):
        self.assertEqual(phone_map.empty_map(), phone_map.load(self.folder))
        with open(phone_map.map_path(self.folder), "w") as handle:
            handle.write("{not json")
        self.assertEqual(phone_map.empty_map(), phone_map.load(self.folder))

    def test_save_round_trips_with_mode_0600(self):
        the_map, _, _ = MapShape.build(self)
        phone_map.save(self.folder, the_map)
        path = phone_map.map_path(self.folder)
        self.assertEqual(0o600, stat.S_IMODE(os.stat(path).st_mode))
        self.assertEqual(the_map, phone_map.load(self.folder))
        self.assertEqual(["map.json"], os.listdir(self.folder), "no temporary file is left behind")

    def test_save_refuses_a_map_with_a_screenshot_and_writes_nothing(self):
        the_map = phone_map.empty_map()
        the_map["screenshot_png_base64"] = "iVBORw0KGgo="
        with self.assertRaises(ValueError):
            phone_map.save(self.folder, the_map)
        self.assertFalse(os.path.exists(phone_map.map_path(self.folder)))

    def test_a_map_built_from_every_world_screen_holds_nothing_private(self):
        world = fake_driver.load_world()
        the_map = phone_map.empty_map()
        for bundle, app in world["apps"].items():
            for name in app["screens"]:
                elements = world_elements(bundle, name)
                if phone_map.is_login_screen(elements):
                    phone_map.note_login_skipped(the_map, bundle, app["name"])
                    continue
                phone_map.record_screen(the_map, bundle, app["name"], phone_map.sanitize(elements), [], NOW)
        phone_map.save(self.folder, the_map)
        with open(phone_map.map_path(self.folder)) as handle:
            text = handle.read()
        for gone in NEVER_IN_THE_MAP + ("18.40", "Good afternoon", "Toyota", "Barber"):
            self.assertNotIn(gone, text)
        saved = json.loads(text)
        keys = set(walk(saved))
        for key in ("value", "screenshot", "screenshot_png_base64", "elements"):
            self.assertNotIn(key, keys)
        self.assertEqual(1, saved["apps"]["com.example.bank"]["login_screens_skipped"])
        self.assertFalse(saved["apps"]["com.example.bank"].get("screens"))
        self.assertTrue(any(re.search(r"\$#\.#", s) for s in walk(saved)))


if __name__ == "__main__":
    unittest.main()
