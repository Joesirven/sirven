#!/usr/bin/env python3
"""a fake iPhone for tests: a fake USB multiplexer on a unix socket, and a fake WebDriverAgent
behind it. no real phone, no real usbmuxd.

  fake_phone.py DIRECTORY

listens on DIRECTORY/usbmuxd, writes every WebDriverAgent call to DIRECTORY/calls.jsonl, and
reads its mood from files in DIRECTORY on every request:
  phones     how many phones are plugged in (default 1)
  untrusted  present: the phone has not trusted the Mac
  locked     present: the phone is locked
  focused    the type of the focused element (default XCUIElementTypeTextField)
  unreadable present: the accessibility tree comes back empty
  tap_fails  present: WebDriverAgent answers a tap with an error, after recording it
DIRECTORY/ready appears once both are listening.

world mode: when DIRECTORY/world.json exists (copy tests/lib/phone_world.json there), the
fake is a small phone with a home screen and several apps instead of one fixed screen. taps
move between screens, typing fills fields, launch and home switch apps, and the position lives
in DIRECTORY/world-state.json. a screen with "awaits_owner" is the phone's own Face ID payment
sheet: it stays until the test plays the owner by creating DIRECTORY/owner_approves (go to the
"awaits_owner" screen) or DIRECTORY/owner_declines (go to the "declined" screen).
"""

import http.server
import json
import os
import plistlib
import socket
import socketserver
import struct
import sys
import threading

DIRECTORY = sys.argv[1]

SOURCE = """<?xml version="1.0" encoding="UTF-8"?>
<AppiumAUT>
  <XCUIElementTypeApplication type="XCUIElementTypeApplication" name="Rides" label="Rides" x="0" y="0" width="390" height="844">
    <XCUIElementTypeTextField type="XCUIElementTypeTextField" name="Where to?" label="Where to?" value="" x="20" y="100" width="350" height="44"/>
    <XCUIElementTypeStaticText type="XCUIElementTypeStaticText" name="Fare" label="Fare" value="$18.40" x="20" y="600" width="200" height="30"/>
    <XCUIElementTypeButton type="XCUIElementTypeButton" name="Request ride" label="Request ride" x="20" y="700" width="350" height="50">
      <XCUIElementTypeStaticText type="XCUIElementTypeStaticText" name="Comfort $18.40" label="Comfort $18.40" x="30" y="710" width="150" height="30"/>
    </XCUIElementTypeButton>
    <XCUIElementTypeButton type="XCUIElementTypeButton" name="Choose pickup" label="Choose pickup" x="20" y="200" width="350" height="50"/>
  </XCUIElementTypeApplication>
</AppiumAUT>"""


WORLD_PATH = os.path.join(DIRECTORY, "world.json")
STATE_PATH = os.path.join(DIRECTORY, "world-state.json")
WORLD_LOCK = threading.Lock()


def world():
    if not os.path.exists(WORLD_PATH):
        return None
    with open(WORLD_PATH) as handle:
        return json.load(handle)


def world_state(the_world):
    if os.path.exists(STATE_PATH):
        with open(STATE_PATH) as handle:
            return json.load(handle)
    return dict(the_world["start"], typed="")


def save_state(state):
    with open(STATE_PATH, "w") as handle:
        json.dump(state, handle)


def current_screen(the_world, state):
    return the_world["apps"][state["app"]]["screens"][state["screen"]]


def owner_decides(the_world, state):
    """the owner answering the phone's own payment sheet, played by the test."""
    screen = current_screen(the_world, state)
    if "awaits_owner" not in screen:
        return state
    for name, target in (("owner_approves", screen["awaits_owner"]), ("owner_declines", screen.get("declined"))):
        path = os.path.join(DIRECTORY, name)
        if os.path.exists(path) and target:
            os.remove(path)
            state = dict(state, screen=target)
            save_state(state)
    return state


def world_source(the_world, state):
    screen = current_screen(the_world, state)
    escape = lambda text: (str(text).replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;"))
    lines = ['<?xml version="1.0" encoding="UTF-8"?>', "<AppiumAUT>",
             '  <XCUIElementTypeApplication type="XCUIElementTypeApplication" name="%s" label="%s" '
             'x="0" y="0" width="390" height="844">' % (escape(the_world["apps"][state["app"]]["name"]),
                                                       escape(the_world["apps"][state["app"]]["name"]))]
    for element in screen["elements"]:
        kind = "XCUIElementType" + element["type"]
        value = state["typed"] if element.get("typing") else element.get("value", "")
        x, y, width, height = element["frame"]
        lines.append('    <%s type="%s" name="%s" label="%s" value="%s" x="%s" y="%s" width="%s" height="%s"/>'
                     % (kind, kind, escape(element["label"]), escape(element["label"]), escape(value),
                        x, y, width, height))
    lines += ["  </XCUIElementTypeApplication>", "</AppiumAUT>"]
    return "\n".join(lines)


def world_tap(the_world, state, x, y):
    screen = current_screen(the_world, state)
    under = [e for e in screen["elements"] if e["frame"][0] <= x <= e["frame"][0] + e["frame"][2]
             and e["frame"][1] <= y <= e["frame"][1] + e["frame"][3]]
    if not under:
        return state
    element = min(under, key=lambda e: e["frame"][2] * e["frame"][3])
    if "launch" in element:
        app = the_world["apps"][element["launch"]]
        return dict(state, app=element["launch"], screen=app["first"], typed="")
    if "goto" in element:
        return dict(state, screen=element["goto"], typed="" if not element.get("keep_typed") else state["typed"])
    return state


def world_action(method, path, body):
    """the world's answer to one WebDriverAgent call, or None to fall through."""
    the_world = world()
    if the_world is None:
        return None
    with WORLD_LOCK:
        state = owner_decides(the_world, world_state(the_world))
        bare = path.split("?")[0]
        if method == "GET":
            if bare == "/wda/activeAppInfo":
                return {"bundleId": state["app"]}
            if bare.endswith("/source"):
                return world_source(the_world, state)
            if bare.endswith("/attribute/type"):
                return current_screen(the_world, state).get("focused", "XCUIElementTypeTextField")
            return None
        if bare.endswith("/wda/tap"):
            state = world_tap(the_world, state, body["x"], body["y"])
        elif bare.endswith("/wda/keys"):
            text = body["value"][0]
            state = dict(state, typed=state["typed"] + text.rstrip("\n"))
            then = current_screen(the_world, state).get("on_type")
            if then:
                state = dict(state, screen=then, typed=state["typed"])
        elif bare == "/wda/homescreen":
            state = dict(state, app=the_world["start"]["app"], screen=the_world["start"]["screen"], typed="")
        elif bare.endswith("/wda/apps/activate"):
            app = the_world["apps"].get(body["bundleId"])
            if app is None:
                return {"error": "unknown error", "message": "no app %s is installed" % body["bundleId"]}
            state = dict(state, app=body["bundleId"], screen=app["first"], typed="")
        elif bare.endswith("/wda/dragfromtoforduration"):
            screen = current_screen(the_world, state)
            if body["fromX"] > body["toX"] and screen.get("next_page"):
                state = dict(state, screen=screen["next_page"])
            elif body["fromX"] < body["toX"] and screen.get("previous_page"):
                state = dict(state, screen=screen["previous_page"])
        else:
            return None
        save_state(state)
        return {"world": "ok"}


def mood(name, default=None):
    path = os.path.join(DIRECTORY, name)
    if not os.path.exists(path):
        return default
    with open(path) as handle:
        return handle.read().strip() or True


def record(method, path, body):
    with open(os.path.join(DIRECTORY, "calls.jsonl"), "a") as handle:
        handle.write(json.dumps({"method": method, "path": path, "body": body}) + "\n")


class WebDriverAgent(http.server.BaseHTTPRequestHandler):
    def log_message(self, *arguments):
        pass

    def answer(self, value, extra=None):
        body = dict({"value": value}, **(extra or {}))
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        record("GET", self.path, None)
        path = self.path.split("?")[0]
        answered = world_action("GET", self.path, None)
        if answered is not None:
            return self.answer(answered)
        if path == "/status":
            return self.answer({"ready": True})
        if path == "/wda/locked":
            return self.answer(bool(mood("locked")))
        if path == "/wda/activeAppInfo":
            return self.answer({"bundleId": "com.example.rides"})
        if path == "/screenshot":
            return self.answer("iVBORw0KGgo=")
        if path.endswith("/source"):
            return self.answer("" if mood("unreadable") else SOURCE)
        if path.endswith("/window/size"):
            return self.answer({"width": 390, "height": 844})
        if path.endswith("/element/active"):
            return self.answer({"ELEMENT": "focused-1"})
        if path.endswith("/attribute/type"):
            return self.answer(mood("focused", "XCUIElementTypeTextField"))
        return self.answer({"error": "unknown command", "message": "unhandled %s" % path})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}") if length else None
        record("POST", self.path, body)
        if self.path == "/session":
            return self.answer({"sessionId": "fake-session"}, {"sessionId": "fake-session"})
        if self.path.endswith("/wda/tap") and mood("tap_fails"):
            return self.answer({"error": "unknown error", "message": "the tap timed out"})
        answered = world_action("POST", self.path, body)
        if answered is not None:
            return self.answer(None if answered == {"world": "ok"} else answered)
        return self.answer(None)


def receive(connection):
    header = b""
    while len(header) < 16:
        piece = connection.recv(16 - len(header))
        if not piece:
            return None
        header += piece
    length, _version, _kind, tag = struct.unpack("<IIII", header)
    body = b""
    while len(body) < length - 16:
        body += connection.recv(length - 16 - len(body))
    return tag, plistlib.loads(body)


def send(connection, tag, message):
    body = plistlib.dumps(message)
    connection.sendall(struct.pack("<IIII", 16 + len(body), 1, 8, tag) + body)


def pipe(source, target):
    try:
        while True:
            data = source.recv(65536)
            if not data:
                break
            target.sendall(data)
    except OSError:
        pass
    finally:
        try:
            target.shutdown(socket.SHUT_WR)
        except OSError:
            pass


class Usbmux(socketserver.BaseRequestHandler):
    def handle(self):
        received = receive(self.request)
        if received is None:
            return
        tag, message = received
        kind = message.get("MessageType")
        if kind == "ListDevices":
            count = int(mood("phones", "1"))
            devices = [{"DeviceID": 7 + n, "MessageType": "Attached",
                        "Properties": {"ConnectionType": "USB", "SerialNumber": "fake-serial-%d" % n}}
                       for n in range(count)]
            return send(self.request, tag, {"DeviceList": devices})
        if kind == "ReadPairRecord":
            if mood("untrusted"):
                return send(self.request, tag, {"MessageType": "Result", "Number": 2})
            return send(self.request, tag, {"PairRecordData": b"fake pair record"})
        if kind == "Connect":
            port = message["PortNumber"]
            port = ((port << 8) & 0xFF00) | (port >> 8)
            if port != 8100:
                return send(self.request, tag, {"MessageType": "Result", "Number": 3})
            send(self.request, tag, {"MessageType": "Result", "Number": 0})
            upstream = socket.create_connection(("127.0.0.1", WEBDRIVERAGENT_PORT))
            forward = threading.Thread(target=pipe, args=(self.request, upstream), daemon=True)
            forward.start()
            pipe(upstream, self.request)
            forward.join(5)
            upstream.close()
            return
        send(self.request, tag, {"MessageType": "Result", "Number": 1})


class UnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


webdriveragent = http.server.ThreadingHTTPServer(("127.0.0.1", 0), WebDriverAgent)
WEBDRIVERAGENT_PORT = webdriveragent.server_address[1]
threading.Thread(target=webdriveragent.serve_forever, daemon=True).start()
usbmux = UnixServer(os.path.join(DIRECTORY, "usbmuxd"), Usbmux)
open(os.path.join(DIRECTORY, "ready"), "w").close()
usbmux.serve_forever()
