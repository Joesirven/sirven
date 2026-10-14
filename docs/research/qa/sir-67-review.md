# SIR-67 review: verify lock and dash-leading key identifiers

Reviewer: quality control thread for task SIR-67. Range reviewed: `git diff origin/integration/2026-10-13-wave-1...HEAD`
(commits `71fea40`, `72645c7`, `ff686fc`). Product code was not changed by this review.

Reviewed head: `ff686fc`. Verdict at the end of this file.

## What was run (all in the foreground, on this branch at `ff686fc`)

| Check | Result |
|---|---|
| `python3 -m unittest discover -s tests/peer_routing` (first run, then 3 more with exit status captured) | 26 tests, exit status 0 on the 3 captured runs; the first run reported a pass |
| `node --test tests/attestation/attestation.test.mjs` | 49 pass, 0 fail, exit status 0. The directory form `node --test tests/attestation/` exits 1 (it tries to load the folder as a test file); `tests/unit/test_attestation.sh:40` uses the file form, so `make test` does run these 49 tests |
| `bash tests/unit/test_attestation.sh` | exit status 0 |
| `make test` (run twice) | exit status 2 both times: 412 passed, **4 failed**: the 3 known installer tests plus `test_no_acronyms` (finding M1) |
| `make lint` | exit status 0 (shellcheck is not installed on this machine, so only the syntax check ran) |
| Mutation: `withExclusiveLock` made to run the work with no lock, scratch copy | `test_a_replay_arriving_during_the_first_verify_is_refused` fails (second verify accepted). The test does detect a missing lock |
| Mutation: `lib/peer_routing.py` from `71fea40` (before the dash fix), scratch copy | `test_a_key_identifier_that_begins_with_a_dash_is_carried` fails with `reciprocity_unavailable` and key `-E-Wceyl3J9Xl5prQCYaww`. The test does detect the old bug |
| Bounded wait: fresh `verify.lock` present, real verify run | exit status 1 after 10.1 seconds, empty standard output, `nonces.json` unchanged. Fails closed |
| Lock file mode | `0600`, in a `0700` peer folder |

## Must fix

### M1. `make test` is red on this branch because of the notes file

`tests/peer_routing/SIR-67-notes.md:47` (the table row for the replay runs across time zones) uses the abbreviation for
coordinated universal time and a two-letter label for time zone. `test_no_acronyms` in `tests/unit/test_language.sh` matches the
standalone word list in its `pattern` variable, which includes the coordinated-universal-time abbreviation (the flagged token is
that one; the two-letter time zone label is not in the list but breaks the standing language rule as well). Verified: that line
is the only hit in the repository. The notes at lines 49 and 64 claim `make test` gave only the 3 known installer failures
(412 or 413 passed); on the committed tree it gives 4 failures (412 passed).
Fix: on line 47 write the time zone names in full ("coordinated universal time", "the Kiritimati and Los Angeles zones" or
similar) and drop the two-letter label, rerun `make test`, and correct the counts in the notes to what is measured (expected:
413 passed, 3 known failures). This blocks merge because `make test` is the gate.

### M2. A live verify can lose its lock after 30 seconds, and then two verifies can both accept one envelope

`lib/attestation/cli.mjs:90-130` (`withExclusiveLock`). The stale rule is purely by age (`LOCK_STALE_MS`, 30 seconds from the
file's modification time) and a holder never refreshes the lock. A holder that is alive but slow (process stopped, disk stall, a
heavily loaded machine) is treated as dead.

Measured in a scratch copy of this branch: verify A held the lock for 45 seconds (the test hold variable). Verify B of the same
envelope started 24 seconds in, found the lock older than 30 seconds at 30 seconds, removed it and was accepted (exit 0,
`accepted: true`) while A was still running. A then exited with status 1 and `ENOENT: no such file or directory, unlink .../verify.lock`
from the `finally` block, because B had already released the file. Net effect in that run was one acceptance, but only by luck of
ordering: the exclusion the lock exists to give was gone for the whole overlap.

Two further defects in the same function, found by reading and not measured:

1. Stale removal is itself racy. Waiters B and C both stat the same stale lock and both judge it stale. B unlinks it and creates
   a fresh lock (B now holds). C then unlinks by path, which removes B's fresh lock, and creates its own. B and C are inside
   the critical section together.
2. The release is `unlinkSync(path)` by name, with no check that the file is still the one this process created. After any
   steal, the original holder deletes someone else's lock, or throws `ENOENT` and replaces the real result or the real error
   with a confusing one (seen above).

Severity: the trigger needs a verify that takes more than 30 seconds inside a step that normally takes milliseconds, so it is
rare. It is in the replay protection path, so it is listed here, not lower.

Fix, in order of preference:
1. Put an owner token in the lock (process identifier, host name, random value) when creating it (`openSync(path, 'wx')`
   then write the token). Release only if the file still holds this process's token, and ignore `ENOENT`.
2. Treat a lock as dead only when its holder is provably gone: same host and `process.kill(pid, 0)` throws `ESRCH`. Keep an age
   fallback, but make it much longer than any real verify (for example 10 minutes), not 30 seconds.
3. Make stale removal exclusive: take a second `wx` file such as `verify.lock.break`, recheck the staleness and the token while
   holding it, then unlink. A losing waiter retries from the top and never unlinks a lock it did not read.
4. Alternatively, a heartbeat that refreshes the lock's modification time every few seconds while work runs (the approach the
   `proper-lockfile` package uses with a directory lock), though 1 to 3 need no extra timer.
Add tests: a live holder whose lock is older than the stale age is not removed (use the test hold plus a short test-only stale
setting), and a release after a lost lock does not throw or delete another process's lock.

## Should fix

### S1. The ledger is written before the nonce memory

`lib/attestation/cli.mjs:403-405` (inside the lock): `ledger.json` is written, then `nonces.json`. If the process dies between
the two writes (kill, power loss), the bytes are charged to the ledger but the nonce is not remembered, so the same envelope
can be accepted again later, and charged again. The lock does not help a crash.
Fix: write `nonces.json` first, then `carried/<nonce>.json`, then `ledger.json`. A crash then fails closed (envelope refused as
replayed, bytes not yet charged) instead of open. Add a short comment saying why the order matters.

### S2. The `finally` can hide the real outcome

`cli.mjs:127-129`. If `work()` throws and `unlinkSync` also throws, the original error is lost; if `work()` succeeded and
`unlinkSync` throws, a completed and recorded acceptance is reported as exit status 1 (the caller then sees a refusal while the
envelope has already been consumed). Release should tolerate `ENOENT` and never throw over the result. (Resolved together with M2.)

### S3. The dash regression test covers only the `check` call, not `record_transfer`

`lib/peer_transport.py:97-104` got the same `--flag=value` change, which I confirmed is needed (`reciprocity.py record ... --peer -E-W...`
exits with `expected one argument`; the `=` form records). But no test exercises `record_transfer` with a dash-leading
identifier, and `record_transfer` returns `None` silently on failure, which would under-count carried bytes without any visible
error. Fix: add a test in `tests/peer_routing/test_transport.py` that calls `record_transfer` with `peer_id="-E-Wceyl3J9Xl5prQCYaww"`
and a session beginning with `-`, and asserts a receipt comes back. Also have the failure branch log or return the reason.

### S4. No test for the bounded wait, and a lock timeout leaves no audit entry

The timeout path works (measured above: exit status 1 after 10.1 seconds, no state change, and the Python side refuses because
any exception from the verifier is a refusal, `lib/policy_engine.py:404-406`). It is untested, and because the error is thrown
before the audit line is written, `audit.jsonl` records nothing for a verify that was turned away for lock contention. Add a test
that a pre-existing fresh `verify.lock` yields exit status 1 and an unchanged `nonces.json` (a short wait time would need to be
configurable for the test), and consider writing a `refused` audit entry with reason `lock_unavailable`.

## Nice to have

- N1. `nowSeconds()` is read at `cli.mjs:355`, before the lock wait of up to 10 seconds. An envelope can be accepted up to 10
  seconds after its expiry. Read the clock after taking the lock, or accept and note it.
- N2. `SIRVEN_ATTESTATION_TEST_HOLD_MS` is honoured in the production verify path (`cli.mjs:130-137`), and the `verify.paused`
  marker is never cleaned up. Anyone who controls the environment of the verify process can stall it up to the lock wait of
  other verifies. Low risk, since that actor can already run the program, but gate it behind a second test-only variable or
  remove the marker at the end of the test.
- N3. A verify killed outright leaves `verify.lock` for up to 30 seconds. Every verify in that window fails after waiting 10
  seconds. That is safe (fails closed) but is a 30-second outage. Owner-liveness checks (M2 fix 2) shorten it to nothing.
- N4. `peerInit` (`cli.mjs:333-334`) rewrites `ledger.json` and `nonces.json` with no lock. Re-running `peer init` against a
  live peer folder would wipe replay memory. Take the same lock there, or refuse to re-init a folder that has a ledger.
- N5. `lib/peer_routing.py:204` still passes `--ledger`, `--now`, `--bytes` as separate values (`peer_transport.py:98` likewise).
  Those cannot begin with `-` today (a path under the state folder, integers). For consistency use the `=` form everywhere, or
  insert `--` before positional values. Not needed for correctness.
- N6. The notes file says `ledger.json` and `nonces.json` are written only by `peerVerify` and `peerInit`; that matches my grep
  (`cli.mjs:333,334,403,405`). Correct as written.

## Answers to the five questions

1. **Lock correctness.**
   - Atomic creation: sound. `openSync(path, 'wx', 0o600)` is `O_CREAT | O_EXCL`, atomic on local filesystems.
   - Release on every path: the `finally` runs on return and on exception, but it unlinks by name, not by ownership (S2).
     A killed process (signal 9) cannot release; the age rule covers that.
   - Stale removal: **not safe** (M2). A slow but live verify can be robbed after 30 seconds; two waiters can rob each other.
   - Bounded wait: correct and fail-closed (measured). Exception, exit status 1, no state written, refused by the caller.
   - Processes and machines: works across processes on one host. It rests on the filesystem's exclusive-create and on clocks;
     on a network filesystem with machines whose clocks differ, `Date.now() - mtime` can misjudge age in either direction.
     The peer folder is documented as local to a node, so this is a note, not a defect.
   - Location and permissions: `verify.lock` is inside the peer folder (`0700`), file mode `0600`. Fine.
2. **Regression test.** Yes for both. Mutation results are in the table above. The replay test relies on a 2 second hold and
   a marker poll of up to 20 seconds, so it is deterministic in ordering, not timing-sensitive in outcome.
3. **Dash fix reach.** Searched every `subprocess` and `child_process` use outside tests (`app/serve.py`, `lib/peer_routing.py`,
   `lib/peer_transport.py`, `lib/policy_engine.py`, `lib/sirven_runtime/fetch.py`, `docs/architecture/build.mjs`, the demo and
   connector test helpers). The only callers of `lib/reciprocity.py` (the only argparse program that takes identifiers) are
   `peer_routing.carry`, `peer_transport.record_transfer` (both fixed) and `app/serve.py:131` (only `read --ledger <absolute
   path>`). The node program parses its own options and takes the next token as the value whatever it begins with
   (`parseOptions`, `cli.mjs:170-183`), so a dash-leading `--host`, `--request-digest` or `--dir` value is safe. `policy_engine.py:507`
   runs a configured command with `shell=True`; that is an operator-supplied command, not an identifier path. No shell script passes
   a key identifier. Gap: S3 (no test for `record_transfer`).
4. **`usage.json` in `sign` left unlocked.** I agree it is out of scope. `usage.json` is the sender's own device-side counter
   (`cli.mjs:297-303`). A lost update can only make a sender under-count its own usage; the peer does not trust that figure, it
   enforces its cap from its own locked ledger (`attestation.mjs:503-506`, `carriedBytes`). A user can also simply edit the file.
   So it does not touch replay protection or the peer's reciprocity accounting. It is worth a one-line note in the follow-up list,
   nothing more.
5. **Tests.** See the table. The only red result attributable to this branch is M1.

## Verdict

**CHANGES REQUIRED** at reviewed head `ff686fc`. The dash fix is correct and well tested for the carry path. The lock closes the race it was written for and
fails closed on contention, but M1 (red `make test`) and M2 (lock can be taken from a live holder) must be fixed before merge, and
S1 (write nonces before the ledger) is a one-line change that should go in with them.

The commit that holds this report is named in the review thread's final message to the parent; it is the first commit after `ff686fc` that touches this file.

## Re-review of `e72c56d` (branch `sir-67-fix-the-flaky-peer-routing-end-to-end-tes-thr_cn3rxrtcw2`)

Reviewed in a scratch worktree at `e72c56d` (range `ff686fc..e72c56d`, nine commits). New lock: `lib/attestation/verify-lock.mjs`.

### Commands run (foreground, scratch worktree at `e72c56d`)

| Check | Result |
|---|---|
| `python3 -m unittest discover -s tests/peer_routing`, 3 runs | 32 tests each, exit status 0 each time |
| `node --test tests/attestation/attestation.test.mjs` | 49 pass, 0 fail, exit status 0 |
| `make test` | exit status 2: 419 passed, 3 failed, and the 3 are exactly the known installer tests. `test_no_acronyms` is green |
| `make lint` | exit status 0 (shellcheck is not installed, so only the syntax check ran) |

### Each earlier finding, verified

| Finding | Verdict | Evidence |
|---|---|---|
| M1 red `make test` | Fixed | Only the 3 known installer failures remain; 419 passed |
| M2 steal from a live holder, the measured 45 second case | **Fixed** | Same script as the first review, new code: verify A held the lock 45 seconds; verify B started at 24 seconds and was refused with `lock_unavailable` (exit status 3) after 34 seconds, having waited the full 10 seconds. A finished with exit status 0 and `accepted: true`. Ledger shows one charge of 51 bytes. The old code accepted B at 30 seconds |
| M2 token-checked release | Fixed | `releaseLock` unlinks only while the file carries this holder's token and never throws over the result. The suite test replaces the lock mid-work and finds the foreign lock intact |
| M2 two waiters on one dead lock | Fixed by construction, probe cannot discriminate | 12 rounds of 8 simultaneous verifies of one envelope on a dead holder's lock: every round exactly 1 accepted, 7 `replayed`, no `verify.lock*` file left behind. But the same probe against a scratch copy where the break file is removed (plain unlink by path) also showed 0 bad rounds, so this test and the suite's two-waiter test do not prove the break file works; that rests on my reading of `clearDeadLockOnce`, which I find sound (the re-read under the break file, plus the identity comparison, rejects a replaced lock) |
| S1 nonce before ledger | Fixed, and the test bites | Scratch run: make the carried-folder write fail after the nonce is remembered, then retry. New code: first attempt exit status 1, retry refused as `replayed`, ledger empty. Same sequence with the nonce write moved after the ledger write: retry is accepted and charged (the replay hole). The suite test `test_a_write_failing_after_the_nonce_is_remembered_refuses_the_replay` covers it |
| S2 release masking the result | Fixed | See token-checked release above; the ENOENT seen in the first review no longer occurs |
| S3 `record_transfer` | Fixed | Dash-leading peer and session get a receipt; a refused record returns `recorded: false` with reason `reciprocity_record_failed` instead of `None`. Two tests, both pass |
| S4 timeout test and audit entry | Fixed | Unit test waits the real 10 seconds and finds `"outcome":"refused","reason":"lock_unavailable"` in `audit.jsonl`; end-to-end test shows a carry that cannot take the lock is refused as `attestation_verifier_unavailable` (via `ATTESTATION_ERROR_STATES`). Exit status 3, which the caller treats as a refusal |
| N1 clock read before the wait | Fixed | `now` is read under the lock |

### New findings in the new lock

**Should fix R1: a live holder is judged dead if the machine's computed boot time moves by more than 5 seconds.**
`verify-lock.mjs`, `holderIsGone` and `bootedAt` (`Date.now()/1000 - uptime()`). The boot time is recomputed from the wall clock, so a wall clock step (time synchronisation correction, virtual machine resume, manual set) of more than `BOOT_TOLERANCE_SECONDS` while a verify is inside its locked step makes the waiter conclude "predates the last boot" and take the lock from a live holder. On Linux, where `uptime()` does not follow the wall clock, this applies directly. Measured with a lock record naming a live process and a recorded boot time 10 seconds off the computed one: the verify took the lock and was accepted (exit status 0). With a 3 second offset it was refused. I did not step a real clock. The exposure is small (a clock step must land inside a step that normally takes milliseconds, with the same envelope arriving at the same moment), so I do not block on it, but it is the same class of fault as the original M2.
Fix: raise the tolerance to minutes (a reboot plus a reused process number inside, say, 5 minutes is far less likely than a clock step above 5 seconds), or compare the lock file's creation time against the boot time with a wide margin, or drop the boot check and rely on process existence plus a long age fallback.

**Should fix R2: a lock that can never be judged dead stays forever and the operator is not told how to clear it.**
A dead holder whose process number was reused by another live process, a holder recorded under a different host name (host names change, for example on a laptop or after renaming a server), or a holder on another machine are all "never dead". Every verify then refuses with `lock_unavailable` after 10 seconds until someone deletes `verify.lock`. That fails closed, so it is safe, but the old code recovered in 30 seconds and this does not recover at all. The refusal detail (`cli.mjs`, "another peer verify holds the lock, so this request was not run") names neither the file nor the remedy, and `docs/` does not mention `verify.lock` (searched).
Fix: put the lock path and the owner's process number and host in `detail`, add one paragraph to `docs/attestation.md` on how to clear a stuck lock after confirming the holder is gone, and consider a very long age fallback (an hour or more) for locks that cannot be checked.

**Nice to have R3: the documented break-file window is described too optimistically.**
`verify-lock.mjs` header says the race "would need two crashes inside microsecond windows". Reading `removeAbandonedBreak`: it needs one earlier crash (to leave the abandoned break file) and then two ordinary waiters recovering it at once. Waiter 2 reads the abandoned record and decides it is dead; waiter 1 renames it away and creates its own live break file under the same name; waiter 2 then renames waiter 1's live break file away and carries on. Both are then inside the break step, and a third party who took a fresh lock in between could have it unlinked. It needs an unusual interleaving of a few microseconds after a crash that is itself rare, so I accept the residual, but correct the comment, and the cheap fix is to check, after the rename, that the parked file still holds the record judged dead and otherwise put it back with a no-overwrite link.

### Items the implementer left open

- **N2, test-only variables honoured in production** (`SIRVEN_ATTESTATION_TEST_HOLD_MS`, `SIRVEN_ATTESTATION_TEST_LOCK_WAIT_MS`). Accept as left. Neither can make a verify accept anything: the hold only stalls the process that carries it, and a shorter wait only makes a verify give up and refuse sooner. Anyone who can set these has the environment of the verify process and could run the program directly. Gating is hygiene, not a fix for a hole. If touched later, gate both behind one test-mode variable, and remove the leftover `verify.paused` marker.
- **N4, `peer init` rewrites the ledger and nonce memory without the lock** (`cli.mjs` `peerInit`). Accept as left. `peer init` also writes a new peer identifier (`newPeerIdentifier`) and a new policy, so every envelope signed for the old identifier fails the audience check afterwards; wiping the nonce memory therefore does not reopen replays. It does reset the reciprocity ledger and could race a running verify, but it is an operator action on a node being set up. Cheap hardening if wanted: refuse to re-initialise a folder that already has a non-empty ledger or nonce memory, or take the verify lock.
- **Documented break-file window.** Accept with the comment corrected (R3).

### Verdict (re-review)

**APPROVE** at `e72c56d`, on condition that R1 and R2 are done before merge or filed as follow-up tasks with owners (neither reopens the original replay gap on the evidence I could produce, and R2 fails closed). All must-fix and should-fix items from the first review are fixed and verified, including the measured 45 second steal, which now refuses the second verify instead of accepting it. The commit that holds this re-review is named in the review thread's final message to the parent.
