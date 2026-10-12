"""phone crawler: the onboarding walk that builds the semantic map of the owner's phone.

it lists the apps on the home screens by name, then walks the screens of the apps the owner
chose (by default the ride apps) and records, through phone_map, where the key controls are
and what each does. it only reads screens and taps by label. it never types, never taps by
point, never taps anything that could spend money, commit, send, delete, or sign out, and it
stops at once when the phone shows its own payment approval. login screens are skipped and
backed out of; only their count is kept.

the driver is any object with screen, tap, launch, home, and swipe, taking and returning what
the phone bridge's Phone methods do. a refusal is an exception with .result and .said. every
call carries a reason in plain words, because it lands in the owner's log.

python standard library only, and no import of phone_bridge (the bridge imports this file).
"""

import copy
import re
import time

import phone_map

DEFAULT_APPS = ("Uber", "Lyft")

HOME_SCREEN_APP = "com.apple.springboard"
ICON_TYPE = "XCUIElementTypeIcon"

# never tapped during a crawl, whatever the map would call it: the money words, plus anything
# that could commit, send, delete, sign out, or reach someone.
_MONEY = phone_map.MONEY_WORDS.pattern if hasattr(phone_map.MONEY_WORDS, "pattern") else str(phone_map.MONEY_WORDS)
NEVER_TAP = re.compile(
    r"(?:%s)|\b(cancel|delete|remove|sign[ -]?out|log[ -]?out|send|call|share|post|reply|compose|allow|"
    r"report|block|unsubscribe|emergency|wallet|pay|clear|reset|erase|close|deactivate|disable|turn off|"
    r"submit|accept|agree|rate|add|resend|continue|verify|install|update|download|join|follow|like|invite)\b"
    % _MONEY,
    re.IGNORECASE,
)

# the only element types the crawler presses. switches change settings, links can leave the
# app, and icons are only tapped on the home screen to open the app being mapped.
TAPPABLE_TYPES = (
    "XCUIElementTypeButton",
    "XCUIElementTypeCell",
    "XCUIElementTypeTextField",
    "XCUIElementTypeSearchField",
    "XCUIElementTypeTab",
    "XCUIElementTypeSegmentedControl",
)

# roles never pressed even when the label slips past the words above
UNSAFE_ROLES = ("request_button", "cancel_ride_button", "confirm_cancel_button", "app_icon", "list_row")

# refusals that end the crawl, and refusals that only mean skip this control
STOPPING = ("owner_approving_on_phone", "phone_locked", "no_consent")
SKIPPING = ("held_for_approval", "not_found")

FALLBACK_SIZE = {"width": 390, "height": 844}


class CrawlStopped(Exception):
    """the crawl stopped before it finished. .said says why, in plain words."""

    def __init__(self, said, summaries=None):
        super().__init__(said)
        self.said = said
        # what was mapped before the stop, so the owner still hears it
        self.summaries = list(summaries or [])


class _Skip(Exception):
    """one control could not be pressed (held for the owner, or no longer on screen)."""


def _stop_words(refusal):
    said = getattr(refusal, "said", None) or str(refusal)
    result = getattr(refusal, "result", None)
    if result == "owner_approving_on_phone":
        return "the phone is showing its own payment approval, which only the owner answers, so mapping stopped: %s" % said
    if result == "phone_locked":
        return "the phone is locked, so mapping stopped: %s" % said
    if result == "no_consent":
        return "the phone session ended, so mapping stopped: %s" % said
    return "the phone refused a step, so mapping stopped: %s" % said


def _call(method, *arguments):
    """one driver call. a stopping refusal becomes CrawlStopped, a skipping one becomes _Skip,
    and any other refusal also stops the crawl, since nothing about the phone is then certain."""
    try:
        return method(*arguments)
    except Exception as refusal:
        result = getattr(refusal, "result", None)
        if result is None:
            raise
        if result in SKIPPING:
            raise _Skip(getattr(refusal, "said", str(refusal)))
        raise CrawlStopped(_stop_words(refusal))


def _read(driver, reason):
    """read the screen; stop when the phone is showing its own payment approval."""
    seen = _call(driver.screen, reason)
    if seen.get("owner_approving_on_phone"):
        raise CrawlStopped("the phone is showing its own payment approval, which only the owner answers, so mapping stopped")
    return seen


def _icon_names(elements):
    names = []
    for element in elements:
        if element.get("type") == ICON_TYPE and element.get("label") and element["label"] not in names:
            names.append(element["label"])
    return names


def _swipe_to_next_page(driver, seen, reason):
    size = seen.get("size") or FALLBACK_SIZE
    width = size.get("width") or FALLBACK_SIZE["width"]
    height = size.get("height") or FALLBACK_SIZE["height"]
    middle = round(height / 2)
    _call(driver.swipe, {"from_x": round(width * 0.8), "from_y": middle, "to_x": round(width * 0.2),
                         "to_y": middle, "reason": reason})


def walk_home_screens(driver, max_pages=6):
    """the names of the app icons on the home screens, in order. goes home first, swipes left
    between pages, stops when a page repeats, and goes back home after."""
    reason = "listing the apps on the home screens for onboarding"
    _call(driver.home, {"reason": reason})
    names = []
    pages_seen = []
    for _ in range(max_pages):
        seen = _read(driver, reason)
        page = tuple(_icon_names(seen.get("elements") or []))
        if page in pages_seen:
            break
        pages_seen.append(page)
        for name in page:
            if name not in names:
                names.append(name)
        _swipe_to_next_page(driver, seen, reason)
    _call(driver.home, {"reason": reason})
    return names


def _open_from_home(driver, name, reason, max_pages=6):
    """go home and page through the home screens until an icon labeled name shows, then tap
    it. returns the bundle that opened, or None when no icon has that name."""
    _call(driver.home, {"reason": reason})
    pages_seen = []
    for _ in range(max_pages):
        seen = _read(driver, reason)
        elements = seen.get("elements") or []
        if any(e.get("type") == ICON_TYPE and e.get("label") == name for e in elements):
            try:
                _call(driver.tap, {"label": name, "reason": reason})
            except _Skip:
                return None
            opened = _read(driver, reason)
            app = opened.get("app")
            if not app or app == HOME_SCREEN_APP:
                return None
            return app
        page = tuple(_icon_names(elements))
        if page in pages_seen:
            break
        pages_seen.append(page)
        _swipe_to_next_page(driver, seen, reason)
    _call(driver.home, {"reason": reason})
    return None


def _one_control(element):
    """the map's view of one element (no value, label shaped), or None when it is not kept."""
    kept = phone_map.sanitize([element])
    return kept[0] if kept else None


def _safe_controls(elements):
    """the controls on this screen that are safe to press, as (label to tap by, label as the
    map stores it). the raw label is only held in memory for the tap; the map gets the shape."""
    safe = []
    seen_labels = set()
    for element in elements:
        label = element.get("label") or ""
        if not label or label in seen_labels:
            continue
        if element.get("type") not in TAPPABLE_TYPES:
            continue
        if NEVER_TAP.search(label):
            continue
        control = _one_control(element)
        if control is None or control.get("label") is None:
            continue
        if control.get("money") or control.get("role") in UNSAFE_ROLES:
            continue
        if NEVER_TAP.search(control["label"]):
            continue
        seen_labels.add(label)
        safe.append((label, control["label"]))
    return safe


def crawl_app(driver, the_map, name, now_stamp, max_screens=12, max_depth=3, max_seconds=150):
    """map one app, breadth first over its safe controls, starting from its home screen icon.
    to reach a screen at depth n it relaunches the app and replays the tap path."""
    reason = "mapping the %s app for onboarding" % name
    if NEVER_TAP.search(name):
        return {"name": name, "result": "not_crawled",
                "said": "the icon's name reads like something that could spend money or send, so it was not opened"}
    app = _open_from_home(driver, name, reason)
    if app is None:
        return {"name": name, "result": "not_installed"}

    recorded = []          # signatures recorded in this crawl
    login_seen = []        # in-memory identities of login screens met, only ever counted
    linked = set()
    expanded = set()
    # each entry: (tap path as raw labels, parent signature, the tapped label as the map keeps it)
    queue = [([], None, None)]
    first = True
    # a time budget per app, well inside the onboarding session, so a control-rich app cannot
    # run the session out and leave the next app with no consent
    deadline = time.monotonic() + max_seconds
    while queue and len(recorded) < max_screens and time.monotonic() < deadline:
        path, parent, via = queue.pop(0)
        if first:
            # the app was just opened from its icon, so the start screen is already showing
            first = False
        else:
            # fresh: a running app resumes where it was left, so close it and start clean
            _call(driver.launch, {"bundle": app, "fresh": True, "reason": reason})
            try:
                for label in path:
                    _call(driver.tap, {"label": label, "reason": reason})
            except _Skip:
                continue
        seen = _read(driver, reason)
        if seen.get("app") != app:
            # the tap left the app; nothing is recorded from another app
            continue
        elements = seen.get("elements") or []
        if phone_map.is_login_screen(elements):
            identity = phone_map.signature(app, phone_map.sanitize(elements))
            if identity not in login_seen:
                login_seen.append(identity)
                phone_map.note_login_skipped(the_map, app, name)
            # back out; the next path relaunches the app
            _call(driver.home, {"reason": reason})
            continue
        controls = phone_map.sanitize(elements)
        signature = phone_map.record_screen(the_map, app, name, controls, [via] if via else [], now_stamp)
        if signature not in recorded:
            recorded.append(signature)
        if parent is not None and (parent, via) not in linked:
            linked.add((parent, via))
            phone_map.link(the_map, app, parent, via, signature)
        if signature in expanded or len(path) >= max_depth:
            continue
        expanded.add(signature)
        for label, shaped in _safe_controls(elements):
            queue.append((path + [label], signature, shaped))

    _call(driver.home, {"reason": reason})
    return {"app": app, "name": name, "screens": len(recorded), "login_screens_skipped": len(login_seen)}


def _bundle_named(the_map, name):
    for bundle, entry in (the_map.get("apps") or {}).items():
        if entry.get("name") == name:
            return bundle
    return None


def onboard(driver, the_map, names, now_stamp, refresh=False):
    """the onboarding walk: list the apps, map each named app (refresh forgets what the map
    already holds for it first), and mark the map onboarded. returns one summary per name."""
    summaries = []
    try:
        phone_map.set_inventory(the_map, walk_home_screens(driver), now_stamp)
        for name in names:
            bundle = _bundle_named(the_map, name) if refresh else None
            kept = copy.deepcopy(the_map["apps"].get(bundle)) if bundle is not None else None
            if bundle is not None:
                phone_map.forget_app_screens(the_map, bundle)
            try:
                summary = crawl_app(driver, the_map, name, now_stamp)
            except CrawlStopped:
                # a refresh that did not finish keeps what the map held before it
                if kept is not None:
                    the_map["apps"][bundle] = kept
                raise
            if kept is not None and summary.get("result") in ("not_installed", "not_crawled"):
                the_map["apps"][bundle] = kept
            summaries.append(summary)
    except CrawlStopped as stopped:
        raise CrawlStopped(stopped.said, summaries)
    phone_map.mark_onboarded(the_map, now_stamp)
    return summaries
