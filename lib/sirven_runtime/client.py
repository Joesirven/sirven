"""A small client for the runtime's control interface, for agents and for tests.

It finds the runtime through runtime.json in the state folder, and reads the token from the
token file named there. It never prints the token.
"""

import base64
import http.client
import json
import os

from .server import default_state_dir


class RuntimeNotRunning(Exception):
    pass


class Client:
    def __init__(self, state_dir=None, timeout=150):
        self.state_dir = state_dir or default_state_dir()
        self.timeout = timeout
        try:
            with open(os.path.join(self.state_dir, "runtime.json"), encoding="utf-8") as handle:
                discovery = json.load(handle)
            with open(discovery["token_file"], encoding="ascii") as handle:
                self.token = handle.read().strip()
        except (OSError, ValueError, KeyError):
            raise RuntimeNotRunning("the runtime is not running: no runtime.json in %s. start it with: sirven runtime serve"
                                    % self.state_dir)
        self.address = discovery["address"]
        self.port = discovery["port"]

    def call(self, method, path, data=None):
        connection = http.client.HTTPConnection(self.address, self.port, timeout=self.timeout)
        body = json.dumps(data).encode("utf-8") if data is not None else None
        headers = {"Authorization": "Bearer " + self.token}
        if body is not None:
            headers["Content-Type"] = "application/json"
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            return response.status, json.loads(response.read().decode("utf-8"))
        except ConnectionRefusedError:
            raise RuntimeNotRunning("the runtime is not answering on %s:%d" % (self.address, self.port))
        finally:
            connection.close()

    def status(self):
        return self.call("GET", "/v1/status")[1]

    def fetch(self, url, method="GET", headers=None, body=None, approval=None, **options):
        data = {"url": url, "method": method, "headers": headers or {}}
        if body is not None:
            data["body_base64"] = base64.b64encode(body).decode("ascii")
        if approval:
            data["approval"] = approval
        data.update(options)
        return self.call("POST", "/v1/fetch", data)[1]

    def classify(self, url, method="GET", channel="fetch"):
        return self.call("POST", "/v1/classify", {"url": url, "method": method, "channel": channel})[1]

    def decisions(self, after=0, limit=100):
        return self.call("GET", "/v1/decisions?after=%d&limit=%d" % (after, limit))[1]

    def proxy_url(self):
        return "http://sirven:%s@%s:%d" % (self.token, self.address, self.port)
