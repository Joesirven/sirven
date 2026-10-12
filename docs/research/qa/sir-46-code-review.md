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
