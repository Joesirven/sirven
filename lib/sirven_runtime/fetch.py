"""Making a request on the fetch channel, and reading a site's answer honestly.

Two fetchers send a single request and never follow a redirect:

- HelperFetcher runs sirven-fetch, the Swift helper, so the request goes through Apple's own
  networking stack with Safari's headers: the fingerprint a site sees from this Mac's browser.
- PythonFetcher uses the Python standard library. Its fingerprint is plainly not a browser's,
  and every result says so. It is the fallback when the helper is not built.

perform() follows redirects itself, sending every hop back through the seam, and classifies
the final answer. A block is a result, never a reason to try again: attempts is always 1 per hop.
"""

import base64
import http.client
import json
import socket
import ssl
import subprocess
from urllib.parse import urljoin, urlsplit

from . import seam

MAX_REDIRECTS = 10
DEFAULT_TIMEOUT = 30
DEFAULT_MAX_BYTES = 5000000

SAFARI_HEADERS = {
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.9",
}


class FetchError(Exception):
    def __init__(self, kind, message):
        Exception.__init__(self, message)
        self.kind = kind
        self.message = message


class HelperFetcher:
    fingerprint = "apple-urlsession"

    def __init__(self, path):
        self.path = path

    def send(self, url, method, headers, body, timeout, max_bytes):
        payload = {"url": url, "method": method, "headers": headers,
                   "timeout_seconds": timeout, "max_bytes": max_bytes}
        if body:
            payload["body_base64"] = base64.b64encode(body).decode("ascii")
        try:
            completed = subprocess.run([self.path], input=json.dumps(payload).encode("utf-8"),
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout + 5)
        except subprocess.TimeoutExpired:
            raise FetchError("timeout", "The site did not answer within %d seconds." % timeout)
        try:
            answer = json.loads(completed.stdout.decode("utf-8"))
        except ValueError:
            raise FetchError("runtime_error", "The fetch helper gave no readable answer.")
        if not answer.get("ok"):
            error = answer.get("error") or {}
            raise FetchError(helper_error_kind(error.get("code")), error.get("message") or "The request failed.")
        # Apple's stack has already decoded the page, so its encoding and length no longer apply
        headers = {name: value for name, value in (answer.get("headers") or {}).items()
                   if name not in ("content-encoding", "content-length")}
        return (answer["status"], headers,
                base64.b64decode(answer.get("body_base64") or ""), bool(answer.get("truncated")))


def helper_error_kind(code):
    # NSURLErrorDomain codes: the ones a person would want named.
    kinds = {-1001: "timeout", -1003: "name_not_found", -1004: "connection_refused",
             -1005: "connection_lost", -1009: "offline", -1200: "secure_connection_failed",
             -1202: "certificate_untrusted", -1206: "certificate_required"}
    return kinds.get(code, "network_error")


class PythonFetcher:
    fingerprint = "python-standard-library"

    def __init__(self, ssl_context=None):
        self.ssl_context = ssl_context or ssl.create_default_context()

    def send(self, url, method, headers, body, timeout, max_bytes):
        parts = urlsplit(url)
        path = parts.path or "/"
        if parts.query:
            path += "?" + parts.query
        if parts.scheme == "https":
            connection = http.client.HTTPSConnection(parts.hostname, parts.port or 443, timeout=timeout,
                                                     context=self.ssl_context)
        else:
            connection = http.client.HTTPConnection(parts.hostname, parts.port or 80, timeout=timeout)
        merged = dict(SAFARI_HEADERS)
        merged.update(headers)
        try:
            connection.request(method, path, body=body, headers=merged)
            response = connection.getresponse()
            data = response.read(max_bytes + 1)
        except socket.timeout:
            raise FetchError("timeout", "The site did not answer within %d seconds." % timeout)
        except socket.gaierror:
            raise FetchError("name_not_found", "The site's name could not be found.")
        except ConnectionRefusedError:
            raise FetchError("connection_refused", "The site refused the connection.")
        except ssl.SSLCertVerificationError:
            raise FetchError("certificate_untrusted", "The site's certificate is not trusted.")
        except ssl.SSLError:
            raise FetchError("secure_connection_failed", "The secure connection to the site failed.")
        except (OSError, http.client.HTTPException) as error:
            raise FetchError("network_error", "The request failed: %s." % type(error).__name__)
        finally:
            connection.close()
        truncated = len(data) > max_bytes
        response_headers = {name.lower(): value for name, value in response.getheaders()}
        return response.status, response_headers, data[:max_bytes], truncated


# what a site says when it is refusing an automated visitor. each pair: where to look, the words.
CHALLENGE_MARKERS = (
    ("header", "cf-mitigated"),
    ("header", "x-datadome"),
    ("header", "x-amzn-waf-action"),
    ("header", "x-px-blocked"),
    ("body", "just a moment..."),
    ("body", "attention required! | cloudflare"),
    ("body", "cf-challenge"),
    ("body", "captcha"),
    ("body", "px-captcha"),
    ("body", "datadome"),
    ("body", "access denied"),
    ("body", "are you a robot"),
    ("body", "unusual traffic"),
    ("body", "request unsuccessful. incapsula"),
)

BLOCK_MESSAGES = {
    "challenge": "The site answered with a bot check instead of the page. The runtime did not try another way around it.",
    "rate_limited": "The site said too many requests. The runtime did not retry.",
    "forbidden": "The site refused this request. The runtime did not try another way around it.",
    "unavailable_for_legal_reasons": "The site says it cannot serve this page for legal reasons.",
}


def classify_response(status, headers, body):
    """Return None for an ordinary answer, or a block record for a refusal."""
    lowered = {name.lower(): value for name, value in headers.items()}
    text = body[:65536].decode("utf-8", "replace").lower()
    evidence = []
    for where, marker in CHALLENGE_MARKERS:
        if where == "header" and marker in lowered:
            evidence.append("header " + marker)
        elif where == "body" and marker in text:
            evidence.append("page text " + repr(marker))
    if status == 451:
        kind = "unavailable_for_legal_reasons"
    elif status == 429:
        kind = "rate_limited"
    elif status in (403, 503) and evidence:
        kind = "challenge"
    elif status == 403:
        kind = "forbidden"
    elif status in (200, 202) and "header cf-mitigated" in evidence:
        kind = "challenge"
    else:
        return None
    block = {"kind": kind, "status": status, "evidence": evidence, "message": BLOCK_MESSAGES[kind]}
    if "retry-after" in lowered:
        block["retry_after"] = lowered["retry-after"]
    return block


def resolves_to_local_network(host, port, allowed):
    """The connect-time guard: a public name that resolves into the local network is refused.
    The seam decides on names without a network call, so this runs after it, before sending."""
    host = seam.normalize_host(host)
    if host in allowed or seam.is_address(host):
        return False
    try:
        answers = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror:
        return False  # the fetcher will report the name as not found
    return any(seam.is_private_address(answer[4][0]) for answer in answers)


def request_for(url, method, channel, tier, approval, envelope, hop):
    parts = urlsplit(url)
    scheme = (parts.scheme or "").lower()
    port = parts.port or (443 if scheme == "https" else 80)
    return seam.EgressRequest(host=parts.hostname or "", port=port, scheme=scheme, channel=channel,
                              method=method, tier=tier, approval=approval, signed_envelope=envelope,
                              redirect_hop=hop)


def perform(url, policy, fetcher, method="GET", headers=None, body=None, channel="fetch", tier="solo",
            approval=None, envelope=None, allow_private_hosts=(), timeout=DEFAULT_TIMEOUT,
            max_bytes=DEFAULT_MAX_BYTES, follow_redirects=True, on_decision=None):
    """Carry one request to its final answer. Returns a result record (see runtime-interface.md)."""
    method = (method or "GET").upper()
    headers = dict(headers or {})
    redirects = []
    hop = 0
    while True:
        try:
            parts = urlsplit(url)
            parts.port  # raises ValueError for a malformed port
        except ValueError:
            return result("invalid_request", url, redirects, fetcher,
                          error={"kind": "invalid_url", "message": "The URL could not be read."})
        request = request_for(url, method, channel, tier, approval, envelope, hop)
        decision = seam.decide(request, policy)
        if decision.route == "local" and resolves_to_local_network(request.host, request.port, allow_private_hosts):
            decision = seam.refuse("local_network", "The site's name points into your local network, so the runtime refused it.",
                                   policy="connect_guard")
        if on_decision:
            on_decision(request, decision)
        if decision.route != "local":
            return result("refused_by_policy", url, redirects, fetcher, decision=decision)
        try:
            status, response_headers, data, truncated = fetcher.send(url, method, headers, body, timeout, max_bytes)
        except FetchError as error:
            return result("network_error", url, redirects, fetcher, decision=decision,
                          error={"kind": error.kind, "message": error.message})
        location = response_headers.get("location")
        if follow_redirects and status in (301, 302, 303, 307, 308) and location:
            if len(redirects) >= MAX_REDIRECTS:
                return result("too_many_redirects", url, redirects, fetcher, decision=decision)
            redirects.append({"url": url, "status": status})
            previous_host = urlsplit(url).hostname
            url = urljoin(url, location)
            if urlsplit(url).hostname != previous_host:
                # credentials meant for one site never travel to another
                headers = {name: value for name, value in headers.items()
                           if name.lower() not in ("authorization", "cookie", "proxy-authorization")}
            if status == 303 or (status in (301, 302) and method == "POST"):
                method, body = "GET", None
            hop += 1
            continue
        block = classify_response(status, response_headers, data)
        return result("blocked_by_site" if block else "ok", url, redirects, fetcher, decision=decision,
                      status=status, headers=response_headers, body=data, truncated=truncated, block=block)


def result(outcome, url, redirects, fetcher, decision=None, status=None, headers=None, body=None,
           truncated=False, block=None, error=None):
    record = {
        "version": 1,
        "outcome": outcome,
        "url": url,
        "redirects": redirects,
        "attempts": 1,
        "egress": "own_connection" if outcome in ("ok", "blocked_by_site") else None,
        "fingerprint": fetcher.fingerprint,
        "decision": decision_record(decision),
        "status": status,
        "headers": headers or {},
        "body_base64": base64.b64encode(body).decode("ascii") if body is not None else None,
        "truncated": truncated,
        "block": block,
        "error": error,
    }
    return record


def decision_record(decision):
    if decision is None:
        return None
    return {"route": decision.route, "reason": decision.reason, "message": decision.message,
            "policy": decision.policy, "details": decision.details}
