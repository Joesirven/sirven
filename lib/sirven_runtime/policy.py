"""The Solo policy: the default, and the only policy this runtime ships with.

Solo sends only from the user's own connection, carries nothing for anyone, and never chooses
another path when a site says no. It refuses:

- any tier but Solo, and any request carrying an attestation envelope
- schemes other than http and https, and ports outside allowed_ports
- this machine and its local network (loopback, private, and link-local addresses, and
  localhost), unless the owner lists the host in allow_private_hosts
- domains the owner lists in blocked_domains, and everything under them
- on the fetch and forward channels, a method in approval_methods without an approval
  reference: the agent asks the user before any real-world action

It never makes a network call. Name lookups happen after the decision, at connect time.
"""

import json

from .seam import Decision, LOCAL_NAMES, is_address, is_private_address, normalize_host

DEFAULTS = {
    "blocked_domains": [],
    "allowed_ports": [80, 443],
    "allow_private_hosts": [],
    "approval_methods": ["POST", "PUT", "PATCH", "DELETE"],
}

NAME = "solo"


def load_settings(path=None):
    """Read the owner's settings file over the defaults. A missing path means defaults."""
    settings = dict(DEFAULTS)
    if path:
        with open(path, encoding="utf-8") as handle:
            loaded = json.load(handle)
        if not isinstance(loaded, dict):
            raise ValueError("the settings file must hold a JSON object")
        unknown = set(loaded) - set(DEFAULTS)
        if unknown:
            raise ValueError("unknown settings: %s" % ", ".join(sorted(unknown)))
        settings.update(loaded)
    settings["blocked_domains"] = [normalize_host(name) for name in settings["blocked_domains"]]
    settings["allow_private_hosts"] = [normalize_host(name) for name in settings["allow_private_hosts"]]
    settings["approval_methods"] = [method.upper() for method in settings["approval_methods"]]
    settings["allowed_ports"] = [int(port) for port in settings["allowed_ports"]]
    return settings


def under(host, domain):
    return host == domain or host.endswith("." + domain)


class SoloPolicy:
    name = NAME

    def __init__(self, settings=None):
        self.settings = settings or load_settings()

    def refuse(self, reason, message, **details):
        return Decision("refuse", reason, message, self.name, details)

    def classify(self, request):
        host = normalize_host(request.host)
        if request.tier != "solo":
            return self.refuse("tier_not_available",
                               "Only Solo is available: your agent uses your own connection and nothing is shared.")
        if request.signed_envelope is not None:
            return self.refuse("peer_traffic_refused", "This device does not carry other people's traffic.")
        if request.scheme not in ("http", "https"):
            return self.refuse("scheme_not_allowed", "The runtime carries web traffic only (http and https).")
        if not host:
            return self.refuse("no_host", "The request names no site.")
        if request.port not in self.settings["allowed_ports"]:
            return self.refuse("port_not_allowed", "The runtime does not connect to port %d." % request.port,
                               port=request.port)
        if host not in self.settings["allow_private_hosts"]:
            if host in LOCAL_NAMES or host.endswith(".localhost") or host.endswith(".local"):
                return self.refuse("local_network", "The runtime does not reach this machine or your local network.")
            if is_address(host) and is_private_address(host):
                return self.refuse("local_network", "The runtime does not reach this machine or your local network.")
        for domain in self.settings["blocked_domains"]:
            if under(host, domain):
                return self.refuse("blocked_by_owner", "You blocked %s, so the runtime will not contact it." % domain,
                                   domain=domain)
        method = (request.method or "").upper()
        if request.channel in ("fetch", "forward") and method in self.settings["approval_methods"]:
            if not request.approval:
                return self.refuse("approval_required",
                                   "A %s request acts in the world. Ask the user first, then send their approval reference." % method,
                                   method=method)
        return Decision("local", "own_connection", "Sent from your own connection.", self.name)
