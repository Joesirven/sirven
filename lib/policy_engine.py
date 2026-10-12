#!/usr/bin/env python3
"""allowlist policy engine: decides, on each node, whether a request may leave it.

three answers, and only three:

  allow_local           the user's own traffic, out through the user's own egress
  allow_peer_carrier    another sirven user's personal-agent traffic, carried by this node
  refuse                with a plain-language reason the user interface can show as written

the decision path is local and deterministic: classify() reads its arguments and nothing
else. it makes no network calls, reads no clock (the caller passes now), and touches no
file. fetching the published allowlist registry happens in refresh_registry(), which is a
separate step that tolerates being offline: when it fails, carrying for peers stops
(fail closed) and the user's own egress carries on (fail open).

rules that hold in every tier, whatever the inputs:

  - Solo never carries traffic for anyone else.
  - a domain that is not on the published registry, for this node's tier, is never
    carried for a peer.
  - with no published registry (the state of a fresh install), nothing is carried.
  - peer traffic needs an identity attestation that the attestation verifier accepted.
  - authenticated peer traffic is refused while the ship gate is closed, and the gate is
    closed in code (SHIP_GATE_AUTHENTICATED_PEER_TRAFFIC) until the attestation layer and
    the site-allowlist review workflow both work end to end.

subcommands (each reads a JSON object on standard input where noted)

  classify --registry-state FILE [--log FILE] [--attestation-verifier COMMAND] --now SECONDS
      read one request as JSON on standard input, print the decision as JSON. with --log,
      append the decision to the local decision log first. COMMAND, when given, runs only
      after every other check has passed (see verify_with_command).

  refresh --registry-state FILE --fetch-command COMMAND --verify-command COMMAND --now SECONDS
      fetch the registry, verify it, and write the registry state file. any failure writes
      an unavailable state instead, so carrying stops until the next good refresh.

  gate-status --registry-state FILE --now SECONDS
      print what the authenticated-traffic ship gate is waiting on, as JSON.

exit status: 0 for a decision (including refuse), 2 for bad arguments, 1 when the decision
log could not be written (the caller must then refuse to dispatch).
"""

import argparse
import base64
import hashlib
import ipaddress
import json
import os
import re
import secrets
import stat
import subprocess
import sys
from collections import namedtuple

SCHEMA_VERSION = 1
TIERS = ("Solo", "Neighborly", "Co-op")
CARRYING_TIERS = ("Neighborly", "Co-op")
DIRECTIONS = ("own", "peer")

# the ship gate, in Jose's words: "Do not ship any peer routing of authenticated traffic
# until the attestation layer and the site-allowlist review workflow are both working end
# to end." flip this only in the release that proves both, never from configuration or from
# anything a request carries.
SHIP_GATE_AUTHENTICATED_PEER_TRAFFIC = "closed"

# the site-allowlist reviewer for the first six months (Jose's decision, October 11, 2026),
# spelled the way allowlist/policy.json and the review workflow record it.
REVIEWERS = ("Jose Sirven",)

# identity-attested per user at first ship. a pseudonymous posture is recognized, so its
# refusal reads as "not enabled yet" rather than "malformed", and can be added here later.
# the posture names are the ones lib/attestation/attestation.mjs signs.
ACCEPTED_POSTURES = ("identity",)
KNOWN_POSTURES = ("identity", "pseudonymous")

ALLOW_LOCAL = "allow_local"
ALLOW_PEER_CARRIER = "allow_peer_carrier"
REFUSE = "refuse"

# every envelope state the attestation verifier can report. the verifier for thread 02
# reports error codes; ATTESTATION_ERROR_STATES maps them onto these.
ENVELOPE_STATES = (
    "valid",
    "missing",
    "malformed",
    "unsupported_posture",
    "invalid_signature",
    "expired",
    "revoked",
    "wrong_domain",
    "wrong_request",
    "wrong_peer",
    "replayed",
    "over_cap",
    "verifier_unavailable",
)

# the refusal reasons of lib/attestation/attestation.mjs (REFUSAL), onto envelope states.
ATTESTATION_ERROR_STATES = {
    "malformed": "malformed",
    "unsigned": "malformed",
    "unsupported-version": "malformed",
    "unsupported-posture": "unsupported_posture",
    "bad-signature": "invalid_signature",
    "untrusted-issuer": "invalid_signature",
    "certificate-invalid": "invalid_signature",
    "certificate-expired": "expired",
    "not-personal-agent": "malformed",
    "user-mismatch": "invalid_signature",
    "expired": "expired",
    "not-yet-valid": "expired",
    "lifetime-too-long": "malformed",
    "wrong-audience": "wrong_peer",
    "wrong-domain": "wrong_domain",
    "domain-not-allowlisted": "wrong_domain",
    "revocation-list-missing": "verifier_unavailable",
    "revocation-list-stale": "verifier_unavailable",
    "revocation-list-rollback": "verifier_unavailable",
    "revoked": "revoked",
    "wrong-period": "wrong_request",
    "over-declared-size": "wrong_request",
    "over-cap": "over_cap",
    "replayed": "replayed",
    "wrong-request": "wrong_request",
}

# plain-language reasons, written for the person who sees them. codes are stable; the log,
# the usage meter, and the user interface key on the code, and show the reason.
REASONS = {
    "own_egress": "This is your own traffic, so it goes out through your own connection.",
    "reviewed_peer_request": "This site is on the reviewed allowlist for your tier, and the request carries a verified identity attestation.",
    "invalid_request": "The request could not be read, so it was refused.",
    "invalid_domain": "The request did not name a plain domain, so it was refused. Addresses, wildcards, and full links cannot stand in for a reviewed domain.",
    "solo_never_carries": "Solo never carries traffic for other people. Switch to Neighborly or Co-op to share.",
    "registry_unavailable": "No published site allowlist is available on this device, so it carries nothing for other people. Your own traffic is not affected.",
    "registry_expired": "The site allowlist on this device is out of date, so it carries nothing for other people until it refreshes. Your own traffic is not affected.",
    "site_not_allowlisted": "This site is not on the reviewed allowlist, so it is never carried for other people.",
    "tier_not_reviewed": "This site is reviewed for a different tier than yours, so this device does not carry it.",
    "ship_gate_closed": "Carrying signed-in traffic for other people is not available yet. It turns on only after identity attestation and site review both work end to end.",
    "authenticated_not_reviewed": "This site is reviewed for carrying public pages only, not signed-in sessions.",
    "attestation_missing": "Carrying for other people needs a verified identity attestation, and this request had none.",
    "attestation_malformed": "The identity attestation could not be read, so the request was refused.",
    "attestation_unsupported_posture": "This kind of attestation is not enabled yet. Only identity-attested requests are carried today.",
    "attestation_invalid_signature": "The identity attestation's signature did not check out, so the request was refused.",
    "attestation_expired": "The identity attestation has expired or is not valid yet, so the request was refused.",
    "attestation_revoked": "The identity behind this attestation has been revoked, so the request was refused.",
    "attestation_wrong_domain": "The identity attestation was issued for a different site, so the request was refused.",
    "attestation_wrong_request": "The identity attestation does not cover this exact request, so it was refused.",
    "attestation_wrong_peer": "The identity attestation names a different carrier than this device, so the request was refused.",
    "attestation_replayed": "This identity attestation was already used once, so the request was refused.",
    "attestation_over_cap": "Carrying this would go past the 5 gigabyte monthly sharing limit, so it was refused.",
    "attestation_verifier_unavailable": "The attestation could not be checked right now, so the request was refused.",
}

Request = namedtuple("Request", "domain tier direction authenticated request_digest envelope")
Request.__new__.__defaults__ = (False, "", None)

# what the attestation verifier returns. state is one of ENVELOPE_STATES; the other fields
# are copied from the verified payload, never from the unverified envelope.
Attestation = namedtuple("Attestation", "state posture domain request_digest key_id nonce maximum_bytes")
Attestation.__new__.__defaults__ = ("", "", "", "", "", 0)

Decision = namedtuple("Decision", "action code reason details")


def decide(action, code, **details):
    return Decision(action, code, REASONS[code], details)


def plain_domain(value):
    """an exact lowercase host name, or ValueError. no links, ports, addresses, wildcards."""
    if not isinstance(value, str) or not value or len(value) > 254:
        raise ValueError("not a domain")
    try:
        value.encode("ascii")
    except UnicodeError:
        raise ValueError("not a domain")
    name = value.lower()
    if name.endswith("."):
        name = name[:-1]
    labels = name.split(".")
    if len(labels) < 2 or len(name) > 253:
        raise ValueError("not a domain")
    for label in labels:
        if not re.match(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", label):
            raise ValueError("not a domain")
    try:
        ipaddress.ip_address(name)
    except ValueError:
        return name
    raise ValueError("an address, not a domain")


def is_time(value):
    return type(value) is int and value >= 0


# registry


def check_snapshot(snapshot, now):
    """validate a verified registry snapshot. returns it normalized, or raises ValueError.

    the snapshot thread 05 publishes, after its signature has been checked:
      {"schema_version": 1, "status": "published", "serial": 7, "reviewer": "Jose",
       "published_at": SECONDS, "expires_at": SECONDS,
       "entries": [{"domain": "example.org", "tiers": ["Neighborly", "Co-op"],
                    "authenticated_sessions": false}]}
    """
    if type(snapshot) is not dict:
        raise ValueError("the registry is not a JSON object")
    if snapshot.get("schema_version") != SCHEMA_VERSION or snapshot.get("status") != "published":
        raise ValueError("the registry is not a published version 1 registry")
    if snapshot.get("reviewer") not in REVIEWERS:
        raise ValueError("the registry was not signed off by the site-allowlist reviewer")
    serial, published, expires = snapshot.get("serial"), snapshot.get("published_at"), snapshot.get("expires_at")
    if not (is_time(serial) and is_time(published) and is_time(expires) and published < expires):
        raise ValueError("the registry serial or validity window is invalid")
    if not published <= now < expires:
        raise ValueError("the registry is not current")
    entries = snapshot.get("entries")
    if type(entries) is not list:
        raise ValueError("the registry entries are not a list")
    normalized = []
    seen = set()
    for entry in entries:
        if type(entry) is not dict or set(entry) - {"domain", "tiers", "authenticated_sessions"}:
            raise ValueError("a registry entry has unknown fields")
        domain = plain_domain(entry.get("domain"))
        tiers = entry.get("tiers")
        authenticated = entry.get("authenticated_sessions", False)
        if (domain in seen or type(tiers) is not list or not tiers
                or len(set(tiers)) != len(tiers)
                or any(tier not in CARRYING_TIERS for tier in tiers)
                or type(authenticated) is not bool):
            raise ValueError("a registry entry is invalid")
        seen.add(domain)
        normalized.append({"domain": domain, "tiers": sorted(tiers), "authenticated_sessions": authenticated})
    normalized.sort(key=lambda entry: entry["domain"])
    return {"schema_version": SCHEMA_VERSION, "status": "published", "serial": serial,
            "reviewer": snapshot["reviewer"], "published_at": published, "expires_at": expires,
            "entries": normalized}


def refresh_registry(fetch, verify, now):
    """fetch and verify a registry snapshot, and return the registry state to save.

    fetch() returns the published bytes. verify(data) checks the publisher's signature
    over exactly those bytes and returns the decoded snapshot. any failure, including being
    offline, returns an unavailable state: the previous snapshot is dropped, never kept, so
    carrying stops until a refresh succeeds. own egress never reads this state.
    """
    try:
        if not is_time(now):
            raise ValueError("the clock is invalid")
        snapshot = check_snapshot(verify(fetch()), now)
    except Exception as error:  # noqa: BLE001, any failure means stop carrying
        # the error class only: fetch errors can carry addresses or credentials in their text.
        return {"schema_version": SCHEMA_VERSION, "status": "unavailable", "checked_at": now,
                "reason": type(error).__name__}
    return {"schema_version": SCHEMA_VERSION, "status": "current", "checked_at": now,
            "snapshot": snapshot}


def usable_snapshot(registry_state, now):
    """the snapshot classify may use, or a refusal code. a fresh install has no state."""
    if type(registry_state) is not dict or registry_state.get("status") != "current":
        return None, "registry_unavailable"
    try:
        return check_snapshot(registry_state.get("snapshot"), now), None
    except ValueError:
        snapshot = registry_state.get("snapshot")
        if type(snapshot) is dict and is_time(snapshot.get("expires_at")) and now >= snapshot["expires_at"]:
            return None, "registry_expired"
        return None, "registry_unavailable"


# attestation


def envelope_payload(envelope):
    """the unverified payload of a signed envelope in the lib/attestation format:
    {"sirven_attestation": 1, "type": "request", "payload": BASE64URL, "signature": BASE64URL}.
    returns the decoded payload, or None when the shape is wrong. nothing read here is trusted;
    it only decides whether the envelope is worth handing to the verifier."""
    if (type(envelope) is not dict or envelope.get("sirven_attestation") != 1 or envelope.get("type") != "request"
            or type(envelope.get("payload")) is not str or type(envelope.get("signature")) is not str
            or not envelope["signature"]):
        return None
    text = envelope["payload"]
    if not re.fullmatch(r"[A-Za-z0-9_-]+", text):
        return None
    try:
        payload = json.loads(base64.urlsafe_b64decode(text + "=" * (-len(text) % 4)).decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    return payload if type(payload) is dict else None


def envelope_problem(envelope, request, now):
    """structural checks the engine makes itself before asking the verifier. returns an
    envelope state, or None when the envelope is worth verifying. these never replace the
    verifier's signature, revocation, replay, and cap checks."""
    if envelope is None:
        return "missing"
    payload = envelope_payload(envelope)
    if payload is None:
        return "malformed"
    posture = payload.get("posture")
    if posture not in KNOWN_POSTURES:
        return "malformed"
    if posture not in ACCEPTED_POSTURES:
        return "unsupported_posture"
    if not (is_time(payload.get("issued_at")) and is_time(payload.get("expires_at"))):
        return "malformed"
    if not payload["issued_at"] <= now < payload["expires_at"]:
        return "expired"
    if payload.get("domain") != request.domain:
        return "wrong_domain"
    if not request.request_digest or payload.get("request_digest") != request.request_digest:
        return "wrong_request"
    return None


def checked_attestation(result, request):
    """the verifier's answer as an envelope state, trusting nothing it did not verify."""
    if not isinstance(result, Attestation) or result.state not in ENVELOPE_STATES:
        return "verifier_unavailable", None
    if result.state != "valid":
        return result.state, None
    if result.posture not in ACCEPTED_POSTURES:
        return "unsupported_posture", None
    if result.domain != request.domain:
        return "wrong_domain", None
    if result.request_digest != request.request_digest:
        return "wrong_request", None
    if not (type(result.maximum_bytes) is int and result.maximum_bytes > 0):
        return "malformed", None
    return "valid", result


# the decision


def classify(request, registry_state, now, verify_attestation=None,
             ship_gate=SHIP_GATE_AUTHENTICATED_PEER_TRAFFIC):
    """the decision table. checks run in this order, and the first that fails decides:

      1. the request is well formed             else refuse invalid_request or invalid_domain
      2. own traffic                            allow_local, in every tier, registry or not
      3. peer traffic in Solo                   refuse solo_never_carries
      4. a current published registry           else registry_unavailable or registry_expired
      5. the domain is on it                    else site_not_allowlisted
      6. for this node's tier                   else tier_not_reviewed
      7. authenticated: the ship gate is open   else ship_gate_closed
      8. authenticated: reviewed for sign-in    else authenticated_not_reviewed
      9. the envelope passes structural checks  else attestation_<state>
     10. the verifier accepts it                else attestation_<state>
     11. allow_peer_carrier

    verify_attestation(envelope, request, now) is called at most once, and only at step 10,
    so a request refused for any other reason never reserves sharing allowance. it must
    return an Attestation; anything else, including an exception, refuses the request.
    """
    if not (isinstance(request, Request) and request.tier in TIERS and request.direction in DIRECTIONS
            and type(request.authenticated) is bool and type(request.request_digest) is str and is_time(now)):
        return decide(REFUSE, "invalid_request")
    try:
        domain = plain_domain(request.domain)
    except ValueError:
        return decide(REFUSE, "invalid_domain")
    request = request._replace(domain=domain)

    if request.direction == "own":
        return decide(ALLOW_LOCAL, "own_egress")
    if request.tier == "Solo":
        return decide(REFUSE, "solo_never_carries")

    snapshot, problem = usable_snapshot(registry_state, now)
    if problem:
        return decide(REFUSE, problem)
    entry = next((entry for entry in snapshot["entries"] if entry["domain"] == domain), None)
    registry = {"registry_serial": snapshot["serial"]}
    if entry is None:
        return decide(REFUSE, "site_not_allowlisted", **registry)
    if request.tier not in entry["tiers"]:
        return decide(REFUSE, "tier_not_reviewed", **registry)
    if request.authenticated:
        if ship_gate != "open":
            return decide(REFUSE, "ship_gate_closed", **registry)
        if not entry["authenticated_sessions"]:
            return decide(REFUSE, "authenticated_not_reviewed", **registry)

    state = envelope_problem(request.envelope, request, now)
    attestation = None
    if state is None:
        if verify_attestation is None:
            state = "verifier_unavailable"
        else:
            try:
                result = verify_attestation(request.envelope, request, now)
            except Exception:  # noqa: BLE001, a verifier failure is a refusal
                result = None
            state, attestation = checked_attestation(result, request)
    if state != "valid":
        return decide(REFUSE, "attestation_" + state, attestation_state=state, **registry)
    return decide(ALLOW_PEER_CARRIER, "reviewed_peer_request", attestation_state="valid",
                  posture=attestation.posture, key_id=attestation.key_id,
                  nonce_digest=hashlib.sha256(attestation.nonce.encode("utf-8")).hexdigest(),
                  maximum_bytes=attestation.maximum_bytes, **registry)


def ship_gate_status(registry_state, now, ship_gate=SHIP_GATE_AUTHENTICATED_PEER_TRAFFIC):
    """what the authenticated-traffic gate waits on, as far as this node can see."""
    snapshot, problem = usable_snapshot(registry_state, now)
    reviewed = [entry["domain"] for entry in snapshot["entries"] if entry["authenticated_sessions"]] if snapshot else []
    return {
        "ship_gate": ship_gate,
        "registry": "current" if snapshot else problem,
        "registry_serial": snapshot["serial"] if snapshot else None,
        "sites_reviewed_for_signed_in_sessions": reviewed,
        "accepted_postures": list(ACCEPTED_POSTURES),
        "authenticated_peer_traffic_possible": ship_gate == "open" and bool(reviewed),
    }


# the decision log


def log_record(request, decision, now):
    """one JSON line for the usage meter and the user interface to read.

    own traffic is logged without its domain, so the log never becomes a browsing history.
    peer traffic keeps the domain (a public, reviewed site) and the verified attestation's
    key fingerprint and maximum bytes, which the usage meter needs for the monthly cap. the
    envelope, its signature, and its nonce never enter the log; only a digest of the nonce.
    """
    valid = isinstance(request, Request)
    peer = valid and request.direction == "peer"
    record = {
        "schema_version": SCHEMA_VERSION,
        "decision_id": secrets.token_hex(16),
        "time": now if is_time(now) else None,
        "direction": request.direction if valid and request.direction in DIRECTIONS else None,
        "tier": request.tier if valid and request.tier in TIERS else None,
        "action": decision.action,
        "code": decision.code,
        "reason": decision.reason,
    }
    if peer:
        try:
            record["domain"] = plain_domain(request.domain)
        except ValueError:
            record["domain"] = None
        record["authenticated"] = request.authenticated if type(request.authenticated) is bool else None
    record.update(decision.details)
    return record


def append_log(path, record):
    """append one line to a private, locally owned log file, and flush it to disk.

    raises on any failure. the caller must refuse to dispatch when this raises, so that
    nothing is ever carried without its decision on record.
    """
    payload = (json.dumps(record, sort_keys=True, allow_nan=False) + "\n").encode("utf-8")
    flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise PermissionError("the decision log must be a private regular file owned by this user")
        if os.write(descriptor, payload) != len(payload):
            raise OSError("the decision log could not be written completely")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def classify_and_log(request, registry_state, now, log_path, verify_attestation=None,
                     ship_gate=SHIP_GATE_AUTHENTICATED_PEER_TRAFFIC):
    """the runtime's entry point: decide, write the decision down, then return it."""
    decision = classify(request, registry_state, now, verify_attestation, ship_gate)
    append_log(log_path, log_record(request, decision, now))
    return decision


def read_log(path):
    """every record in the decision log, oldest first. a torn last line is skipped."""
    records = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            try:
                records.append(json.loads(line))
            except ValueError:
                continue
    return records


# command line


def run_command(command, data, timeout):
    completed = subprocess.run(command, shell=True, input=data, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, timeout=timeout, check=True)
    return completed.stdout


def verify_with_command(command):
    """a verify_attestation that runs COMMAND, a local program, with
    {"envelope", "domain", "request_digest", "now"} as JSON on standard input. it prints
    either {"state": "valid", "posture", "domain", "request_digest", "key_id", "nonce",
    "maximum_bytes"} or {"error": CODE} with a code from ATTESTATION_ERROR_STATES."""
    def verify(envelope, request, now):
        question = json.dumps({"envelope": envelope, "domain": request.domain,
                               "request_digest": request.request_digest, "now": now})
        answer = json.loads(run_command(command, question.encode("utf-8"), 10))
        if "error" in answer:
            return Attestation(ATTESTATION_ERROR_STATES.get(answer["error"], "verifier_unavailable"))
        fields = {name: answer[name] for name in Attestation._fields if name in answer}
        return Attestation(**fields)
    return verify


def read_state(path):
    """the registry state file, or None when it is missing or unreadable."""
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def write_state(path, state):
    temporary = "%s.%s.tmp" % (path, secrets.token_hex(8))
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(descriptor, (json.dumps(state, sort_keys=True) + "\n").encode("utf-8"))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, path)


def request_from_json(data):
    if type(data) is not dict or set(data) - set(Request._fields):
        raise ValueError("the request has unknown fields")
    return Request(**data)


def main(argv=None):
    parser = argparse.ArgumentParser(description="allowlist policy engine")
    commands = parser.add_subparsers(dest="command")
    commands.required = True

    classify_parser = commands.add_parser("classify")
    classify_parser.add_argument("--registry-state", required=True)
    classify_parser.add_argument("--log")
    classify_parser.add_argument("--attestation-verifier")
    classify_parser.add_argument("--now", type=int, required=True)

    refresh_parser = commands.add_parser("refresh")
    refresh_parser.add_argument("--registry-state", required=True)
    refresh_parser.add_argument("--fetch-command", required=True)
    refresh_parser.add_argument("--verify-command", required=True)
    refresh_parser.add_argument("--now", type=int, required=True)

    gate_parser = commands.add_parser("gate-status")
    gate_parser.add_argument("--registry-state", required=True)
    gate_parser.add_argument("--now", type=int, required=True)

    args = parser.parse_args(argv)

    if args.command == "refresh":
        def fetch():
            return run_command(args.fetch_command, b"", 30)

        def verify(data):
            return json.loads(run_command(args.verify_command, data, 30))

        state = refresh_registry(fetch, verify, args.now)
        write_state(args.registry_state, state)
        print(json.dumps({"status": state["status"], "reason": state.get("reason"),
                          "serial": state.get("snapshot", {}).get("serial")}, sort_keys=True))
        return 0

    registry_state = read_state(args.registry_state)
    if args.command == "gate-status":
        print(json.dumps(ship_gate_status(registry_state, args.now), sort_keys=True))
        return 0

    try:
        request = request_from_json(json.loads(sys.stdin.read()))
    except (ValueError, TypeError):
        request = None
    verifier = verify_with_command(args.attestation_verifier) if args.attestation_verifier else None
    if args.log:
        try:
            decision = classify_and_log(request, registry_state, args.now, args.log, verifier)
        except OSError as error:
            print("policy engine: the decision log could not be written (%s); refuse to dispatch"
                  % type(error).__name__, file=sys.stderr)
            return 1
    else:
        decision = classify(request, registry_state, args.now, verifier)
    print(json.dumps({"action": decision.action, "code": decision.code, "reason": decision.reason,
                      "details": decision.details}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
