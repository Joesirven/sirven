"""the schema file itself: it loads, the validator checks every keyword it uses, it rejects what it should,
and the published tool list matches it."""

import json
import os
import unittest

from helpers import HERE, VALIDATOR, usd
from ride_connector.schema import SchemaError, Validator, bundle_tools, load_schema

TOOLS_PATH = os.path.join(os.path.dirname(HERE), "schemas", "v1", "tools.json")


class SchemaFileTests(unittest.TestCase):
    def test_version_is_semantic(self):
        self.assertRegex(load_schema()["x-contract-version"], r"^1\.\d+\.\d+$")

    def test_unknown_keywords_are_refused(self):
        schema = {"$defs": {"thing": {"type": "string", "format": "email", "contentEncoding": "base64"}}}
        with self.assertRaises(SchemaError):
            Validator(schema)

    def test_published_tool_list_is_current(self):
        with open(TOOLS_PATH, encoding="utf-8") as handle:
            published = json.load(handle)
        self.assertEqual(bundle_tools(), published,
                         "run: python3 -m ride_connector.server --tools > schemas/v1/tools.json")

    def test_bundled_tool_schemas_stand_alone(self):
        for tool in bundle_tools()["tools"]:
            for key in ("inputSchema", "outputSchema"):
                standalone = Validator(tool[key])
                for ref in _refs(tool[key]):
                    standalone.resolve(ref)  # raises if a definition was left behind

    def test_tool_names_are_the_contract_names(self):
        names = [tool["name"] for tool in bundle_tools()["tools"]]
        self.assertEqual(["quote_ride", "book_ride", "cancel_ride", "get_ride"], names)

    def test_every_output_field_is_required(self):
        # results are complete by construction: an absent value is null, never a missing key.
        schema = load_schema()["$defs"]
        for name in ("ride_option", "booking", "charge_terms", "tracking", "final_charge", "fulfillment"):
            self.assertEqual(sorted(schema[name]["properties"]), sorted(schema[name]["required"]), name)


class ValidatorTests(unittest.TestCase):
    def check(self, value, definition):
        return [path for path, _ in VALIDATOR.validate(value, definition)]

    def test_money_is_whole_minor_units(self):
        self.assertEqual([], self.check(usd(2500), "money"))
        self.assertEqual(["/amount_minor"], self.check({"amount_minor": 25.0, "currency": "USD"}, "money"))
        self.assertEqual(["/amount_minor"], self.check({"amount_minor": -1, "currency": "USD"}, "money"))
        self.assertEqual(["/currency"], self.check({"amount_minor": 1, "currency": "usd"}, "money"))
        self.assertEqual(["/amount_minor"], self.check({"amount_minor": True, "currency": "USD"}, "money"))

    def test_timestamps_need_an_offset(self):
        self.assertEqual([], self.check("2026-10-12T15:00:00-07:00", "timestamp"))
        self.assertEqual([], self.check("2026-10-12T22:00:00Z", "timestamp"))
        self.assertEqual(["/"], self.check("2026-10-12T15:00:00", "timestamp"))
        self.assertEqual(["/"], self.check("2026-13-40T15:00:00Z", "timestamp"))

    def test_a_place_needs_an_address_or_coordinates(self):
        self.assertEqual([], self.check({"address": "500 Valencia St"}, "place"))
        self.assertEqual([], self.check({"coordinates": {"latitude": 1, "longitude": 2}}, "place"))
        self.assertEqual(["/"], self.check({"label": "barber"}, "place"))
        self.assertEqual(["/coordinates/latitude"],
                         self.check({"coordinates": {"latitude": 91, "longitude": 2}}, "place"))

    def test_unknown_fields_are_refused(self):
        self.assertEqual(["/vendor_ride_id"],
                         self.check({"quote_id": "qt_" + "a" * 26, "vendor_ride_id": "x"}, "book_ride_input"))

    def test_identifiers_have_one_shape(self):
        self.assertEqual([], self.check("qt_" + "a2" * 13, "quote_id"))
        self.assertEqual(["/"], self.check("bk_" + "a2" * 13, "quote_id"))
        self.assertEqual(["/"], self.check("qt_" + "A" * 26, "quote_id"))

    def test_payment_reference_cannot_carry_a_card_number_with_spaces_or_be_short(self):
        base = {"quote_id": "qt_" + "a" * 26}
        self.assertEqual([], self.check(dict(base, payment_reference="hold_abc12345"), "book_ride_input"))
        self.assertEqual(["/payment_reference"],
                         self.check(dict(base, payment_reference="4242 4242 4242 4242"), "book_ride_input"))


def _refs(node):
    if isinstance(node, dict):
        if "$ref" in node:
            yield node["$ref"]
        for child in node.values():
            yield from _refs(child)
    elif isinstance(node, list):
        for child in node:
            yield from _refs(child)


if __name__ == "__main__":
    unittest.main()
