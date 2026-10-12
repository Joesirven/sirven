"""Stripe-Signature headers: verify what Stripe sends, and sign what the stand-in sends.

the header is t=TIMESTAMP,v1=HEX where HEX is the HMAC with SHA-256 of "TIMESTAMP.PAYLOAD"
under the endpoint's signing secret. a stale timestamp is refused so a captured event cannot
be replayed later.
"""
import hashlib
import hmac
import json
import time

TOLERANCE_SECONDS = 300


class SignatureError(Exception):
    pass


def compute_signature(secret, timestamp, payload):
    message = f"{timestamp}.".encode() + payload
    return hmac.new(secret.encode(), message, hashlib.sha256).hexdigest()


def sign(secret, payload, timestamp=None):
    timestamp = int(time.time()) if timestamp is None else int(timestamp)
    return f"t={timestamp},v1={compute_signature(secret, timestamp, payload)}"


def verify(secret, payload, header, now=None, tolerance=TOLERANCE_SECONDS):
    """return the parsed event, or raise SignatureError."""
    if not secret:
        raise SignatureError("no webhook signing secret is configured")
    if not header:
        raise SignatureError("missing Stripe-Signature header")
    timestamp = None
    candidates = []
    for part in header.split(","):
        key, _, value = part.strip().partition("=")
        if key == "t":
            timestamp = value
        elif key == "v1":
            candidates.append(value)
    if timestamp is None or not timestamp.isdigit() or not candidates:
        raise SignatureError("malformed Stripe-Signature header")
    expected = compute_signature(secret, timestamp, payload)
    if not any(hmac.compare_digest(expected, candidate) for candidate in candidates):
        raise SignatureError("signature does not match")
    now = time.time() if now is None else now
    if abs(now - int(timestamp)) > tolerance:
        raise SignatureError("timestamp is outside the tolerance window")
    try:
        return json.loads(payload)
    except ValueError as error:
        raise SignatureError("payload is not JSON") from error
