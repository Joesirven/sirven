"""the owner's iPhone and the phone bridge, in memory, for the rehearsal.

SUBSTITUTION. a live fire drives the owner's own plugged-in iPhone through the phone bridge
(lib/phone_bridge.py, docs/phone-interface.md). the rehearsal has no phone, so RehearsalPhone
plays both: a small phone read from fixtures/rehearsal-phone.json (a home screen and the Uber
and Lyft apps, invented prices), and the bridge's rules on top of it. it speaks the same calls
the real ride backend makes of the bridge (connectors/ride/ride_phone/client.py), and its
driver() speaks the calls the onboarding crawler makes (lib/phone_crawler.py).

the bridge's rules it keeps:
  a tap on something labeled like money (phone_map.MONEY_WORDS), or marked money, is held: it
  raises PhoneRefusal("held_for_approval") with a fresh hold, unless the tap carries a hold the
  owner approved for that same label. an approval is used once and never covers a later tap.
  hold_state asks the owner, through the demo's Asker (kind "phone_hold"), the question
  sirven phone approve answers on a real Mac.
  a screen marked awaits_owner is the phone's own Apple Pay sheet. reading it reports
  owner_approving_on_phone, asks the owner (kind "phone_payment", worded as the phone's own
  prompt, answered on the phone), and moves to the screen for yes or for no. while the sheet is
  up, every tap and every typed letter is refused with "owner_approving_on_phone". nothing here
  stores, replays, or stands in for that answer: each sheet asks again.
  the onboarding driver never taps a money word, and never creates a hold for one.
"""

import copy
import json
import os
import secrets
import sys

DEMO_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_DIR = os.path.dirname(os.path.dirname(DEMO_DIR))
for _path in (os.path.join(REPO_DIR, "connectors", "ride"), os.path.join(REPO_DIR, "lib")):
    if _path not in sys.path:
        sys.path.insert(0, _path)

import phone_map  # noqa: E402
from ride_phone.client import PhoneRefusal  # noqa: E402

FIXTURE = os.path.join(DEMO_DIR, "fixtures", "rehearsal-phone.json")
SIZE = {"width": 390, "height": 844}


def refusal(result, said, status=409, hold=None):
    return PhoneRefusal(result, said, status, {"hold": hold} if hold else {})


class RehearsalPhone:
    """ask(question, kind) plays the owner and returns True for yes. the_map is what onboarding
    learned; it starts empty, so the ride backend finds nothing until the phone is onboarded."""

    def __init__(self, ask, fixture=FIXTURE):
        with open(fixture) as handle:
            self.world = json.load(handle)
        self.ask = ask
        self.state = dict(self.world["start"], typed="")
        self.holds = {}
        self.the_map = phone_map.empty_map()
        # what happened, in the bridge's words, for the tests and the owner
        self.log = []

    # the world --------------------------------------------------------------------------

    def _app(self):
        return self.world["apps"][self.state["app"]]

    def _current(self):
        return self._app()["screens"][self.state["screen"]]

    def _elements(self):
        found = []
        for element in self._current()["elements"]:
            found.append({"type": "XCUIElementType" + element["type"], "label": element["label"],
                          "value": self.state["typed"] if element.get("typing") else element.get("value", ""),
                          "frame": list(element["frame"])})
        return found

    def _note(self, action, said, **details):
        self.log.append(dict(details, action=action, said=said))

    def _sheet_up(self, action, reason):
        if "awaits_owner" in self._current():
            self._note(action, "refused: the phone is showing its own payment approval", reason=reason)
            raise refusal("owner_approving_on_phone",
                          "the phone is showing its own face recognition or Apple Pay approval; only the owner "
                          "answers it, on the phone. read the screen again once it is gone")

    def _owner_answers_the_sheet(self):
        """the phone's own prompt, asked of the owner. the answer is the owner's, on the phone;
        sirven only sees the screen that follows."""
        screen = self._current()
        lines = [e["label"] for e in screen["elements"] if e["type"] == "StaticText"]
        question = ("the phone's own Apple Pay sheet, on your iPhone (sirven never presses it or answers it): %s. "
                    "Double click the side button and look at the phone to pay with face recognition. "
                    "Pay for this one ride?" % ", ".join(line for line in lines if "Double Click" not in line))
        approved = self.ask(question, "phone_payment")
        target = screen["awaits_owner"] if approved else screen.get("declined")
        self._note("owner", "approved on the phone" if approved else "declined on the phone")
        if target:
            self.state = dict(self.state, screen=target, typed="")

    # the bridge's calls, as the ride backend makes them -------------------------------------

    def screen(self, reason):
        answer = {"app": self.state["app"], "size": dict(SIZE), "elements": self._elements(),
                  "owner_approving_on_phone": "awaits_owner" in self._current()}
        self._note("screen", "read the screen in %s" % self.state["app"], reason=reason)
        if answer["owner_approving_on_phone"]:
            self._owner_answers_the_sheet()
        return answer

    def phone_map(self, app=None):
        return {"map": self.the_map}

    def tap(self, label, reason, money=False, approval=None):
        self._sheet_up("tap", reason)
        element = next((e for e in self._current()["elements"] if e["label"] == label), None)
        if element is None:
            element = next((e for e in self._current()["elements"] if e["label"].lower() == label.lower()), None)
        if element is None:
            raise refusal("not_found", "nothing labeled \"%s\" is on the screen" % label, 404)
        app = self.state["app"]
        if money or phone_map.MONEY_WORDS.search(element["label"]):
            if approval:
                self._take_approval(approval, element["label"])
            else:
                hold = secrets.token_hex(4)
                self.holds[hold] = {"label": element["label"], "app": app, "reason": reason, "state": "waiting"}
                self._note("tap", "held \"%s\" for the owner" % element["label"], reason=reason, hold=hold)
                raise refusal("held_for_approval",
                              "tapping \"%s\" could spend money or commit a booking, so it waits for the owner: "
                              "sirven phone approve %s" % (element["label"], hold), hold=hold)
        self._press(element)
        self._note("tap", "tapped \"%s\" in %s" % (element["label"], app), reason=reason, hold=approval)
        return {"result": "ok"}

    def _take_approval(self, hold, label):
        record = self.holds.get(hold)
        if not record or record["state"] != "approved":
            raise refusal("not_approved", "hold %s has not been approved by the owner" % hold, 403)
        if record["label"] != label or record["app"] != self.state["app"]:
            raise refusal("not_approved", "hold %s was approved for a different action" % hold, 403)
        record["state"] = "used"

    def _press(self, element):
        if "launch" in element:
            app = self.world["apps"][element["launch"]]
            self.state = {"app": element["launch"], "screen": app["first"], "typed": ""}
        elif "goto" in element:
            self.state = dict(self.state, screen=element["goto"], typed="")

    def type_text(self, text, reason):
        self._sheet_up("type", reason)
        self.state = dict(self.state, typed=self.state["typed"] + text)
        then = self._current().get("on_type")
        if then:
            self.state = dict(self.state, screen=then)
        self._note("type", "typed into %s" % self.state["app"], reason=reason)
        return {"result": "ok"}

    def launch(self, bundle, reason, fresh=False):
        app = self.world["apps"].get(bundle)
        if app is None:
            raise refusal("launch_failed", "no app %s is installed" % bundle, 404)
        if bundle != self.state["app"] or fresh:
            # like iOS: an app already in front resumes where it was, unless closed first (fresh)
            self.state = {"app": bundle, "screen": app["first"], "typed": ""}
        self._note("launch", "opened %s" % bundle, reason=reason)
        return {"result": "ok"}

    def home(self, reason):
        self.state = dict(self.world["start"], typed="")
        self._note("home", "went to the home screen", reason=reason)
        return {"result": "ok"}

    def swipe(self, from_x, to_x, reason):
        self._sheet_up("swipe", reason)
        screen = self._current()
        if from_x > to_x and screen.get("next_page"):
            self.state = dict(self.state, screen=screen["next_page"])
        elif from_x < to_x and screen.get("previous_page"):
            self.state = dict(self.state, screen=screen["previous_page"])
        return {"result": "ok"}

    def hold_state(self, hold):
        """what sirven phone approve decides, asked of the owner once per hold."""
        record = self.holds.get(hold)
        if record is None:
            raise refusal("not_found", "there is no hold %s" % hold, 404)
        if record["state"] == "waiting":
            name = self.world["apps"][record["app"]]["name"]
            question = ("sirven phone approve %s: the agent wants to tap \"%s\" in %s, because: %s. "
                        "Approve this one tap, once?" % (hold, record["label"], name, record["reason"]))
            record["state"] = "approved" if self.ask(question, "phone_hold") else "denied"
        return {"hold": hold, "state": record["state"], "label": record["label"], "app": record["app"]}

    # the onboarding crawler's view ------------------------------------------------------

    def driver(self):
        return OnboardingDriver(self)

    # for tests and narration --------------------------------------------------------------

    def where(self):
        return self._app()["name"], self.state["screen"]

    def reprice(self, old_label, new_label):
        """the app's price moved: every row labeled old_label now reads new_label."""
        world = copy.deepcopy(self.world)
        for app in world["apps"].values():
            for screen in app["screens"].values():
                for element in screen["elements"]:
                    if element["label"] == old_label:
                        element["label"] = new_label
        self.world = world


class OnboardingDriver:
    """the crawler's driver, as the bridge gives it: no typing, and a money word is refused
    before the tap reaches the phone, without asking the owner anything."""

    def __init__(self, phone):
        self.phone = phone

    def screen(self, reason):
        return self.phone.screen(reason)

    def tap(self, body):
        label = body.get("label")
        if isinstance(label, str) and phone_map.MONEY_WORDS.search(label):
            raise refusal("held_for_approval", "onboarding never taps \"%s\", which could spend money" % label)
        return self.phone.tap(label, body["reason"])

    def launch(self, body):
        return self.phone.launch(body["bundle"], body["reason"], fresh=bool(body.get("fresh")))

    def home(self, body):
        return self.phone.home(body["reason"])

    def swipe(self, body):
        return self.phone.swipe(body["from_x"], body["to_x"], body["reason"])
