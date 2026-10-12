"""a small Stripe API client on the standard library, locked to test mode.

the lock is two checks. a key must start with sk_test_ or rk_test_ before any request is
built, and every response that says livemode true is treated as an error. live mode waits for
Jose's explicit approval; nothing in this package can reach it by accident.
"""
import json
import urllib.error
import urllib.parse
import urllib.request

API_BASE = "https://api.stripe.com"
# pinned so field shapes do not move under us. the real-time authorization response must carry
# a Stripe-Version header too, and it uses this same value.
STRIPE_VERSION = "2025-03-31.basil"
TEST_KEY_PREFIXES = ("sk_test_", "rk_test_")


class StripeError(Exception):
    def __init__(self, message, status=None, code=None, body=None):
        super().__init__(message)
        self.status = status
        self.code = code
        self.body = body


class LiveModeRefused(StripeError):
    pass


def require_test_key(key):
    if not isinstance(key, str) or not key.startswith(TEST_KEY_PREFIXES):
        # never echo the key itself, not even a prefix of it.
        raise LiveModeRefused("only Stripe test mode keys (sk_test_ or rk_test_) are accepted")
    return key


def encode_form(params, prefix=None):
    """flatten nested dicts and lists into Stripe's bracketed form encoding."""
    pairs = []
    if isinstance(params, dict):
        items = params.items()
    else:
        items = enumerate(params)
    for key, value in items:
        name = f"{prefix}[{key}]" if prefix is not None else str(key)
        if value is None:
            continue
        if isinstance(value, (dict, list, tuple)):
            pairs.extend(encode_form(value, name))
        elif isinstance(value, bool):
            pairs.append((name, "true" if value else "false"))
        else:
            pairs.append((name, str(value)))
    return pairs


def urllib_transport(method, url, headers, body, timeout=30):
    request = urllib.request.Request(url, data=body, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


class StripeClient:
    """call shape: client.post(path, params, idempotency_key=...) and client.get(path, params).

    transport is any callable (method, url, headers, body) -> (status, body bytes). tests pass
    the in-memory stand-in from fake_stripe; real runs use urllib_transport.
    """

    def __init__(self, key, transport=urllib_transport, api_base=API_BASE):
        self._key = require_test_key(key)
        self._transport = transport
        self._api_base = api_base.rstrip("/")

    def _headers(self, idempotency_key=None):
        headers = {
            "Authorization": f"Bearer {self._key}",
            "Stripe-Version": STRIPE_VERSION,
            "Content-Type": "application/x-www-form-urlencoded",
        }
        if idempotency_key:
            headers["Idempotency-Key"] = idempotency_key
        return headers

    def _call(self, method, path, params=None, idempotency_key=None):
        encoded = urllib.parse.urlencode(encode_form(params or {}))
        url = self._api_base + path
        body = None
        if method == "GET":
            if encoded:
                url = f"{url}?{encoded}"
        else:
            body = encoded.encode()
        status, raw = self._transport(method, url, self._headers(idempotency_key), body)
        try:
            payload = json.loads(raw or b"{}")
        except ValueError as error:
            raise StripeError(f"Stripe returned a body that is not JSON (status {status})", status) from error
        if status >= 400:
            detail = payload.get("error", {}) if isinstance(payload, dict) else {}
            raise StripeError(detail.get("message", f"Stripe returned status {status}"), status,
                              detail.get("code"), payload)
        if isinstance(payload, dict) and payload.get("livemode") is True:
            raise LiveModeRefused("Stripe answered in live mode; refusing to continue")
        return payload

    def get(self, path, params=None):
        return self._call("GET", path, params)

    def post(self, path, params=None, idempotency_key=None):
        return self._call("POST", path, params, idempotency_key)
