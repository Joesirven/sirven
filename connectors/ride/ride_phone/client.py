"""a small client for the phone bridge's local interface (docs/phone-interface.md).

it speaks to http://127.0.0.1:PORT/v1/phone with the owner's bearer token, the same way any
agent does. it never reaches past the interface: consent, money holds, the password field rule,
and the phone's own payment approval are all the bridge's to enforce.
"""

import json
import os
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_URL = "http://127.0.0.1:47817/v1/phone"


class PhoneRefusal(Exception):
    """the bridge answered with a refusal: result is its stable code, said is plain words."""

    def __init__(self, result, said, status, body):
        super().__init__("%s: %s" % (result, said))
        self.result = result
        self.said = said
        self.status = status
        self.hold = body.get("hold")


def default_token_path():
    folder = os.environ.get("SIRVEN_PHONE_DIR") or os.path.join(os.path.expanduser("~"), ".sirven", "phone")
    return os.path.join(folder, "token")


class PhoneClient:
    def __init__(self, url=None, token=None, token_path=None, timeout=30):
        self.url = (url or os.environ.get("SIRVEN_PHONE_URL") or DEFAULT_URL).rstrip("/")
        parsed = urllib.parse.urlsplit(self.url)
        if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "localhost", "::1"):
            raise ValueError("the phone interface is loopback HTTP only")
        self._token = token
        self.token_path = token_path or default_token_path()
        self.timeout = timeout

    def token(self):
        if self._token is None:
            with open(self.token_path) as handle:
                self._token = handle.read().strip()
        return self._token

    def call(self, method, route, body=None):
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(self.url + route, data=data, method=method)
        request.add_header("Authorization", "Bearer " + self.token())
        if data is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return json.loads(response.read() or b"{}")
        except urllib.error.HTTPError as error:
            try:
                answer = json.loads(error.read() or b"{}")
            except ValueError:
                answer = {}
            raise PhoneRefusal(answer.get("result", "http_%d" % error.code), answer.get("said", ""), error.code, answer)
        except (urllib.error.URLError, OSError) as error:
            raise PhoneRefusal("bridge_not_running", "the phone bridge did not answer: %s" % error, 503, {})

    def screen(self, reason):
        return self.call("GET", "/screen?" + urllib.parse.urlencode({"reason": reason, "image": "0"}))

    def phone_map(self, app=None):
        return self.call("GET", "/map" + ("?" + urllib.parse.urlencode({"app": app}) if app else ""))

    def tap(self, label, reason, money=False, approval=None):
        body = {"label": label, "reason": reason}
        if money:
            body["money"] = True
        if approval:
            body["approval"] = approval
        return self.call("POST", "/tap", body)

    def type_text(self, text, reason):
        return self.call("POST", "/type", {"text": text, "reason": reason})

    def launch(self, bundle, reason):
        return self.call("POST", "/launch", {"bundle": bundle, "reason": reason})

    def hold_state(self, hold):
        return self.call("GET", "/holds/" + urllib.parse.quote(hold))
