# SIR-67: intermittent failure of the peer routing end-to-end test

## Root cause of the intermittent failure

A key identifier is base64url, so about one in 64 generated keys begins with `-`. The carry
passed that identifier to `lib/reciprocity.py` as the separate value of `--peer`. argparse reads
a value beginning with `-` as an option, exits with status 2, and `peer_routing.carry` reported
`reciprocity_unavailable`. A valid, reviewed, correctly attested carry was then refused. Each
test run generates new keys, so the failure is intermittent. In `test_a_replayed_envelope_is_refused`
the first carry is the assertion that fails, which is why it reads as a replay assertion.

Confirmed: 3 of 200 isolated replay runs failed before the fix. All three logs show
`'allow_peer_carrier' != 'refuse'`. The instrumented copy showed `reciprocity_unavailable`
with `key_id` `-E-Wceyl3J9Xl5prQCYaww`. Fixed in `72645c7`, with a regression test that fails
against the previous `peer_routing.py`.

## Separate product fix: lock on the verify step (`71fea40`)

`peer verify` in `lib/attestation/cli.mjs` read the nonce memory and the ledger, checked the
envelope, and wrote both back without a lock. The carrier serves requests on several threads
and runs one verify process per request. Two verifies of one envelope could both read before
either writes, and both be accepted. Now the read, check and write run under an exclusive lock
file (`verify.lock`) that records its holder's process number, host name, and a random token.
A lock is removed only when its holder process is gone on this host, never by age while the holder
lives. Removal is exclusive: one waiter creates a break file named for the dead token, and only that
waiter removes the lock. Release removes the lock only while it still carries its own token. A lock
that cannot be taken within 10 seconds refuses the request (`lock_unavailable`); it never runs without
the lock. The 30-second age rule in the earlier version could take a lock from a live holder.

Could this race explain the flake? No. The end-to-end test has no concurrent carries. The race
produces a double acceptance, not a refusal of the first carry, so it cannot produce the observed
failure. It is fixed because it is a real replay gap, not because it explains this flake.

The probe that tried to hit the race found no double acceptance: 10 rounds of 40 concurrent
verifies on one envelope each gave exactly one acceptance. The regression test
`test_a_replay_arriving_during_the_first_verify_is_refused` shows the window deterministically.
It fails with the lock removed (the second verify is accepted).

Other read-modify-write sites checked: `ledger.json` and `nonces.json` are written only by
`peerVerify` and `peerInit`. `usage.json` on the user's device is read and written by `sign`
without a lock. That affects the sender's own cap, not replay protection, and is not changed here.

## Counts

Base code (`0ffd59f`, before any change):

| Condition | Runs | Failures |
|---|---|---|
| Full peer routing suite, idle machine | 40 | 0 |
| Full peer routing suite, three concurrent loops | 45 | 0 |
| Replay tests only, working directory `/tmp` and the worktree, with the time zone set to coordinated universal time, Pacific/Kiritimati, and America/Los_Angeles | 120 | 0 |
| Full suite from a copy of the keep-awake worktree (`thr_2huemangmh-1`) | 30 | 0 |
| `make test` | 1 | 0 peer failures (412 passed, 3 known installer failures) |

Lock fix only (`71fea40`):

| Condition | Runs | Failures |
|---|---|---|
| Replay tests only (`stress.sh 200 replay`) | 200 | 3 (all `reciprocity_unavailable` on the first carry, dash-leading key) |
| Full peer routing suite (`stress.sh 10`) | 10 | 0 |

Lock fix and dash fix (`72645c7`):

| Condition | Runs | Failures |
|---|---|---|
| End-to-end class, isolated (`stress.sh 200 EndToEnd`) | 200 | 0 |
| Full peer routing suite (`stress.sh 10`) | 10 | 0 |
| `make test` | 1 | 0 peer failures (413 passed, 3 known installer failures, exit status 2) |
| `make lint` | 1 | exit status 0 (shellcheck not installed here, so its step was skipped) |

The base-code runs recorded no failures in 235 runs. At the per-run rate implied by the
dash-leading key probability (1 in 64), the chance of zero failures in 235 runs is about 2.5
percent. The base-code zeros therefore do not confirm that the flake was absent, and they are
unexplained by the dash cause alone. The lock-fix build recorded 3 failures in 200 runs, all
with the dash cause. This discrepancy is not resolved.

## Review round (commits `c865d68` to `263a267`)

Response to the strict review of `ff686fc`.

- M1: the notes named the time zones in full. `make test` no longer fails on `test_no_acronyms`.
- M2: the lock moved to `lib/attestation/verify-lock.mjs` and the age rule was removed. An owner
  record (process number, host name, boot time, random token) marks each lock. A lock is dead only
  when its holder is gone on this host, or was written before the last boot. Removal is exclusive
  by dead token. Release checks the token. A lock that cannot be taken within 10 seconds refuses
  the request (`lock_unavailable`), recorded in the audit log.
- S1: the nonce is written before the carried envelope and the ledger.
- S2: release never throws over the result of the work.
- S3: `record_transfer` reports `reciprocity_record_failed` instead of returning nothing, and its
  dash-leading identifier case is tested.
- S4: the ten-second wait is tested, the refusal is audited, and a carry that cannot take the lock
  is refused as `attestation_verifier_unavailable`.
- N1: the clock is read under the lock, so an envelope cannot be accepted after its expiry by
  the length of the wait.

Measured on the final tree (`263a267`): `make test` 419 passed, 3 known installer failures,
exit status 2. `make lint` exit status 0 (shellcheck not installed, so only the syntax check ran).
Peer routing suite: 32 tests, exit status 0. Attestation shell tests: 23 passed. Node attestation
library tests: 49 passed. End-to-end class stress, 40 runs: 40 passed.

Not done, and left open:

- N2: `SIRVEN_ATTESTATION_TEST_HOLD_MS` is still honoured by the production verify path. A process
  that controls the environment of a verify can already run the program, so the risk is low.
- N4: `peer init` still rewrites `ledger.json` and `nonces.json` without the lock.
- N5: some reciprocity arguments are still separate values. None can begin with `-` today.

Residual window, documented in `verify-lock.mjs`: one earlier crash, a waiter dying between creating a
break file and removing the lock, leaves the break file behind. Two waiters recovering that abandoned
break file at about the same moment can then both be inside the break step, which needs an interleaving
of microseconds. It is not closed. The cheap closure is named in the header comment.

Final review round (commits `acdc160` to `cebc71d`):

- R1: the boot tolerance is ten minutes, so a clock step of seconds cannot make a live holder dead.
  Tested with a ten-second offset on a live holder, which is refused.
- R2: the refusal names the lock file and the owner it records. A lock whose owner cannot be checked
  from this machine is dead after 24 hours (tested at 23 and 25 hours). The clearing procedure is in
  `docs/peer-routing.md`, "The peer verify lock, and clearing a stuck verify lock".
- R3: the header comment describes the break-file window as one crash plus two concurrent recoveries.

## Reproducing

`tests/peer_routing/stress.sh COUNT [PATTERN]` runs the suite COUNT times and keeps the logs of
failing runs. The dash-leading key case is deterministic in `test_a_key_identifier_that_begins_with_a_dash_is_carried`.
