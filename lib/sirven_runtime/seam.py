"""The classification seam: the one place an egress request is given a route.

Every request the runtime carries, on either channel and at every redirect hop, passes through
decide() exactly once before any byte leaves the machine. A policy is any object with a
classify(request) method that returns a Decision. The policy engine plugs in here.

Peer routing is not built. A policy may already answer route="peer", and the seam turns that
answer into a refusal, so a later policy engine can be developed against the real seam without
anything being carried for another person. The ship gate: no peer routing of authenticated
traffic until the attestation layer and the site-allowlist review workflow both work end to end.
"""

from dataclasses import dataclass, field
import ipaddress

TIERS = ("solo", "neighborly", "co-op")
ROUTES = ("local", "peer", "refuse")
CHANNELS = ("fetch", "tunnel", "forward")

# literal names that always mean this machine or its own network
LOCAL_NAMES = ("localhost", "localhost.localdomain")


@dataclass(frozen=True)
class EgressRequest:
    """What the seam knows about a request. Never content: no body, no headers, no path.

    channel: "fetch" (the agent asked the runtime to make the request), "tunnel" (an HTTPS
    proxy CONNECT, so the runtime sees only host and port), or "forward" (a plain HTTP proxy
    request). method is None on the tunnel channel, where it is encrypted and invisible.
    signed_envelope is the attestation envelope bytes, if any. Solo never carries one.
    """

    host: str
    port: int
    scheme: str
    channel: str
    method: object = None
    tier: str = "solo"
    approval: object = None
    signed_envelope: object = None
    redirect_hop: int = 0


@dataclass(frozen=True)
class Decision:
    """route: "local", "peer", or "refuse". reason: a stable machine-readable code.
    message: one plain-language sentence a person can read."""

    route: str
    reason: str
    message: str
    policy: str = "unknown"
    details: dict = field(default_factory=dict)


def refuse(reason, message, policy="seam", **details):
    return Decision("refuse", reason, message, policy, details)


def is_address(host):
    try:
        ipaddress.ip_address(host.strip("[]"))
    except ValueError:
        return False
    return True


def is_private_address(host):
    """True for loopback, link-local, private, and other non-public literal addresses."""
    try:
        address = ipaddress.ip_address(host.strip("[]"))
    except ValueError:
        return False
    return not address.is_global


def normalize_host(host):
    host = (host or "").strip().lower().rstrip(".")
    if host.startswith("[") and host.endswith("]"):
        host = host[1:-1]
    return host


def decide(request, policy):
    """Return the one Decision for this request. Never raises."""
    if request.tier not in TIERS:
        return refuse("unknown_tier", "The runtime does not recognize the tier %r." % request.tier)
    if request.channel not in CHANNELS:
        return refuse("unknown_channel", "The runtime does not recognize that channel.")
    try:
        decision = policy.classify(request)
    except Exception as error:  # a broken policy refuses; it never waves traffic through
        return refuse("policy_error", "The policy failed, so the runtime refused the request.",
                      error=type(error).__name__)
    if not isinstance(decision, Decision) or decision.route not in ROUTES:
        return refuse("policy_error", "The policy gave an answer the runtime cannot read.")
    if decision.route == "peer":
        return refuse("peer_routing_not_built",
                      "Routing through another person's connection is not built yet; "
                      "this runtime only sends from your own connection.",
                      policy=decision.policy, asked_for="peer")
    if decision.route == "local" and request.signed_envelope is not None:
        # an envelope means traffic carried for someone else. Solo carries nothing for anyone.
        return refuse("peer_traffic_refused",
                      "This device does not carry other people's traffic.",
                      policy=decision.policy)
    return decision
