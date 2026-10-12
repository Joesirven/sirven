"""an in-memory phone for the crawler tests: it plays tests/lib/phone_world.json the way the fake
phone does in world mode, and answers like the bridge's thin adapter over a Phone does.

it keeps every call (with its reason) and every tap label, so a test can say what the crawler
touched. it refuses like the bridge: a tap on something labeled with money words is held for
the owner, a label not on screen is not found, and while the phone's own payment approval is
up every touch is refused. it has no way to type, on purpose.

replay_taps(world, calls) reads a fake phone's calls.jsonl lines and names what each tap landed
on, so the shell tests can check the same things against the real bridge.
"""

import copy
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPOSITORY = os.path.dirname(os.path.dirname(HERE))
WORLD_PATH = os.path.join(REPOSITORY, "tests", "lib", "phone_world.json")

# the same words the bridge holds for the owner (lib/phone_bridge.py MONEY_WORDS)
MONEY_WORDS = re.compile(
    r"\b(book|booking|request|confirm|pay|payment|purchase|buy|order|place order|checkout|"
    r"check out|subscribe|reserve|rent|tip|donate|send money|transfer)\b",
    re.IGNORECASE,
)
OWNER_APPROVAL_SHEET = re.compile(
    r"\b(double[- ]click to pay|confirm with side button|pay with face id|pay with passcode|"
    r"pay with touch id|confirm with face id|face id)\b",
    re.IGNORECASE,
)


def load_world():
    with open(WORLD_PATH) as handle:
        return json.load(handle)


class Refusal(Exception):
    """what the bridge raises instead of acting: .result and .said."""

    def __init__(self, result, said):
        super().__init__(said)
        self.result = result
        self.said = said


class WorldDriver:
    def __init__(self, world=None):
        self.world = copy.deepcopy(world if world is not None else load_world())
        self.app = self.world["start"]["app"]
        self.screen_name = self.world["start"]["screen"]
        self.calls = []          # (method, body or reason)
        self.reasons = []
        self.taps = []           # labels actually tapped
        self.tap_bodies = []     # every tap body asked for, tapped or not
        self.touches_during_sheet = 0
        self.locked = False
        self.missing_labels = set()   # labels the driver pretends are not on screen when tapped
        self.screens_seen = []
        self.missing_reasons = []     # methods called without a reason
        self.point_taps = []          # tap bodies without a label

    # the world --------------------------------------------------------------------------

    def current(self):
        return self.world["apps"][self.app]["screens"][self.screen_name]

    def elements(self):
        app = self.world["apps"][self.app]
        found = [{"type": "XCUIElementTypeApplication", "label": app["name"], "value": "",
                  "frame": [0.0, 0.0, 390.0, 844.0]}]
        for element in self.current()["elements"]:
            found.append({"type": "XCUIElementType" + element["type"], "label": element["label"],
                          "value": element.get("value", ""), "frame": [float(n) for n in element["frame"]]})
        return found

    def sheet_up(self):
        return any(OWNER_APPROVAL_SHEET.search(e["label"]) for e in self.current()["elements"])

    def _note(self, method, body):
        reason = body.get("reason") if isinstance(body, dict) else body
        self.calls.append((method, body))
        self.reasons.append(reason)
        if not reason or not str(reason).strip():
            self.missing_reasons.append(method)
        if self.locked:
            raise Refusal("phone_locked", "the phone is locked; the owner unlocks it, the agent never does")

    def _touch(self, method, body):
        self._note(method, body)
        if self.sheet_up():
            self.touches_during_sheet += 1
            raise Refusal("owner_approving_on_phone",
                          "the phone is showing its own face recognition or Apple Pay approval; only the owner answers it")

    # the driver interface ---------------------------------------------------------------

    def screen(self, reason):
        self._note("screen", reason)
        self.screens_seen.append((self.app, self.screen_name))
        return {"app": self.app, "elements": self.elements(), "owner_approving_on_phone": self.sheet_up()}

    def tap(self, body):
        self.tap_bodies.append(dict(body))
        self._touch("tap", body)
        if "label" not in body:
            self.point_taps.append(dict(body))
            raise Refusal("not_found", "the test phone only takes taps by label")
        label = str(body["label"])
        if label in self.missing_labels:
            raise Refusal("not_found", "nothing labeled \"%s\" is on the screen" % label)
        elements = self.current()["elements"]
        exact = [e for e in elements if e["label"] == label] or \
            [e for e in elements if e["label"].lower() == label.lower()]
        if not exact:
            raise Refusal("not_found", "nothing labeled \"%s\" is on the screen" % label)
        element = exact[0]
        if MONEY_WORDS.search(element["label"]):
            raise Refusal("held_for_approval", "tapping \"%s\" could spend money, so it waits for the owner" % label)
        self.taps.append(element["label"])
        if "launch" in element:
            self.app = element["launch"]
            self.screen_name = self.world["apps"][self.app]["first"]
        elif "goto" in element:
            self.screen_name = element["goto"]
        return {"said": "tapped \"%s\"" % label}

    def launch(self, body):
        self._touch("launch", body)
        bundle = body["bundle"]
        if bundle not in self.world["apps"]:
            raise Refusal("launch_failed", "no app %s is installed" % bundle)
        if bundle != self.app or body.get("fresh"):
            # like the fake phone and iOS: an app already in front resumes where it was, unless
            # the launch asks to start fresh
            self.app = bundle
            self.screen_name = self.world["apps"][bundle]["first"]
        return {"said": "opened %s" % bundle}

    def home(self, body):
        self._touch("home", body)
        self.app = self.world["start"]["app"]
        self.screen_name = self.world["start"]["screen"]
        return {"said": "went to the home screen"}

    def swipe(self, body):
        self._touch("swipe", body)
        screen = self.current()
        if body["from_x"] > body["to_x"] and screen.get("next_page"):
            self.screen_name = screen["next_page"]
        elif body["from_x"] < body["to_x"] and screen.get("previous_page"):
            self.screen_name = screen["previous_page"]
        return {"said": "swiped"}


def replay_taps(world, calls):
    """the labels a fake phone's taps landed on, replaying its calls.jsonl in order."""
    state = dict(world["start"])
    landed = []
    for call in calls:
        path = call["path"].split("?")[0]
        body = call.get("body") or {}
        screen = world["apps"][state["app"]]["screens"][state["screen"]]
        if call["method"] != "POST":
            continue
        if path.endswith("/wda/tap"):
            x, y = body["x"], body["y"]
            under = [e for e in screen["elements"] if e["frame"][0] <= x <= e["frame"][0] + e["frame"][2]
                     and e["frame"][1] <= y <= e["frame"][1] + e["frame"][3]]
            if not under:
                landed.append(None)
                continue
            element = min(under, key=lambda e: e["frame"][2] * e["frame"][3])
            landed.append(element["label"])
            if "launch" in element:
                state = {"app": element["launch"], "screen": world["apps"][element["launch"]]["first"]}
            elif "goto" in element:
                state = dict(state, screen=element["goto"])
        elif path == "/wda/homescreen":
            state = dict(world["start"])
        elif path.endswith("/wda/apps/activate"):
            app = world["apps"].get(body.get("bundleId"))
            if app is not None and body["bundleId"] != state["app"]:
                state = {"app": body["bundleId"], "screen": app["first"]}
        elif path.endswith("/wda/dragfromtoforduration"):
            if body["fromX"] > body["toX"] and screen.get("next_page"):
                state = dict(state, screen=screen["next_page"])
            elif body["fromX"] < body["toX"] and screen.get("previous_page"):
                state = dict(state, screen=screen["previous_page"])
    return landed


if __name__ == "__main__":
    # fake_driver.py WORLD CALLS: print each tap's label, one per line
    with open(sys.argv[1]) as handle:
        the_world = json.load(handle)
    with open(sys.argv[2]) as handle:
        lines = [json.loads(line) for line in handle if line.strip()]
    for label in replay_taps(the_world, lines):
        print(label if label is not None else "(nothing)")
