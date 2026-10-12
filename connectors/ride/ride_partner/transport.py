"""how carrier adapters reach a carrier.

three transports, chosen by SIRVEN_RIDE_PARTNER_MODE:

  fixture   recorded request and response pairs from fixtures/. the default, and the only
            mode the tests use.
  sandbox   real HTTP calls, but only to a carrier's sandbox host. BLOCKED ON PARTNER
            APPROVAL: sandbox credentials come with the partner applications (thread 07).
            without them, every call raises PartnerApprovalRequired.
  live      BLOCKED ON JOSE'S APPROVAL of the partner accounts and the money layer. always
            raises LiveCallsBlocked; there is deliberately no code path that reaches a
            production carrier host.
"""

import json
import os
import urllib.error
import urllib.parse
import urllib.request

FIXTURES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")


class PartnerApprovalRequired(Exception):
    """the call needs partner credentials that only an approved application provides."""


class LiveCallsBlocked(Exception):
    """live rides and live charges wait for Jose's explicit approval."""


class CarrierError(Exception):
    """a carrier answered with an error. adapters map it to a contract error; its text
    never reaches the caller."""

    def __init__(self, status, body):
        super().__init__("carrier answered %s" % status)
        self.status = status
        self.body = body


class Response:
    def __init__(self, status, body):
        self.status = status
        self.body = body


class FixtureTransport:
    """replays a recorded scenario. a scenario file lists interactions; each matches one
    method and path (the query string is recorded but not matched) and holds one or more
    responses, used in order and the last one repeated. every call is kept in .calls so
    tests can check what an adapter sent."""

    def __init__(self, carrier, scenario):
        path = os.path.join(FIXTURES_DIR, carrier, scenario + ".json")
        with open(path, encoding="utf-8") as handle:
            recording = json.load(handle)
        self.interactions = {}
        for interaction in recording["interactions"]:
            key = (interaction["method"], interaction["path"])
            self.interactions[key] = list(interaction["responses"])
        self.calls = []

    def request(self, method, path, query=None, body=None):
        self.calls.append({"method": method, "path": path, "query": query, "body": body})
        responses = self.interactions.get((method, path))
        if not responses:
            raise AssertionError("no recorded response for %s %s" % (method, path))
        recorded = responses.pop(0) if len(responses) > 1 else responses[0]
        return Response(recorded["status"], recorded.get("body"))


class SandboxTransport:
    """real HTTP, sandbox hosts only. BLOCKED ON PARTNER APPROVAL until thread 07's
    applications produce sandbox credentials, which arrive through bb secret as a bearer
    token in the named environment variable and are never written to the repository."""

    def __init__(self, base_url, sandbox_hosts, token_variable):
        host = urllib.parse.urlparse(base_url).hostname
        if host not in sandbox_hosts:
            raise LiveCallsBlocked("%s is not a sandbox host; live calls wait for Jose's approval" % host)
        self.base_url = base_url.rstrip("/")
        self.token_variable = token_variable

    def request(self, method, path, query=None, body=None):
        token = os.environ.get(self.token_variable)
        if not token:
            raise PartnerApprovalRequired(
                "%s is not set; sandbox credentials arrive with partner approval (thread 07)" % self.token_variable)
        url = self.base_url + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
        })
        try:
            with urllib.request.urlopen(request, timeout=15) as reply:
                raw = reply.read()
                return Response(reply.status, json.loads(raw) if raw else None)
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                parsed = json.loads(raw) if raw else None
            except ValueError:
                parsed = None
            return Response(error.code, parsed)


def transport_for(carrier, mode=None, scenario="standard"):
    """the transport a carrier adapter should use. carrier is an adapter class."""
    mode = mode or os.environ.get("SIRVEN_RIDE_PARTNER_MODE", "fixture")
    if mode == "fixture":
        return FixtureTransport(carrier.name, scenario)
    if mode == "sandbox":
        return SandboxTransport(carrier.sandbox_base_url, carrier.sandbox_hosts, carrier.token_variable)
    if mode == "live":
        raise LiveCallsBlocked("live rides and live charges wait for Jose's approval of partner accounts and the money layer")
    raise ValueError("SIRVEN_RIDE_PARTNER_MODE must be fixture, sandbox, or live")
