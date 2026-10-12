"""load the ride connector schema and validate values against it, with the standard library only.

this checks the subset of JSON Schema (draft 2020-12) the contract uses. a keyword it does not
know is an error, not a silent pass, so the schema cannot start relying on a rule nothing checks.
"""

import json
import os
import re
from datetime import datetime

SCHEMA_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "schemas", "v1", "ride-connector.schema.json",
)

# keywords that only describe, so validation ignores them.
ANNOTATIONS = {"$schema", "$id", "$defs", "$comment", "title", "description", "default", "examples"}
CHECKED = {
    "$ref", "type", "properties", "required", "additionalProperties", "enum", "const", "items",
    "minItems", "maxItems", "uniqueItems", "minimum", "maximum", "minLength", "maxLength",
    "pattern", "format", "anyOf", "oneOf", "allOf",
}

TIMESTAMP_FORM = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$")


class SchemaError(Exception):
    """the schema itself is malformed or uses a keyword this validator does not check."""


def load_schema(path=SCHEMA_PATH):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def contract_version(schema=None):
    return (schema or load_schema())["x-contract-version"]


def parse_timestamp(text):
    """a timestamp in the Request for Comments 3339 form, with an offset, as an aware datetime, or None."""
    if not isinstance(text, str) or not TIMESTAMP_FORM.match(text):
        return None
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None


def _type_ok(value, name):
    if name == "object":
        return isinstance(value, dict)
    if name == "array":
        return isinstance(value, list)
    if name == "string":
        return isinstance(value, str)
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if name == "boolean":
        return isinstance(value, bool)
    if name == "null":
        return value is None
    raise SchemaError("unknown type %r" % name)


class Validator:
    def __init__(self, schema=None):
        self.schema = schema if schema is not None else load_schema()
        self._check_keywords(self.schema, "#")

    def _check_keywords(self, node, where):
        if isinstance(node, dict):
            for key, child in node.items():
                if key in ("properties", "$defs"):
                    for name, sub in child.items():
                        self._check_keywords(sub, "%s/%s/%s" % (where, key, name))
                    continue
                if key in ANNOTATIONS or key.startswith("x-"):
                    continue
                if key not in CHECKED:
                    raise SchemaError("%s uses %r, which this validator does not check" % (where, key))
                if key in ("items", "additionalProperties"):
                    self._check_keywords(child, "%s/%s" % (where, key))
                elif key in ("anyOf", "oneOf", "allOf"):
                    for index, sub in enumerate(child):
                        self._check_keywords(sub, "%s/%s/%d" % (where, key, index))

    def resolve(self, ref):
        if not ref.startswith("#/"):
            raise SchemaError("only local references are supported: %r" % ref)
        node = self.schema
        for part in ref[2:].split("/"):
            node = node[part]
        return node

    def definition(self, name):
        return self.resolve("#/$defs/" + name)

    def errors(self, value, schema, path=""):
        """every way value fails schema, as (path, message) pairs. empty means valid."""
        found = []
        self._validate(value, schema, path, found)
        return found

    def validate(self, value, definition_name):
        """errors for value against one named definition in the contract."""
        return self.errors(value, self.definition(definition_name))

    def _validate(self, value, schema, path, found):
        if "$ref" in schema:
            self._validate(value, self.resolve(schema["$ref"]), path, found)

        if "type" in schema:
            names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
            if not any(_type_ok(value, name) for name in names):
                found.append((path or "/", "expected %s" % " or ".join(names)))
                return

        if "const" in schema and value != schema["const"]:
            found.append((path or "/", "must be %r" % (schema["const"],)))
        if "enum" in schema and value not in schema["enum"]:
            found.append((path or "/", "must be one of %s" % ", ".join(map(str, schema["enum"]))))

        if isinstance(value, str):
            if "minLength" in schema and len(value) < schema["minLength"]:
                found.append((path or "/", "shorter than %d" % schema["minLength"]))
            if "maxLength" in schema and len(value) > schema["maxLength"]:
                found.append((path or "/", "longer than %d" % schema["maxLength"]))
            if "pattern" in schema and not re.search(schema["pattern"], value):
                found.append((path or "/", "does not match %s" % schema["pattern"]))
            if schema.get("format") == "date-time" and parse_timestamp(value) is None:
                found.append((path or "/", "not a date and time with an offset, like 2026-10-12T15:00:00-07:00"))

        if _type_ok(value, "number"):
            if "minimum" in schema and value < schema["minimum"]:
                found.append((path or "/", "below %s" % schema["minimum"]))
            if "maximum" in schema and value > schema["maximum"]:
                found.append((path or "/", "above %s" % schema["maximum"]))

        if isinstance(value, list):
            if "minItems" in schema and len(value) < schema["minItems"]:
                found.append((path or "/", "fewer than %d items" % schema["minItems"]))
            if "maxItems" in schema and len(value) > schema["maxItems"]:
                found.append((path or "/", "more than %d items" % schema["maxItems"]))
            if schema.get("uniqueItems"):
                seen = [json.dumps(item, sort_keys=True) for item in value]
                if len(set(seen)) != len(seen):
                    found.append((path or "/", "items are not unique"))
            if "items" in schema:
                for index, item in enumerate(value):
                    self._validate(item, schema["items"], "%s/%d" % (path, index), found)

        if isinstance(value, dict):
            for name in schema.get("required", []):
                if name not in value:
                    found.append(("%s/%s" % (path, name), "is required"))
            properties = schema.get("properties", {})
            for name, item in value.items():
                if name in properties:
                    self._validate(item, properties[name], "%s/%s" % (path, name), found)
                elif schema.get("additionalProperties") is False:
                    found.append(("%s/%s" % (path, name), "is not part of the contract"))
                elif isinstance(schema.get("additionalProperties"), dict):
                    self._validate(item, schema["additionalProperties"], "%s/%s" % (path, name), found)

        for sub in schema.get("allOf", []):
            self._validate(value, sub, path, found)
        if "anyOf" in schema:
            if not any(not self.errors(value, sub, path) for sub in schema["anyOf"]):
                found.append((path or "/", "matches none of the allowed shapes"))
        if "oneOf" in schema:
            matches = sum(1 for sub in schema["oneOf"] if not self.errors(value, sub, path))
            if matches != 1:
                found.append((path or "/", "must match exactly one allowed shape, matched %d" % matches))


def bundle_tools(schema=None):
    """the model context protocol tool list, each schema self-contained with its own $defs.

    model context protocol clients read inputSchema and outputSchema without following
    references into other files, so each tool carries a copy of the definitions it uses.
    """
    schema = schema or load_schema()
    descriptions = {
        "quote_ride": (
            "Get ranked ride options from origin to destination within a departure window, "
            "each with price, provider, estimated pickup and drop-off, and constraint flags. "
            "Read only: nothing is booked or charged."
        ),
        "book_ride": (
            "Book one option from quote_ride by its quote_id. Ask the person first. Booking "
            "the same quote_id again returns the same booking; it never books twice."
        ),
        "cancel_ride": (
            "Cancel a booking and reconcile what is owed. Safe to repeat: a second call "
            "returns the first cancellation unchanged."
        ),
        "get_ride": "Read a booking's current status, tracking details, and final charge.",
    }
    tools = []
    for name in ("quote_ride", "book_ride", "cancel_ride", "get_ride"):
        tool = {
            "name": name,
            "description": descriptions[name],
            "inputSchema": _self_contained(schema, name + "_input"),
            "outputSchema": _self_contained(schema, name + "_output"),
        }
        if name in ("quote_ride", "get_ride"):
            tool["annotations"] = {"readOnlyHint": True, "idempotentHint": name == "get_ride"}
        else:
            tool["annotations"] = {"readOnlyHint": False, "destructiveHint": name == "cancel_ride", "idempotentHint": True}
        tools.append(tool)
    return {
        "x-contract-version": schema["x-contract-version"],
        "x-error-schema": _self_contained(schema, "error_output"),
        "tools": tools,
    }


def _self_contained(schema, name):
    needed = set()
    _collect_refs(schema["$defs"][name], schema, needed)
    root = json.loads(json.dumps(schema["$defs"][name]))
    root = {"$schema": schema["$schema"], **root}
    if needed:
        root["$defs"] = {key: schema["$defs"][key] for key in sorted(needed)}
    return root


def _collect_refs(node, schema, needed):
    if isinstance(node, dict):
        ref = node.get("$ref")
        if ref and ref.startswith("#/$defs/"):
            key = ref[len("#/$defs/"):]
            if key not in needed:
                needed.add(key)
                _collect_refs(schema["$defs"][key], schema, needed)
        for child in node.values():
            _collect_refs(child, schema, needed)
    elif isinstance(node, list):
        for child in node:
            _collect_refs(child, schema, needed)
