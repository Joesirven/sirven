#!/usr/bin/env python3
"""allowlist review: the human review workflow for sites eligible for peer routing.

a site is carried for other sirven users only after a named reviewer approves it here. the
tool keeps the paperwork: requests, decision records with the rubric answers, reviewer votes,
and the public registry built from them. it never decides anything itself. the rubric lives
in docs/allowlist-review.md.

files, all under the allowlist folder (--root, default: allowlist next to lib):

  policy.json                  reviewers, quorum, notice period, growth limit
  requests/REQUEST.json        one intake record per request
  decisions/DECISION.json      one decision record per review; append-only
  registry.json                the public registry, built from the decisions, never hand edited

subcommands

  request --domain D --requested-by CLASS --case TEXT [--risk TEXT] [--link KIND=URL]...
          [--date YYYY-MM-DD]
      write an intake record and print its name.

  prepare REQUEST [--prepared-by NAME] [--date YYYY-MM-DD]
      write a decision record skeleton for a request, rubric answers unknown, no votes. the
      preparer fills in the rubric findings and the recommendation; the reviewer votes.

  queue
      list every domain whose newest decision is still waiting for votes.

  sheet DECISION
      print one decision as a review sheet: the request, the rubric findings, the
      recommendation, and the exact vote commands. this is what the reviewer reads.

  vote DECISION --reviewer NAME --decision approve|decline|defer [--scope SCOPE]...
       [--note TEXT] [--date YYYY-MM-DD]
      add a reviewer's vote to a decision record. only reviewers named in policy.json count.

  build [--check]
      rebuild registry.json from the decision records. the version goes up by one whenever
      the content changes, and the change is written to the history. with --check, change
      nothing and exit 1 when registry.json is out of date.

  validate
      check every record and the registry against the rules in docs/allowlist-review.md.

  publish --dest DIR (--staging | --confirmed-by REVIEWER)
      copy the registry to DIR: registry.json, versions/registry-vN.json, and a sha256 file.
      a published version is never overwritten with different content.

build reads no clock: every date it writes comes from the records, so tests can pin it.
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import sys

SCOPES = ("public_pages", "authenticated_sessions")
DECISIONS = ("approve", "decline", "defer")
RATINGS = ("pass", "concern", "fail", "unknown")
RUBRIC_KEYS = ("legitimate_personal_agent_use", "peer_operator_risk", "site_position")
REQUESTED_BY = ("sirven_user", "sirven", "site_operator")
LINK_KINDS = ("terms", "statement", "enforcement", "robots", "other")
DATE_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}$")
LABEL_PATTERN = re.compile(r"^(?!-)[a-z0-9-]{1,63}(?<!-)$")
REGISTRY_FORMAT = "sirven-allowlist-registry/1"


class ReviewError(Exception):
    pass


def default_root():
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "allowlist")


def normalize_domain(text):
    """the registry matching contract: lowercase, punycode, no scheme, port, path, trailing
    dot, or leading www label."""
    raw = text.strip()
    if not raw or re.search(r"[/:@*\s]", raw):
        raise ReviewError("domain '%s' must be a bare host name: no scheme, port, path, or wildcard" % text)
    try:
        domain = raw.rstrip(".").encode("idna").decode("ascii").lower()
    except UnicodeError:
        raise ReviewError("domain '%s' is not a valid host name" % text)
    if domain.startswith("www.") and domain.count(".") >= 2:
        domain = domain[len("www."):]
    labels = domain.split(".")
    if len(labels) < 2 or not all(LABEL_PATTERN.match(label) for label in labels):
        raise ReviewError("domain '%s' is not a valid host name" % text)
    return domain


def check_date(text, what):
    if not DATE_PATTERN.match(text or ""):
        raise ReviewError("%s must be a date like 2026-10-11, got '%s'" % (what, text))
    try:
        return datetime.date.fromisoformat(text)
    except ValueError:
        raise ReviewError("%s is not a real date: '%s'" % (what, text))


def today():
    return datetime.date.today().isoformat()


def read_json(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        raise ReviewError("%s does not exist" % path)
    except json.JSONDecodeError as error:
        raise ReviewError("%s is not valid JSON: %s" % (path, error))


def dump_json(data):
    return json.dumps(data, indent=2, ensure_ascii=False, sort_keys=False) + "\n"


def write_json(path, data, exclusive=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        with open(path, "x" if exclusive else "w", encoding="utf-8") as handle:
            handle.write(dump_json(data))
    except FileExistsError:
        raise ReviewError("%s already exists; records are append-only, so write a new one" % path)


def load_policy(root):
    policy = read_json(os.path.join(root, "policy.json"))
    reviewers = policy.get("reviewers")
    if not isinstance(reviewers, list) or not reviewers:
        raise ReviewError("policy.json needs a non-empty reviewers list")
    quorum = policy.get("quorum")
    if not isinstance(quorum, int) or not 1 <= quorum <= len(reviewers):
        raise ReviewError("policy.json quorum must be between 1 and the number of reviewers")
    check_date(policy.get("created"), "policy.json created")
    for key in ("notice_days", "max_additions_per_version"):
        if not isinstance(policy.get(key), int) or policy[key] < 0:
            raise ReviewError("policy.json %s must be a whole number" % key)
    return policy


def load_folder(root, folder):
    path = os.path.join(root, folder)
    records = {}
    if not os.path.isdir(path):
        return records
    for name in sorted(os.listdir(path)):
        if name.endswith(".json"):
            records[name[: -len(".json")]] = read_json(os.path.join(path, name))
    return records


def next_name(root, folder, stem):
    taken = set(load_folder(root, folder))
    number = 1
    while "%s-%d" % (stem, number) in taken:
        number += 1
    return "%s-%d" % (stem, number)


# --- intake ------------------------------------------------------------------------------

def command_request(args):
    domain = normalize_domain(args.domain)
    received = args.date or today()
    check_date(received, "--date")
    if args.requested_by not in REQUESTED_BY:
        raise ReviewError("--requested-by must be one of: %s" % ", ".join(REQUESTED_BY))
    if not args.case.strip():
        raise ReviewError("--case must say why a personal agent legitimately needs this site")
    links = []
    for item in args.link or []:
        kind, _, url = item.partition("=")
        if kind not in LINK_KINDS or not url.startswith("https://"):
            raise ReviewError("--link must be KIND=https://..., KIND one of: %s" % ", ".join(LINK_KINDS))
        links.append({"kind": kind, "url": url, "retrieved": received})
    name = next_name(args.root, "requests", "%s-%s" % (received, domain))
    record = {
        "request": name,
        "domain": domain,
        "received": received,
        "requested_by": args.requested_by,
        "case_for_personal_agent_use": args.case.strip(),
        "risk_notes": (args.risk or "").strip(),
        "public_positions": links,
    }
    write_json(os.path.join(args.root, "requests", name + ".json"), record, exclusive=True)
    print(name)


def command_prepare(args):
    requests = load_folder(args.root, "requests")
    if args.request not in requests:
        raise ReviewError("no request named '%s'" % args.request)
    request = requests[args.request]
    prepared = args.date or today()
    check_date(prepared, "--date")
    previous = newest_decision_for(load_folder(args.root, "decisions"), request["domain"])
    name = next_name(args.root, "decisions", "%s-%s" % (prepared, request["domain"]))
    record = {
        "decision": name,
        "request": args.request,
        "domain": request["domain"],
        "includes_subdomains": False,
        "supersedes": previous,
        "prepared_by": args.prepared_by,
        "prepared": prepared,
        "rubric": {key: {"rating": "unknown", "finding": ""} for key in RUBRIC_KEYS},
        "recommendation": {"decision": "defer", "scope": [], "rationale": ""},
        "votes": [],
    }
    write_json(os.path.join(args.root, "decisions", name + ".json"), record, exclusive=True)
    print(name)


# --- status ------------------------------------------------------------------------------

def decision_order(record):
    return (record.get("prepared", ""), record.get("decision", ""))


def newest_decision_for(decisions, domain):
    mine = [record for record in decisions.values() if record.get("domain") == domain]
    if not mine:
        return None
    return max(mine, key=decision_order)["decision"]


def counted_votes(record, request, policy):
    """the votes that count: by a listed reviewer, newest per reviewer, after the notice period."""
    reviewers = set(policy["reviewers"])
    earliest = check_date(request["received"], "received") + datetime.timedelta(days=policy["notice_days"])
    newest = {}
    for vote in record.get("votes", []):
        if vote.get("reviewer") not in reviewers:
            continue
        if vote.get("decision") == "approve" and check_date(vote["date"], "vote date") < earliest:
            continue
        if vote["reviewer"] not in newest or vote["date"] >= newest[vote["reviewer"]]["date"]:
            newest[vote["reviewer"]] = vote
    return list(newest.values())


def status_of(record, request, policy):
    """approved, declined, or pending, and for approved the scope every approving vote shares."""
    votes = counted_votes(record, request, policy)
    approvals = [vote for vote in votes if vote["decision"] == "approve"]
    declines = [vote for vote in votes if vote["decision"] == "decline"]
    if len(approvals) >= policy["quorum"]:
        scope = set(SCOPES)
        for vote in approvals:
            scope &= set(vote.get("scope", []))
        if scope:
            return "approved", [item for item in SCOPES if item in scope], approvals
    if len(declines) >= policy["quorum"]:
        return "declined", [], declines
    return "pending", [], []


def current_records(root):
    policy = load_policy(root)
    requests = load_folder(root, "requests")
    decisions = load_folder(root, "decisions")
    current = {}
    for record in decisions.values():
        domain = record["domain"]
        if domain not in current or decision_order(record) > decision_order(current[domain]):
            current[domain] = record
    return policy, requests, decisions, current


# --- review ------------------------------------------------------------------------------

def command_queue(args):
    policy, requests, _, current = current_records(args.root)
    for domain in sorted(current):
        record = current[domain]
        status, _, _ = status_of(record, requests[record["request"]], policy)
        if status == "pending":
            recommendation = record["recommendation"]
            print("%s\t%s\trecommended: %s %s" % (
                record["decision"], domain, recommendation["decision"],
                ",".join(recommendation["scope"]) or "(no scope)"))


def command_sheet(args):
    policy, requests, decisions, _ = current_records(args.root)
    if args.decision not in decisions:
        raise ReviewError("no decision named '%s'" % args.decision)
    record = decisions[args.decision]
    request = requests[record["request"]]
    status, scope, _ = status_of(record, request, policy)
    earliest = check_date(request["received"], "received") + datetime.timedelta(days=policy["notice_days"])
    lines = [
        "review sheet: %s" % record["domain"],
        "decision record: %s (status: %s%s)" % (
            record["decision"], status, ", scope " + ",".join(scope) if scope else ""),
        "request: %s, received %s from %s" % (request["request"], request["received"], request["requested_by"]),
        "subdomains included: %s" % ("yes" if record["includes_subdomains"] else "no, this exact host only"),
        "prepared by: %s on %s" % (record["prepared_by"], record["prepared"]),
        "",
        "case for personal-agent use:",
        "  " + request["case_for_personal_agent_use"],
    ]
    if request["risk_notes"]:
        lines += ["risk notes from the request:", "  " + request["risk_notes"]]
    lines += ["", "the site's public positions:"]
    for link in request["public_positions"] + record.get("additional_positions", []):
        lines.append("  %-12s %s (retrieved %s)%s" % (
            link["kind"], link["url"], link["retrieved"],
            ", " + link["note"] if link.get("note") else ""))
    lines += ["", "rubric (docs/allowlist-review.md):"]
    for key in RUBRIC_KEYS:
        answer = record["rubric"][key]
        lines.append("  %s: %s" % (key.replace("_", " "), answer["rating"]))
        lines.append("    " + (answer["finding"] or "(not yet prepared)"))
    recommendation = record["recommendation"]
    lines += [
        "",
        "recommendation from the preparer: %s %s" % (
            recommendation["decision"], ",".join(recommendation["scope"]) or ""),
        "  " + (recommendation["rationale"] or "(not yet prepared)"),
        "",
        "votes so far: %d of %d needed" % (
            len([vote for vote in record["votes"] if vote["reviewer"] in policy["reviewers"]]), policy["quorum"]),
    ]
    for vote in record["votes"]:
        lines.append("  %s %s %s %s" % (vote["date"], vote["reviewer"], vote["decision"], ",".join(vote.get("scope", []))))
    lines += [
        "",
        "approval counts from %s (notice period: %d days after the request)." % (earliest.isoformat(), policy["notice_days"]),
        "to vote, run one of:",
        "  lib/allowlist_review.py vote %s --reviewer NAME --decision approve --scope public_pages" % record["decision"],
        "  lib/allowlist_review.py vote %s --reviewer NAME --decision approve --scope public_pages --scope authenticated_sessions" % record["decision"],
        "  lib/allowlist_review.py vote %s --reviewer NAME --decision decline --note 'why'" % record["decision"],
        "  lib/allowlist_review.py vote %s --reviewer NAME --decision defer --note 'what is missing'" % record["decision"],
        "then: lib/allowlist_review.py build && lib/allowlist_review.py validate",
    ]
    print("\n".join(lines))


def command_vote(args):
    policy, requests, decisions, current = current_records(args.root)
    if args.decision not in decisions:
        raise ReviewError("no decision named '%s'" % args.decision)
    record = decisions[args.decision]
    if current[record["domain"]]["decision"] != args.decision:
        raise ReviewError("%s has been superseded by %s; vote on the newest decision" % (
            args.decision, current[record["domain"]]["decision"]))
    if args.reviewer not in policy["reviewers"]:
        raise ReviewError("'%s' is not a reviewer in policy.json" % args.reviewer)
    if policy["quorum"] > 1 and args.reviewer == record["prepared_by"]:
        raise ReviewError("%s prepared this review; with a council, the preparer does not vote on it" % args.reviewer)
    date = args.date or today()
    check_date(date, "--date")
    scope = list(dict.fromkeys(args.scope or []))
    if args.decision_value == "approve":
        if not scope:
            raise ReviewError("an approve vote needs at least one --scope: %s" % ", ".join(SCOPES))
        earliest = check_date(requests[record["request"]]["received"], "received") + datetime.timedelta(days=policy["notice_days"])
        if check_date(date, "--date") < earliest:
            raise ReviewError("the notice period runs until %s; an approval before then does not count" % earliest.isoformat())
        if any(rating["rating"] == "unknown" for rating in record["rubric"].values()):
            raise ReviewError("every rubric question needs a finding before an approval")
    elif scope:
        raise ReviewError("--scope belongs only on an approve vote")
    vote = {"reviewer": args.reviewer, "date": date, "decision": args.decision_value, "scope": scope}
    if args.note:
        vote["note"] = args.note
    record["votes"].append(vote)
    write_json(os.path.join(args.root, "decisions", args.decision + ".json"), record)
    status, scope, _ = status_of(record, requests[record["request"]], policy)
    print("%s is now %s%s" % (record["domain"], status, " for " + ",".join(scope) if scope else ""))


# --- registry ----------------------------------------------------------------------------

def registry_entry(record, request, status, scope, votes):
    entry = {
        "domain": record["domain"],
        "includes_subdomains": record["includes_subdomains"],
        "decision_record": "decisions/%s.json" % record["decision"],
        "requested": request["received"],
        "rationale": record["recommendation"]["rationale"],
    }
    if status == "approved":
        entry["scope"] = scope
        entry["reviewed"] = max(vote["date"] for vote in votes)
        entry["reviewers"] = sorted(vote["reviewer"] for vote in votes)
    elif status == "declined":
        entry["reviewed"] = max(vote["date"] for vote in votes)
        entry["reviewers"] = sorted(vote["reviewer"] for vote in votes)
        entry["rationale"] = "; ".join(vote["note"] for vote in votes if vote.get("note")) or entry["rationale"]
    else:
        entry["recommended"] = {
            "decision": record["recommendation"]["decision"],
            "scope": record["recommendation"]["scope"],
        }
        entry["status"] = "pending reviewer approval"
    return entry


def registry_content(root):
    policy, requests, _, current = current_records(root)
    lists = {"approved": [], "pending": [], "declined": []}
    dates = []
    for domain in sorted(current):
        record = current[domain]
        request = requests[record["request"]]
        status, scope, votes = status_of(record, request, policy)
        lists[status].append(registry_entry(record, request, status, scope, votes))
        dates += [record["prepared"], request["received"]] + [vote["date"] for vote in record["votes"]]
    return lists, max(dates) if dates else None


def summarize_change(old, new):
    change = {}
    for key in ("approved", "pending", "declined"):
        before = {entry["domain"]: entry for entry in old.get(key, [])}
        after = {entry["domain"]: entry for entry in new[key]}
        added = sorted(set(after) - set(before))
        removed = sorted(set(before) - set(after))
        changed = sorted(domain for domain in set(after) & set(before) if after[domain] != before[domain])
        for label, domains in (("added_to_", added), ("removed_from_", removed), ("changed_in_", changed)):
            if domains:
                change[label + key] = domains
    return change


def build_registry(root):
    path = os.path.join(root, "registry.json")
    old = read_json(path) if os.path.exists(path) else {"version": 0, "history": []}
    policy = load_policy(root)
    lists, newest_date = registry_content(root)
    same_policy = old.get("reviewers") == policy["reviewers"] and old.get("quorum") == policy["quorum"]
    same = same_policy and all(old.get(key, []) == lists[key] for key in lists)
    if same and old["version"] > 0:
        return old, False
    change = summarize_change(old, lists)
    if not same_policy and old["version"] > 0:
        change["reviewers_now"] = policy["reviewers"]
        change["quorum_now"] = policy["quorum"]
    added = change.get("added_to_approved", [])
    if len(added) > policy["max_additions_per_version"]:
        raise ReviewError("this version would approve %d domains (%s); policy.json allows %d per version" % (
            len(added), ", ".join(added), policy["max_additions_per_version"]))
    version = old["version"] + 1
    date = max(filter(None, (newest_date, old.get("updated"), policy["created"])))
    if old["version"] == 0:
        change["note"] = "registry created"
    history = list(old.get("history", []))
    history.append(dict({"version": version, "date": date}, **change))
    registry = {
        "format": REGISTRY_FORMAT,
        "version": version,
        "updated": date,
        "about": "sites a sirven node may carry for other sirven users. only the approved list is "
                 "eligible; pending and declined are published so operators see what is coming and "
                 "what was refused. the matching rules and the review rubric are in docs/allowlist-review.md.",
        "matching": {
            "domain": "lowercase punycode host name, no scheme, port, path, or trailing dot",
            "includes_subdomains": "false: the exact host only. true: the host and every subdomain",
            "scope": "public_pages: requests without the user's login. authenticated_sessions: requests carrying the user's session",
        },
        "reviewers": policy["reviewers"],
        "quorum": policy["quorum"],
        "approved": lists["approved"],
        "pending": lists["pending"],
        "declined": lists["declined"],
        "history": history,
    }
    return registry, True


def command_build(args):
    registry, changed = build_registry(args.root)
    path = os.path.join(args.root, "registry.json")
    if args.check:
        if changed:
            print("registry.json is out of date; run: lib/allowlist_review.py build", file=sys.stderr)
            return 1
        print("registry.json is current: version %d" % registry["version"])
        return 0
    if changed:
        write_json(path, registry)
        print("registry.json is now version %d" % registry["version"])
    else:
        print("registry.json is current: version %d" % registry["version"])
    return 0


# --- validate ----------------------------------------------------------------------------

def validate(root):
    problems = []
    try:
        policy, requests, decisions, current = current_records(root)
    except (ReviewError, KeyError) as error:
        return [str(error)]
    for name, request in requests.items():
        try:
            if request.get("request") != name:
                problems.append("requests/%s.json: request field must be %s" % (name, name))
            if normalize_domain(request["domain"]) != request["domain"]:
                problems.append("requests/%s.json: domain is not normalized" % name)
            check_date(request["received"], "requests/%s.json received" % name)
            if request["requested_by"] not in REQUESTED_BY:
                problems.append("requests/%s.json: requested_by is not a known class" % name)
            if not request["case_for_personal_agent_use"]:
                problems.append("requests/%s.json: the case for personal-agent use is empty" % name)
        except (ReviewError, KeyError) as error:
            problems.append("requests/%s.json: %s" % (name, error))
    for name, record in decisions.items():
        where = "decisions/%s.json" % name
        try:
            if record.get("decision") != name:
                problems.append("%s: decision field must be %s" % (where, name))
            if record["request"] not in requests:
                problems.append("%s: request %s does not exist" % (where, record["request"]))
            elif requests[record["request"]]["domain"] != record["domain"]:
                problems.append("%s: domain differs from its request" % where)
            if record["supersedes"] is not None and record["supersedes"] not in decisions:
                problems.append("%s: supersedes a decision that does not exist" % where)
            check_date(record["prepared"], where + " prepared")
            if set(record["rubric"]) != set(RUBRIC_KEYS):
                problems.append("%s: the rubric must answer exactly: %s" % (where, ", ".join(RUBRIC_KEYS)))
            for key, answer in record["rubric"].items():
                if answer.get("rating") not in RATINGS:
                    problems.append("%s: rubric %s rating must be one of %s" % (where, key, ", ".join(RATINGS)))
            recommendation = record["recommendation"]
            if recommendation["decision"] not in DECISIONS or not set(recommendation["scope"]) <= set(SCOPES):
                problems.append("%s: the recommendation needs a known decision and scope" % where)
            for vote in record["votes"]:
                check_date(vote["date"], where + " vote date")
                if vote["reviewer"] not in policy["reviewers"]:
                    problems.append("%s: vote by %s, who is not a reviewer in policy.json" % (where, vote["reviewer"]))
                if vote["decision"] not in DECISIONS or not set(vote.get("scope", [])) <= set(SCOPES):
                    problems.append("%s: a vote has an unknown decision or scope" % where)
                if policy["quorum"] > 1 and vote["reviewer"] == record["prepared_by"]:
                    problems.append("%s: %s both prepared and voted; a council must keep those apart" % (where, vote["reviewer"]))
        except (ReviewError, KeyError) as error:
            problems.append("%s: %s" % (where, error))
    if problems:
        return problems
    path = os.path.join(root, "registry.json")
    if not os.path.exists(path):
        return problems + ["registry.json does not exist; run: lib/allowlist_review.py build"]
    registry = read_json(path)
    if registry.get("format") != REGISTRY_FORMAT:
        problems.append("registry.json: format must be %s" % REGISTRY_FORMAT)
    listed = {}
    for key in ("approved", "pending", "declined"):
        for entry in registry.get(key, []):
            if entry["domain"] in listed:
                problems.append("registry.json: %s is in both %s and %s" % (entry["domain"], listed[entry["domain"]], key))
            listed[entry["domain"]] = key
    for entry in registry.get("approved", []):
        record = current.get(entry["domain"])
        status = status_of(record, requests[record["request"]], policy) if record else ("missing", [], [])
        if status[0] != "approved" or status[1] != entry.get("scope"):
            problems.append("registry.json: %s is approved without enough reviewer votes for that scope" % entry["domain"])
    if not problems:
        try:
            if build_registry(root)[1]:
                problems.append("registry.json is out of date; run: lib/allowlist_review.py build")
        except ReviewError as error:
            problems.append(str(error))
    return problems


def command_validate(args):
    problems = validate(args.root)
    for problem in problems:
        print("problem: " + problem, file=sys.stderr)
    if problems:
        return 1
    print("allowlist: requests, decisions, and registry are consistent")
    return 0


# --- publish -----------------------------------------------------------------------------

def command_publish(args):
    policy = load_policy(args.root)
    if not args.staging:
        if args.confirmed_by not in policy["reviewers"]:
            raise ReviewError("a public publish needs --confirmed-by naming a reviewer in policy.json; "
                              "use --staging to rehearse")
    problems = validate(args.root)
    if problems:
        raise ReviewError("validate found problems; fix them before publishing:\n  " + "\n  ".join(problems))
    with open(os.path.join(args.root, "registry.json"), "rb") as handle:
        content = handle.read()
    version = json.loads(content)["version"]
    digest = hashlib.sha256(content).hexdigest()
    versioned = os.path.join(args.dest, "versions", "registry-v%d.json" % version)
    if os.path.exists(versioned):
        with open(versioned, "rb") as handle:
            if handle.read() != content:
                raise ReviewError("%s was already published with different content; build a new version" % versioned)
    current_path = os.path.join(args.dest, "registry.json")
    if os.path.exists(current_path):
        published = json.loads(open(current_path, "rb").read())["version"]
        if published > version:
            raise ReviewError("%s already holds version %d, newer than %d" % (current_path, published, version))
    os.makedirs(os.path.dirname(versioned), exist_ok=True)
    for path, data in (
        (versioned, content),
        (versioned + ".sha256", ("%s  registry-v%d.json\n" % (digest, version)).encode()),
        (current_path, content),
        (current_path + ".sha256", ("%s  registry.json\n" % digest).encode()),
    ):
        with open(path, "wb") as handle:
            handle.write(data)
    print("published version %d to %s%s" % (version, args.dest, " (staging)" if args.staging else ""))
    print("sha256 %s" % digest)
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="allowlist_review.py", description=__doc__.split("\n")[0])
    parser.add_argument("--root", default=default_root(), help="the allowlist folder")
    sub = parser.add_subparsers(dest="command", required=True)

    request = sub.add_parser("request")
    request.add_argument("--domain", required=True)
    request.add_argument("--requested-by", required=True)
    request.add_argument("--case", required=True)
    request.add_argument("--risk")
    request.add_argument("--link", action="append")
    request.add_argument("--date")

    prepare = sub.add_parser("prepare")
    prepare.add_argument("request")
    prepare.add_argument("--prepared-by", required=True)
    prepare.add_argument("--date")

    sub.add_parser("queue")

    sheet = sub.add_parser("sheet")
    sheet.add_argument("decision")

    vote = sub.add_parser("vote")
    vote.add_argument("decision")
    vote.add_argument("--reviewer", required=True)
    vote.add_argument("--decision", dest="decision_value", required=True, choices=DECISIONS)
    vote.add_argument("--scope", action="append", choices=SCOPES)
    vote.add_argument("--note")
    vote.add_argument("--date")

    build = sub.add_parser("build")
    build.add_argument("--check", action="store_true")

    sub.add_parser("validate")

    publish = sub.add_parser("publish")
    publish.add_argument("--dest", required=True)
    group = publish.add_mutually_exclusive_group(required=True)
    group.add_argument("--staging", action="store_true")
    group.add_argument("--confirmed-by")

    args = parser.parse_args(argv)
    handlers = {
        "request": command_request,
        "prepare": command_prepare,
        "queue": command_queue,
        "sheet": command_sheet,
        "vote": command_vote,
        "build": command_build,
        "validate": command_validate,
        "publish": command_publish,
    }
    try:
        return handlers[args.command](args) or 0
    except ReviewError as error:
        print("error: %s" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
