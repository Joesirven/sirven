# SIR-46 code review: the phone runner supervisor

Reviewed: `git diff origin/main...HEAD` on branch `sir-46-code-review-xcode-free-runner-supervisor-thr_qrpf8gtxtr` (head d7cdf01). Reviewer worked inline, read only, did not touch the phone and did not run pymobiledevice3 (its installed source was read).

Verdict: **CHANGES REQUIRED** (one must fix, five should fix, the rest nice to have).

## Test and lint evidence

| Command | Exit status | Notes |
|---|---|---|
| `make test` | 2 | 3 failures, all in `tests/unit/test_preflight.sh` / install flow and unrelated to this diff: `test_install_started_by_sh_says_to_use_bash` (macOS `sh` is bash, so `sh install.sh --help` exits 0), `test_enter_twice_accepts_the_shown_defaults`, `test_input_that_ends_takes_the_defaults`. The diff does not touch `install.sh`. I did not re-run them on `origin/main`, so "pre-existing" is inferred, not shown. |
| `make lint` | 0 | `bash -n` clean on 55 files; shellcheck is not installed, so it was skipped. |
| New tests | pass | `test_phone_runner_unit_tests_pass` ok; `test_phone_start_*` (three preflight tests) ok. |

## Must fix

### 1. A live tunnel never restarts, so the launcher can loop forever against a stale address
`lib/phone_bridge.py:626` (`supervise`), `:684` (`_restart_launcher`).

Evidence: pymobiledevice3 11.28.2, `cli/remote.py` `native_tunnel_task`, ends with `await asyncio.Event().wait()  # hold the assertion until Ctrl-C`. The native tunnel process therefore does **not** exit when the phone is unplugged, rebooted or locked out. `supervise` restarts the tunnel only when the tunnel process dies, and otherwise restarts only the launcher with the address read once at startup. After a replug the address or the remote service discovery session can change or go dead, the launcher fails every time, and the tunnel is never restarted. This is the exact situation a supervisor exists for, and it also makes open item "a changed tunnel address is only picked up when the tunnel exits" a real failure rather than a theory.

Fix: count consecutive launcher failures that did not reach `STABLE_SECONDS` (the `Backoff` already sees the uptime). After a small number (suggest 3), call `_restart_tunnel` instead of `_restart_launcher`, and reset the count when a launcher stays up. Add a test with a launcher that exits at once and a tunnel that lives, asserting the tunnel restarts and the launcher receives the new address.

## Should fix

### 2. The child processes' output is never shown, so a failing launcher is silent
`lib/phone_bridge.py:518` (`Child`), `:684`. `Child.lines()` is read only to find the tunnel address (`:647`). When the launcher fails (wrong bundle identifier, runner not installed, user interface automation switch off, Developer Mode off), the owner sees "the launcher stopped; starting it again" every 30 seconds with no reason. Fix: when a child exits, print its last few lines (for example the last 5 from `recent`) with the restart message; the deque already holds them.

### 3. Nothing stops two supervisors, and a hard kill leaves orphans plus stale process identifiers
`command_start` (`:705`) and `_record` (`:699`). A second `sirven phone start` starts a second tunnel and launcher and overwrites `runner.json`, orphaning the first pair's identifiers. After `kill -9` of the supervisor the tunnel and launcher keep running (the children are not in a death-linked group), and `runner.json` stays. Then `runner_status` (`:502`) calls `process_alive(pid)`, which only does `os.kill(pid, 0)`, so a reused process identifier reports "running" for something unrelated, and an orphaned-but-real tunnel is reported "running" after the supervisor is gone. This confirms the implementer's open item, severity should fix, not must fix, because it needs a hard kill. The recorded `supervisor` identifier is written but never read. Fix: in `command_start`, refuse (code 64 or 1, plain words) if `runner.json` names a live `supervisor` that is not this process; in `runner_status`, report "not running" when the supervisor identifier is dead, regardless of the children. Optionally compare the process start time or command line with `ps -o lstart=,command= -p`.

### 4. No checksum on the downloaded runner zip, and the tag is mutable
`lib/phone_bridge.py:1387`, `docs/phone-interface.md` step 4. `curl -L -o ... && unzip -o` fetches a prebuilt app that is then signed with the owner's certificate and runs with user interface automation rights on their phone. A tampered or replaced release asset would run as the owner. GitHub publishes a digest for the asset: `WebDriverAgentRunner-Runner.zip` (1,139,669 bytes) in `v16.14.0` reports `sha256:6f7758f72d348d2c35c3fd134fa76a941bba0c447de04b2e9d065682f31fc47f` (read from the GitHub releases API during this review; the implementer should re-fetch it and confirm it matches what their own spike downloaded). Fix: add a constant `WEBDRIVERAGENT_RELEASE_SHA256`, print `echo "<sha>  runner.zip" | shasum -a 256 -c -` between `curl` and `unzip`, and use `curl -fL` so a 404 page is not saved as the zip. Same for `pymobiledevice3==11.28.2`: version-pinned but not hash-pinned; acceptable, mention only.

### 5. The docs point to an xtool route the document does not contain
`lib/phone_bridge.py:1389` says "route A: the xtool route in docs/phone-interface.md", but that file names the route (steps 5 and the verification note) and gives no commands. The commands exist only in `docs/research/xtool-lighter-phone-path.md` (line 55: `xtool auth login`, `xtool install WebDriverAgentRunner-Runner.app`). An owner following the setup text cannot do route A. Fix: either add the two xtool commands and the open questions to step 5, or point the setup line at `docs/research/xtool-lighter-phone-path.md`. Also, route B builds from the cloned source and never uses the downloaded zip, so step 4 (download) is pointless for route B; say "route A only" on that step.

### 6. No signal handling for hang-up, and cleanup is not exception-safe
`lib/phone_bridge.py:607` (`run`), `:553` (`Child.stop`), `:634` (`stop`). Only SIGTERM and Ctrl-C are handled. When the terminal closes (SIGHUP) or an ssh session drops, the supervisor dies by default action; the children usually get the hang-up too, but not under `nohup`, `tmux` detach edge cases or a launch agent, leaving orphans. Also `stop()` stops the launcher first and the tunnel second without `try/finally`, so an exception or a second SIGTERM during the launcher's stop leaves the tunnel running. Fix: install `interrupt` for SIGHUP as well, and wrap each child stop in `try/finally`. A second small gap: a signal between `Popen` returning and `self.tunnel = Child(...)` completing (`:518` to `:642`) leaks that child (microsecond window; nice to have on its own).

## Nice to have

7. No test for a failed tunnel restart (the implementer's open item). `_restart_tunnel` (`:666`) swallows `Refusal` and retries on the next poll, which is correct reading of the code (`self.tunnel` is `None`, so the next loop iteration restarts again, and the backoff doubles because the uptime is 0). A test with a tunnel command that prints an address once and then a command that exits silently would lock this in. Severity low.
8. `Refusal("missing_tool", MISSING_TOOL, 1)` (`:523`) passes `1` where the third argument is an HTTP status (`status=403` default, `:104`); main only prints `refusal.said` and exits 1, so it works, but it is the only refusal with a non-HTTP status. Use 424 or 503 for consistency, or drop it (`tunnel_no_address` uses 503).
9. Option injection: `re.fullmatch(r"[A-Za-z0-9.-]+", bundle)` (`:707`, same pattern at `:957` and `:1374`) accepts a value starting with `-`, which would be read as an option by `pymobiledevice3 ... xcuitest`. Require a leading alphanumeric: `[A-Za-z0-9][A-Za-z0-9.-]*`. Source is the owner's own environment variable, so low.
10. `subprocess.Popen(text=True)` (`:521`) needs Python 3.7; `lib/preflight.sh` still sets `PREFLIGHT_MINIMUM_PYTHON="3.6"`. macOS ships 3.9 so no real impact; use `universal_newlines=True` or raise the floor.
11. Printed setup commands interpolate `~` paths unquoted (`:1387`); a home folder with a space breaks them. Pre-existing pattern in `command_setup`; `shlex.quote` the folders.
12. `runner_status` calls `state_file`, which creates the state folder as a side effect on a plain `status`; this matches existing behaviour of `Phone.status`, so no change needed. Listed for completeness.

## Checked and found correct

- **Address parsing.** `TUNNEL_ADDRESS` and `TUNNEL_PORT` (`:461`) match the real output in `/tmp/sirven-xtool-spike/ptunnel.log` (`RSD Address: fdad:de9c:ad9e::1`, `RSD Port: 50562`), and the test uses a different Internet Protocol version 6 address with colons. The source prints the plain-text form when output is not coloured (`cli/remote.py`, `native_tunnel_task`); coloured output (a terminal) would add escape codes, but `Child` reads a pipe, so the plain form is what arrives. A prefix match with `strip()` is sufficient.
- **Restart with capped backoff.** `Backoff` doubles to the cap and resets after the stable time; the test pins `[1, 2, 4, 8, 16, 30, 30]`.
- **Launcher restarts with the tunnel.** `_restart_tunnel` stops the launcher, restarts the tunnel and starts the launcher with the new address; tested (`test_a_dead_tunnel_restarts_...`).
- **Cleanup on interrupt and on errors.** `run` stops both children in `finally` and removes `runner.json`; tested for Ctrl-C during startup and during supervision, for a tunnel that never prints, and for a missing tool.
- **Exposure.** All processes are started with argument lists, no shell. The tunnel is Apple's kernel tunnel (`--native`, no root); the printed address is a unique-local Internet Protocol version 6 address on this Mac. Nothing in the diff binds a listening socket; the existing `serve` stays on 127.0.0.1. `runner.json` is written with `write_private` (mode 0600, state folder 0700) and holds only process identifiers and a start time.
- **Style.** `start` is registered in `main` like the other subcommands, listed in the module help, and refusals go through `Refusal` and `fail(..., 64)` as in `command_setup`. Naming follows the file.
- **Docs.** Full Xcode is no longer a run-time requirement in the README and `docs/phone-interface.md`; route B (Xcode) is still described as sign and install once, the `xcodebuild` command is the same as before apart from the source folder and the Ctrl-C note; go-ios is not recommended anywhere in the diff (only in the research note, as "not recommended yet"). The phone-side steps (Trust, Developer Mode, device management trust, user interface automation switch) are unchanged and correct.

## Suggested order of work

1. Finding 1 with its test.
2. Findings 2 and 3 (small, same file).
3. Finding 4 and finding 5 (setup text and docs together, one commit).
4. Finding 6, then the nice-to-haves as time allows.

## Re-review at 6eaa62d

Reviewed `git diff d7cdf01 6eaa62d` (lib/phone_bridge.py, docs/phone-interface.md, tests/phone/test_phone_runner.py) in a scratch worktree at 6eaa62d. Read only; the phone was not touched. Test results are in the last table of this section.

### Status of the first review's findings

| # | Finding | Status | Evidence |
|---|---|---|---|
| 1 | Live tunnel never restarted after launcher failures (must fix) | **Resolved** | `_launcher_stopped` counts quick failures and, at `LAUNCHER_FAILURES_BEFORE_TUNNEL_RESTART` (3), calls `_restart_tunnel` with a new address. Test `test_three_quick_launcher_failures_restart_the_tunnel_for_a_new_address` asserts three launches on 10.0.0.1, then 10.0.0.2. |
| 2 | Child output never shown | **Resolved for the launcher, with a regression** (see R1) | `show_last_output` prints the last 5 lines on each restart; test `test_a_launcher_that_stops_shows_the_reason_it_printed`. The initial tunnel failure (`tunnel_no_address`) still prints only the fixed message, which is acceptable. |
| 3 | Two supervisors, orphans, stale identifiers | **Resolved** | `take_runner_lock` (an exclusive `flock` on `runner.lock`) is held for the whole run and released by the system on a hard kill; `run` refuses with `already_running`; `runner_status` says "not running" when the lock is free; `_refuse_leftovers` refuses a new start while recorded children are alive. Four new tests cover it. The lock file descriptor is non-inheritable (Python default), so orphaned children do not keep the lock held. |
| 4 | No checksum on the runner zip | **Resolved in the setup text, broken in the document** (see R2) | `WEBDRIVERAGENT_RUNNER_SHA256` equals the digest GitHub reports (`6f7758f7…c47f`); setup prints `curl -fL … && echo '<sha>  path' \| shasum -a 256 -c - && unzip`. |
| 5 | xtool route not in the document; zip pointless for route B | **Resolved** | Document step 4 now has route A (brew install, download, check, `xtool auth login`, `xtool install`, known limits) and route B marked as not using the download; the setup plan prints the same split and a test asserts the download sits between route A and route B. The brew line matches the research note (line 63). |
| 6 | No hang-up handling; cleanup not exception-safe | **Resolved** | `STOP_SIGNALS` = terminate and hang-up; `stop()` nests `try/finally` so the tunnel is stopped even if the launcher stop raises; tests for hang-up and for a failing launcher stop. |
| 7 | No test for a failed tunnel restart | **Resolved** | `test_a_tunnel_that_does_not_come_back_is_retried_and_no_launcher_starts_without_an_address`. |
| 8 to 11 | Nice-to-haves (status code 1 in `Refusal`, leading dash in bundle, Python 3.6 floor, unquoted paths) | **Not changed** | Still open, low. `Refusal("already_running", …, 1)` repeats the odd status argument. |

### The three gaps the implementer named

- **Window between starting the tunnel process and assigning `self.tunnel` (`Child.__init__` then `_start_tunnel`).** Accept as nice to have. The window is a few Python statements long (thread creation, return, assignment) and needs a signal in exactly that moment. Cheap fix if wanted: in `Child.__init__`, wrap everything after `Popen` in `try/except BaseException` and kill the process before re-raising.
- **Process identifiers in `runner.json` trusted while a supervisor holds the lock.** Accept. While the lock is held the supervisor itself is the writer, and the identifiers are rewritten on every restart through `_record`. A narrow stale window exists between a child dying and the next poll (0.5 seconds), which only makes status lag. Separately, the leftover check after a hard kill trusts bare identifiers: if the operating system reused an identifier for an unrelated process, start refuses and tells the owner to stop "process number N, for example with kill". That is a refusal, not a destructive action, but the advice could lead to killing an unrelated process (see R4).
- **A status call that briefly takes the lock can make a simultaneous start refuse.** Real but negligible: the status call holds the exclusive lock for microseconds, and the refusal text ("already running") would be wrong for that instant. Two simple fixes: have `run` retry the lock for about 1 second before refusing, or make `runner_status` probe with a non-acquiring lock query (`fcntl.lockf` with `F_GETLK` is not available through Python directly, so the retry is simpler). Nice to have.

### New findings introduced by the fixes

**R1 (should fix). The new last-output feature prints the phone's device identifier.** `show_last_output` (lib/phone_bridge.py, near the supervisor) prints the last 5 lines of each stopped child. The tunnel's output includes `Identifier: <device identifier>` (it is line 2 of 6 in the real tunnel output, so it falls inside the last 5), and this happens on every tunnel restart. Reproduced by feeding the real tunnel lines to `show_last_output`: it printed `| Identifier: 00008101-00112DD42193001E`. `docs/phone-interface.md` line 31 promises the phone's serial number never appears in any output, and the module already treats `SerialNumber` as private. The device identifier is not literally the serial number, but it is a device-unique value that ends up in terminal scrollback or any log the owner redirects. Fix: skip lines that start with `Identifier:` in `show_last_output` (and add a test), or print only launcher output.

**R2 (should fix). The checksum command in `docs/phone-interface.md` cannot succeed.** The block uses `echo '<sha>  ~/.sirven/WebDriverAgent/runner.zip' | shasum -a 256 -c -`; the tilde sits inside single quotes, so the shell does not expand it. Reproduced: `shasum` printed `~/nonexist/r.zip: No such file or directory`, `FAILED open or read`, exit 1. It fails closed (nothing is unzipped), so it is not a security problem, but the documented route A cannot be followed as written. The setup plan output is fine because it prints expanded paths. Fix: in the document, use `cd ~/.sirven/WebDriverAgent && echo '<sha>  runner.zip' | shasum -a 256 -c -` or use `"$HOME"` outside the single quotes.

**R3 (nice to have). The count of quick launcher failures is not reset when the tunnel restarts for another reason.** `quick_failures` resets only on a stable launcher or at 3. Two failures, then a tunnel exit, then one failure of the new launcher causes an extra tunnel restart. Reset it in `_restart_tunnel`.

**R4 (nice to have). The leftover refusal can name a reused process identifier.** Confirm the recorded identifier is still a `pymobiledevice3` process (`ps -o command= -p N`) before refusing or advising `kill`, or word the message "check what these are before stopping them".

**R5 (nice to have, behaviour note).** When the launcher fails for a reason unrelated to the tunnel (wrong bundle identifier, interface automation off), the tunnel is now also restarted every third failure. The backoffs keep growing to the 30 second cap, so this is bounded, but it churns Apple's tunnel. The printed last output (R1 aside) tells the owner why; no change required.

### Results at 6eaa62d
