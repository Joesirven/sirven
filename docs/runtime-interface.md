# runtime interface

the sirven runtime carries the personal agent's web requests out through the user's own
connection, in Solo, and reports every refusal honestly. this document is the contract other
components build against: the policy engine plugs into the seam, the usage meter reads the
decision log, the tier dial reads and sets the tier. the code is `lib/sirven_runtime/`, and
`tests/unit/test_runtime.sh` checks that every endpoint the runtime serves is named here.

interface version: `1`. every response carries `"version": 1`.

## what works today

- Solo, and only Solo. Neighborly and Co-op are refused at the seam and at `PUT /v1/tier`.
  peer routing is not built: no request is ever carried for another person, and no request of
  the user's is ever sent through anyone else.
- macOS, Apple Silicon and Intel: `make runtime` builds one helper binary for both.
- every egress decision is made on the machine, without a network call.
- a block is a result. the runtime never retries a refused or blocked request, and never
  chooses another path around it.

## starting it

```sh
make runtime                 # macos: builds dist/runtime/sirven-fetch, the fetch helper
sirven runtime serve         # runs in the foreground on 127.0.0.1:47290
sirven runtime status
sirven runtime fetch https://example.com/
sirven runtime exec -- curl https://example.com/     # any program, through the proxy
```

`serve` options: `--port` (0 picks a free port), `--settings FILE`, `--fetcher auto|helper|python`,
`--helper PATH`, `--policy module:factory`. every command takes `--state-dir`.

the state folder, mode 0700, holds:

| file | what it is |
|---|---|
| `runtime.json` | where the runtime listens: `address`, `port`, `pid`, `token_file`, `started_at`. written at start, removed at stop |
| `token` | the runtime token, mode 0600. created once, kept across restarts |
| `decisions.jsonl` | the decision log, mode 0600 (below) |

the default state folder is `~/Library/Application Support/sirven/runtime` on macos and
`$XDG_STATE_HOME/sirven/runtime` (or `~/.local/state/sirven/runtime`) elsewhere.

## who may talk to it

- the runtime listens on `127.0.0.1` only. there is no option to listen anywhere else.
- every call needs the token. the control interface takes `Authorization: Bearer <token>`.
  the proxy takes the token as the proxy password: `http://sirven:<token>@127.0.0.1:47290`.
  `sirven runtime exec` sets this up for a child process without printing the token.
- the control interface refuses any request with an `Origin` header (a web page in a
  browser), and any `Host` other than `127.0.0.1:<port>` or `localhost:<port>`.
- a component that runs as another account (the `agent` service user, for example) needs read
  access to the token file. granting it is the owner's choice.

## two ways for an agent to send a request

| | the fetch endpoint | the proxy |
|---|---|---|
| how | `POST /v1/fetch` with the URL | `HTTPS_PROXY` and `HTTP_PROXY` set to the runtime |
| what the runtime sees | the method, the URL, the site's answer | for https: only the host and port (`CONNECT`). for plain http: everything |
| a site's block | classified: `blocked_by_site` with the kind and evidence | https: invisible inside the encrypted tunnel; the agent sees the site's own answer. plain http: marked with `X-Sirven-Outcome` |
| a policy refusal | `refused_by_policy` with the reason | a 403 with the same JSON record and `X-Sirven-Reason` |
| approval for actions | enforced (below) | https: cannot be enforced, the method is encrypted. plain http: enforced through `X-Sirven-Approval` |
| fingerprint | the fetch helper's (below) | the agent's own HTTP client |

the fetch endpoint is the full path: use it whenever the agent can. the proxy exists for
tools that only know proxies.

## the control interface

### GET /v1/status

```json
{
  "version": 1,
  "tier": "solo",
  "tiers_available": ["solo"],
  "peer_routing": "not_built",
  "egress": "own_connection",
  "fingerprint": "apple-urlsession",
  "policy": "solo",
  "listening": {"address": "127.0.0.1", "port": 47290},
  "started_at": "2026-10-11T23:59:00Z",
  "decision_log": "/Users/name/Library/Application Support/sirven/runtime/decisions.jsonl",
  "outcomes": {"ok": 12, "blocked_by_site": 1, "refused_by_policy": 2},
  "platform": "Darwin arm64",
  "peer_routing_available": false,
  "last_block": {"version": 1, "outcome": "blocked_by_site", "block_kind": "challenge", "status": 403,
                 "route": "local", "reason": "own_connection", "host": "tickets.example",
                 "at": "2026-10-11T16:42:00Z"}
}
```

`peer_routing_available` is `lib/peer_routing.py readiness` for the `peer-routing` folder inside
the state folder. it is true only when the attestation layer is configured with a current
revocation list, a signed site-allowlist registry version is installed and current with at
least one approved site, and the peer transport is built. the transport is not built, so it
is false today on every machine. the tier dial reads it to decide whether Neighborly can be
offered.

`last_block` is the latest read a site refused (`blocked_by_site`) since the runtime started,
or `null`: host and time only, never a path. the consent moment opens on it.

`outcomes` counts results since this runtime started.

### POST /v1/fetch

the runtime makes one request for the agent and returns its result.

```json
{
  "url": "https://example.com/",
  "method": "GET",
  "headers": {"Accept-Language": "en-US"},
  "body_base64": null,
  "approval": null,
  "follow_redirects": true,
  "timeout_seconds": 30,
  "max_bytes": 5000000
}
```

only `url` is required. `timeout_seconds` is capped at 120 and `max_bytes` at 5000000.
`approval` is the agent's reference to the user's approval of this action, such as the
identifier of the agent's own approval prompt. the runtime records it in the decision log and
cannot verify it: asking the user is the agent's job, and the runtime refuses an action that
arrives without one.

the answer is always HTTP 200 with a result record when the runtime produced a result, and
the outcome is in the record and in the `X-Sirven-Outcome` header. a malformed request gets a
4xx with `{"outcome": "invalid_request", "error": {...}}`.

### the result record

```json
{
  "version": 1,
  "outcome": "blocked_by_site",
  "url": "https://shop.example/item",
  "redirects": [{"url": "https://shop.example/old", "status": 301}],
  "attempts": 1,
  "egress": "own_connection",
  "fingerprint": "apple-urlsession",
  "decision": {"route": "local", "reason": "own_connection", "message": "Sent from your own connection.",
               "policy": "solo", "details": {}},
  "status": 403,
  "headers": {"cf-mitigated": "challenge"},
  "body_base64": "PHRpdGxlPkp1c3QgYSBtb21lbnQuLi48L3RpdGxlPg==",
  "truncated": false,
  "block": {"kind": "challenge", "status": 403, "evidence": ["header cf-mitigated"],
            "message": "The site answered with a bot check instead of the page. The runtime did not try another way around it."},
  "error": null
}
```

| field | meaning |
|---|---|
| `outcome` | one of the outcomes below |
| `url` | the last URL tried, after redirects |
| `redirects` | each hop followed, with its status |
| `attempts` | always 1. nothing is retried |
| `egress` | `own_connection` when anything was sent, `null` when nothing was |
| `fingerprint` | `apple-urlsession` (the helper) or `python-standard-library` (the fallback) |
| `decision` | the seam's decision for the last hop: `route`, `reason`, `message`, `policy`, `details` |
| `status`, `headers` | the site's answer. header names are lowercase. the helper hands back the decoded page, so `content-encoding` and `content-length` are dropped |
| `body_base64`, `truncated` | the page, base64, cut at `max_bytes` |
| `block` | for `blocked_by_site`: `kind`, `status`, `evidence`, `message`, and `retry_after` when the site sent one |
| `error` | for `network_error` and `invalid_request`: `kind` and `message` |

| outcome | meaning |
|---|---|
| `ok` | the site answered. any status that is not a block, including 404 |
| `blocked_by_site` | the site refused the agent. kinds: `challenge` (a bot check: a 403 or 503 with a known marker, or a 200 or 202 carrying `cf-mitigated`), `rate_limited` (429), `forbidden` (a 403 with no marker), `unavailable_for_legal_reasons` (451) |
| `refused_by_policy` | the seam refused, and nothing was sent for this hop. the reason is in `decision` |
| `network_error` | the site could not be reached. kinds: `timeout`, `name_not_found`, `connection_refused`, `connection_lost`, `offline`, `secure_connection_failed`, `certificate_untrusted`, `certificate_required`, `network_error`, `runtime_error` |
| `too_many_redirects` | more than 10 redirects |
| `invalid_request` | the URL could not be read |

redirects: the runtime follows them itself, and every hop goes back through the seam, so a
redirect to a refused site stops there. `Authorization` and `Cookie` headers are dropped
when a redirect leaves the original host.

### POST /v1/classify

the seam's decision for a URL, with nothing sent. for the tier dial and for policy testing.

```json
{"url": "https://shop.example/", "method": "GET", "channel": "fetch"}
```

answers `{"version": 1, "decision": {...}, "sent": false}`. it writes nothing to the log.
the connect-time guard (below) is not run, since it needs a name lookup.

### GET /v1/decisions?after=N&limit=M

decision log entries with `sequence` greater than `after` (default 0), at most `limit`
(default 100, at most 1000), from the most recent 1000 kept in memory. answers
`{"version": 1, "decisions": [...], "next_after": N}`: pass `next_after` back to read on.
sequence numbers start again at 1 when the runtime restarts; the file keeps everything.

### GET /v1/tier and PUT /v1/tier

`GET /v1/tier` answers `{"version": 1, "tier": "solo", "tiers_available": ["solo"]}`.
`PUT /v1/tier` with `{"tier": "solo"}` answers the same. any other tier answers 409 with
`"error": {"kind": "tier_not_available", ...}`, and the tier stays Solo. tiers move past Solo
only when the attestation layer and the site-allowlist review workflow work end to end.

## the proxy

point an HTTP client at `http://sirven:<token>@127.0.0.1:<port>`.

- `CONNECT host:port` (https): the seam decides on the host and port. allowed: `200
  Connection Established` with `X-Sirven-Outcome: tunnel_open`, then bytes are piped both ways
  until either side closes or 300 seconds pass idle. refused: a 403 with the result record
  as JSON and `X-Sirven-Outcome: refused_by_policy` and `X-Sirven-Reason: <reason>`. most
  clients report this as "CONNECT tunnel failed, response 403". unreachable: a 502 with a
  `network_error` record.
- an absolute `http://` URL: sent through the fetcher without following redirects, so the
  client follows them. the answer is the site's own status, headers, and page, plus
  `X-Sirven-Outcome` (`ok` or `blocked_by_site`) and, for a block, `X-Sirven-Block-Kind`.
  to send an action, add `X-Sirven-Approval: <reference>`; the runtime removes it before sending.
- no token: 407 with `Proxy-Authenticate`.

## the decision log

`decisions.jsonl`, one JSON object per line, one line per hop. usage metadata only: never
a path, a query, a header, or any content.

```json
{"approval": null, "block_kind": null, "bytes_received": 1256, "bytes_sent": 0, "channel": "fetch",
 "host": "example.com", "method": "GET", "outcome": "ok", "policy": "solo", "port": 443,
 "reason": "own_connection", "redirect_hop": 0, "route": "local", "sequence": 7, "status": 200,
 "tier": "solo", "time": "2026-10-11T23:59:30Z"}
```

| field | meaning |
|---|---|
| `channel` | `fetch`, `tunnel`, or `forward` (plain http through the proxy) |
| `host`, `port` | the site |
| `method` | `null` on the tunnel, where it is encrypted |
| `route`, `reason`, `policy` | the seam's decision |
| `outcome` | the result outcome, or `redirected` for a hop that led to another, or `tunnel_closed` for a finished tunnel |
| `status`, `block_kind` | the site's status and the block kind, when there is one |
| `approval` | the approval reference the agent sent, if any |
| `bytes_sent`, `bytes_received` | on the tunnel: every byte each way. on fetch and forward: the request and response bodies |

the usage meter reads byte counts from here. Solo has no cap, since nothing is carried for
anyone; the reciprocity ledger applies once peer routing exists.

## the seam

`lib/sirven_runtime/seam.py`. every request on every channel, and every redirect hop, passes
through `decide(request, policy)` exactly once before anything is sent. this is the one place
a route is chosen, and the place a peer-routing decision slots in later.

```python
EgressRequest(host, port, scheme, channel, method=None, tier="solo",
              approval=None, signed_envelope=None, redirect_hop=0)
Decision(route, reason, message, policy="unknown", details={})
```

- `route` is `local` (send from the user's own connection), `peer` (carry through, or for,
  another person), or `refuse`.
- `reason` is a stable code; `message` is one plain sentence a person can read.
- `decide()` never raises. a policy that raises, or answers something that is not a
  `Decision`, refuses with `policy_error`.
- `decide()` turns any `peer` answer into a refusal, `peer_routing_not_built`, and refuses
  any request with a `signed_envelope`, `peer_traffic_refused`. that is the ship gate in code:
  nothing is carried for anyone until the attestation layer and the site-allowlist review
  workflow both work end to end. when they do, this is the line that changes, and the
  request already has the field the envelope arrives in.

after the seam says `local`, a connect-time guard looks up the name and refuses
(`local_network`, policy `connect_guard`) if it points into the local network. the seam itself
makes no network call.

### plugging in a policy engine

```sh
sirven runtime serve --policy my_module:make_policy
```

`make_policy(settings)` is called once with the Solo settings and returns an object with a
`name` attribute and a `classify(request)` method that takes an `EgressRequest` and returns a
`Decision`. the module must be importable: put it in `lib/` or on `PYTHONPATH`.

a policy engine that keeps every Solo rule should call `SoloPolicy(settings).classify(request)`
first and return its refusal when there is one. the allowlist policy engine's own request
type (domain, tier, whether it is peer-carried, the verified attestation) maps from
`EgressRequest` this way: `domain` is `host`, the tier is `tier` capitalized, `peer_carried`
is `signed_envelope is not None`.

### the Solo policy and its settings

`lib/sirven_runtime/policy.py`. refusal reasons, in the order they are checked:

| reason | when |
|---|---|
| `tier_not_available` | the tier is not Solo |
| `peer_traffic_refused` | the request carries an envelope |
| `scheme_not_allowed` | not http or https |
| `no_host` | no host |
| `port_not_allowed` | the port is not in `allowed_ports` |
| `local_network` | `localhost`, a `.local` or `.localhost` name, or a loopback, private, or link-local address, unless listed in `allow_private_hosts` |
| `blocked_by_owner` | the host is, or is under, a domain in `blocked_domains` |
| `approval_required` | on fetch and forward: the method is in `approval_methods` and no approval came with it |

anything else: `local`, reason `own_connection`. the seam adds `unknown_tier`,
`unknown_channel`, `policy_error`, `peer_routing_not_built`, and `peer_traffic_refused`.

the settings file, all fields optional, unknown fields rejected:

```json
{
  "blocked_domains": [],
  "allowed_ports": [80, 443],
  "allow_private_hosts": [],
  "approval_methods": ["POST", "PUT", "PATCH", "DELETE"]
}
```

## the fingerprint, honestly

what a site sees on the fetch endpoint with the helper built:

- the address: the user's own connection. the helper ignores system and environment proxy
  settings. if the machine itself sends everything through a virtual private network or a
  Tailscale exit node, that is where traffic leaves; the runtime does not change Tailscale
  settings and does not detect them yet.
- the encryption handshake and HTTP version: Apple's own networking stack (`URLSession`),
  the system stack Safari is built on. it has not been compared byte for byte with Safari's
  handshake.
- the headers: Safari's user agent with the installed Safari version, Safari's `Accept`, and
  `Accept-Language` from the user's language preferences. the agent's own headers win.
- no cookies, no cache, no JavaScript. a site whose bot check needs JavaScript answers with
  that check, and the runtime reports it as `blocked_by_site`, kind `challenge`.

without the helper (not macos, or not built) the fetcher is the Python standard library, and
`fingerprint` says `python-standard-library`. on the proxy's tunnel the fingerprint is
whatever the agent's own HTTP client presents.

## not built yet

- Windows; launching at login; a menu bar control (the menu bar app owns that surface).
- peer routing, Neighborly, and Co-op, by design (above).
- verifying an approval reference: it is recorded, not checked.
- enforcing approval on https through the proxy: the method is encrypted. agents that act
  should use the fetch endpoint.
- detecting a block inside an https tunnel.

## changes to this interface

within version 1, fields and endpoints may be added and new reason codes and outcomes may
appear; clients should treat unknown ones as opaque. removing or renaming a field, changing
what a field or a code means, or changing a status code needs version 2.
