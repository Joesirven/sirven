#!/usr/bin/env python3
"""phone bridge: the owner's agent drives the owner's own iPhone, plugged in over USB (the
phone's charging cable), through a local, authenticated, plainly logged interface.

the approach comes from the iPhone-use project (github.com/zhongerxin/iPhone-use, MIT license,
copyright 2026 ZHONG XIN): WebDriverAgent runs on the phone as a test runner, and the Mac talks
to it over the USB multiplexer. this file is sirven's own code. it uses only the python
standard library: no Node, no libimobiledevice, no analytics of any kind.

one personal device, the owner's own, signed into the owner's own accounts. this is not the
multi-phone device-farm tier from the scope, which stays deferred.

subcommands (bin/sirven phone passes its arguments here)

  detect                 is an iPhone plugged in, and has it trusted this Mac
  setup --team TEAM --bundle BUNDLE
                         print the WebDriverAgent setup plan. it only prints; the owner runs it
  allow [--minutes N] [--allow-submit]
                         the owner opens a phone session. asks for a typed yes on a terminal
  stop                   the owner ends the phone session now
  status                 the session, the device, and WebDriverAgent readiness
  serve [--port N]       run the local interface on 127.0.0.1 for the agent
  log [--json]           every agent action on the phone, in plain language
  holds                  actions waiting for the owner's approval
  approve HOLD           the owner approves one held action, once, for five minutes
  deny HOLD              the owner refuses one held action

state lives in SIRVEN_PHONE_DIR (default ~/.sirven/phone), owned by the owner, mode 0700:
  session.json   the open phone session, if any
  token          the bearer token for the local interface, mode 0600, new on every serve
  actions.jsonl  the plain-language log, one JSON object per line, appended
  holds/         one file per held action

the interface itself is described in docs/phone-interface.md.
"""

import base64
import datetime
import http.client
import http.server
import json
import os
import plistlib
import re
import secrets
import socket
import struct
import sys
import threading
import time
import urllib.parse
import xml.etree.ElementTree as ElementTree

USBMUX_SOCKET = "/var/run/usbmuxd"
WEBDRIVERAGENT_PORT = 8100
DEFAULT_PORT = 47817
DEFAULT_MINUTES = 30
LONGEST_SESSION_MINUTES = 240
APPROVAL_MINUTES = 5

# WebDriverAgent as iPhone-use pins it. fetched by the owner at setup time, never bundled.
WEBDRIVERAGENT_REPOSITORY = "https://github.com/appium/WebDriverAgent.git"
WEBDRIVERAGENT_COMMIT = "d17782422d55ff1e5e0ceb74eb1fd509cc0c35b6"

# a tap on something labeled like this could commit money or a booking. it waits for the
# owner's approval. a heuristic, so the agent can also mark any action money-bearing itself.
MONEY_WORDS = re.compile(
    r"\b(book|booking|request|confirm|pay|payment|purchase|buy|order|place order|checkout|"
    r"check out|subscribe|reserve|rent|tip|donate|send money|transfer)\b",
    re.IGNORECASE,
)

SECURE_FIELD_TYPES = ("XCUIElementTypeSecureTextField",)


class Refusal(Exception):
    """an honest result the agent gets back instead of an action: the reason, in plain words."""

    def __init__(self, result, said, status=403, extra=None):
        super().__init__(said)
        self.result = result
        self.said = said
        self.status = status
        self.extra = extra or {}


# time --------------------------------------------------------------------------------------


def now():
    pinned = os.environ.get("SIRVEN_TIME_OVERRIDE")
    if pinned and test_mode():
        return datetime.datetime.strptime(pinned, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    return datetime.datetime.now(datetime.timezone.utc)


def stamp(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_stamp(text):
    return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)


# where things are --------------------------------------------------------------------------


def usbmux_socket():
    return os.environ.get("SIRVEN_USBMUX_SOCKET", USBMUX_SOCKET)


def test_mode():
    """a fake device, never a real one. only then may tests skip the typed yes."""
    return usbmux_socket() != USBMUX_SOCKET


def state_dir():
    path = os.environ.get("SIRVEN_PHONE_DIR") or os.path.join(os.path.expanduser("~"), ".sirven", "phone")
    os.makedirs(os.path.join(path, "holds"), mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def state_file(name):
    return os.path.join(state_dir(), name)


def write_private(path, text):
    temporary = path + ".new"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        handle.write(text)
    os.replace(temporary, path)


def read_json(path):
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


# the USB multiplexer -----------------------------------------------------------------------
# usbmuxd speaks property lists over a unix socket. a Connect message turns the socket into a
# raw pipe to one port on the phone, so no separate port forwarder is needed.


class Usbmux:
    def __init__(self, path=None):
        self.path = path or usbmux_socket()
        self.tag = 0

    def _open(self):
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(5)
        try:
            connection.connect(self.path)
        except OSError as error:
            connection.close()
            raise Refusal("no_usb_service", "the Mac's USB multiplexer did not answer (%s)" % error.strerror, 503)
        return connection

    def _send(self, connection, message):
        self.tag += 1
        message = dict(message, ClientVersionString="sirven", ProgName="sirven")
        body = plistlib.dumps(message)
        # length, version 1 (property lists), message type 8 (property list), tag
        connection.sendall(struct.pack("<IIII", 16 + len(body), 1, 8, self.tag) + body)

    def _receive(self, connection):
        header = _read_exactly(connection, 16)
        length = struct.unpack("<IIII", header)[0]
        return plistlib.loads(_read_exactly(connection, length - 16))

    def request(self, message):
        connection = self._open()
        try:
            self._send(connection, message)
            return self._receive(connection)
        finally:
            connection.close()

    def devices(self):
        """attached iPhones over USB, each as {"device": number, "serial": text}."""
        reply = self.request({"MessageType": "ListDevices"})
        found = []
        for entry in reply.get("DeviceList", []):
            properties = entry.get("Properties", {})
            if properties.get("ConnectionType") != "USB":
                continue
            found.append({"device": entry.get("DeviceID"), "serial": properties.get("SerialNumber", "")})
        return found

    def trusted(self, serial):
        """the phone trusts this Mac when a pairing record exists for it. the record itself holds
        keys, so it is never kept, printed, or logged: only whether it exists."""
        reply = self.request({"MessageType": "ReadPairRecord", "PairRecordID": serial})
        return bool(reply.get("PairRecordData"))

    def connect(self, device, port):
        connection = self._open()
        # the port goes in network byte order inside a little-endian field, as usbmuxd expects
        swapped = ((port << 8) & 0xFF00) | (port >> 8)
        self._send(connection, {"MessageType": "Connect", "DeviceID": device, "PortNumber": swapped})
        reply = self._receive(connection)
        if reply.get("MessageType") != "Result" or reply.get("Number") != 0:
            connection.close()
            raise Refusal(
                "webdriveragent_not_running",
                "the phone did not accept a connection on port %d: WebDriverAgent is not running on it" % port,
                503,
            )
        connection.settimeout(30)
        return connection


def _read_exactly(connection, count):
    data = b""
    while len(data) < count:
        piece = connection.recv(count - len(data))
        if not piece:
            raise Refusal("no_usb_service", "the USB multiplexer closed the connection early", 503)
        data += piece
    return data


def detect():
    """the plugged-in phone, or an honest reason there is none."""
    mux = Usbmux()
    phones = mux.devices()
    if not phones:
        return {"result": "no_phone", "said": "no iPhone is plugged in over USB"}
    if len(phones) > 1:
        return {
            "result": "several_phones",
            "said": "%d phones are plugged in; sirven drives one personal phone, so unplug the others" % len(phones),
        }
    phone = phones[0]
    if not mux.trusted(phone["serial"]):
        return {
            "result": "not_trusted",
            "said": "an iPhone is plugged in but has not trusted this Mac yet: unlock it and tap Trust",
            "device": phone["device"],
        }
    return {"result": "trusted", "said": "an iPhone is plugged in and trusts this Mac", "device": phone["device"]}


# WebDriverAgent ----------------------------------------------------------------------------


class UsbHTTPConnection(http.client.HTTPConnection):
    """HTTP to WebDriverAgent on the phone, through the USB multiplexer."""

    def __init__(self, device, port):
        super().__init__("127.0.0.1", port, timeout=30)
        self.device = device
        self.device_port = port

    def connect(self):
        self.sock = Usbmux().connect(self.device, self.device_port)


class WebDriverAgent:
    def __init__(self, device):
        self.device = device
        self.session = None
        self.lock = threading.Lock()

    def _connection(self):
        direct = os.environ.get("SIRVEN_WEBDRIVERAGENT_URL")
        if direct:
            # for an owner already running a port forwarder. loopback only, never the network
            parsed = urllib.parse.urlsplit(direct)
            if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
                raise Refusal("not_loopback", "SIRVEN_WEBDRIVERAGENT_URL must be http on this Mac's loopback", 500)
            return http.client.HTTPConnection(parsed.hostname, parsed.port or WEBDRIVERAGENT_PORT, timeout=30)
        return UsbHTTPConnection(self.device, WEBDRIVERAGENT_PORT)

    def call(self, method, path, body=None):
        connection = self._connection()
        try:
            payload = None if body is None else json.dumps(body)
            headers = {"Content-Type": "application/json"} if payload is not None else {}
            try:
                connection.request(method, path, body=payload, headers=headers)
                response = connection.getresponse()
                data = response.read()
            except (OSError, http.client.HTTPException) as error:
                raise Refusal("webdriveragent_not_running", "WebDriverAgent on the phone did not answer (%s)" % error, 503)
        finally:
            connection.close()
        try:
            value = json.loads(data or b"{}").get("value")
        except ValueError:
            raise Refusal("webdriveragent_error", "WebDriverAgent sent something that is not JSON", 502)
        if isinstance(value, dict) and value.get("error"):
            raise Refusal("webdriveragent_error", "WebDriverAgent said: %s" % value.get("message", value["error"]), 502)
        return value

    def ready(self):
        status = self.call("GET", "/status")
        return bool(isinstance(status, dict) and status.get("ready", True))

    def locked(self):
        return bool(self.call("GET", "/wda/locked"))

    def session_path(self, suffix):
        with self.lock:
            if self.session is None:
                created = self.call(
                    "POST",
                    "/session",
                    {"capabilities": {"alwaysMatch": {"shouldWaitForQuiescence": False, "shouldTerminateApp": False}}},
                )
                self.session = (created or {}).get("sessionId")
                if not self.session:
                    raise Refusal("webdriveragent_error", "WebDriverAgent did not open a session", 502)
            return "/session/%s%s" % (self.session, suffix)

    def screenshot(self):
        return self.call("GET", "/screenshot")

    def source(self):
        return self.call("GET", self.session_path("/source?format=xml&excluded_attributes=visible,accessible"))

    def window_size(self):
        return self.call("GET", self.session_path("/window/size"))

    def active_app(self):
        info = self.call("GET", "/wda/activeAppInfo") or {}
        return info.get("bundleId") or "an unknown app"

    def active_element_type(self):
        try:
            element = self.call("GET", self.session_path("/element/active")) or {}
        except Refusal:
            return None
        element_id = element.get("ELEMENT") or element.get("element-6066-11e4-a52e-4f735466cecf")
        if not element_id:
            return None
        return self.call("GET", self.session_path("/element/%s/attribute/type" % element_id))

    def tap(self, x, y):
        self.call("POST", self.session_path("/wda/tap"), {"x": x, "y": y})

    def keys(self, text):
        self.call("POST", self.session_path("/wda/keys"), {"value": [text], "frequency": 30})

    def swipe(self, from_x, from_y, to_x, to_y):
        self.call(
            "POST",
            self.session_path("/wda/dragfromtoforduration"),
            {"fromX": from_x, "fromY": from_y, "toX": to_x, "toY": to_y, "duration": 0.1},
        )

    def home(self):
        self.call("POST", "/wda/homescreen", {})

    def launch(self, bundle):
        self.call("POST", self.session_path("/wda/apps/activate"), {"bundleId": bundle})


def elements_from_source(xml_text):
    """the accessibility tree (XML, the extensible markup language WebDriverAgent returns) as a
    flat list of the elements an agent can act on: type, label, value, and frame in points."""
    try:
        root = ElementTree.fromstring(xml_text)
    except ElementTree.ParseError:
        return []
    found = []
    for node in root.iter():
        label = node.get("label") or node.get("name") or ""
        value = node.get("value") or ""
        if not (label or value):
            continue
        try:
            frame = [float(node.get(key, "0")) for key in ("x", "y", "width", "height")]
        except ValueError:
            continue
        if frame[2] <= 0 or frame[3] <= 0:
            continue
        found.append({"type": node.tag, "label": label, "value": value, "frame": frame})
    return found


def element_at(elements, x, y):
    """the smallest labeled element under a point, or None. the app itself does not count."""
    under = [e for e in elements if e["type"] != "XCUIElementTypeApplication" and e["frame"][0] <= x <= e["frame"][0] + e["frame"][2]
             and e["frame"][1] <= y <= e["frame"][1] + e["frame"][3] and e["label"]]
    if not under:
        return None
    return min(under, key=lambda e: e["frame"][2] * e["frame"][3])


def element_named(elements, label):
    exact = [e for e in elements if e["label"] == label]
    if not exact:
        exact = [e for e in elements if e["label"].lower() == label.lower()]
    return exact[0] if exact else None


def centre(element):
    x, y, width, height = element["frame"]
    return round(x + width / 2, 1), round(y + height / 2, 1)


# consent -----------------------------------------------------------------------------------


def current_session():
    """the open phone session, or None when there is none or it has expired."""
    session = read_json(state_file("session.json"))
    if not session:
        return None
    if parse_stamp(session["expires"]) <= now():
        return None
    return session


def require_session():
    session = current_session()
    if session is None:
        raise Refusal(
            "no_consent",
            "phone control is off: the owner has not opened a phone session (sirven phone allow)",
            403,
        )
    return session


# the plain-language log --------------------------------------------------------------------


def log_action(event, said, outcome, session=None, **fields):
    entry = {"time": stamp(now()), "event": event, "session": (session or {}).get("session"),
             "said": said, "outcome": outcome}
    entry.update({key: value for key, value in fields.items() if value is not None})
    line = json.dumps(entry, sort_keys=True)
    path = state_file("actions.jsonl")
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(descriptor, "a") as handle:
        handle.write(line + "\n")
    return entry


def plain_line(entry):
    clock = entry["time"][11:16]
    text = "%s  %s" % (clock, entry["said"])
    if entry.get("reason"):
        text += ", because: %s" % entry["reason"]
    if entry.get("outcome") not in ("done", None):
        text += " [%s]" % entry["outcome"]
    return text


# holds for money-bearing actions -----------------------------------------------------------


def hold_path(hold):
    if not re.fullmatch(r"[a-z0-9]{6,32}", hold or ""):
        raise Refusal("bad_request", "a hold is a short lowercase token like h4k2p9q7", 400)
    return os.path.join(state_dir(), "holds", hold + ".json")


def create_hold(session, action, label, app, reason):
    hold = secrets.token_hex(4)
    record = {"hold": hold, "session": session["session"], "action": action, "label": label, "app": app,
              "reason": reason, "created": stamp(now()), "state": "waiting"}
    write_private(hold_path(hold), json.dumps(record, indent=2, sort_keys=True) + "\n")
    return record


def take_approval(hold, session, label):
    """an approval is good once, for the same label, in the same session, for five minutes."""
    record = read_json(hold_path(hold))
    if not record or record.get("state") != "approved":
        raise Refusal("not_approved", "hold %s has not been approved by the owner" % hold, 403)
    if record["session"] != session["session"] or record["label"] != label:
        raise Refusal("not_approved", "hold %s was approved for a different action" % hold, 403)
    if parse_stamp(record["approved"]) + datetime.timedelta(minutes=APPROVAL_MINUTES) < now():
        raise Refusal("not_approved", "the approval for hold %s has expired; ask the owner again" % hold, 403)
    record["state"] = "used"
    record["used"] = stamp(now())
    write_private(hold_path(hold), json.dumps(record, indent=2, sort_keys=True) + "\n")


# the actions -------------------------------------------------------------------------------


class Phone:
    """every agent action passes through here: consent, safety checks, then the log."""

    def __init__(self):
        self.agent = None
        self.device = None
        self.busy = threading.Lock()

    def webdriveragent(self):
        found = detect()
        if found["result"] != "trusted":
            raise Refusal(found["result"], found["said"], 409)
        if self.agent is None or self.device != found["device"]:
            self.device = found["device"]
            self.agent = WebDriverAgent(found["device"])
        if self.agent.locked():
            raise Refusal("phone_locked", "the phone is locked; the owner unlocks it, the agent never does", 409)
        return self.agent

    def status(self):
        session = current_session()
        found = detect()
        report = {"phone": found["result"], "said": found["said"],
                  "session": None if session is None else {"expires": session["expires"],
                                                           "allow_submit": session["allow_submit"]}}
        if found["result"] == "trusted":
            try:
                agent = WebDriverAgent(found["device"])
                report["webdriveragent"] = "ready" if agent.ready() else "starting"
                report["locked"] = agent.locked()
            except Refusal as refusal:
                report["webdriveragent"] = refusal.result
        return report

    def screen(self, reason, include_image=True):
        session = require_session()
        agent = self.webdriveragent()
        app = agent.active_app()
        result = {"app": app, "size": agent.window_size(), "elements": elements_from_source(agent.source())}
        if include_image:
            # a PNG image, base64 encoded, in points scaled by the phone. kept in memory only
            result["screenshot_png_base64"] = agent.screenshot()
        log_action("screen", "read the screen in %s" % app, "done", session, app=app, reason=reason)
        return result

    def tap(self, body):
        session = require_session()
        reason = need_reason(body)
        agent = self.webdriveragent()
        app = agent.active_app()
        elements = elements_from_source(agent.source())
        if "label" in body:
            element = element_named(elements, str(body["label"]))
            if element is None:
                log_action("tap", "looked for \"%s\" in %s but it is not on screen" % (body["label"], app),
                           "not_found", session, app=app, reason=reason)
                raise Refusal("not_found", "nothing labeled \"%s\" is on the screen" % body["label"], 404)
            x, y = centre(element)
        else:
            x, y = number(body, "x"), number(body, "y")
            element = element_at(elements, x, y)
        label = element["label"] if element else None
        target = "\"%s\"" % label if label else "an unlabeled spot at %s, %s" % (x, y)
        if body.get("money") or (label and MONEY_WORDS.search(label)):
            if body.get("approval"):
                take_approval(str(body["approval"]), session, label or target)
            else:
                record = create_hold(session, "tap", label or target, app, reason)
                log_action("tap", "wanted to tap %s in %s, which could spend money or commit a booking; held for the owner"
                           % (target, app), "held", session, app=app, reason=reason, hold=record["hold"])
                raise Refusal(
                    "held_for_approval",
                    "tapping %s could spend money or commit a booking, so it waits for the owner: "
                    "sirven phone approve %s" % (target, record["hold"]),
                    409,
                    {"hold": record["hold"]},
                )
        agent.tap(x, y)
        return log_action("tap", "tapped %s in %s" % (target, app), "done", session, app=app, reason=reason,
                          hold=body.get("approval"))

    def type_text(self, body):
        session = require_session()
        reason = need_reason(body)
        text = body.get("text")
        if not isinstance(text, str) or not text:
            raise Refusal("bad_request", "type needs text", 400)
        submit = bool(body.get("submit"))
        if ("\n" in text or "\r" in text or submit) and not session["allow_submit"]:
            raise Refusal(
                "submit_not_allowed",
                "a return key can send a message or a form, and this phone session was opened without "
                "--allow-submit; the text was not typed",
                403,
            )
        agent = self.webdriveragent()
        app = agent.active_app()
        if agent.active_element_type() in SECURE_FIELD_TYPES:
            log_action("type", "was asked to type into a password field in %s and refused" % app, "refused",
                       session, app=app, reason=reason)
            raise Refusal("secure_field", "the focused field is a password field; the owner types passwords, never the agent", 403)
        agent.keys(text + ("\n" if submit else ""))
        shown = text if len(text) <= 60 else text[:57] + "..."
        said = "typed \"%s\" in %s" % (shown, app) + (" and pressed return" if submit else "")
        return log_action("type", said, "done", session, app=app, reason=reason)

    def swipe(self, body):
        session = require_session()
        reason = need_reason(body)
        points = [number(body, key) for key in ("from_x", "from_y", "to_x", "to_y")]
        agent = self.webdriveragent()
        app = agent.active_app()
        agent.swipe(*points)
        return log_action("swipe", "swiped from %s, %s to %s, %s in %s" % tuple(points + [app]), "done", session,
                          app=app, reason=reason)

    def home(self, body):
        session = require_session()
        reason = need_reason(body)
        self.webdriveragent().home()
        return log_action("home", "went to the home screen", "done", session, reason=reason)

    def launch(self, body):
        session = require_session()
        reason = need_reason(body)
        bundle = body.get("bundle")
        if not isinstance(bundle, str) or not re.fullmatch(r"[A-Za-z0-9.-]+", bundle):
            raise Refusal("bad_request", "launch needs bundle, an app bundle name like com.apple.Maps", 400)
        self.webdriveragent().launch(bundle)
        return log_action("launch", "opened %s" % bundle, "done", session, app=bundle, reason=reason)


def need_reason(body):
    reason = body.get("reason")
    if not isinstance(reason, str) or not reason.strip():
        raise Refusal("bad_request", "every action carries a reason in plain words, for the owner's log", 400)
    return reason.strip()[:200]


def number(body, key):
    value = body.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise Refusal("bad_request", "%s must be a number of points" % key, 400)
    return value


# the local interface -----------------------------------------------------------------------


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "sirven-phone/1"
    phone = None
    token = None

    def log_message(self, *arguments):
        pass

    def reply(self, status, body):
        data = (json.dumps(body, sort_keys=True) + "\n").encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        given = self.headers.get("Authorization", "")
        return secrets.compare_digest(given.encode(), ("Bearer " + self.token).encode())

    def handle_any(self, method):
        if not self.authorized():
            return self.reply(401, {"result": "unauthorized", "said": "missing or wrong bearer token"})
        path = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(path.query)
        try:
            body = {}
            if method == "POST":
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length) or b"{}") if length else {}
                if not isinstance(body, dict):
                    raise Refusal("bad_request", "the body must be a JSON object", 400)
            route = (method, path.path)
            if route == ("GET", "/v1/phone/status"):
                return self.reply(200, dict(self.phone.status(), result="ok"))
            if route == ("GET", "/v1/phone/screen"):
                reason = (query.get("reason") or ["reading the screen"])[0]
                image = (query.get("image") or ["1"])[0] != "0"
                return self.reply(200, dict(self.phone.screen(reason, image), result="ok"))
            actions = {"/v1/phone/tap": self.phone.tap, "/v1/phone/type": self.phone.type_text,
                       "/v1/phone/swipe": self.phone.swipe, "/v1/phone/home": self.phone.home,
                       "/v1/phone/launch": self.phone.launch}
            if method == "POST" and path.path in actions:
                # one action at a time: two taps racing on one phone help no one
                with self.phone.busy:
                    entry = actions[path.path](body)
                return self.reply(200, {"result": "done", "said": entry["said"]})
            return self.reply(404, {"result": "unknown_route", "said": "no such route: %s %s" % route})
        except Refusal as refusal:
            return self.reply(refusal.status, dict(refusal.extra, result=refusal.result, said=refusal.said))
        except ValueError:
            return self.reply(400, {"result": "bad_request", "said": "the body is not valid JSON"})
        except Exception as error:  # an honest failure, never a dropped connection
            return self.reply(500, {"result": "internal_error", "said": "the phone bridge failed: %s" % error})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")


def serve(port):
    token = secrets.token_urlsafe(32)
    token_path = state_file("token")
    write_private(token_path, token + "\n")
    Handler.phone = Phone()
    Handler.token = token
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print("phone interface on http://127.0.0.1:%d/v1/phone, bearer token in %s" % (server.server_address[1], token_path),
          flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        os.remove(token_path)


# owner commands ----------------------------------------------------------------------------


def confirm(question):
    if test_mode() and os.environ.get("SIRVEN_PHONE_TEST_YES") == "yes":
        return True
    try:
        with open("/dev/tty", "r+") as terminal:
            terminal.write(question + " type yes to continue: ")
            terminal.flush()
            return terminal.readline().strip() == "yes"
    except OSError:
        return False


def command_allow(minutes, allow_submit):
    if not 1 <= minutes <= LONGEST_SESSION_MINUTES:
        fail("--minutes must be between 1 and %d" % LONGEST_SESSION_MINUTES, 64)
    question = "let your agent see and tap your plugged-in iPhone for %d minutes%s?" % (
        minutes, ", including pressing return to send" if allow_submit else "")
    if not confirm(question):
        fail("phone control stays off. opening a phone session needs the owner at a terminal, typing yes", 1)
    opened = now()
    session = {"session": secrets.token_hex(4), "opened": stamp(opened),
               "expires": stamp(opened + datetime.timedelta(minutes=minutes)), "allow_submit": allow_submit}
    write_private(state_file("session.json"), json.dumps(session, indent=2, sort_keys=True) + "\n")
    log_action("allow", "the owner opened a phone session for %d minutes%s" % (
        minutes, ", with return allowed" if allow_submit else ""), "done", session)
    print("phone session open until %s. end it any time: sirven phone stop" % session["expires"])
    print("the phone stays yours: it stays visible and usable, and every action is in sirven phone log")


def command_stop():
    session = current_session()
    path = state_file("session.json")
    if os.path.exists(path):
        os.remove(path)
    if session:
        log_action("stop", "the owner ended the phone session", "done", session)
        print("phone session ended. the agent can no longer see or touch the phone")
    else:
        print("no phone session was open")


def command_holds():
    directory = os.path.join(state_dir(), "holds")
    waiting = [read_json(os.path.join(directory, name)) for name in sorted(os.listdir(directory))]
    waiting = [record for record in waiting if record and record.get("state") == "waiting"]
    if not waiting:
        print("nothing is waiting for approval")
    for record in waiting:
        print("%s  tap \"%s\" in %s, because: %s" % (record["hold"], record["label"], record["app"], record["reason"]))


def command_decide(hold, approve):
    path = hold_path(hold)
    record = read_json(path)
    if not record or record.get("state") != "waiting":
        fail("hold %s is not waiting for a decision" % hold, 1)
    if approve and not confirm("approve the agent tapping \"%s\" in %s, once?" % (record["label"], record["app"])):
        fail("not approved", 1)
    record["state"] = "approved" if approve else "denied"
    record["approved" if approve else "denied"] = stamp(now())
    write_private(path, json.dumps(record, indent=2, sort_keys=True) + "\n")
    session = {"session": record["session"]}
    if approve:
        log_action("approve", "the owner approved tapping \"%s\" in %s, once" % (record["label"], record["app"]),
                   "done", session, hold=hold)
        print("approved once, for %d minutes. the agent retries with approval %s" % (APPROVAL_MINUTES, hold))
    else:
        log_action("deny", "the owner refused tapping \"%s\" in %s" % (record["label"], record["app"]), "done",
                   session, hold=hold)
        print("refused. the agent is told no")


def command_log(as_json):
    path = state_file("actions.jsonl")
    if not os.path.exists(path):
        print("no phone actions yet")
        return
    with open(path) as handle:
        for line in handle:
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            print(json.dumps(entry, sort_keys=True) if as_json else plain_line(entry))


def command_setup(team, bundle):
    if not team or not re.fullmatch(r"[A-Z0-9]{10}", team):
        fail("--team needs your ten character Apple development team, from Xcode > Settings > Accounts", 64)
    if not bundle or not re.fullmatch(r"[A-Za-z0-9.-]+", bundle):
        fail("--bundle needs a bundle name you own, like com.yourname.WebDriverAgentRunner", 64)
    folder = os.path.join(os.path.expanduser("~"), ".sirven", "WebDriverAgent")
    steps = [
        ("on the phone", "plug it in, unlock it, and tap Trust when it asks about this Mac"),
        ("on the phone", "Settings > Privacy & Security > Developer Mode: on, then restart the phone"),
        ("on this Mac", "full Xcode, signed into your Apple account under Xcode > Settings > Accounts"),
        ("on this Mac", "git clone %s %s && git -C %s checkout %s" % (WEBDRIVERAGENT_REPOSITORY, folder, folder,
                                                                        WEBDRIVERAGENT_COMMIT)),
        ("on this Mac", "xcodebuild -project %s/WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner "
                        "-destination 'platform=iOS,name=<your phone>' -allowProvisioningUpdates "
                        "DEVELOPMENT_TEAM=%s CODE_SIGN_STYLE=Automatic PRODUCT_BUNDLE_IDENTIFIER=%s test"
                        % (folder, team, bundle)),
        ("on the phone", "the first time: Settings > General, the Device Management page, trust your developer certificate"),
        ("on the phone", "Settings > Developer: turn on the user interface automation switch"),
        ("on this Mac", "keep the xcodebuild command running, then: sirven phone status"),
    ]
    print("WebDriverAgent setup plan. sirven only prints this; you run each step yourself.")
    print("it signs WebDriverAgent with your own Apple account, on your own phone. nothing is sent anywhere else.")
    for number_, (where, what) in enumerate(steps, 1):
        print("  %d. %s: %s" % (number_, where, what))


def fail(message, status):
    print("error: %s" % message, file=sys.stderr)
    sys.exit(status)


def main(arguments):
    if not arguments or arguments[0] in ("-h", "--help", "help"):
        text = __doc__
        print(text[text.index("subcommands"):text.index("\nstate lives")].rstrip())
        return 0 if arguments else 64
    command, rest = arguments[0], arguments[1:]
    options = {}
    flags = set()
    positional = []
    index = 0
    while index < len(rest):
        word = rest[index]
        if word in ("--allow-submit", "--json"):
            flags.add(word)
        elif word in ("--minutes", "--port", "--team", "--bundle"):
            if index + 1 >= len(rest):
                fail("%s needs a value" % word, 64)
            options[word] = rest[index + 1]
            index += 1
        elif word.startswith("--"):
            fail("unknown option '%s'" % word, 64)
        else:
            positional.append(word)
        index += 1
    try:
        if command == "detect":
            found = detect()
            print(json.dumps(found, sort_keys=True) if "--json" in flags else found["said"])
            return 0 if found["result"] == "trusted" else 1
        if command == "status":
            print(json.dumps(Phone().status(), indent=2, sort_keys=True))
            return 0
        if command == "allow":
            command_allow(int(options.get("--minutes", DEFAULT_MINUTES)), "--allow-submit" in flags)
            return 0
        if command == "stop":
            command_stop()
            return 0
        if command == "serve":
            serve(int(options.get("--port", DEFAULT_PORT)))
            return 0
        if command == "log":
            command_log("--json" in flags)
            return 0
        if command == "holds":
            command_holds()
            return 0
        if command in ("approve", "deny"):
            if len(positional) != 1:
                fail("%s needs one hold, from sirven phone holds" % command, 64)
            command_decide(positional[0], command == "approve")
            return 0
        if command == "setup":
            command_setup(options.get("--team"), options.get("--bundle"))
            return 0
    except Refusal as refusal:
        fail(refusal.said, 1)
    except ValueError:
        fail("--minutes and --port take whole numbers", 64)
    fail("unknown phone command '%s'; run sirven phone --help" % command, 64)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
