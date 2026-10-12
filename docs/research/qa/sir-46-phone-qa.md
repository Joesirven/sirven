# SIR-46 phone quality assurance (partial report, 2026-10-12)

Status: PARTIAL. The iPhone was not attached to this Mac, so every step that needs the phone
(steps 3 to 7) is NOT RUN. Nothing below claims a result for those steps.

Branch: sir-46-quality-assurance-real-iphone-test-of-the-thr_g5ntaeebpm, head d7cdf01 when tested.
Host: Joses-MacBook-Pro-4.local (Omashu).

| Step | Result | Evidence |
|---|---|---|
| 1. Free memory, phone plugged in and unlocked | FAIL (phone absent) | see below |
| 2. Follow `setup` as a new owner | PASS with notes | see below |
| 3. Start supervisor, no `xcodebuild` | NOT RUN | needs phone |
| 4. status, screenshot, accessibility tree, active app | NOT RUN, except status | `no_phone` |
| 5. Kill tunnel, then launcher; recovery times | NOT RUN | needs phone |
| 6. Interrupt supervisor, no leftover processes | NOT RUN | needs phone |
| 7. Resident memory over two minutes | NOT RUN | needs phone |
| 8. The 3 failing tests predate the work | PASS (confirmed) | see below |

## Step 1
- `vm_stat` at 13:28:35 PDT (16384-byte pages): free 3751, active 261269, inactive 256431,
  speculative 3834, wired not shown in the first lines. `memory_pressure`: system-wide free
  percentage 51% (an earlier reading in the same session said 66%).
- `bin/sirven phone status` (exit 0): `"phone": "no_phone"`, `"said": "no iPhone is plugged in
  over USB"`, tunnel and launcher `not running`.
- `ioreg -p IOUSB` lists only the Mac's own USB controllers; no iPhone entry. `/var/run/usbmuxd` exists.
- `pgrep -fl 'xcodebuild|pymobiledevice3'` before any start: no match (exit 1).
- Parent thread was told with `bb thread tell` and asked Jose to plug in and unlock the phone.

## Step 2: setup as a new owner
- `bin/sirven phone setup --team TEAMID --bundle com.josesirven.wda.runner` exit 64: "--team needs
  your ten character Apple development team, from Xcode > Settings > Accounts". Correct refusal
  (five characters is not ten). With `--team ABCDE12345` (a placeholder, not a real team) exit 0
  and it printed 12 steps. Step 11 gives the runner identifier
  `com.josesirven.wda.runner.xctrunner`.
- Step 3 command run exactly: `uv tool install pymobiledevice3==11.28.2` exit 0 (uv's tool
  installer reported "Installed 1 executable: pymobiledevice3"), 1.55 s wall time (dependencies
  were in uv's cache, so a first install on a clean machine will take longer), 133 MB on disk
  under `~/.local/share/uv/tools/pymobiledevice3`. `pymobiledevice3 version` prints 11.28.2.
- Steps 4 to 10 were not executed (download and signing; the runner is already on the phone).
- Notes on clarity:
  1. Steps 5 to 8 read as a list of three routes in sequence; a new owner may try to do all of
     them. Step 5 and step 6 say "or" only in step 6. Suggest numbering "A or B" once.
  2. The `--team` error message points to Xcode, but the light path is meant for owners without
     full Xcode; the message gives no other place to find the team identifier.
  3. Step 4 downloads the runner that step 5 may not need when the runner is already installed.

## Step 8: the three failing tests predate this work
Scratch worktree of origin/main at 418133c under /tmp (removed afterwards). Command
`bash tests/run.sh preflight` and `bash tests/run.sh questions` in each tree (the exit codes did
not survive the pipe in my capture; the pass and fail counts are the evidence):

| Tree | preflight | questions |
|---|---|---|
| origin/main 418133c | 16 passed, 1 failed: test_install_started_by_sh_says_to_use_bash | 20 passed, 2 failed: test_enter_twice_accepts_the_shown_defaults, test_input_that_ends_takes_the_defaults |
| branch d7cdf01 | 19 passed, 1 failed: same test | 20 passed, 2 failed: same two tests |

The implementer's claim holds: the same three tests fail on both. The branch adds 3 passing
preflight tests. Also `python3 -m unittest discover -s tests/phone`: 78 tests OK (exit 0). I did
not diagnose why the three fail (not in scope; possibly this machine's shell or terminal setup).

## Defects so far
1. (Low) Setup wording: see the three clarity notes under step 2.
2. (Info) Three tests fail on main and on the branch alike; not caused by SIR-46.

No product defects found yet; the supervisor itself is untested on a real phone.

## To finish when the phone is attached
Run steps 3 to 7 per the plan, including the screenshot at docs/research/qa/.
