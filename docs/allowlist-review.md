# Site allowlist review

Status: built 2026-10-11, held for Jose's review. The registry is empty: nothing is approved.

A sirven node in the Neighborly or Co-op tier carries other sirven users' personal-agent traffic,
but only to sites on the allowlist. This document is the rubric and the workflow a human reviewer
runs to put a site on that list, and the format of the public registry that results. It is one of
the two components named in the first ship gate: no peer routing of authenticated traffic ships
until this workflow and the attestation layer both work end to end.

The tool is `lib/allowlist_review.py`. The records live in `allowlist/`.

## Roles

| Role | Who | Does |
|---|---|---|
| Requester | a sirven user, sirven itself, or the site's operator | asks for a site to be reviewed |
| Preparer | anyone, including an agent | researches the site and drafts the rubric findings and a recommendation |
| Reviewer | the names in `allowlist/policy.json` | reads the review sheet and votes. Only votes decide |

Jose Sirven is the only reviewer for the first six months (his decision of 2026-10-11), so the
quorum is one. Every decision record names who prepared it, apart from who voted. With a single
reviewer, Jose may prepare and vote on the same review, so the whole workflow runs end to end
with one person. Once a council takes over (quorum above one), the preparer of a review does not
vote on it: `vote` refuses and `validate` flags it. An agent may prepare a review. An agent never
votes.

**Reviewer identity rests on process alone for now.** A vote records a reviewer's name as typed,
and anyone with write access to the repository could type Jose's name. On this machine even the
agent's commits carry Jose's git identity. Until votes are signed (a dependency on the
attestation work, see Publication), the safeguards are that only Jose runs `vote`, that votes
arrive in commits he makes himself, and that every vote is public in the registry history.

## The workflow, end to end

A reviewer with a prepared request needs a few minutes: read one sheet, run one command.

1. **Intake.** One record per request:

   ```
   lib/allowlist_review.py request --domain waymo.com --requested-by sirven_user \
     --case "why a personal agent acting for one person legitimately needs this site" \
     --risk "anything the requester already knows" \
     --link terms=https://... --link statement=https://... --link enforcement=https://...
   ```

   `--requested-by` is one of `sirven_user`, `sirven`, or `site_operator`. Link kinds are
   `terms`, `statement`, `enforcement`, `robots`, and `other`. The record lands in
   `allowlist/requests/`.

2. **Preparation.** `lib/allowlist_review.py prepare REQUEST --prepared-by NAME` writes a decision
   record skeleton in `allowlist/decisions/`. The preparer reads the site's own public positions
   (terms, robots.txt, public statements, enforcement history), fills in a rating and a finding
   for each rubric question below, and writes a recommendation: a decision (`approve`,
   `decline`, or `defer`), a scope, and a one-paragraph rationale. Every finding names its source
   and the date it was read. Anything not read at the primary source says so.

3. **Review.** `lib/allowlist_review.py queue` lists what is waiting. `lib/allowlist_review.py
   sheet DECISION` prints the whole review on one screen: the case, the sources, the three
   findings, the recommendation, and the exact vote commands. The reviewer may follow the
   recommendation or not.

4. **Vote.**

   ```
   lib/allowlist_review.py vote DECISION --reviewer "Jose Sirven" --decision approve --scope public_pages
   lib/allowlist_review.py vote DECISION --reviewer "Jose Sirven" --decision decline --note "why"
   lib/allowlist_review.py vote DECISION --reviewer "Jose Sirven" --decision defer --note "what is missing"
   ```

   An approval needs at least one scope, a finding for every rubric question, and the notice
   period to have passed.

5. **Build and check.** `lib/allowlist_review.py build` regenerates `allowlist/registry.json`,
   then `lib/allowlist_review.py validate` checks everything. The reviewer commits the records
   and the registry together.

## The rubric

Each question gets a rating, `pass`, `concern`, `fail`, or `unknown`, and a written finding with
its sources.

**1. Legitimate personal-agent use.** Is this a site where a personal agent acting for one
individual user is a legitimate use? The test is whether the user could do the same thing
themself, at human pace, for their own purposes: book their own ride, buy their own groceries,
read a public schedule. Resale, bulk data gathering, ticket scalping, and anything done for
someone other than the user fail this question no matter what the site says.

**2. Risk to peer operators.** Is the risk acceptable for the person whose home connection
carries the traffic? The site sees the operator's network address, not the requester's. Ask
what happens to that operator if the site objects: a blocked address for their own use of the
site, an account flag, or a legal claim. Public pages without a login usually carry little risk.
Authenticated sessions carry the requester's account and are judged separately.

**3. The site's own position.** Does the site's own position suggest it would treat
personal-agent traffic from residential peers as abuse? Read the terms (clauses on robots,
automated means, third-party applications, account sharing, acting for others), robots.txt, any
public statement on agents, and any enforcement history: lawsuits, cease and desist letters,
published blocking. A supportive public statement counts; so does a lawsuit.

### From ratings to a decision

- Any `fail` means decline, for every scope.
- `unknown` on any question means defer; the tool refuses an approval until every question has
  a finding.
- `concern` on questions 2 or 3 limits the scope: approve `public_pages` only, or defer until
  the concern is resolved (usually by the site's written consent).
- `authenticated_sessions` is approved only with `pass` on all three questions. It is the scope
  the ship gate is about.

These are the rules the preparer recommends by. The reviewer's vote is the decision.

## Growth limits

Growth of the list is curated and legible, never quiet or fast. Two numbers in
`allowlist/policy.json` enforce it, and both are proposals awaiting Jose's confirmation:

- `notice_days` (proposed: 7): an approval counts only on or after this many days after the
  request was received. Each new request enters the registry's `pending` list at the next build,
  so once the registry is published, operators can see a site coming before they can be asked to
  carry it. The period counts from the request date, not from a publish date, so the reviewer
  should publish the registry soon after accepting a request.
- `max_additions_per_version` (proposed: 3): `build` refuses a registry version that approves
  more sites than this at once.

Nothing changes quietly: every change to the registry content raises the version by one and adds
a history entry naming each domain added to, removed from, or changed in each list.

## Removing a site

Records are append-only. To remove or narrow a site, file a new request (a site operator asking
to be removed uses `--requested-by site_operator`), prepare a new decision, and vote `decline`
or approve a narrower scope. The new decision supersedes the old one; votes on a superseded
decision are refused. The registry history records the removal.

## Registry format and matching rules

`allowlist/registry.json`, format `sirven-allowlist-registry/1`:

| Field | Meaning |
|---|---|
| `version` | whole number, up by one on every content change |
| `updated` | date of the newest record behind this version |
| `reviewers`, `quorum` | from the policy in force |
| `approved` | the only list a node may carry for. Starts empty |
| `pending` | under review, with the preparer's recommendation. Never carried |
| `declined` | refused, with the reviewer's reason. Never carried |
| `history` | one entry per version: date and the domains added, removed, or changed per list |

Each entry has `domain`, `includes_subdomains`, `decision_record` (a path under `allowlist/`),
`requested`, and `rationale`. Approved entries add `scope`, `reviewed`, and `reviewers`.

Matching rules, for the local policy engine:

- `domain` is a lowercase host name in punycode, with no scheme, port, path, wildcard, or
  trailing dot, and with a leading `www.` label dropped: `www.zillow.com` is recorded as
  `zillow.com`. Normalize the requested host the same way before comparing, so a request to
  `www.zillow.com` matches the entry `zillow.com`.
- `includes_subdomains: false` matches that exact host only. `true` matches the host and every
  subdomain. Every entry so far is `false`; a reviewer widens it by editing the decision record
  before voting.
- `scope` lists what may be carried: `public_pages` (requests without the user's login) and
  `authenticated_sessions` (requests carrying the user's session). Carry a request only when its
  kind is in the scope.
- Read only `approved`. A domain in `pending` or `declined` is never carried. `validate` refuses
  a registry where a domain appears in two lists, or where an approved entry lacks enough
  reviewer votes for its scope.

## Publication

`lib/allowlist_review.py publish --dest DIR` copies the registry to a folder laid out for a static
host:

```
DIR/registry.json             the current version
DIR/registry.json.sha256
DIR/versions/registry-vN.json every published version, kept forever
DIR/versions/registry-vN.json.sha256
```

Each `.sha256` file holds the file's SHA-256 checksum (a fingerprint of its exact bytes), so an
operator can confirm the copy they fetched is the one published. It refuses to publish when `validate` finds a problem, refuses to overwrite a published version
with different content, and refuses to replace a newer version with an older one.

- `--staging` publishes anywhere for rehearsal.
- A public publish needs `--confirmed-by` naming a reviewer in the policy. The first public
  publish is held for Jose: the agent that built this does not run it.

The public location is Jose's call. The proposal is a static site, such as GitHub Pages for this
repository, so operators can fetch `registry.json` and check it against its checksum. Until the attestation layer exists, the
checksum proves integrity in transit only. Two signatures are dependencies on the attestation
work: each reviewer's vote, so a vote proves who cast it, and each registry version, so a node can
prove the copy it fetched came from sirven. The policy engine should verify the version signature
once it exists.

The `allowlist/` folder is not in the npm package's files list on purpose: nodes fetch the
published registry rather than trusting whatever copy shipped with the installer.

## Handing over to a council

A council takes over by editing `allowlist/policy.json`: add the reviewers' names and raise
`quorum`. Nothing else changes. With a quorum above one, an approval needs that many approving
votes, and the approved scope is the scope every approving vote shares. Each reviewer's newest
vote counts.
