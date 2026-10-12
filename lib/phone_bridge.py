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
  start                  run the phone runner: the tunnel and the launcher that keep WebDriverAgent
                         running on the phone, restarted when they stop. Ctrl-C stops both.
                         needs SIRVEN_PHONE_RUNNER_BUNDLE set to the runner's bundle identifier
  serve [--port N]       run the local interface on 127.0.0.1 for the agent
  log [--json]           every agent action on the phone, in plain language
  holds                  actions waiting for the owner's approval
  approve HOLD           the owner approves one held action, once, for five minutes
  deny HOLD              the owner refuses one held action
  onboard [--app NAME]... [--refresh]
                         the owner maps the home screens and the chosen apps (by default Uber
                         and Lyft) so the agent knows where to look. asks for a typed yes
  map [--json]           the semantic map of the phone, in plain lines or as JSON
  map prune APP [SCREEN] forget one app (a bundle or an app name), or one screen of it

state lives in SIRVEN_PHONE_DIR (default ~/.sirven/phone), owned by the owner, mode 0700:
  session.json   the open phone session, if any
  token          the bearer token for the local interface, mode 0600, new on every serve
  actions.jsonl  the plain-language log, one JSON object per line, appended
  holds/         one file per held action
  map.json       the semantic map from onboarding: apps, screens, and controls, never a
                 screenshot, a value, or anything from a sign in screen
  runner.json    while sirven phone start runs: the process identifiers of its tunnel and
                 launcher, and when it started

the interface itself is described in docs/phone-interface.md.
"""

import base64
import collections
import datetime
import fcntl
import http.client
import http.server
import json
import os
import plistlib
import re
import secrets
import signal
import socket
import struct
import subprocess
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
WEBDRIVERAGENT_RELEASE = "v16.14.0"
WEBDRIVERAGENT_RUNNER_SHA256 = "6f7758f72d348d2c35c3fd134fa76a941bba0c447de04b2e9d065682f31fc47f"

# a tap on something labeled like this could commit money or a booking. it waits for the
# owner's approval. a heuristic, so the agent can also mark any action money-bearing itself.
MONEY_WORDS = re.compile(
    r"\b(book|booking|request|confirm|pay|payment|purchase|buy|order|place order|checkout|"
    r"check out|subscribe|reserve|rent|tip|donate|send money|transfer)\b",
    re.IGNORECASE,
)

SECURE_FIELD_TYPES = ("XCUIElementTypeSecureTextField",)

# the phone's own approval for a payment: the face recognition or Apple Pay sheet. while it is on screen
# the owner is deciding, on the phone, so the agent touches nothing. sirven never stands in for
# this prompt, never presses its button, and never keeps or replays a scan.
OWNER_APPROVAL_SHEET = re.compile(
    r"\b(double[- ]click to pay|confirm with side button|pay with face id|pay with passcode|"
    r"pay with touch id|confirm with face id|face id)\b",
    re.IGNORECASE,
)


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

    def launch(self, bundle, fresh=False):
        if fresh:
            # an app already running resumes where it was; closing it first starts it clean
            self.call("POST", self.session_path("/wda/apps/terminate"), {"bundleId": bundle})
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


def approval_sheet_showing(elements):
    """true while the phone's own face recognition or Apple Pay prompt is on screen."""
    return any(OWNER_APPROVAL_SHEET.search(e["label"]) for e in elements if e["label"])


def refuse_during_approval_sheet(elements, session, app, event, reason):
    if approval_sheet_showing(elements):
        log_action(event, "waited: the phone is showing its own payment approval in %s, which only the owner answers"
                   % app, "refused", session, app=app, reason=reason)
        raise Refusal("owner_approving_on_phone",
                      "the phone is showing its own face recognition or Apple Pay approval; only the owner answers it, "
                      "on the phone. read the screen again once it is gone", 409)


def elements_at(elements, x, y):
    """every labeled element under a point, smallest first. the app itself does not count."""
    under = [e for e in elements if e["type"] != "XCUIElementTypeApplication" and e["label"]
             and e["frame"][0] <= x <= e["frame"][0] + e["frame"][2]
             and e["frame"][1] <= y <= e["frame"][1] + e["frame"][3]]
    return sorted(under, key=lambda e: e["frame"][2] * e["frame"][3])


def element_named(elements, label):
    exact = [e for e in elements if e["label"] == label]
    if not exact:
        exact = [e for e in elements if e["label"].lower() == label.lower()]
    return exact[0] if exact else None


def centre(element):
    x, y, width, height = element["frame"]
    return round(x + width / 2, 1), round(y + height / 2, 1)


# the phone runner --------------------------------------------------------------------------
# two long-running processes keep WebDriverAgent running on the phone, with no full Xcode at
# run time. the tunnel (pymobiledevice3 remote start-tunnel --native) prints the remote service
# discovery address, and the launcher (pymobiledevice3 developer dvt xcuitest) starts the
# runner through it. a tunnel that restarts prints a new address, so the launcher restarts too.

PYMOBILEDEVICE3_VERSION = "11.28.2"
MISSING_TOOL = ("pymobiledevice3 was not found on PATH. install it once with the Python tool installer, uv "
                "(needs Python 3.12 or newer): uv tool install pymobiledevice3==" + PYMOBILEDEVICE3_VERSION)
RUNNER_BUNDLE_VARIABLE = "SIRVEN_PHONE_RUNNER_BUNDLE"
RUNNER_FILE = "runner.json"
RUNNER_LOCK = "runner.lock"
STOP_SIGNALS = (signal.SIGTERM, signal.SIGHUP)
TUNNEL_COMMAND = ["pymobiledevice3", "remote", "start-tunnel", "--native"]
TUNNEL_ADDRESS = re.compile(r"RSD Address: (\S+)$")
TUNNEL_PORT = re.compile(r"RSD Port: (\d+)$")
TUNNEL_WAIT_SECONDS = 60
BACKOFF_START_SECONDS = 1
BACKOFF_CAP_SECONDS = 30
STABLE_SECONDS = 60
POLL_SECONDS = 0.5
STOP_SECONDS = 5
RECENT_LINES = 200
OUTPUT_JOIN_SECONDS = 2
LAUNCHER_FAILURES_BEFORE_TUNNEL_RESTART = 3
LAST_OUTPUT_LINES = 5


def tunnel_endpoint(lines):
    """the address and port the tunnel printed, or None until it has printed both."""
    address = port = None
    for line in lines:
        found = TUNNEL_ADDRESS.match(line.strip())
        if found:
            address = found.group(1)
        found = TUNNEL_PORT.match(line.strip())
        if found:
            port = found.group(1)
    return (address, port) if address and port else None


def launcher_argv(bundle, address, port):
    return ["pymobiledevice3", "developer", "dvt", "xcuitest", bundle, "--rsd", address, port]


def process_alive(process_id):
    if not isinstance(process_id, int) or process_id <= 0:
        return False
    try:
        os.kill(process_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def take_runner_lock():
    """the lock a running supervisor holds for its whole run, or None while another one holds it.
    the system releases it when the process ends, even after a hard kill."""
    handle = open(state_file(RUNNER_LOCK), "a")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        handle.close()
        return None
    return handle


def runner_status():
    """the tunnel and the launcher, each running or not, read from the runner file. with no
    supervisor holding the lock, both say not running, whatever the file says."""
    lock = take_runner_lock()
    if lock is not None:
        lock.close()
        return {"tunnel": "not running", "launcher": "not running"}
    record = read_json(state_file(RUNNER_FILE))
    if not isinstance(record, dict):
        record = {}
    return {name: "running" if process_alive(record.get(name)) else "not running" for name in ("tunnel", "launcher")}


def interrupt(signum, frame):
    raise KeyboardInterrupt()


def show_last_output(children):
    for child in children:
        if child is not None:
            for line in child.lines()[-LAST_OUTPUT_LINES:]:
                print("  | %s" % line, flush=True)


class Child:
    """one long-running process. a thread reads its output, so its pipe never fills."""

    def __init__(self, command, clock):
        try:
            self.process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                            text=True, errors="replace")
        except FileNotFoundError:
            raise Refusal("missing_tool", MISSING_TOOL, 1)
        self.clock = clock
        self.started = clock()
        self.recent = collections.deque(maxlen=RECENT_LINES)
        self.lock = threading.Lock()
        self.reader = threading.Thread(target=self._drain, daemon=True)
        self.reader.start()

    def _drain(self):
        for line in self.process.stdout:
            with self.lock:
                self.recent.append(line.rstrip("\n"))

    def lines(self):
        with self.lock:
            return list(self.recent)

    def alive(self):
        return self.process.poll() is None

    def exited(self):
        """true once the process has ended, after its last output has been read."""
        if self.process.poll() is None:
            return False
        self.reader.join(OUTPUT_JOIN_SECONDS)
        return True

    def uptime(self):
        return self.clock() - self.started

    def stop(self, seconds):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=seconds)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.reader.join(OUTPUT_JOIN_SECONDS)
        self.process.stdout.close()


class Backoff:
    """the wait before a restart: it starts at the first value, doubles, and is capped. a process
    that stayed up for the stable time starts again from the first value."""

    def __init__(self, start, cap, stable):
        self.start = start
        self.cap = cap
        self.stable = stable
        self.delay = start

    def next_wait(self, uptime):
        if uptime >= self.stable:
            self.delay = self.start
        wait = self.delay
        self.delay = min(self.delay * 2, self.cap)
        return wait


class RunnerSupervisor:
    """starts the tunnel and the launcher, watches both, and restarts whichever stopped. the
    commands and the timing are arguments, so tests run small fake processes instead."""

    def __init__(self, bundle, tunnel_command=TUNNEL_COMMAND, build_launcher=launcher_argv,
                 backoff_start=BACKOFF_START_SECONDS, backoff_cap=BACKOFF_CAP_SECONDS,
                 stable_seconds=STABLE_SECONDS, poll_seconds=POLL_SECONDS,
                 tunnel_wait_seconds=TUNNEL_WAIT_SECONDS, stop_seconds=STOP_SECONDS,
                 clock=time.monotonic, sleep=time.sleep):
        self.bundle = bundle
        self.tunnel_command = tunnel_command
        self.build_launcher = build_launcher
        self.tunnel_backoff = Backoff(backoff_start, backoff_cap, stable_seconds)
        self.launcher_backoff = Backoff(backoff_start, backoff_cap, stable_seconds)
        self.poll_seconds = poll_seconds
        self.tunnel_wait_seconds = tunnel_wait_seconds
        self.stop_seconds = stop_seconds
        self.stable_seconds = stable_seconds
        self.clock = clock
        self.sleep = sleep
        self.tunnel = None
        self.launcher = None
        self.endpoint = None
        self.started = None
        self.quick_failures = 0

    def run(self):
        lock = take_runner_lock()
        if lock is None:
            raise Refusal("already_running", "a phone runner is already running; stop it with Ctrl-C in the "
                          "terminal that started it", 1)
        try:
            self._refuse_leftovers()
            previous = {number: signal.signal(number, interrupt) for number in STOP_SIGNALS}
            try:
                self.start()
                self.supervise()
            except KeyboardInterrupt:
                pass
            finally:
                try:
                    self.stop()
                finally:
                    for number, handler in previous.items():
                        signal.signal(number, handler)
        finally:
            lock.close()
        print("the phone runner stopped", flush=True)

    def _refuse_leftovers(self):
        record = read_json(state_file(RUNNER_FILE))
        if not isinstance(record, dict):
            return
        left = [str(record[name]) for name in ("tunnel", "launcher") if process_alive(record.get(name))]
        if left:
            raise Refusal("leftover_processes", "processes from an earlier phone runner are still running (process "
                          "ID %s). stop them, for example with kill, then start again" % " and ".join(left), 1)

    def start(self):
        self.started = stamp(now())
        self._start_tunnel()
        self.launcher = self._start_launcher()
        self._record()
        print("the phone runner is up: the tunnel and the launcher are running. Ctrl-C stops both", flush=True)

    def supervise(self):
        while True:
            self.sleep(self.poll_seconds)
            if self.tunnel is None or not self.tunnel.alive():
                self._restart_tunnel("the tunnel to the phone stopped; the launcher stops with it, and both start again")
            elif self.launcher is None or not self.launcher.alive():
                self._launcher_stopped()

    def _launcher_stopped(self):
        if self.launcher is not None and self.launcher.uptime() >= self.stable_seconds:
            self.quick_failures = 0
        self.quick_failures += 1
        if self.quick_failures >= LAUNCHER_FAILURES_BEFORE_TUNNEL_RESTART:
            self.quick_failures = 0
            self._restart_tunnel("the launcher failed %d times in a row without staying up; the tunnel may be "
                                 "holding a stale address, so the tunnel and the launcher start again"
                                 % LAUNCHER_FAILURES_BEFORE_TUNNEL_RESTART)
        else:
            self._restart_launcher()

    def stop(self):
        try:
            if self.launcher is not None:
                self.launcher.stop(self.stop_seconds)
        finally:
            self.launcher = None
            try:
                if self.tunnel is not None:
                    self.tunnel.stop(self.stop_seconds)
            finally:
                self.tunnel = None
        if os.path.exists(state_file(RUNNER_FILE)):
            os.remove(state_file(RUNNER_FILE))

    def _start_tunnel(self):
        self.tunnel = Child(self.tunnel_command, self.clock)
        deadline = self.clock() + self.tunnel_wait_seconds
        while True:
            exited = self.tunnel.exited()
            endpoint = tunnel_endpoint(self.tunnel.lines())
            if endpoint:
                self.endpoint = endpoint
                return
            if exited or self.clock() >= deadline:
                self.tunnel.stop(self.stop_seconds)
                self.tunnel = None
                raise Refusal(
                    "tunnel_no_address",
                    "the tunnel %s its remote service discovery address; check that the phone is plugged in and "
                    "unlocked, and that Developer Mode is on" % ("stopped before it printed"
                                                              if exited else "did not print"),
                    503,
                )
            self.sleep(self.poll_seconds)

    def _start_launcher(self):
        return Child(self.build_launcher(self.bundle, *self.endpoint), self.clock)

    def _restart_tunnel(self, why):
        uptime = self.tunnel.uptime() if self.tunnel is not None else 0
        stopped = (self.launcher, self.tunnel)
        for child in stopped:
            if child is not None:
                child.stop(self.stop_seconds)
        print(why, flush=True)
        show_last_output(stopped)
        self.tunnel = self.launcher = None
        self.sleep(self.tunnel_backoff.next_wait(uptime))
        try:
            self._start_tunnel()
            self.launcher = self._start_launcher()
        except Refusal as refusal:
            print("the tunnel did not come back: %s. trying again" % refusal.said, flush=True)
            return
        self._record()
        print("the tunnel and the launcher are running again", flush=True)

    def _restart_launcher(self):
        uptime = self.launcher.uptime() if self.launcher is not None else 0
        stopped = self.launcher
        if stopped is not None:
            stopped.stop(self.stop_seconds)
        print("the launcher stopped; starting it again. its last output:", flush=True)
        show_last_output([stopped])
        self.launcher = None
        self.sleep(self.launcher_backoff.next_wait(uptime))
        try:
            self.launcher = self._start_launcher()
        except Refusal as refusal:
            print("the launcher did not start: %s. trying again" % refusal.said, flush=True)
            return
        self._record()
        print("the launcher is running again", flush=True)

    def _record(self):
        record = {"supervisor": os.getpid(), "tunnel": self.tunnel.process.pid,
                  "launcher": self.launcher.process.pid, "started": self.started}
        write_private(state_file(RUNNER_FILE), json.dumps(record, indent=2, sort_keys=True) + "\n")


def command_start():
    bundle = os.environ.get(RUNNER_BUNDLE_VARIABLE, "")
    if not re.fullmatch(r"[A-Za-z0-9.-]+", bundle):
        fail("set %s to the runner's bundle identifier: the bundle name you gave sirven phone setup with --bundle, "
             "with .xctrunner added, for example com.yourname.WebDriverAgentRunner.xctrunner" % RUNNER_BUNDLE_VARIABLE,
             64)
    RunnerSupervisor(bundle).run()


# consent -----------------------------------------------------------------------------------


def current_session():
    """the open phone session, or None when there is none or it has expired."""
    session = read_json(state_file("session.json"))
    if not session:
        return None
    if parse_stamp(session["expires"]) <= now():
        return None
    if session.get("test_only") and not test_mode():
        # opened through the test seam, against a fake phone: never honoured for a real one
        return None
    return session


def require_session(onboarding=False):
    session = current_session()
    if session is None:
        raise Refusal(
            "no_consent",
            "phone control is off: the owner has not opened a phone session (sirven phone allow)",
            403,
        )
    if session.get("purpose") == "onboarding" and not onboarding:
        # a session the owner opened only to map the phone is for the crawl, not for the agent
        raise Refusal("no_consent", "the phone is being mapped for onboarding; the agent waits until that ends", 403)
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


def hold_state(hold):
    """what the agent may know about its own hold: waiting, approved, denied, or used. read only."""
    record = read_json(hold_path(hold))
    if not record:
        raise Refusal("not_found", "there is no hold %s" % hold, 404)
    state = record["state"]
    if record.get("test_only") and not test_mode():
        state = "waiting"
    return {"hold": hold, "state": state, "label": record["label"], "app": record["app"]}


def take_approval(hold, session, label):
    """an approval is good once, for the same label, in the same session, for five minutes."""
    record = read_json(hold_path(hold))
    if not record or record.get("state") != "approved" or (record.get("test_only") and not test_mode()):
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

    def __init__(self, onboarding=False):
        self.agent = None
        self.device = None
        self.busy = threading.Lock()
        self.onboarding = onboarding

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
        report.update(runner_status())
        report["onboarding_due"] = found["result"] == "trusted" and onboarding_due()
        if found["result"] == "trusted":
            try:
                agent = WebDriverAgent(found["device"])
                report["webdriveragent"] = "ready" if agent.ready() else "starting"
                report["locked"] = agent.locked()
            except Refusal as refusal:
                report["webdriveragent"] = refusal.result
        return report

    def screen(self, reason, include_image=True):
        session = require_session(self.onboarding)
        agent = self.webdriveragent()
        app = agent.active_app()
        elements = elements_from_source(agent.source())
        result = {"app": app, "size": agent.window_size(), "elements": elements,
                  "owner_approving_on_phone": approval_sheet_showing(elements)}
        if include_image:
            # the screenshot image, base64 encoded. kept in memory only, never written to disk
            result["screenshot_png_base64"] = agent.screenshot()
        log_action("screen", "read the screen in %s" % app, "done", session, app=app, reason=reason)
        return result

    def tap(self, body):
        session = require_session(self.onboarding)
        reason = need_reason(body)
        agent = self.webdriveragent()
        app = agent.active_app()
        elements = elements_from_source(agent.source())
        if not elements:
            # without the tree there is no telling what a tap would press, so it is not made
            raise Refusal("screen_unreadable", "the screen's elements could not be read, so the tap was not made", 409)
        refuse_during_approval_sheet(elements, session, app, "tap", reason)
        if "label" in body:
            element = element_named(elements, str(body["label"]))
            if element is None:
                looked = re.sub(r"\d+", "#", str(body["label"])) if self.onboarding else body["label"]
                log_action("tap", "looked for \"%s\" in %s but it is not on screen" % (looked, app),
                           "not_found", session, app=app, reason=reason)
                raise Refusal("not_found", "nothing labeled \"%s\" is on the screen" % body["label"], 404)
            x, y = centre(element)
        else:
            x, y = number(body, "x"), number(body, "y")
        under = elements_at(elements, x, y)
        # a price label inside a "Request ride" button still presses the button, so every
        # element under the point counts, not just the smallest
        money = [e["label"] for e in under if MONEY_WORDS.search(e["label"])]
        label = money[0] if money else (under[0]["label"] if under else None)
        shown = re.sub(r"\d+", "#", label) if (label and self.onboarding) else label
        target = "\"%s\"" % shown if label else "an unlabeled spot at %s, %s" % (x, y)
        if body.get("money") or money:
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
        attempt(agent.tap, (x, y), "tap", "tried to tap %s in %s" % (target, app), session, app, reason)
        return log_action("tap", "tapped %s in %s" % (target, app), "done", session, app=app, reason=reason,
                          hold=body.get("approval"))

    def type_text(self, body):
        session = require_session(self.onboarding)
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
        refuse_during_approval_sheet(elements_from_source(agent.source()), session, app, "type", reason)
        if agent.active_element_type() in SECURE_FIELD_TYPES:
            log_action("type", "was asked to type into a password field in %s and refused" % app, "refused",
                       session, app=app, reason=reason)
            raise Refusal("secure_field", "the focused field is a password field; the owner types passwords, never the agent", 403)
        shown = text if len(text) <= 60 else text[:57] + "..."
        attempt(agent.keys, (text + ("\n" if submit else ""),), "type", "tried to type \"%s\" in %s" % (shown, app),
                session, app, reason)
        said = "typed \"%s\" in %s" % (shown, app) + (" and pressed return" if submit else "")
        return log_action("type", said, "done", session, app=app, reason=reason)

    def swipe(self, body):
        session = require_session(self.onboarding)
        reason = need_reason(body)
        points = [number(body, key) for key in ("from_x", "from_y", "to_x", "to_y")]
        agent = self.webdriveragent()
        app = agent.active_app()
        refuse_during_approval_sheet(elements_from_source(agent.source()), session, app, "swipe", reason)
        attempt(agent.swipe, points, "swipe", "tried to swipe in %s" % app, session, app, reason)
        return log_action("swipe", "swiped from %s, %s to %s, %s in %s" % tuple(points + [app]), "done", session,
                          app=app, reason=reason)

    def home(self, body):
        session = require_session(self.onboarding)
        reason = need_reason(body)
        attempt(self.webdriveragent().home, (), "home", "tried to go to the home screen", session, None, reason)
        return log_action("home", "went to the home screen", "done", session, reason=reason)

    def launch(self, body):
        session = require_session(self.onboarding)
        reason = need_reason(body)
        bundle = body.get("bundle")
        if not isinstance(bundle, str) or not re.fullmatch(r"[A-Za-z0-9.-]+", bundle):
            raise Refusal("bad_request", "launch needs bundle, an app bundle name like com.apple.Maps", 400)
        fresh = bool(body.get("fresh"))
        attempt(self.webdriveragent().launch, (bundle, fresh), "launch", "tried to open %s" % bundle, session, bundle,
                reason)
        return log_action("launch", "opened %s%s" % (bundle, " from the start" if fresh else ""), "done", session,
                          app=bundle, reason=reason)


# the semantic map -------------------------------------------------------------------------
# lib/phone_map.py keeps the map and lib/phone_crawler.py walks the phone to build it. neither
# imports this file, and this file imports them only inside the commands that need them.


def companion(name):
    """lib/phone_map or lib/phone_crawler, imported on first use, with no bytecode left behind."""
    here = os.path.dirname(os.path.abspath(__file__))
    if here not in sys.path:
        sys.path.insert(0, here)
    sys.dont_write_bytecode = True
    return __import__(name)


def today():
    # the owner's own day, so the once-a-day offer follows their clock, not universal time
    return now().astimezone().strftime("%Y-%m-%d")


def onboarding_due():
    """true when the map has not been made today. false when the map store is not installed."""
    try:
        phone_map = companion("phone_map")
    except ImportError:
        return False
    return bool(phone_map.onboarding_due(phone_map.load(state_dir()), today()))


class OnboardingDriver:
    """the crawler's view of the phone: the same consent, checks, and log as the agent gets,
    with no typing at all, no screenshot, and a second refusal of anything that could spend
    money, before the tap even reaches the phone."""

    def __init__(self, phone):
        self.phone = phone

    def screen(self, reason):
        return self.phone.screen(reason, include_image=False)

    def tap(self, body):
        label = body.get("label")
        if isinstance(label, str) and MONEY_WORDS.search(label):
            # not held: onboarding never asks the owner to approve a purchase, it skips it
            raise Refusal("held_for_approval", "onboarding never taps \"%s\", which could spend money" % label, 409)
        return self.phone.tap(body)

    def launch(self, body):
        return self.phone.launch(body)

    def home(self, body):
        return self.phone.home(body)

    def swipe(self, body):
        return self.phone.swipe(body)


def attempt(action, arguments, event, said, session, app, reason):
    """run one phone action. if it fails after it may have reached the phone, the log still
    says so, so a half-done action is never missing from the owner's record."""
    try:
        action(*arguments)
    except Refusal as refusal:
        log_action(event, "%s, and it failed: %s" % (said, refusal.said), "failed", session, app=app, reason=reason)
        raise


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
            if method == "GET" and path.path.startswith("/v1/phone/holds/"):
                return self.reply(200, dict(hold_state(path.path.rsplit("/", 1)[1]), result="ok"))
            if route == ("GET", "/v1/phone/map"):
                return self.reply(200, read_map((query.get("app") or [None])[0]))
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


def read_map(app=None):
    """the agent's read of the semantic map. it describes the owner's phone, so it needs an
    open session like every other read."""
    session = require_session()
    phone_map = companion("phone_map")
    the_map = phone_map.load(state_dir())
    if app is None:
        log_action("map", "read the semantic map of the phone", "done", session)
        return dict(the_map, result="ok")
    entry = the_map.get("apps", {}).get(app)
    if entry is None:
        raise Refusal("not_found", "the map has nothing for %s; the owner can map it: sirven phone onboard" % app, 404)
    log_action("map", "read the semantic map of %s" % app, "done", session, app=app)
    return dict(entry, app=app, result="ok")


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
    if test_mode():
        session["test_only"] = True
    write_private(state_file("session.json"), json.dumps(session, indent=2, sort_keys=True) + "\n")
    log_action("allow", "the owner opened a phone session for %d minutes%s" % (
        minutes, ", with return allowed" if allow_submit else ""), "done", session)
    print("phone session open until %s. end it any time: sirven phone stop" % session["expires"])
    print("the phone stays yours: it stays visible and usable, and every action is in sirven phone log")
    try:
        trusted = detect()["result"] == "trusted"
    except Refusal:
        trusted = False
    if trusted and onboarding_due():
        # an offer only: onboarding runs when the owner asks for it
        print("first connection today: map your ride apps so your agent knows where to look? sirven phone onboard")


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
    if test_mode():
        record["test_only"] = True
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


ONBOARD_MINUTES = 10


def command_onboard(names, refresh):
    phone_crawler = companion("phone_crawler")
    phone_map = companion("phone_map")
    names = list(names) or list(phone_crawler.DEFAULT_APPS)
    question = "map your iPhone's home screens and the %s app%s, so your agent knows where to look? " \
               "sirven only looks and taps through menus: it never types, buys, sends, or keeps a screenshot." % (
                   " and ".join(names), "s" if len(names) > 1 else "")
    found = detect()
    if found["result"] != "trusted":
        fail(found["said"], 1)
    if not confirm(question):
        fail("nothing was mapped. onboarding needs the owner at a terminal, typing yes", 1)
    session = current_session()
    opened_here = session is None
    if opened_here:
        # a short session for the crawl alone, closed again when it ends
        opened = now()
        session = {"session": secrets.token_hex(4), "opened": stamp(opened), "purpose": "onboarding",
                   "expires": stamp(opened + datetime.timedelta(minutes=ONBOARD_MINUTES)), "allow_submit": False}
        if test_mode():
            session["test_only"] = True
        write_private(state_file("session.json"), json.dumps(session, indent=2, sort_keys=True) + "\n")
        log_action("allow", "the owner opened a phone session for %d minutes, to map the phone" % ONBOARD_MINUTES,
                   "done", session)
    the_map = phone_map.load(state_dir())
    driver = OnboardingDriver(Phone(onboarding=True))
    try:
        try:
            summaries = phone_crawler.onboard(driver, the_map, names, stamp(now()), refresh=refresh)
        except phone_crawler.CrawlStopped as stopped:
            # what was learned before the stop is kept; the map is not marked onboarded
            save_map(phone_map, the_map)
            log_action("onboard", "mapping the phone stopped early: %s" % stopped.said, "stopped", session)
            fail("mapping stopped: %s. run sirven phone onboard again when the phone is free" % stopped.said, 1)
        except Refusal as refusal:
            save_map(phone_map, the_map)
            log_action("onboard", "mapping the phone failed: %s" % refusal.said, "failed", session)
            fail("mapping failed: %s" % refusal.said, 1)
        # the day the offer is measured against is the owner's own, as in today()
        the_map["onboarded_day"] = today()
        save_map(phone_map, the_map)
        lines = [onboard_line(summary) for summary in summaries]
        count = len(the_map.get("inventory", {}).get("names", []))
        log_action("onboard", "the owner mapped the phone: %d apps on the home screens; %s" % (count, "; ".join(lines)),
                   "done", session)
    finally:
        # whatever happened, including an interrupt, the session opened for the crawl closes
        end_onboarding_session(session, opened_here)
    print("mapped the home screens: %d apps" % count)
    for line in lines:
        print("  " + line)
    print("see the map: sirven phone map. forget an app: sirven phone map prune APP")


def save_map(phone_map, the_map):
    try:
        phone_map.save(state_dir(), the_map)
    except ValueError as error:
        # the map store refuses anything it must never keep; then nothing is written at all
        fail("the map was not saved: %s" % error, 1)


def onboard_line(summary):
    if summary.get("result") == "not_installed":
        return "%s: not on the home screens" % summary["name"]
    skipped = summary.get("login_screens_skipped", 0)
    text = "%s: %d screen%s mapped" % (summary["name"], summary.get("screens", 0),
                                      "" if summary.get("screens", 0) == 1 else "s")
    if skipped:
        text += ", %d sign in screen%s skipped and not kept" % (skipped, "" if skipped == 1 else "s")
    return text


def end_onboarding_session(session, opened_here):
    if not opened_here:
        return
    path = state_file("session.json")
    if (read_json(path) or {}).get("session") == session["session"]:
        os.remove(path)
        log_action("stop", "the phone session for mapping ended", "done", session)


def command_map(positional, as_json):
    phone_map = companion("phone_map")
    the_map = phone_map.load(state_dir())
    if not positional:
        if as_json:
            print(json.dumps(the_map, indent=2, sort_keys=True))
        else:
            for line in phone_map.describe(the_map):
                print(line)
        return
    if positional[0] != "prune" or len(positional) not in (2, 3):
        fail("sirven phone map takes --json, or prune APP [SCREEN]", 64)
    app = resolve_app(the_map, positional[1])
    screen = positional[2] if len(positional) == 3 else None
    removed = phone_map.prune(the_map, app, screen)
    if not removed:
        fail("the map has no screen %s for %s" % (screen, app) if screen else "the map has nothing for %s" % app, 1)
    save_map(phone_map, the_map)
    said = ("the owner removed screen %s of %s from the map" % (screen, app) if screen
            else "the owner removed %s from the map" % app)
    log_action("prune", said, "done", current_session(), app=app)
    print(said.replace("the owner removed", "removed"))


def resolve_app(the_map, given):
    """an app bundle, or the app's name as the owner sees it on the home screen."""
    apps = the_map.get("apps", {})
    if given in apps:
        return given
    named = [bundle for bundle, entry in apps.items() if str(entry.get("name", "")).lower() == given.lower()]
    if len(named) == 1:
        return named[0]
    if named:
        fail("several mapped apps are called %s; name one by bundle: %s" % (given, ", ".join(sorted(named))), 64)
    fail("the map has nothing for %s" % given, 1)


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
        fail("--team needs your ten character Apple team identifier, shown on the membership page of your Apple "
             "developer account", 64)
    if not bundle or not re.fullmatch(r"[A-Za-z0-9.-]+", bundle):
        fail("--bundle needs a bundle name you own, like com.yourname.WebDriverAgentRunner", 64)
    home = os.path.join(os.path.expanduser("~"), ".sirven")
    runner_folder = os.path.join(home, "WebDriverAgent")
    source_folder = os.path.join(home, "WebDriverAgent-source")
    runner_identifier = bundle + ".xctrunner"
    archive = "https://github.com/appium/WebDriverAgent/releases/download/%s/WebDriverAgentRunner-Runner.zip" \
        % WEBDRIVERAGENT_RELEASE
    steps = [
        ("on the phone", "plug it in, unlock it, and tap Trust when it asks about this Mac"),
        ("on the phone", "Settings > Privacy & Security > Developer Mode: on, then restart the phone"),
        ("on this Mac", "uv tool install pymobiledevice3==%s, with the Python tool installer, uv "
                        "(needs Python 3.12 or newer; no administrator password)" % PYMOBILEDEVICE3_VERSION),
        ("on this Mac", "sign and install the runner once, with ONE of these two routes, not both:"),
        (None, "route A, EXPERIMENTAL and not yet proven on a real phone: xtool signs the runner with your Apple "
               "account. first download the pinned runner:"),
        (None, "mkdir -p %s && curl -fL -o %s/runner.zip %s && echo '%s  %s/runner.zip' | shasum -a 256 -c - "
               "&& unzip -o %s/runner.zip -d %s"
               % (runner_folder, runner_folder, archive, WEBDRIVERAGENT_RUNNER_SHA256, runner_folder,
                  runner_folder, runner_folder)),
        (None, "the checksum line must say OK. if it does not, stop: the download is not the release. then follow "
               "route A in docs/phone-interface.md (xtool install, and what it can and cannot do yet)"),
        (None, "route B, the fallback: full Xcode, used only for this step and never at run time. it builds "
               "from source and does not use the download above:"),
        (None, "git clone %s %s && git -C %s checkout %s" % (WEBDRIVERAGENT_REPOSITORY, source_folder,
                                                            source_folder, WEBDRIVERAGENT_COMMIT)),
        (None, "xcodebuild -project %s/WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner "
               "-destination 'platform=iOS,name=<your phone>' -allowProvisioningUpdates DEVELOPMENT_TEAM=%s "
               "CODE_SIGN_STYLE=Automatic PRODUCT_BUNDLE_IDENTIFIER=%s test, then press Ctrl-C once the test "
               "starts on the phone" % (source_folder, team, bundle)),
        ("on the phone", "the first time: Settings > General, the device management page, "
                         "trust your developer certificate"),
        ("on the phone", "Settings > Developer: turn on the user interface automation switch"),
        ("on this Mac", "SIRVEN_PHONE_RUNNER_BUNDLE=%s sirven phone start, and leave it running" % runner_identifier),
        ("on this Mac", "in another terminal: sirven phone status (the tunnel and the launcher should say running)"),
    ]
    print("WebDriverAgent setup plan. sirven only prints this; you run each step yourself.")
    print("it signs WebDriverAgent with your own Apple account, on your own phone. nothing is sent anywhere else.")
    number_ = 0
    for where, what in steps:
        if where is None:
            print("       %s" % what)
            continue
        number_ += 1
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
    apps = []
    index = 0
    while index < len(rest):
        word = rest[index]
        if word in ("--allow-submit", "--json", "--refresh"):
            flags.add(word)
        elif word == "--app":
            if index + 1 >= len(rest):
                fail("--app needs an app name, as it shows on the home screen", 64)
            apps.append(rest[index + 1])
            index += 1
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
        if command == "start":
            command_start()
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
        if command == "onboard":
            command_onboard(apps, "--refresh" in flags)
            return 0
        if command == "map":
            command_map(positional, "--json" in flags)
            return 0
        if command == "setup":
            command_setup(options.get("--team"), options.get("--bundle"))
            return 0
    except Refusal as refusal:
        fail(refusal.said, 1)
    except ImportError as error:
        fail("the semantic map needs lib/phone_map.py and lib/phone_crawler.py beside this file (%s)" % error, 1)
    except ValueError:
        fail("--minutes and --port take whole numbers", 64)
    fail("unknown phone command '%s'; run sirven phone --help" % command, 64)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
