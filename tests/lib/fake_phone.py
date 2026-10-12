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
