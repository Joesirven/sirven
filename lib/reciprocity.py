#!/usr/bin/env python3
"""reciprocity ledger: bytes carried for neighbors and sent through them, counted per month.

the contract (shapes, units, exit statuses, reconciliation) is docs/reciprocity.md. this file
keeps usage metadata only: volumes, bare host names, and opaque references. never content.

subcommands

  check --direction carried|sent --tier solo|neighborly|co-op --domain HOST --session S
        --peer P [--bytes N] [--cap-bytes N]
      the enforcement hook the policy engine calls before it carries or routes. prints one JSON
      answer. exit 0 within the cap, 3 over it. a refusal is appended with its reason.

  record --direction carried|sent --bytes N --domain HOST --session S --transfer T --peer P
      append what a finished transfer actually moved.

  read [--tier TIER] [--cap-bytes N]
      the read-out the usage meter renders: this month's usage, the cap, sessions, refusals.

  reconcile --receipts FILE
      match the peer receipts in FILE against this ledger by transfer, print the result as JSON,
      and append each disagreement to the ledger so the read-out can show it.

  prune
      drop everything older than the previous month.

every subcommand takes --ledger FILE (default $SIRVEN_STATE_DIR/reciprocity/ledger.jsonl, with
the state folder defaulting to ~/.sirven) and --now SECONDS, so tests can pin the clock. the
month is a calendar month in the local time zone, so the TZ environment variable moves it.
"""

import argparse
import calendar
import fcntl
import json
import os
import sys
import time
from contextlib import contextmanager

SCHEMA_VERSION = 1
GIGABYTE = 1000 ** 3
MEGABYTE = 1000 ** 2
KILOBYTE = 1000

# co-op's cap is "higher" in Jose's scope, with no number yet. until he sets one it is the
# neighborly cap; this table is the one place to change it.
TIER_CAPS = {
    "solo": 0,
    "neighborly": 5 * GIGABYTE,
    "co-op": 5 * GIGABYTE,
}
DIRECTIONS = ("carried", "sent")

# two counts of the same stream agree when they are within this many bytes or this fraction of
# the larger count, whichever is more: room for bytes in flight when a session is cut off.
TOLERANCE_BYTES = 65536
TOLERANCE_FRACTION = 0.01
# a peer with this many disagreements in the current month is one to stop pairing with.
PEER_DISAGREEMENT_LIMIT = 3

EXIT_WITHIN_CAP = 0
EXIT_USAGE_ERROR = 2
EXIT_OVER_CAP = 3

FORBIDDEN_IN_DOMAIN = set("/?#@: \t\\")


class UsageError(Exception):
    pass


# ---- months ---------------------------------------------------------------------------------

def month_start(year, month):
    return int(time.mktime((year, month, 1, 0, 0, 0, 0, 0, -1)))


def period_for(now):
    """the calendar month around now, in local time: (label, starts_at, resets_at, resets_on)."""
    local = time.localtime(now)
    year, month = local.tm_year, local.tm_mon
    next_year, next_month = (year + 1, 1) if month == 12 else (year, month + 1)
    label = "%s %d" % (calendar.month_name[month], year)
    resets_on = "%s 1" % calendar.month_name[next_month]
    return label, month_start(year, month), month_start(next_year, next_month), resets_on


def previous_month_start(now):
    local = time.localtime(now)
    year, month = local.tm_year, local.tm_mon
    year, month = (year - 1, 12) if month == 1 else (year, month - 1)
    return month_start(year, month)


# ---- plain language -------------------------------------------------------------------------

def amount(count):
    """bytes in words: 1.25 gigabytes, 800 megabytes, 12 kilobytes, 512 bytes."""
    for size, unit in ((GIGABYTE, "gigabytes"), (MEGABYTE, "megabytes"), (KILOBYTE, "kilobytes")):
        if count >= size:
            text = ("%.2f" % (count / size)).rstrip("0").rstrip(".")
            return "%s %s" % (text, unit)
    return "1 byte" if count == 1 else "%d bytes" % count


def cap_words(cap):
    return "%s monthly cap" % amount(cap).replace("gigabytes", "gigabyte").replace("megabytes", "megabyte")


def session_summary(direction, total, domain):
    if direction == "carried":
        return "Carried %s to %s for a neighbor." % (amount(total), domain)
    return "Sent %s to %s through a neighbor." % (amount(total), domain)


def refusal_reason(tier, direction, requested, used, cap, resets_on):
    if cap == 0:
        if tier == "solo":
            return ("Solo shares nothing: your device does not carry traffic for others or send "
                    "yours through them.")
        return "No monthly cap is set for %s, so nothing is carried or sent through others." % tier
    verb = "Carrying this" if direction == "carried" else "Sending this through a neighbor"
    if requested == 0 or used >= cap:
        return ("Your %s is used up: %s used this month. Usage resets %s."
                % (cap_words(cap), amount(used), resets_on))
    return ("%s would go past your %s: %s already used this month and %s more requested. "
            "Usage resets %s." % (verb, cap_words(cap), amount(used), amount(requested), resets_on))


def usage_summary(tier, used, carried, sent, cap, resets_on):
    if cap == 0 and tier == "solo":
        return "Solo shares nothing, so there is no usage to count."
    return ("You have used %s of your %s: %s carried for neighbors and %s sent through neighbors. "
            "Resets %s." % (amount(used), cap_words(cap), amount(carried), amount(sent), resets_on))


# ---- the ledger file ------------------------------------------------------------------------

def default_ledger():
    state = os.environ.get("SIRVEN_STATE_DIR") or os.path.join(os.path.expanduser("~"), ".sirven")
    return os.path.join(state, "reciprocity", "ledger.jsonl")


@contextmanager
def locked(path):
    """the ledger, opened for append and exclusively locked, so a check and its record are one step."""
    folder = os.path.dirname(path)
    if folder:
        os.makedirs(folder, mode=0o700, exist_ok=True)
    handle = open(path, "a+", encoding="utf-8")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield handle
    finally:
        fcntl.flock(handle, fcntl.LOCK_UN)
        handle.close()


def read_entries(handle):
    handle.seek(0)
    entries = []
    for number, line in enumerate(handle, start=1):
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except ValueError:
            raise UsageError("ledger line %d is not JSON; the ledger was edited by hand or cut off" % number)
    return entries


def append(handle, entry):
    handle.seek(0, os.SEEK_END)
    handle.write(json.dumps(entry, sort_keys=True) + "\n")
    handle.flush()
    os.fsync(handle.fileno())


def in_period(entry, starts_at, resets_at):
    return starts_at <= entry.get("at", 0) < resets_at


def usage(entries, starts_at, resets_at):
    carried = sent = 0
    for entry in entries:
        if entry.get("kind") != "transfer" or not in_period(entry, starts_at, resets_at):
            continue
        if entry["direction"] == "carried":
            carried += entry["bytes"]
        else:
            sent += entry["bytes"]
    return carried, sent


# ---- validation -----------------------------------------------------------------------------

def bare_host(domain):
    domain = (domain or "").strip().lower().rstrip(".")
    if not domain or any(character in FORBIDDEN_IN_DOMAIN for character in domain) or "." not in domain:
        raise UsageError("--domain must be a bare host name such as example.com, never a URL or path")
    return domain


def opaque(value, flag):
    if not value or any(character in value for character in "\n\r\t"):
        raise UsageError("%s must be a non-empty opaque reference on one line" % flag)
    return value


def byte_count(value, flag):
    if value is None:
        return 0
    if value < 0:
        raise UsageError("%s must be zero or more" % flag)
    return value


def cap_for(tier, override):
    if override is not None:
        if override < 0:
            raise UsageError("--cap-bytes must be zero or more")
        return override
    return TIER_CAPS[tier]


# ---- subcommands ----------------------------------------------------------------------------

def do_check(args, now):
    domain = bare_host(args.domain)
    session = opaque(args.session, "--session")
    peer = opaque(args.peer, "--peer")
    requested = byte_count(args.bytes, "--bytes")
    cap = cap_for(args.tier, args.cap_bytes)
    _, starts_at, resets_at, resets_on = period_for(now)
    with locked(args.ledger) as handle:
        carried, sent = usage(read_entries(handle), starts_at, resets_at)
        used = carried + sent
        if cap == 0:
            within = False
        elif requested == 0:
            within = used < cap
        else:
            within = used + requested <= cap
        reason = None
        if not within:
            reason = refusal_reason(args.tier, args.direction, requested, used, cap, resets_on)
            append(handle, {
                "kind": "refusal", "direction": args.direction, "tier": args.tier,
                "bytes": requested, "domain": domain, "session": session, "peer": peer,
                "at": now, "reason": reason,
            })
    answer = {
        "schema_version": SCHEMA_VERSION,
        "within_cap": within,
        "direction": args.direction,
        "tier": args.tier,
        "requested_bytes": requested,
        "used_bytes": used,
        "cap_bytes": cap,
        "remaining_bytes": max(cap - used, 0),
        "reason": reason,
    }
    print(json.dumps(answer, sort_keys=True))
    return EXIT_WITHIN_CAP if within else EXIT_OVER_CAP


def do_record(args, now):
    entry = {
        "kind": "transfer", "direction": args.direction,
        "bytes": byte_count(args.bytes, "--bytes"), "domain": bare_host(args.domain),
        "session": opaque(args.session, "--session"), "transfer": opaque(args.transfer, "--transfer"),
        "peer": opaque(args.peer, "--peer"), "at": now,
    }
    with locked(args.ledger) as handle:
        append(handle, entry)
    return 0


def readout(entries, tier, cap, now):
    label, starts_at, resets_at, resets_on = period_for(now)
    month = [entry for entry in entries if in_period(entry, starts_at, resets_at)]
    carried, sent = usage(month, starts_at, resets_at)
    used = carried + sent

    sessions = {}
    for entry in month:
        if entry.get("kind") != "transfer":
            continue
        key = (entry["session"], entry["direction"], entry["domain"])
        found = sessions.setdefault(key, {"bytes": 0, "first_at": entry["at"], "last_at": entry["at"]})
        found["bytes"] += entry["bytes"]
        found["first_at"] = min(found["first_at"], entry["at"])
        found["last_at"] = max(found["last_at"], entry["at"])
    session_list = [
        {"session": session, "direction": direction, "domain": domain, "bytes": found["bytes"],
         "first_at": found["first_at"], "last_at": found["last_at"],
         "summary": session_summary(direction, found["bytes"], domain)}
        for (session, direction, domain), found in sessions.items()
    ]
    session_list.sort(key=lambda item: (-item["last_at"], item["session"], item["direction"]))

    refusals = [
        {"session": entry["session"], "direction": entry["direction"], "domain": entry["domain"],
         "requested_bytes": entry["bytes"], "at": entry["at"], "reason": entry["reason"]}
        for entry in month if entry.get("kind") == "refusal"
    ]
    refusals.sort(key=lambda item: -item["at"])

    disagreements = [
        {"transfer": entry["transfer"], "peer": entry["peer"], "status": entry["status"],
         "our_bytes": entry["our_bytes"], "their_bytes": entry["their_bytes"], "at": entry["at"]}
        for entry in month if entry.get("kind") == "disagreement"
    ]
    per_peer = {}
    for item in disagreements:
        per_peer[item["peer"]] = per_peer.get(item["peer"], 0) + 1
    stop_pairing = sorted(peer for peer, count in per_peer.items() if count >= PEER_DISAGREEMENT_LIMIT)

    percent = 0 if cap == 0 else min(100, used * 100 // cap)
    return {
        "schema_version": SCHEMA_VERSION,
        "tier": tier,
        "period": {"label": label, "starts_at": starts_at, "resets_at": resets_at, "resets_on": resets_on},
        "cap_bytes": cap,
        "used_bytes": used,
        "carried_bytes": carried,
        "sent_bytes": sent,
        "remaining_bytes": max(cap - used, 0),
        "percent_used": percent,
        "summary": usage_summary(tier, used, carried, sent, cap, resets_on),
        "sessions": session_list,
        "refusals": refusals,
        "disagreements": disagreements,
        "stop_pairing_with": stop_pairing,
    }


def do_read(args, now):
    cap = cap_for(args.tier, args.cap_bytes)
    with locked(args.ledger) as handle:
        entries = read_entries(handle)
    print(json.dumps(readout(entries, args.tier, cap, now), sort_keys=True, indent=2))
    return 0


def counts_agree(ours, theirs):
    allowed = max(TOLERANCE_BYTES, int(max(ours, theirs) * TOLERANCE_FRACTION))
    return abs(ours - theirs) <= allowed


def load_receipts(path):
    receipts = []
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                receipt = json.loads(line)
            except ValueError:
                raise UsageError("receipt line %d is not JSON" % number)
            for field in ("transfer", "peer", "direction", "bytes"):
                if field not in receipt:
                    raise UsageError("receipt line %d has no %s" % (number, field))
            if receipt["direction"] not in DIRECTIONS or not isinstance(receipt["bytes"], int) or receipt["bytes"] < 0:
                raise UsageError("receipt line %d has a bad direction or byte count" % number)
            receipts.append(receipt)
    return receipts


def do_reconcile(args, now):
    receipts = load_receipts(args.receipts)
    opposite = {"carried": "sent", "sent": "carried"}
    results = []
    with locked(args.ledger) as handle:
        entries = read_entries(handle)
        already = {(entry["transfer"], entry["peer"]) for entry in entries if entry.get("kind") == "disagreement"}
        ours = {}
        for entry in entries:
            if entry.get("kind") == "transfer":
                key = (entry["transfer"], entry["peer"])
                found = ours.setdefault(key, {"bytes": 0, "direction": entry["direction"]})
                found["bytes"] += entry["bytes"]
        theirs = {}
        for receipt in receipts:
            key = (receipt["transfer"], receipt["peer"])
            found = theirs.setdefault(key, {"bytes": 0, "direction": receipt["direction"]})
            found["bytes"] += receipt["bytes"]

        for key in sorted(set(ours) | set(theirs)):
            transfer, peer = key
            mine, other = ours.get(key), theirs.get(key)
            if mine and other:
                if other["direction"] != opposite[mine["direction"]]:
                    status = "discrepant"
                elif counts_agree(mine["bytes"], other["bytes"]):
                    status = "agreed"
                else:
                    status = "discrepant"
            elif mine:
                status = "missing_receipt"
            else:
                status = "unknown_to_us"
            result = {"transfer": transfer, "peer": peer, "status": status,
                      "our_bytes": mine["bytes"] if mine else None,
                      "their_bytes": other["bytes"] if other else None}
            results.append(result)
            # a missing receipt may still arrive, so only disagreements a receipt proves are kept.
            if status in ("discrepant", "unknown_to_us") and key not in already:
                append(handle, dict(result, kind="disagreement", at=now))
    print(json.dumps({"schema_version": SCHEMA_VERSION, "transfers": results}, sort_keys=True, indent=2))
    return 0


def do_prune(args, now):
    keep_from = previous_month_start(now)
    with locked(args.ledger) as handle:
        entries = read_entries(handle)
        kept = [entry for entry in entries if entry.get("at", 0) >= keep_from]
        handle.seek(0)
        handle.truncate()
        for entry in kept:
            handle.write(json.dumps(entry, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    print("pruned %d of %d ledger lines older than %s" % (
        len(entries) - len(kept), len(entries), period_for(keep_from)[0]))
    return 0


# ---- command line ---------------------------------------------------------------------------

def build_parser():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--ledger", default=None)
    common.add_argument("--now", type=int, default=None)

    parser = argparse.ArgumentParser(prog="reciprocity", description=__doc__.split("\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)

    check = commands.add_parser("check", parents=[common])
    check.add_argument("--direction", choices=DIRECTIONS, required=True)
    check.add_argument("--tier", choices=sorted(TIER_CAPS), required=True)
    check.add_argument("--domain", required=True)
    check.add_argument("--session", required=True)
    check.add_argument("--peer", required=True)
    check.add_argument("--bytes", type=int, default=None)
    check.add_argument("--cap-bytes", type=int, default=None)

    record = commands.add_parser("record", parents=[common])
    record.add_argument("--direction", choices=DIRECTIONS, required=True)
    record.add_argument("--bytes", type=int, required=True)
    record.add_argument("--domain", required=True)
    record.add_argument("--session", required=True)
    record.add_argument("--transfer", required=True)
    record.add_argument("--peer", required=True)

    read = commands.add_parser("read", parents=[common])
    read.add_argument("--tier", choices=sorted(TIER_CAPS), default="neighborly")
    read.add_argument("--cap-bytes", type=int, default=None)

    reconcile = commands.add_parser("reconcile", parents=[common])
    reconcile.add_argument("--receipts", required=True)

    commands.add_parser("prune", parents=[common])
    return parser


def main(argv):
    args = build_parser().parse_args(argv)
    args.ledger = args.ledger or default_ledger()
    now = args.now if args.now is not None else int(time.time())
    handlers = {"check": do_check, "record": do_record, "read": do_read,
                "reconcile": do_reconcile, "prune": do_prune}
    try:
        return handlers[args.command](args, now)
    except UsageError as error:
        print("error: %s" % error, file=sys.stderr)
        return EXIT_USAGE_ERROR


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
