# Reciprocity accounting

Neighborly lends a little of your connection to other sirven users' personal agents, and borrows a
little of theirs. This document is the contract for how that is counted on your device, how the cap is
enforced, how the usage meter reads it, and how two devices that share one transfer agree on its size.

Reciprocity is measured in bytes. Nothing here is money: there is nothing to buy, earn, or pay off.

The code is `lib/reciprocity.py` (Python standard library only). Tests are
`tests/unit/test_reciprocity.sh`, and `tests/fixtures/usage_meter_consumer.py` is a test consumer that
reads only the shapes documented below.

## The cap

- **5 gigabytes per person per month, symmetric.** Bytes your device carries for others and bytes your
  agent sends through others count against the same single cap. 5 gigabytes is decimal:
  5,000,000,000 bytes.
- **Solo has no peer allowance.** In Solo, every carry and every send through a peer is refused.
- **Co-op's cap is not decided yet.** Jose's scope says Co-op has "higher caps" without a number. Until
  Jose sets one, Co-op uses the Neighborly cap of 5 gigabytes. The number lives in one place,
  `TIER_CAPS` in `lib/reciprocity.py`, and can also be overridden per call with `--cap-bytes`.
- **The month is a calendar month in the device's own time zone.** Usage resets at midnight on the first
  of the month, local time, so "resets November 1" in the meter is literally true for the person reading
  it. Two devices in different time zones close their months at different moments; reconciliation
  matches records by transfer, never by month, so that difference is harmless.

## What counts as a byte

A counted byte is a byte of the inner stream between the requesting agent and the allowlisted site, in
either direction: request bytes going out plus response bytes coming back. It is measured at the edge
of the peer tunnel on each device:

- the device that sends counts bytes it writes into the tunnel and bytes it reads out of it;
- the device that carries counts bytes it reads from the tunnel and forwards to the site, plus bytes it
  reads from the site and writes back into the tunnel.

The peer link's own framing, encryption, and retransmissions are not counted. With that definition both
devices measure the same stream, so their counts should be identical apart from bytes still in flight
when a session is cut off. That is what makes the reconciliation tolerance below meaningful instead of
arbitrary.

## What is stored, and what never is

The ledger is an append-only file of JSON lines at `$SIRVEN_STATE_DIR/reciprocity/ledger.jsonl`
(the default state folder is `~/.sirven`). Each line is usage metadata only:

| field | meaning |
| --- | --- |
| `kind` | `transfer`, `reservation` (a passing sized check), `refusal`, or `disagreement` (written by `reconcile`) |
| `direction` | `carried` (you carried it for someone) or `sent` (your agent sent it through someone) |
| `bytes` | an integer count of bytes, as defined above |
| `domain` | a bare host name at the granularity the published allowlist uses, such as `example.com` |
| `session` | an opaque session reference chosen by the runtime |
| `transfer` | an opaque transfer reference both devices share for the same transfer |
| `peer` | an opaque peer reference, such as a key fingerprint from the attestation envelope |
| `at` | the time, in seconds since 1970, as an integer |
| `reason` | refusals only: a plain-language sentence |
| `status`, `our_bytes`, `their_bytes` | disagreements only: what reconciliation found |

Never stored: content, URLs, paths, query strings, headers, cookies, or anyone's real identity. The
ledger refuses a domain that is not a bare host name (anything with a slash, `?`, `#`, `@`, `:`, or a
space), so a full URL cannot slip in by accident. The peer reference is whatever opaque string the
attestation envelope exposes; with identity-attested users at first ship it is still a key fingerprint,
never a name, which also lets a pseudonymous posture slot in later without changing this file.

Retention: `prune` keeps the current month and the previous one (the previous month stays for late
reconciliation) and drops everything older.

## Enforcement hook (for the policy engine)

The policy engine calls the hook before it agrees to carry or route. The hook answers one question,
"is this within the cap?", and nothing else. It is not permission to carry: the allowlist, the
attestation envelope, the tier, and the ship gate are the policy engine's decisions, and a `within_cap`
answer of true never overrides a refusal from any of them.

```
python3 lib/reciprocity.py check --direction carried|sent --tier solo|neighborly|co-op \
    --domain example.com --session S --peer P [--bytes N]
```

`--domain` is the allowlist entry the policy engine matched, not the host the agent asked for: if the
registry publishes `example.com` and the agent reached `accounts.example.com`, pass `example.com`. That
keeps the ledger at the granularity the allowlist already publishes. The ledger itself cannot check
this without the registry (thread 05), so it is the caller's duty.

`--bytes` is the size the caller expects, when it knows it. Without it, the hook asks "is there any room
left at all", and the answer's `remaining_bytes` tells the caller where to cut the stream off.

The answer is one JSON object on standard output:

```json
{
  "schema_version": 1,
  "within_cap": false,
  "direction": "sent",
  "tier": "neighborly",
  "requested_bytes": 4000000000,
  "used_bytes": 1250000000,
  "reserved_bytes": 0,
  "cap_bytes": 5000000000,
  "remaining_bytes": 3750000000,
  "reason": "Sending this through a neighbor would go past your 5 gigabyte monthly cap: 1.25 gigabytes used this month, and 4 gigabytes more requested. Usage resets November 1."
}
```

The exit status mirrors the answer: 0 when within the cap, 3 when over it, 2 for a malformed call.
`reason` is null when the answer is within the cap. A request that lands exactly on the cap is within
it; one byte past it is not. A check with no `--bytes` is within the cap while at least one byte is
left. Every refusal is
appended to the ledger with its reason, so the meter can show it and the person can see why.

**Reservations.** A sized check that passes appends a `reservation` for its bytes, under the same file
lock as the check itself, so two sessions cannot both pass against the same headroom. A reservation
holds its bytes until a `record` for the same session is written, or for one hour if none ever is (a
crashed session does not hold headroom forever). `reserved_bytes` in the answer is everything currently
held, this check included, and `remaining_bytes` is what is left after it: `cap_bytes` minus
`used_bytes` minus `reserved_bytes`. A check without `--bytes` cannot reserve a size it does not know,
so two sizeless checks can both pass and together overshoot; the runtime should send a size whenever it
has one, and cut a sizeless stream off at `remaining_bytes`.

After a transfer, the runtime records what was actually moved:

```
python3 lib/reciprocity.py record --direction carried|sent --bytes N --domain example.com \
    --session S --transfer T --peer P
```

A carry that the check let through is never cut short by the ledger itself: the runtime is expected to
stop at `remaining_bytes`, and `record` writes the true count even if a session overran by bytes in
flight, because an honest ledger matters more than a tidy one. The next check will refuse.

## Read-out (for the usage meter)

```
python3 lib/reciprocity.py read [--tier neighborly]
```

prints one JSON object. Every count is an integer number of bytes; times are seconds since 1970. This
example is real output for a person in San Francisco on October 15, 2026, who carried 800 megabytes,
sent 450, and then had a 4 gigabyte send refused:

```json
{
  "schema_version": 1,
  "tier": "neighborly",
  "period": {"label": "October 2026", "starts_at": 1790838000, "resets_at": 1793516400, "resets_on": "November 1"},
  "cap_bytes": 5000000000,
  "used_bytes": 1250000000,
  "carried_bytes": 800000000,
  "sent_bytes": 450000000,
  "reserved_bytes": 0,
  "remaining_bytes": 3750000000,
  "percent_used": 25,
  "summary": "You have used 1.25 gigabytes of your 5 gigabyte monthly cap: 800 megabytes carried for neighbors and 450 megabytes sent through neighbors. Resets November 1.",
  "sessions": [
    {"session": "s2", "direction": "sent", "domain": "example.org", "bytes": 450000000,
     "first_at": 1792090860, "last_at": 1792090860,
     "summary": "Sent 450 megabytes to example.org through a neighbor."},
    {"session": "s1", "direction": "carried", "domain": "example.com", "bytes": 800000000,
     "first_at": 1792090800, "last_at": 1792090800,
     "summary": "Carried 800 megabytes to example.com for a neighbor."}
  ],
  "refusals": [
    {"session": "s3", "direction": "sent", "domain": "example.org", "requested_bytes": 4000000000,
     "at": 1792090920,
     "reason": "Sending this through a neighbor would go past your 5 gigabyte monthly cap: 1.25 gigabytes used this month, and 4 gigabytes more requested. Usage resets November 1."}
  ],
  "disagreements": [],
  "stop_pairing_with": []
}
```

Sessions are grouped by session, direction, and domain, and listed newest first. Refusals are newest
first. `disagreements` lists transfers that reconciliation flagged this month, and `stop_pairing_with`
lists peer references with three or more of them (see below). `used_bytes` counts finished transfers only; `reserved_bytes` is headroom held by transfers in progress,
shown apart so the meter can draw it differently or not at all. `percent_used` is of `used_bytes` and is
rounded down so the meter never shows 100 before
the cap is actually reached. In Solo the read-out still works: the cap is 0, there is nothing in it, and
the summary says that Solo shares nothing. `read` defaults to `--tier neighborly`, so the meter must pass
the person's actual tier; otherwise a Solo user would see a 5 gigabyte cap.

## Reconciliation between two devices

Both devices in a transfer record it, under the same `transfer` reference, from their own measurement.
The design goal: neither side can silently inflate the other's usage, and neither can quietly
understate its own.

1. **Your cap counts your own measurement.** Your device never charges your cap with a number another
   device reported. A peer that wants to inflate your usage has no write path to your ledger.
2. **The peer's receipt is the check against understating.** At the end of a transfer, each side sends
   the other a receipt: the transfer reference, its own byte count, and its signature with the key from
   the attestation envelope. Each device keeps the receipts it receives alongside its ledger.
3. **Compare by transfer, not by month.** `reconcile` takes your ledger and the peer's receipts and
   matches them by transfer reference:

   ```
   python3 lib/reciprocity.py reconcile --receipts receipts.jsonl
   ```

   Counts are summed per transfer and peer on both sides, so a transfer recorded in several pieces
   still matches one receipt. Each transfer comes back as `agreed`, `discrepant`, `missing_receipt` (you recorded it, they sent no
   receipt), or `unknown_to_us` (they claim a transfer you never recorded).
4. **Tolerance.** Counts agree when they differ by no more than the larger of 65,536 bytes or 1 percent
   of the larger count. That covers bytes in flight when a session is cut off and nothing else, since
   both sides measure the same stream.
5. **What happens on a discrepancy.** A `discrepant` or `unknown_to_us` transfer is appended to the
   ledger as a `disagreement` (once, however often `reconcile` runs), shows in the read-out, and does
   not change either cap. A `missing_receipt` is reported but not stored, since the receipt may still
   arrive. A receipt whose direction is not the opposite of yours is discrepant. A peer with three discrepant or `unknown_to_us` transfers in the
   current month is marked as one to stop pairing with, and the runtime stops choosing it. Repeated
   discrepancies are evidence for the attestation layer's revocation process, not grounds for any
   automatic penalty here.
6. **Known limit: late receipts.** `prune` drops ledger lines older than the previous month. A receipt
   for a transfer that was already pruned comes back as `unknown_to_us` and would count against an
   honest peer. Receipts carry no time of their own, so the runtime should drop receipts older than
   the retention window before calling `reconcile`; once signed receipts land (thread 02) they should
   carry the transfer time so `reconcile` can do this itself.
7. **Why not take the smaller of the two counts?** It would stop inflation but reward a side that
   understates its own usage. Counting your own measurement and auditing it with signed receipts stops
   both.

### Dependencies on other threads

- **Receipt signing and verification** belongs to the attestation layer (thread 02). Until it lands,
  `reconcile` compares counts and trusts the receipt file's provenance; the signature check is the one
  missing step, and the receipt shape already carries a `signature` field for it.
- **The policy engine** (thread 03) calls `check` before carrying or routing, treats `within_cap` as
  one input among several, and passes the matched allowlist entry as `--domain`.
- **The site-allowlist registry** (thread 05) defines the domain granularity the ledger stores.
- **The usage meter** (thread 06) reads `read` and nothing else, and passes the person's `--tier`.
- **The runtime** (thread 01) calls `record` after each transfer and exchanges receipts with the peer.

Receipt lines, one JSON object per line:

```json
{"transfer": "t1", "peer": "fingerprint-of-the-receipt-author", "direction": "carried", "bytes": 800000000, "signature": "..."}
```

`direction` is the receipt author's own view, so a receipt saying `carried` matches a ledger entry of
yours saying `sent`.
