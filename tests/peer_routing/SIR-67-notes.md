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
file (`verify.lock`). A lock older than 30 seconds is removed as left by a dead process. A lock
that cannot be taken within 10 seconds fails the request.

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
| Replay tests only, cwd `/tmp` and the worktree, TZ UTC, Pacific/Kiritimati, America/Los_Angeles | 120 | 0 |
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

The base-code runs did not reproduce the flake. The 3 failures in 200 came from the lock-fix
build, and their cause is the dash-leading key identifier, which was present in the base code
too. The base code's 0 in 120 or 40 runs is consistent with about 1 in 64 per run only at a low
sample size, so it does not show the flake was absent.

## Reproducing

`tests/peer_routing/stress.sh COUNT [PATTERN]` runs the suite COUNT times and keeps the logs of
failing runs. The dash-leading key case is deterministic in `test_a_key_identifier_that_begins_with_a_dash_is_carried`.
