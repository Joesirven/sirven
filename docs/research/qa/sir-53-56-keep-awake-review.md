# Keep-awake review: SIR-53 (bb watcher) and SIR-56 (lid-closed helper re-check)

Reviewed branch `keep-awake-bb-watcher`, tip 2da19df (two commits on top of c3a4b7f). Source only: the installed
LaunchAgent on Jose's Mac was not stopped, unloaded or modified. Reviewer: thread thr_kkin8y68sk, 2026-10-13.

## Verification run (foreground, this Mac, outside the sandbox)

| Command | Exit | Result |
| --- | --- | --- |
| `make test-keep-awake` | 0 | 20 tests, 0 failures |
| `make lint` | 0 | `bash -n` clean on 54 files; shellcheck is not installed, so it was skipped |
| `make test` | 2 | 375 passed, 3 failed: `test_install_started_by_sh_says_to_use_bash`, `test_enter_twice_accepts_the_shown_defaults`, `test_input_that_ends_takes_the_defaults`. These are the 3 known installer failures. |

No test covers the watcher script or the helper executable (see S6). Live check: `bb thread list --json` returns 650 threads
(913 KB) in 0.4 s; the live watcher log shows holds as recent as 16:41 today, and this review thread was itself counted as active.

## Must fix

### M1. SIR-56: the helper never re-checks the sleep state during a hold
Evidence: `macos/keep-awake/Sources/sirven-keep-awake-helper/main.swift:44` returns early with success when the marker file exists
(`if ours || systemSleepIsDisabled() { return nil }`), even if `SleepDisabled` is now 0. `main.swift:79` (`guard wanted != applied`)
stops a second request from reaching it, and the holder only calls the helper on a state change (`Holder.swift:112`, `guard wanted != lidClosedActive`).
Nothing reads the setting again until the hold ends, so if something clears it mid-hold (a `sudo pmset disablesleep 0`, another tool, a
system settings reset) the lid-closed hold silently stops while status keeps reporting `lidClosedActive true`.

The fix (all in the helper, so it works even when the holder is idle):

1. In `setSystemSleepDisabled(true)`, drop the `ours ||` shortcut. Ask the system, not the marker:
   - setting is on: return nil (nothing to do; keep or leave the marker as it is).
   - setting is off: write the marker first, then run `pmset -a disablesleep 1`; if pmset fails, remove the marker and return the error.
2. In `Helper`, keep a repeating `DispatchSourceTimer` (every 15 seconds) that runs only while `asking` is non-empty and `applied` is true.
   Each tick calls `setSystemSleepDisabled(true)` and logs with NSLog when it had to re-assert (`sleep-disabled was cleared during a hold; asserted again`).
   Cancel the timer when `asking` becomes empty.
3. Policy to document: during a hold the helper treats the setting as sirven's. If the user clears it on purpose mid-hold it comes back within
   15 seconds; the user's way out is `sirven awake release` (or lid-closed off), which reverts it and the marker.
4. Report the truth instead of the belief: add `func isSleepDisabled(withReply:)` to `KeepAwakeHelperProtocol`, call it from `sirven awake status`, and show it next to `lidClosedActive`.
5. Tests (needs M3 first): with a stand-in pmset runner, (a) marker present and setting cleared, a tick re-asserts; (b) setting on with no marker (the user's own), release leaves it on; (c) hold, clear, tick, release ends with setting off and no marker.

### M2. A crash or power loss mid-hold leaves lid-closed sleep disabled across reboot until sirven next connects
Evidence: `Support/xyz.sirven.keep-awake-helper.plist` has no `RunAtLoad` and no `KeepAlive`; launchd starts the helper only when a client connects.
The revert-at-start (`main.swift:105`) therefore runs only the next time Jose turns lid-closed on or the holder asks. `pmset disablesleep` is a persistent
setting (not verified here: no sudo), so a MacBook that was force-shut mid-hold, or whose helper was killed, keeps `SleepDisabled 1` with nothing watching
it, which is the heat and battery risk in a bag. Fix: add `<key>RunAtLoad</key><true/>` (and `<key>KeepAlive</key><true/>` so a killed helper returns and reverts)
to the plist; the start-up revert then covers every boot. Also write the marker before the pmset call (see S2) so a crash between the two cannot orphan the setting.

### M3. The helper accepts any Apple-signed caller with the identifier `xyz.sirven.app`
Evidence: `Sources/SirvenKeepAwake/Identity.swift:20`: `identifier "xyz.sirven.app" and anchor apple generic`. `anchor apple generic` accepts any
certificate chained to Apple, including a free Apple Development certificate, and the identifier is whatever the signer chooses. Any such binary can talk to a root
process that runs `pmset`. The impact is bounded (it can only flip disablesleep, not run commands, and `build-app.sh` ends in an unattended Mac that will not sleep), but it is the one privileged
entry point and the comment at `Identity.swift:18` promises the team identifier is added. Fix: append `and certificate leaf[subject.OU] = "<TEAMID>"`,
injected at build time from the signing certificate (for example `build-app.sh` writes it into a generated constants file or the helper reads it from its own signature with `SecCodeCopySigningInformation`), so no
personal identifier is hard-coded in this public repository. Keep ad hoc builds working by falling back to the current requirement only when the build is ad hoc.

## Should fix

### S1. No ceiling on a lid-closed hold, and no battery or heat condition
Evidence: `bb-watcher/sirven-bb-awake-watcher.sh` begins the task with `--lease 300` and renews it every 90 seconds for as long as bb reports any busy thread (lines 81, 120-127), so the documented 12-hour
lease (`Client.swift:46`) applies only to manual `begin` calls. Any thread stuck in `active` (one stuck turn) holds the Mac, lid closed, indefinitely. There is no use of battery state anywhere
(`grep -rniE "battery|thermal|IOPS" Sources` finds nothing). Fix: in the watcher, stop renewing after a maximum continuous hold (default 12 hours, `SIRVEN_BB_MAX_HOLD`), log `bb-watcher-max-hold`, and
require an idle period before holding again; in the holder, read `IOPSCopyPowerSourcesInfo` and turn the lid-closed part off when running on battery below 20 percent.

### S2. Marker written after pmset
`main.swift:48-52`: pmset runs, then the marker is written. A crash in between leaves the setting on with no marker, and `setSystemSleepDisabled(false)` returns early at line 40
(`!ours`) so it is never reverted. Fix: create the marker first, remove it if pmset fails.

### S3. Signal handler calls Foundation
`main.swift:112-114`: the SIGTERM and SIGINT handler runs `Process` and file operations inside a `signal()` callback, which is not async-signal-safe. Use
`DispatchSource.makeSignalSource` for both signals (ignore the default action first), and run the revert on the main queue.

### S4. Clean removal is incomplete
`bb-watcher/install.sh remove` (lines 22-26) boots out the LaunchAgent (SIGTERM, whose trap ends the task, good) and deletes the plist, but leaves the copied script and `watcher.log` in
`~/Library/Application Support/sirven/bb-watcher` (the message says so). The privileged side has no removal path at all: nothing calls `SMAppService.unregister()`, and nothing documents deleting the marker directory
`/Library/Application Support/sirven/keep-awake-helper` or running `sudo pmset -a disablesleep 0`. Fix: `remove` deletes `$TARGET`; add `sirven-keep-awake helper unregister` (calls
`service.unregister()` after a lid-closed-off revert) and a "Removing everything" section in `macos/keep-awake/README.md`.

### S5. The plist embeds `BB_SERVER_URL`
`install.sh` writes the value of `BB_SERVER_URL` into a world-readable plist (mode 644). It is an https URL on this machine, not a secret, but if bb ever puts a token in that URL it would be exposed. Write the plist with mode 600
(`umask 077` before the heredoc) and add a one-line check that the URL has no user information or query string.

### S6. No automated test for the watcher or the helper state machine
The tests cover the library only; the hold, release and idle logic in the 182-line watcher was verified with a stand-in bb by hand, and the helper executable (the privileged part) has no tests. Fix: add
`tests/unit/test_keep_awake_watcher.sh` driving the watcher with `SIRVEN_BB_COMMAND` and `SIRVEN_KEEP_AWAKE_BIN` stand-ins and `SIRVEN_BB_ONCE=1` (busy begins, idle window, failing bb, user release), and move the helper's state machine into the library behind a pmset protocol (see M1.5).

## Nice to have

- N1. Hard-coded host id: `sirven-bb-awake-watcher.sh:30` and `README.md:108` default to `host_na8kye9eas` (a bb host id for Jose's MacBook, not a path, but it is personal data in a public repository). Resolve the host at install time (`bb status`) and write it into the plist as `SIRVEN_BB_HOST`; make the script fail loudly when it is unset.
- N2. `mktemp` files in `count_work` are leaked if the watcher is killed during a query; create them once under `$TARGET` and reuse, or trap `EXIT`.
- N3. The old blanket agent `xyz.sirven.bb-keep-awake.plist` is still in `~/Library/LaunchAgents` (SIR-53 step 5); the README should say it conflicts in purpose and when to remove it.
- N4. Polling 913 KB of JSON every 30 seconds is fine today (0.4 s) but grows with thread count; use `--status`/host filters if bb gains them.

## Checks that passed (with evidence)

- Detection: `bb thread list --json`, filtered to the watched host, counts status `active`/`starting`/`running` plus background agent, background command and workflow counts (script lines 84-94). Live data confirms the fields exist (`activity.activeWorkflowCount` etc.) and `error` and `idle` threads are not counted.
- Release logic: 300 s idle window; a failed or hung bb query (60 s kill, lines 53-60) counts as idle, so an unreachable bb cannot hold the Mac forever; the user release is respected through the idle window (commit 2da19df).
- Watcher crash or kill: the work is owned by the watcher's process id with a 300 s lease (`Holder.endReason`, `Holder.swift:36-45`), so the holder reaps it; SIGTERM ends the task (trap, line 134). The holder's power assertion is released by the system if the holder dies; the helper reverts when the holder's connection drops (`main.swift:93-94`).
- Mac sleeps anyway: after wake a stale `idle_since` only causes an earlier release; an expired lease is reaped and re-begun on the next pass while bb is busy.
- Privilege: only the helper is root and only runs `/usr/bin/pmset` with fixed arguments (`main.swift:12-30`); no sudoers entry, nothing from the caller reaches pmset; the marker lives in a root-owned directory. The LaunchAgent runs as the user and needs no administrator rights.
- Paths: the plist and install script use `$HOME`; no `/Users/...` paths in `macos/keep-awake` (`grep` clean). Only the host id in N1.

## Verdict

CHANGES REQUIRED. M1 (SIR-56), M2 and M3 must land before the blanket `disablesleep 1` is removed; S1 is strongly recommended before relying on this with the lid closed in a bag.

Reviewed commit: 2da19df. Report commit: see `git log -1` on branch `code-review-keep-awake-watcher-and-lid-closed-ha-thr_kkin8y68sk`.

---

## Re-review (2026-10-13)

Reviewed the implementer's branch `sir-53-sir-56-harden-keep-awake-watcher-and-lid-thr_2huemangmh`, tip b165c95 (six commits: 7bd39a2, 42d502a, 6bb3caf, 3f54614, 88aaae9, b165c95), in a scratch worktree at `/tmp/rr-wt`. The installed LaunchAgent, helper and app were not touched; no sudo.

### Verification run (foreground)

| Command | Exit | Result |
| --- | --- | --- |
| `make test-keep-awake` | 0 | 40 tests, 0 failures (was 20) |
| `make lint` | 0 | `bash -n` clean on 58 files (the three new scripts are now in the lint list); shellcheck still not installed |
| `make test` | 2 | 388 passed, 3 failed: the same 3 known installer failures |

### New must fix

**R1. The helper cannot read its team identifier when it runs from the app bundle, so it refuses every connection and lid-closed operation never works.**
`Identity.swift`, `KeepAwakeHelperAccess.embeddedTeamIdentifier` calls `Bundle.main.object(forInfoDictionaryKey: "SirvenTeamIdentifier")`.
The helper executable lives in `Sirven.app/Contents/MacOS/` (`Support/xyz.sirven.keep-awake-helper.plist`, `BundleProgram`), and there `Bundle.main` is the app bundle, whose `Info.plist` does not carry the key. Verified by experiment, not by reading: a test tool linked with `-sectcreate __TEXT __info_plist` containing `SirvenTeamIdentifier` prints the value when run standalone, and prints `nil` when the same binary is copied into `T.app/Contents/MacOS/` next to an app `Info.plist` without the key. The result fails closed (the helper logs "refusing a connection" and nothing can drive `pmset`), so it is safe but breaks the feature the branch exists for.
Why nothing caught it: the unit tests exercise `requirement(teamIdentifier:)` with literal values and never the lookup; `build-app.sh` only checks that the team string is present in the binary with `grep -a` (line near the end), which passes while the runtime lookup fails.
Fix: read the helper's own embedded section instead of `Bundle.main` (for example `getsectiondata` on the main executable header for `__TEXT,__info_plist` and parse the plist, or `CFBundleCopyInfoDictionaryForURL` on the executable URL). Then add a build-time check to `build-app.sh` that runs the built helper from inside the finished bundle with a `--print-team` style flag (exits before listening) and compares the answer to `$TEAM`. This is the only item that blocks approval.

### Verification of the earlier items

| Item | Verdict | Evidence |
| --- | --- | --- |
| M1 sleep state from the system, re-checked every 15 s | Fixed, with one test gap | `SleepSetting.swift` `enforce(true)` asks `setting.isDisabled()` and ignores the marker; `HelperCore.swift` has a 15 s repeating timer started in `setAsking` while any connection asks and stopped when none does. Mutation: restoring the `sirvenTurnedItOn ||` shortcut fails 3 tests. But the timer wiring itself is untested: disabling `startTimer` (`guard timer == nil else { return }` replaced by `return`) still passes all 40 tests, because `testAClearedSettingIsAssertedAgainDuringAHold` calls `recheck()` directly. See S-new-1. |
| M2 RunAtLoad and KeepAlive | Fixed in the plist, untested | `Support/xyz.sirven.keep-awake-helper.plist` now has both keys; the helper reverts at its start (`core.revertAll()`). Flipping `RunAtLoad` to false passes every test, so a regression would not be noticed. |
| M3 team identifier at build time and in the requirement | Fixed on paper, broken at runtime (R1) | `requirement(teamIdentifier:)` adds `certificate leaf[subject.OU]` and returns nil for a missing or malformed team; the helper refuses all connections then. `build-app.sh` requires `SIRVEN_TEAM_IDENTIFIER` and a real signing identity, no ad hoc fallback. Mutation: removing the team clause fails 1 test. Nothing personal committed: `git grep` for `host_na8kye9eas` and `/Users/` over `macos` and the new test finds nothing. |
| S1 12-hour ceiling | Fixed, tested | Watcher `MAX_HOLD` (default 43200), `capped` until bb has been idle for the idle window. Mutation (ceiling check disabled) fails `test_the_ceiling_releases_a_hold_and_holds_again_only_after_bb_is_idle`. Note: a watcher restart (launchd `KeepAlive`) resets the clock; acceptable because the holder-side battery release and the 300 s lease still bound it. |
| S1 battery below 20 percent | Fixed, tested | `Holder.swift` releases the hold (and lid-closed with it) on battery below 20; unreadable level is not treated as low; 20 exactly still holds. Mutation (threshold 10) fails 5 tests. No hysteresis: a Mac hovering at 19 to 20 percent can flap hold and release on charge; harmless. |
| S2 marker before pmset | Fixed, tested | `SleepDisableGuard.enforce` writes the marker, then runs pmset, removes the marker if pmset fails. Mutation (marker after pmset) fails 1 test. |
| S3 signal handling | Fixed | Helper uses `DispatchSource.makeSignalSource` on the main queue for SIGTERM and SIGINT after `signal(n, SIG_IGN)`; the revert runs in ordinary code. Not covered by a test (cannot be, in process); read and accepted. |
| S4 complete removal | Fixed | `install.sh remove` stops the agent, deletes the plist and the copied watcher directory, runs `sirven-keep-awake helper unregister` (which reverts lid-closed first, then `SMAppService.unregister()`), and prints the two root commands for a marker left behind instead of running them. Tested by `test_remove_stops_the_agent_before_removing_its_files_and_unregistering_the_helper`. |
| Installer validates before any launchctl call | Fixed, tested | Argument and every prerequisite are checked before `stop_agent`; usage error exits 64. Mutation (stop moved ahead of the checks) fails `test_the_installer_stops_nothing_when_a_prerequisite_is_missing`. The host comes from `bb status --json`; I confirmed `.thread.environment.hostId` exists in that output here. |
| S5 plist mode 600 and no server URL | Fixed, tested | `umask 077` plus `chmod 600`; the plist carries `SIRVEN_BB_HOST` instead of `BB_SERVER_URL`. Mutation (umask 022, no chmod) fails the install test. |
| S6 watcher and helper tests | Mostly fixed | 13 watcher tests in `tests/unit/test_keep_awake_watcher.sh` and 20 new Swift tests; mutation results above (7 of 9 mutations caught; survivors: the timer wiring and the plist keys). |
| N1 hard-coded host id | Fixed | The script now requires `SIRVEN_BB_HOST` (`:?` error); install derives it. |
| N2 leaked scratch files | Fixed | One `mktemp -d`, removed by an `EXIT` trap; tested. |

### The two deviations

1. **Status reads `pmset -g` directly instead of a new helper call: accepted, and better than what I proposed.** `pmset -g` needs no privilege, so `sirven awake status` reports the system's own answer even when the helper is not approved, is not running, or is refusing connections, which are exactly the cases where a helper-reported value would be least trustworthy. It also adds no method to the root-facing XPC surface, so the privileged interface stays one method. The JSON field `systemSleepDisabled` is nullable and the text says "unknown" when pmset does not answer. Caveat to document: it reports the setting whoever set it, so it can read "on" with `lidClosedActive` false when the user's own `disablesleep 1` is on; the status text already labels it "read from pmset now".
2. **A refused lid-closed request waits 15 seconds before the next one: accepted.** `Holder.setLidClosed` records `lastAsked`, resends at most every 15 s while lid-closed is wanted (this also covers a restarted helper that forgot the request, which matters now that `KeepAlive` restarts it), and never delays turning it off. A refusal sets `lidClosedActive` false and surfaces the problem. Tests: asked-again-every-15-seconds, refused-waits, off-never-held-back; a mutation to interval 0 fails 4 tests. One small residual (unchanged from before, so not a regression): if the call that turns lid-closed off throws, the connection is not invalidated until the holder exits (about 3 seconds later), which also drops the request.

### Regressions

None found beyond R1. The watcher's ceiling does not change release or user-release behavior (existing tests still pass), the `EXIT` trap composes with the signal trap (the signal trap exits, which runs the cleanup), and the library, command and lifecycle behavior from the first review still pass 40 of 40.

### Should fix (new, small)

- **S-new-1.** Add a test that the helper's timer actually fires: construct `KeepAwakeHelperCore` with `interval: 0.05`, clear the fake setting, wait 0.3 s, and assert it was asserted again without calling `recheck()`. Add a plain test that the shipped helper plist contains `RunAtLoad` and `KeepAlive` true (a `plutil -extract` check in the shell tests).
- **S-new-2.** Document in the README that `sirven awake status` can show the setting on while lid-closed is off when the user's own setting is on.

### Verdict

CHANGES REQUIRED. Everything from the first review is fixed except that R1 makes the helper refuse the real app, so lid-closed operation cannot work as built. After R1 is fixed (and ideally S-new-1), this is ready to approve. Reviewed tip: b165c95.
