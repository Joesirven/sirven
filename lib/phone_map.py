"""phone map: what the owner's phone looks like, so the agent knows where to look.

onboarding walks the home screens and the screens of the apps the owner chose, and this file
keeps what it learned: which app, which screen, where the key controls are, and what each one
does. plain JSON in the phone state folder (map.json, mode 0600), that the owner can read,
refresh, and prune.

privacy, enforced here and not left to the caller:
  never a screenshot, never an element value;
  nothing from a login screen, only a count of the ones skipped;
  never static text, never a list row's label unless it carries a price, and then only its
  shape, every run of digits turned into one #;
  button and field labels only when 40 characters or fewer, with no @, digits shaped the same way.

python standard library only. this file does not import phone_bridge, which imports it.
"""

import hashlib
import json
import os
import re
import secrets

SCHEMA_VERSION = 1

# the element types worth remembering: things the owner can tap or type into.
CONTROL_TYPES = (
    "XCUIElementTypeButton",
    "XCUIElementTypeTextField",
    "XCUIElementTypeSearchField",
    "XCUIElementTypeCell",
    "XCUIElementTypeIcon",
    "XCUIElementTypeSwitch",
    "XCUIElementTypeLink",
    "XCUIElementTypeSegmentedControl",
    "XCUIElementTypeTab",
)

FIELD_TYPES = ("XCUIElementTypeTextField", "XCUIElementTypeSearchField")

# a copy of phone_bridge.MONEY_WORDS: keep the two in sync. copied, not imported, so that
# phone_bridge can import this file without a cycle.
MONEY_WORDS = re.compile(
    r"\b(book|booking|request|confirm|pay|payment|purchase|buy|order|place order|checkout|"
    r"check out|subscribe|reserve|rent|tip|donate|send money|transfer)\b",
    re.IGNORECASE,
)

# keys that must never appear anywhere in a saved map.
FORBIDDEN_KEYS = ("value", "screenshot", "screenshot_png_base64", "elements")

SECURE_FIELD_TYPES = ("XCUIElementTypeSecureTextField",)

LOGIN_WORDS = re.compile(
    r"\b(sign[ -]?in|sign[ -]?up|log[ -]?in|password|passcode|verification code|one[- ]time code|"
    r"\d+[- ]digit code|enter (the |your )?code|code (was )?sent|continue with (google|apple|facebook|email))\b",
    re.IGNORECASE,
)

LABEL_LIMIT = 40
# a priced row's shape may be a little longer than a button label; past this it is more
# likely to be someone's message than an offer.
PRICED_LABEL_LIMIT = 60

PRICE = re.compile(r"\$\s?[\d#]")
# a ride offer row: a short product name, then only prices, minutes, clock times, or seats.
# anything else with a price in it (a message, a trip history row with an address) is a plain
# list row, and its words are not kept.
OFFER_PART = re.compile(
    r"^\s*(\$\s?\d+(\.\d+)?|\d+\s*(min|mins|minutes)(\s*(away|trip))?|\d{1,2}:\d{2}\s*([ap]\.?m\.?)?|"
    r"\d+\s*seats?|arrives?\s+\d{1,2}:\d{2}\s*([ap]\.?m\.?)?)\s*$",
    re.IGNORECASE,
)


def offer_like(label):
    parts = (label or "").split(",")
    product = parts[0].strip()
    if not product or len(product) > 24 or len(product.split()) > 3 or re.search(r"[\d:@\uff20]", product):
        return False
    return len(parts) > 1 and all(OFFER_PART.match(part) for part in parts[1:]) and bool(PRICE.search(label))
DESTINATION = re.compile(r"where to|search destination|enter destination", re.IGNORECASE)
REQUEST = re.compile(r"^\s*(request|book|confirm|choose|order)\b", re.IGNORECASE)
CANCEL_RIDE = re.compile(r"cancel ride|cancel trip|cancel booking", re.IGNORECASE)
CONFIRM_CANCEL = re.compile(r"yes, cancel|confirm cancel|cancel anyway", re.IGNORECASE)
BACK = re.compile(r"^\s*(back|close|done)\s*$", re.IGNORECASE)
TAB_TOP = 760

DOES = {
    "app_icon": "opens the app",
    "destination_field": "where you type the destination",
    "search_field": "a search or text field",
    "priced_option": "one option with its price; tapping selects it",
    "request_button": "commits the choice; can spend money",
    "cancel_ride_button": "starts cancelling the trip",
    "confirm_cancel_button": "confirms the cancellation; can carry a fee",
    "back_button": "goes back",
    "tab": "switches section",
    "list_row": "one row in a list",
    "button": "a button",
}

CONTROL_KEYS = ("role", "type", "label", "frame", "does", "money", "leads_to")


def empty_map():
    return {"schema_version": SCHEMA_VERSION, "onboarded_at": None, "onboarded_day": None,
            "inventory": {"names": [], "taken_at": None}, "apps": {}}


def map_path(state_dir):
    return os.path.join(state_dir, "map.json")


def load(state_dir):
    """the saved map, or an empty one when it is missing, unreadable, or from another schema."""
    try:
        with open(map_path(state_dir)) as handle:
            the_map = json.load(handle)
        validate(the_map)
    except (OSError, ValueError):
        return empty_map()
    for key, default in empty_map().items():
        the_map.setdefault(key, default)
    return the_map


def save(state_dir, the_map):
    """check the map, then write it whole: a temporary file, mode 0600, moved into place."""
    validate(the_map)
    os.makedirs(state_dir, mode=0o700, exist_ok=True)
    path = map_path(state_dir)
    temporary = "%s.%d.%s.new" % (path, os.getpid(), secrets.token_hex(3))
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        json.dump(the_map, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(temporary, path)


def _forbidden_key(node, where):
    if isinstance(node, dict):
        for key, child in node.items():
            if key in FORBIDDEN_KEYS:
                return "%s.%s" % (where, key)
            found = _forbidden_key(child, "%s.%s" % (where, key))
            if found:
                return found
    elif isinstance(node, list):
        for index, child in enumerate(node):
            found = _forbidden_key(child, "%s[%d]" % (where, index))
            if found:
                return found
    return None


def validate(the_map):
    """raise ValueError when the map is not one this file wrote, or holds something it never keeps."""
    if not isinstance(the_map, dict):
        raise ValueError("the map is not a JSON object")
    if the_map.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("the map has schema version %r, expected %d"
                         % (the_map.get("schema_version"), SCHEMA_VERSION))
    found = _forbidden_key(the_map, "map")
    if found:
        raise ValueError("the map must never hold %s" % found)
    if not isinstance(the_map.get("apps", {}), dict):
        raise ValueError("the map's apps is not a JSON object")


def shape(label):
    """every run of digits becomes one #, so a price or a time keeps its form and loses its number."""
    return re.sub(r"\d+", "#", label or "")


def is_login_screen(elements):
    """a screen with a secure text field, or labeled like sign in, password, or a one-time code."""
    for element in elements or []:
        if element.get("type") in SECURE_FIELD_TYPES:
            return True
        if LOGIN_WORDS.search(element.get("label") or ""):
            return True
    return False


def _short_label(label):
    """a button or field label we may keep, shaped, or None when it is too long or carries an @."""
    label = (label or "").strip()
    if not label or "@" in label or "\uff20" in label or len(label) > LABEL_LIMIT:
        return None
    return shape(label)


def _frame(frame):
    try:
        return [int(round(float(number))) for number in list(frame)[:4]]
    except (TypeError, ValueError):
        return [0, 0, 0, 0]


def classify(control):
    """the role of a control and what it does, in plain words. first match wins."""
    kind = control.get("type") or ""
    label = control.get("label") or ""
    frame = control.get("frame") or [0, 0, 0, 0]
    if kind == "XCUIElementTypeIcon":
        role = "app_icon"
    elif kind in FIELD_TYPES and DESTINATION.search(label):
        role = "destination_field"
    elif kind in FIELD_TYPES:
        role = "search_field"
    elif kind == "XCUIElementTypeCell" and offer_like(label):
        role = "priced_option"
    elif kind == "XCUIElementTypeButton" and REQUEST.search(label) and "cancel" not in label.lower():
        # "confirm cancel" starts with confirm, but it is a cancellation, handled below.
        role = "request_button"
    elif CANCEL_RIDE.search(label):
        role = "cancel_ride_button"
    elif CONFIRM_CANCEL.search(label):
        role = "confirm_cancel_button"
    elif BACK.search(label):
        role = "back_button"
    elif kind == "XCUIElementTypeTab" or (kind == "XCUIElementTypeButton" and len(frame) > 1
                                           and float(frame[1]) >= TAB_TOP):
        role = "tab"
    elif kind == "XCUIElementTypeCell":
        role = "list_row"
    else:
        role = "button"
    return role, DOES[role]


def _is_money(label, role):
    return bool(role in ("request_button", "confirm_cancel_button") or (label and MONEY_WORDS.search(label)))


def sanitize(elements):
    """the controls worth remembering from one screen, in the order they appear. never a value,
    never static text, never a secure field, never a list row's words unless it is a priced
    option, and then only its shape."""
    controls = []
    for element in elements or []:
        kind = element.get("type") or ""
        if kind not in CONTROL_TYPES:
            continue
        raw = (element.get("label") or "").strip()
        if not raw:
            continue
        frame = _frame(element.get("frame") or [0, 0, 0, 0])
        role, does = classify({"type": kind, "label": raw, "frame": frame})
        if role == "list_row":
            label = None
        elif role == "priced_option":
            if "@" in raw or "\uff20" in raw or len(raw) > PRICED_LABEL_LIMIT:
                continue
            label = shape(raw)
        else:
            label = _short_label(raw)
            if label is None:
                continue
        controls.append({"role": role, "type": kind, "label": label, "frame": frame, "does": does,
                         "money": _is_money(raw, role), "leads_to": None})
    return controls


def signature(app, controls):
    """twelve hexadecimal characters that name a screen: the app and its controls' types and labels."""
    pairs = sorted([c.get("type") or "", c.get("label") or ""] for c in controls or [])
    text = json.dumps([app or "", pairs], separators=(",", ":"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:12]


def _clean_control(control):
    """only the keys a control may carry, so nothing else rides along into the map."""
    clean = {key: control.get(key) for key in CONTROL_KEYS}
    clean["frame"] = _frame(clean["frame"] or [0, 0, 0, 0])
    clean["money"] = bool(clean["money"])
    return clean


def _app_entry(the_map, app, app_name):
    apps = the_map.setdefault("apps", {})
    entry = apps.get(app)
    if entry is None:
        entry = {"name": app_name or app, "mapped_at": None, "login_screens_skipped": 0, "screens": {}}
        apps[app] = entry
    elif app_name:
        entry["name"] = app_name
    entry.setdefault("screens", {})
    entry.setdefault("login_screens_skipped", 0)
    return entry


def _resolve_app(the_map, app):
    """a bundle as given, or the bundle of the app with that name (any case)."""
    apps = the_map.get("apps", {})
    if app in apps:
        return app
    wanted = (app or "").strip().lower()
    for bundle, entry in apps.items():
        if (entry.get("name") or "").strip().lower() == wanted:
            return bundle
    return None


def record_screen(the_map, app, app_name, controls, reached_by, now_stamp):
    """keep one screen of an app and return its signature. a screen seen before keeps its
    controls and links, and gains the new way it was reached."""
    entry = _app_entry(the_map, app, app_name)
    entry["mapped_at"] = now_stamp
    sig = signature(app, controls)
    screen = entry["screens"].get(sig)
    if screen is None:
        screen = {"first_seen": now_stamp, "reached_by": [],
                  "controls": [_clean_control(c) for c in controls or []]}
        entry["screens"][sig] = screen
    if isinstance(reached_by, str):
        reached_by = [reached_by]
    for label in reached_by or []:
        kept = _short_label(label)
        if kept and kept not in screen["reached_by"]:
            screen["reached_by"].append(kept)
    return sig


def link(the_map, app, from_signature, label, to_signature):
    """the control labeled label on one screen leads to another screen."""
    screen = the_map.get("apps", {}).get(app, {}).get("screens", {}).get(from_signature)
    if not screen:
        return
    for control in screen.get("controls", []):
        if control.get("label") is not None and control.get("label") in (label, shape(label)):
            control["leads_to"] = to_signature
            return


def note_login_skipped(the_map, app, app_name):
    entry = _app_entry(the_map, app, app_name)
    entry["login_screens_skipped"] = int(entry.get("login_screens_skipped") or 0) + 1


def set_inventory(the_map, names, now_stamp):
    """the installed apps by name, in home screen order, each once."""
    seen = []
    for name in names or []:
        name = (name or "").strip()
        if name and name not in seen:
            seen.append(name)
    the_map["inventory"] = {"names": seen, "taken_at": now_stamp}


def mark_onboarded(the_map, now_stamp):
    the_map["onboarded_at"] = now_stamp
    the_map["onboarded_day"] = (now_stamp or "")[:10] or None


def onboarding_due(the_map, today):
    """true until onboarding has run on the given day (written year-month-day)."""
    return (the_map or {}).get("onboarded_day") != today


def prune(the_map, app, screen=None):
    """remove a whole app, or one of its screens. app is a bundle or an app name. returns how
    many things were removed: one, or zero when there was nothing by that name."""
    bundle = _resolve_app(the_map, app)
    if bundle is None:
        return 0
    apps = the_map["apps"]
    if screen is None:
        del apps[bundle]
        return 1
    screens = apps[bundle].get("screens", {})
    if screen not in screens:
        return 0
    del screens[screen]
    for other in screens.values():
        for control in other.get("controls", []):
            if control.get("leads_to") == screen:
                control["leads_to"] = None
    return 1


def forget_app_screens(the_map, app):
    """refresh starts an app over: its screens and its login count go, its name stays."""
    bundle = _resolve_app(the_map, app)
    if bundle is None:
        return
    entry = the_map["apps"][bundle]
    entry["screens"] = {}
    entry["login_screens_skipped"] = 0


def find(the_map, app, role):
    """every control with that role in an app, each with the screen it is on, in map order."""
    bundle = _resolve_app(the_map, app)
    if bundle is None:
        return []
    found = []
    for sig, screen in the_map["apps"][bundle].get("screens", {}).items():
        for control in screen.get("controls", []):
            if control.get("role") == role:
                item = dict(control)
                item["screen"] = sig
                found.append(item)
    return found


def _plural(count, word):
    return "%d %s%s" % (count, word, "" if count == 1 else "s")


def describe(the_map):
    """the map in plain lines for the owner."""
    lines = []
    if the_map.get("onboarded_at"):
        lines.append("mapped on %s" % the_map["onboarded_at"])
    else:
        lines.append("not mapped yet; run sirven phone onboard")
    names = the_map.get("inventory", {}).get("names") or []
    if names:
        lines.append("apps on the home screens: %s" % ", ".join(names))
    for bundle, entry in sorted(the_map.get("apps", {}).items(), key=lambda item: item[1].get("name") or item[0]):
        screens = entry.get("screens", {})
        line = "%s (%s): %s" % (entry.get("name") or bundle, bundle, _plural(len(screens), "screen"))
        skipped = int(entry.get("login_screens_skipped") or 0)
        if skipped:
            line += ", %s skipped and not stored" % _plural(skipped, "login screen")
        lines.append(line)
        for sig, screen in screens.items():
            reached = ", ".join(screen.get("reached_by") or []) or "opening the app"
            lines.append("  screen %s, reached by %s" % (sig, reached))
            for control in screen.get("controls", []):
                label = control.get("label")
                words = "    %s%s: %s" % (control.get("role"), ' "%s"' % label if label else "", control.get("does"))
                if control.get("money"):
                    words += " (can spend money, waits for the owner)"
                if control.get("leads_to"):
                    words += ", leads to screen %s" % control["leads_to"]
                lines.append(words)
    return lines
