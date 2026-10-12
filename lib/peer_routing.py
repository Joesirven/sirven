#!/usr/bin/env python3
"""peer routing, version 1: where the five pieces meet.

the attestation layer (lib/attestation), the site-allowlist registry (lib/allowlist_review.py),
the allowlist policy engine (lib/policy_engine.py), and the reciprocity ledger
(lib/reciprocity.py) each work alone. this module is the wiring between them, so a carrying
decision on a node runs the real code of every one:

  1. refresh   a registry version signed by the identity issuer is verified with the
               attestation library, turned into the policy engine's snapshot, and saved.
  2. carry     a request another member asks this node to carry goes through the policy
               engine; the engine's attestation step runs the attestation peer verifier on the
               exact request bytes; an allowed request then reserves its bytes in the
               reciprocity ledger. the first refusal decides.
  3. readiness what the tier dial and the runtime report: whether the pieces are configured
               and current on this node, and whether peer routing is available.

the ship gate, in Jose's words: "Do not ship any peer routing of authenticated traffic until
the attestation layer and the site-allowlist review workflow are both working end to end."
this module never opens it. the gate stays the policy engine's constant, and the peer
transport that would move bytes between two nodes is not built (TRANSPORT_BUILT), so
peer_routing_available is false on every node today, whatever readiness finds.

the state folder holds:
  peer/                  the attestation peer folder (lib/attestation/cli.mjs peer init)
  registry-state.json    the policy engine's registry state
  registry-domains.txt   the approved domains of the verified registry, one per line
  decisions.jsonl        the policy engine's decision log
  reciprocity.jsonl      the reciprocity ledger

command line:
  peer_routing.py refresh   --state DIR --signed FILE [--now SECONDS]
  peer_routing.py carry     --state DIR [--now SECONDS] < REQUEST_JSON
  peer_routing.py readiness --state DIR [--now SECONDS]

REQUEST_JSON: {"host", "tier", "authenticated", "request_base64", "envelope", "session"}.
"""

import argparse
import base64
import hashlib
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import policy_engine as engine  # noqa: E402

LIB = os.path.dirname(os.path.abspath(__file__))
ATTESTATION_COMMAND = os.path.join(LIB, "attestation", "cli.mjs")
RECIPROCITY = os.path.join(LIB, "reciprocity.py")

REGISTRY_FORMAT = "sirven-allowlist-registry/1"

# the peer transport, the part that moves bytes between two nodes, is not built. until it is,
# no node offers peer routing, even with every piece above configured and current.
TRANSPORT_BUILT = False

TIER_NAMES = {"solo": "Solo", "neighborly": "Neighborly", "coop": "Co-op", "co-op": "Co-op"}
LEDGER_TIERS = {"Solo": "solo", "Neighborly": "neighborly", "Co-op": "co-op"}

REASONS = {
    "reciprocity_over_cap": "Carrying this would go past the 5 gigabyte monthly sharing limit, so it was refused.",
    "reciprocity_unavailable": "The sharing ledger could not be checked, so the request was refused.",
}


def paths(state):
    return {
        "peer": os.path.join(state, "peer"),
        "registry_state": os.path.join(state, "registry-state.json"),
        "registry_domains": os.path.join(state, "registry-domains.txt"),
        "decisions": os.path.join(state, "decisions.jsonl"),
        "ledger": os.path.join(state, "reciprocity.jsonl"),
    }


def run_node(arguments, now, data=None):
    environment = dict(os.environ, SIRVEN_ATTESTATION_NOW=str(now))
    return subprocess.run(["node", ATTESTATION_COMMAND] + arguments, input=data, capture_output=True,
                          env=environment, timeout=30)


def registry_host(host):
    """a requested host at the registry's granularity: lowercase, no trailing dot, and a leading
    www. label dropped, the matching rule in docs/allowlist-review.md."""
    name = host.lower().rstrip(".") if isinstance(host, str) else host
    if isinstance(name, str) and name.startswith("www.") and name.count(".") >= 2:
        name = name[4:]
    return name


# 1. the registry


def registry_snapshot(registry, published_at, expires_at):
    """the policy engine's snapshot from a sirven-allowlist-registry/1 document.

    only the approved list is read. every approved entry may be carried in Neighborly and in
    Co-op: version 1 of the registry has no tier dimension. two kinds of entry are left out,
    so they are never carried, until the engine can express them:
      - includes_subdomains true: the engine matches exact domains only.
      - a scope without public_pages: the engine cannot carry signed-in sessions of a site
        while refusing its public pages.
    """
    if type(registry) is not dict or registry.get("format") != REGISTRY_FORMAT:
        raise ValueError("not a version 1 site-allowlist registry")
    reviewers = registry.get("reviewers")
    if type(reviewers) is not list or len(reviewers) != 1 or reviewers[0] not in engine.REVIEWERS:
        raise ValueError("the registry names reviewers this node does not accept")
    entries = []
    for entry in registry.get("approved") or []:
        scope = entry.get("scope") or []
        if entry.get("includes_subdomains") is not False or "public_pages" not in scope:
            continue
        entries.append({"domain": entry["domain"], "tiers": ["Neighborly", "Co-op"],
                        "authenticated_sessions": "authenticated_sessions" in scope})
    return {"schema_version": engine.SCHEMA_VERSION, "status": "published", "serial": registry.get("version"),
            "reviewer": reviewers[0], "published_at": published_at, "expires_at": expires_at,
            "entries": entries}


def verify_registry(state, signed_bytes, now):
    """the attestation library's check of the issuer's signature over a registry version, then
    the snapshot. raises on any failure."""
    answer = run_node(["registry", "verify", "--dir", paths(state)["peer"], "--signed", "-"], now, signed_bytes)
    if answer.returncode != 0:
        raise ValueError("the registry signature was refused")
    opened = json.loads(answer.stdout)
    return registry_snapshot(opened["registry"], opened["published_at"], opened["expires_at"])


def refresh(state, signed_bytes, now):
    """verify and install a signed registry version. any failure leaves an unavailable state,
    so the node carries nothing until the next good refresh (the engine's own rule)."""
    where = paths(state)
    registry_state = engine.refresh_registry(lambda: signed_bytes, lambda data: verify_registry(state, data, now), now)
    engine.write_state(where["registry_state"], registry_state)
    domains = [entry["domain"] for entry in registry_state.get("snapshot", {}).get("entries", [])]
    with open(where["registry_domains"], "w", encoding="utf-8") as handle:
        handle.write("".join(domain + "\n" for domain in domains))
    return registry_state


# 2. carrying


def unverified_payload(envelope):
    payload = engine.envelope_payload(envelope)
    return payload if payload is not None else {}


def attestation_verifier(state):
    """the engine's verify_attestation, backed by the attestation peer verifier. the bytes
    reserved are the size the envelope declares; the transport must cut the stream there."""
    where = paths(state)

    def verify(envelope, request, now):
        declared = (unverified_payload(envelope).get("cap") or {}).get("request_bytes")
        if type(declared) is not int or declared <= 0:
            return engine.Attestation("malformed")
        answer = run_node(["peer", "verify", "--dir", where["peer"], "--host", request.domain,
                           "--bytes", str(declared), "--request-digest", request.request_digest,
                           "--allowlist", where["registry_domains"]], now, json.dumps(envelope).encode("utf-8"))
        verdict = json.loads(answer.stdout)
        if answer.returncode == 0 and verdict.get("accepted") is True:
            return engine.Attestation("valid", "identity", verdict["domain"], verdict["request_digest"],
                                      verdict["key"], verdict["nonce"], verdict["request_bytes"])
        return engine.Attestation(engine.ATTESTATION_ERROR_STATES.get(verdict.get("reason"), "verifier_unavailable"))
    return verify


def refusal(code, reason, **details):
    return {"action": engine.REFUSE, "code": code, "reason": reason, "details": details}


def carry(state, host, tier, authenticated, request_bytes, envelope, session, now,
          ship_gate=engine.SHIP_GATE_AUTHENTICATED_PEER_TRAFFIC):
    """decide whether this node carries one request for another member. returns
    {"action", "code", "reason", "details"}; carry only when action is allow_peer_carrier."""
    where = paths(state)
    tier_name = TIER_NAMES.get(str(tier).lower(), tier)
    request = engine.Request(registry_host(host), tier_name, "peer", authenticated,
                             hashlib.sha256(request_bytes).hexdigest(), envelope)
    try:
        registry_state = engine.read_state(where["registry_state"])
    except (OSError, ValueError):
        registry_state = None
    decision = engine.classify_and_log(request, registry_state, now, where["decisions"],
                                       attestation_verifier(state), ship_gate)
    answer = {"action": decision.action, "code": decision.code, "reason": decision.reason,
              "details": dict(decision.details)}
    if decision.action != engine.ALLOW_PEER_CARRIER:
        return answer
    # the reciprocity ledger last: it is asked only for a request every other check allowed.
    ledger = subprocess.run([sys.executable, RECIPROCITY, "check", "--ledger", where["ledger"], "--now", str(now),
                             "--direction", "carried", "--tier", LEDGER_TIERS[tier_name],
                             "--domain", request.domain, "--session", session,
                             "--peer", decision.details["key_id"], "--bytes", str(decision.details["maximum_bytes"])],
                            capture_output=True, timeout=30)
    if ledger.returncode == 3:
        return refusal("reciprocity_over_cap", REASONS["reciprocity_over_cap"], **answer["details"])
    if ledger.returncode != 0:
        return refusal("reciprocity_unavailable", REASONS["reciprocity_unavailable"], **answer["details"])
    answer["details"]["reciprocity"] = json.loads(ledger.stdout)
    return answer


# 3. readiness


def attestation_readiness(state, now):
    """ready when this node has a peer identity, a trusted issuer, and a current revocation
    list from that issuer. otherwise the reason it is not."""
    peer = paths(state)["peer"]
    for name, problem in (("policy.json", "no_peer_identity"), ("trusted-issuers.json", "no_trusted_issuer"),
                          ("revocation-list.json", "no_revocation_list")):
        if not os.path.exists(os.path.join(peer, name)):
            return problem
    try:
        with open(os.path.join(peer, "revocation-list.json"), encoding="utf-8") as handle:
            listed = json.load(handle)["list"]
        payload = json.loads(base64.urlsafe_b64decode(listed["payload"] + "=" * (-len(listed["payload"]) % 4)))
    except (OSError, ValueError, KeyError, TypeError):
        return "no_revocation_list"
    if not (type(payload.get("next_update")) is int and now < payload["next_update"]):
        return "revocation_list_stale"
    return "ready"


def readiness(state, now):
    where = paths(state)
    try:
        registry_state = engine.read_state(where["registry_state"])
    except (OSError, ValueError):
        registry_state = None
    snapshot, problem = engine.usable_snapshot(registry_state, now)
    attestation = attestation_readiness(state, now)
    registry = "current" if snapshot and snapshot["entries"] else ("empty" if snapshot else problem)
    components_ready = attestation == "ready" and registry == "current"
    return {
        "version": 1,
        "attestation": attestation,
        "registry": registry,
        "registry_serial": snapshot["serial"] if snapshot else None,
        "approved_sites": len(snapshot["entries"]) if snapshot else 0,
        "ship_gate": engine.SHIP_GATE_AUTHENTICATED_PEER_TRAFFIC,
        "transport": "built" if TRANSPORT_BUILT else "not_built",
        "components_ready": components_ready,
        "peer_routing_available": components_ready and TRANSPORT_BUILT,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(prog="peer_routing", description=__doc__.split("\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("refresh", "carry", "readiness"):
        command = commands.add_parser(name)
        command.add_argument("--state", required=True)
        command.add_argument("--now", type=int, default=None)
        if name == "refresh":
            command.add_argument("--signed", required=True)
    args = parser.parse_args(argv)
    now = args.now if args.now is not None else int(time.time())
    if args.command == "refresh":
        with open(args.signed, "rb") as handle:
            result = refresh(args.state, handle.read(), now)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result["status"] == "current" else 3
    if args.command == "readiness":
        print(json.dumps(readiness(args.state, now), indent=2, sort_keys=True))
        return 0
    data = json.load(sys.stdin)
    result = carry(args.state, data["host"], data["tier"], bool(data.get("authenticated", False)),
                   base64.b64decode(data["request_base64"]), data.get("envelope"), data["session"], now)
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0 if result["action"] == engine.ALLOW_PEER_CARRIER else 3


if __name__ == "__main__":
    sys.exit(main())
