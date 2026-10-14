# SIR-32 review: the kill switch (`install.sh revoke --all`)

Reviewer: code review thread thr_z2dqwmzswi (Sonnet 5.5), for parent thr_4mddufbqcn.
Reviewed: `git diff origin/integration/2026-10-14-wave-3...HEAD`, commits fb7a73e, e1fcf64, 5966e9f, e0906e2, 009137e.
Reviewed commit: `009137e1424d6dc8d797f180fa3ca0a29db953e8`.
Stance: the agent is hostile, runs in parallel with the kill switch, and owns its home folder.

Verdict: **CHANGES REQUIRED** (4 must fix, 7 should fix, 8 nice to have). The core is good: the process sweep, the lock, the
no-follow key removal and the grant restore held up against every attack that needs a live agent. The four must-fix items are
places where the kill switch can be undone, bypassed or left unfinished by something the agent plants or by a normal owner action.

## How this was run (and what was not)

- **Docker Desktop on this Mac cannot start** ("Invalid virtual machine configuration. The storage device attachment is
  invalid"). I did not reset it (that deletes its images). With the parent's approval I ran every container on the server
  ba-sing-se, one at a time, each with `--memory 256m --memory-swap 256m --pids-limit 256 --cpus 1 --network none
  --cap-drop NET_RAW`, available memory checked before each run (never below 1.3 GB), no existing container touched.
  All containers and images I created are removed. The installer was never run on the Mac.
- **Scenario coverage, stated exactly.** The first pass of `bash tests/harness/run-linux.sh` ran with the harness's own defaults
  (256 MB, 256 processes, no swap or processor cap), before the parent's limits reached me, and I stopped it myself at scenario
  22 when I saw that scenario 27 asks for 3 GB; it therefore has **no exit status**. In that pass 01 to 16, 18, 20 and 21 passed
  and 17 and 22 failed (below). Under the parent's caps I then ran 01 to 04, 19, 22 to 25, 28 to 38: all passed except 22.
  **Scenarios 05 to 18, 20, 21 passed only in the first pass; 26 and 27 were not run.**
- **Scenarios 17 and 22 fail on this server** with `OSError: File name too long` while building 12,000 or 3,000 nested
  folders. Scenario 17 fails identically on the base branch (`origin/integration/2026-10-14-wave-3`), so this is the server's
  file system, not this branch. Neither touches the kill switch. Scenario 22 was not rerun on the base branch.
- **`make test`** (local; it ran past the tool's ten minute limit and finished in the background, so the figures are from its saved output): exit 2, 460 passed, 4 failed. Three are the known macOS installer tests
  (`test_install_started_by_sh_says_to_use_bash`, `test_enter_twice_accepts_the_shown_defaults`,
  `test_input_that_ends_takes_the_defaults`). The fourth, `test_make_lint_passes_with_or_without_shellcheck`, fails only because
  of the recorded lint baseline below.
- **`make lint`** (local, foreground): exit 2, bash syntax check clean on 65 files, shellcheck 28 findings. I normalized the findings
  (file, rule, message) and compared them with `docs/research/qa/wave-3-shellcheck-baseline.txt`: **28 baseline, 28 now, the
  difference is empty, so 0 new findings from this branch.** The 28 are the baseline and predate this work.
- The attack scripts are in `docs/research/qa/sir-32-review-attacks/`. Each mounts the repository at `/src` and runs as root
  in a fresh container; `run-limited.sh` is the capped runner.

## Must fix

### M1. A stopped revoke is undone by a plain install, without `--reinstate`

`lib/kill_switch.sh:228-230` runs the same `quiesce` helper an install uses, so it writes the install's marker
`agent-quiesce.json` holding the account's earlier state (unlocked, no expiry). The refusal that is meant to stop an install on a
revoked account, `kill_switch_account_cut_off` (`lib/kill_switch.sh:161-168`, used at `lib/adopt.sh:298` and
`install.sh:263`), only fires once the shell is `nologin`, which is step 3. Between step 1 and step 3 the account is locked and
expired but not "cut off". A plain install then passes the refusal, and its grant step "give the account back" (`release`,
`lib/access_control_snapshot.py:735`) finds the leftover marker and restores the earlier state.

Evidence (`a2-partial-then-install.sh`, a unit that will not stop, revoke exits 4):
```
after the stopped revoke:     passwd=!* expire='1' shell=/bin/bash keys=authorized_keys marker=yes
plain install exit 0
after the plain install:      passwd=*  expire=''  shell=/bin/bash keys=authorized_keys marker=no
```
The agent is back: unlocked, no expiry, shell and key in place. A second route, a real interrupt (`b1-kill-at-each-step.sh`: the whole installer process group is sent the kill signal just
before the Kth of the 10 state-changing commands; installer exit status 137 every time), then a plain install: the account is
unlocked after kill points 2 (before the expiry), 3 and 4 (inside the process sweep, with the agent's process still alive) and 5
(before the nologin shell). From kill point 6 on the install is refused with exit 2, correctly. Kill point 1 changes nothing, so
it is not a finding.
An agent that can make step 1 or step 2 fail (a unit it keeps alive, a process storm that outlasts the 20 sweeps) turns a
routine "run install again" by the owner into a restore of its access. Two kill switch and install runs at the same time
(there is no lock anywhere, see S5) hit the same path.

Fix, in this order of value:
1. In `command_release` (`lib/access_control_snapshot.py:735`) refuse to unlock, and exit non-zero with a message, when a
   revoke marker exists. This closes every route, including a concurrent install.
2. Give the kill switch its own marker file (for example `$STATE_DIR/agent-revoked.json`) instead of sharing
   `agent-quiesce.json`, written before the first change, kept after the run, and removed only by `--reinstate`. Make
   `kill_switch_account_cut_off` true when that file exists, in addition to the shell and expiry test.
3. Remove the window: lock, expire and set the nologin shell in the one `usermod` call inside step 1, so the account is never
   half cut off. If the install's marker exists when revoke starts, overwrite it with `{"locked": true, "expire": "1"}`.
4. Correct `docs/PERMISSIONS.md`: "(7) the marker is deleted so no later release can unlock the account" and "an install on an
   account the kill switch cut off refuses" are true only after the run finishes or after step 3.

Add a harness scenario that makes step 2 fail (scenario 36's stand-in does it) and then runs a plain install.

### M2. The kill switch runs, as root, whatever code sits in the folder it was started from

`install.sh:16` sets `ROOT_DIR` to the folder of the script that was run, and `lib/kill_switch.sh:24-26` runs the helpers from
there ("so the lock never waits on the pinned copy"). The installer's default granted folder is the current folder, which is
often the repository itself. If the owner runs `bash install.sh revoke --all` from a copy the agent can write, the agent's
edits run as root, and it can replace the lock with a no-op that prints success.

Evidence (`d1-writable-source.sh`): copy of the package at `/work/repo`, installed with `--path /work/repo --level builder`;
the agent appends `touch /tmp/ROOT-RAN-AGENT-CODE` to `lib/kill_switch.sh`; the owner runs `revoke --all` from `/work/repo`:
```
revoke from the granted copy: exit 0
-rw-r--r-- 1 root root 0 Oct 14 12:37 /tmp/ROOT-RAN-AGENT-CODE
not ok  the kill switch did not run code the agent edited
```
The pinned copy `/var/lib/sirven/package` is root-owned (`drwxr-xr-x root root`) and safe; the documentation tells the owner to
use it, but `uninstall.sh` usage and `AFTER_ALPHA_SESSIONS` now say `sudo bash install.sh revoke --all` from the current folder.

Fix: at the start of `revoke` in `main` (`install.sh`, before the first source of `lib/kill_switch.sh`), when the pinned
`install.sh` exists and is owned by root and not writable by group or others, and `ROOT_DIR` is not the pinned folder,
`exec bash "$pinned/install.sh" "$@"`. When there is no pinned copy, refuse if the service user can write to `ROOT_DIR`, `lib`,
or any folder above them, tested with the agent's identity (`setpriv --reuid ... test -w`, which honors modes and access
lists), with a message that names the pinned copy. The same check belongs in `uninstall.sh`.

### M3. The agent can stop revoke before it restores the grants, with one file name

`lib/kill_switch.py:36-47` (`open_folder`) turns "not a directory" into a `Failure`, and `command_remove_keys` calls it at
`lib/kill_switch.py:80` (`command_keys_gone` at line 140 as well). If the agent replaces `~/.ssh` with a regular file (or a named
pipe, a socket), step 4 fails and the run stops with exit 4 before the access-list restore (step 5 onward).

Evidence (`a3-ssh-is-a-file.sh`):
```
error: .ssh cannot be opened without following a link (Not a directory)
error: step 4 failed: remove every authorized key of agent, by name, without following a link
revoke exit 4
acl on /srv/app: user:agent:rwx   default:user:agent:rwx      <- the grant is still in force
grant record: agent.json                                      <- not renamed
```
The account is already locked, expired and on `nologin` (layers 1 to 3 held, and `install` is correctly refused), but the
promise "restores every grant" is broken until someone runs `rm` as root by hand, and the same state makes `uninstall.sh`'s key
removal fail (reasoned from `lib/layout.sh`, not run). The recovery text is right, but in an emergency one planted name should not need hand work.

Fix:
1. In `lib/kill_switch.py`, when `.ssh` exists and is neither a folder nor a link, unlink the name (sshd can read no key from
   it), print what was done, and go on; do the same for `remove-ssh-folder`. A non-folder home folder gets the same treatment.
2. Make a failed step non-fatal for the steps that do not depend on it: lock first, then run the remaining steps, collect the
   failures, and exit 4 at the end listing every failed step. The ordering note in `lib/kill_switch.sh:7-9` shows only the
   services step must come before the access-list restore.

### M4. The refusal list uses 500, so Linux system accounts are not protected

`lib/kill_switch.sh:200` refuses user numbers below 500. That was the old Red Hat and Mac boundary. Debian, Ubuntu and
Fedora keep ordinary users from 1000 (`UID_MIN` in `/etc/login.defs`) and system accounts below that, and `useradd -r` hands
out 100 to 999. `nobody` is 65534.

Evidence (`a4-uid-boundary.sh`, Debian 12; `revoke --all --user NAME`):
```
svcdb   (user number 999, useradd -r):  revoke exit 0; locked, expire 1, shell nologin, processes killed
svc700  (user number 700):             revoke exit 0; locked, expire 1, shell nologin, processes killed
nobody  (user number 65534):            revoke exit 0; locked, expire 1, shell nologin, processes killed
www-data (33), _apt (42), daemon (1): refused, exit 2
```
A mistyped `--user postgres` or `--user nobody` takes down a database or breaks every service that drops to `nobody`.

Fix: read `UID_MIN` from `/etc/login.defs` (default 1000 on Linux, 501 on macOS) and refuse below it; also refuse user number
65534 and 4294967294, any account whose group list contains `sudo`, `wheel`, `admin`, `root`, `adm`, `docker` (the install
already refuses to create such an agent, `lib/service_user.sh:22-30`), `SUDO_USER`, and the user running the command
(`logname`). Strongest guard: refuse an account that neither the install record nor a grant record names, unless the owner
adds an explicit flag. Add the system-account cases to scenario 03.

## Should fix

### S1. No final sweep and no final check: "finished" can be printed while the agent runs

The one process sweep runs in step 1 (`end_processes`, `lib/access_control_snapshot.py:720-733`); the services step comes
after it, and nothing re-checks at the end. `revoke_finished outcome=finished` (`install.sh`, `apply_for_real`) is written on
exit status 0 of the steps, not on the state of the machine.

Evidence (`b2-residuals.sh`): a root-owned supervisor loop (a stand-in for a service unit with `Restart=always` that starts the
agent's work through `setpriv`/`runuser`, which does not check account expiry) restarts a process of the agent every second:
```
revoke exit 0           (audit: revoke_finished, outcome finished)
agent processes 3 s after revoke finished: 1   (supervised sleep)
```
Fix: after the last step, run a verification pass that reuses the existing read-only checks
(`kill_switch_account_stopped`, `kill_switch_services_stopped`, `kill_switch_keys_gone`, the access-list `status` checks); sweep
again (bounded) if a process of the agent exists; if anything is still wrong, write `revoke_finished outcome=failed`, exit 4 and
print the list of what is left. A unit with `Restart=always` can restart its process between step 1 and step 2; the services step then
stops the unit (and `systemctl stop` ends the unit's whole control group), so that case is covered, but a final check is what proves
it. I could not reproduce a unit restart (the harness has no systemd; see S2), only the supervisor stand-in.

### S2. Service coverage is narrower than "every service that runs as the agent"

`kill_switch_user_units` (`lib/kill_switch.sh:59-68`) asks `systemctl list-unit-files --type=service` and keeps units whose
`User=` is the agent. It misses: instances of template units (`name@agent.service` with `User=%i` is not listed, only the
template is); units created at run time; the timer, socket and path units that start a stopped service again (`stop` plus
`disable` does not stop a timer from firing the service later; the plan stops only `*.service`); and any unit that runs as
root and starts the agent's work by `su`, `runuser` or `setpriv` (invisible to `User=`; S1's final check is what catches it).
Fix: also list loaded units (`systemctl list-units --all --plain --no-legend`), include `.timer`, `.socket` and `.path`
units whose `Unit=` or name maps to a matched service, stop those first, and use `systemctl mask --runtime` where the owner
would not want a reboot to bring the service back. This part is reasoned from the code, not run: the container has no systemd,
so scenario 36 uses stand-ins for `systemctl` and `loginctl` (it proves what is asked of them, not what systemd does). Run one
real test on a machine with systemd before this is trusted (a virtual machine, or the Linux server with a throwaway user).

### S3. Scheduled jobs of the agent are not removed

The kill switch leaves `/var/spool/cron/crontabs/agent` and the `at` queue (`/var/spool/cron/atjobs`) in place
(`b2-residuals.sh`: "crontab left: agent"). Whether `cron` or `atd` runs them for an expired account depends on the login checks
of the distribution; I tried to measure it (`c1-cron-at.sh`, `c2-cron-control.sh`, `c3-cron-control2.sh`) but cron did not run a
job even for a normal account with a password in the container ("Authentication failure" before any change), so **the effect on
a running cron is not established**. What is certain: `--reinstate` would bring the old jobs back to life. Fix: `crontab -r -u
USER`, `atrm` every job of the user (`atq` as root lists them), and say so in the plan and the audit entry; leave the files
alone if the commands are missing and print a warning.

### S4. Silent failures in the services step, and no check

`lib/kill_switch.sh:95` (`systemctl disable ... || true`), `:100` (`loginctl disable-linger ... || true`) and `:101`
(`loginctl terminate-user ... || true`) cannot fail the step. If lingering stays on, the step prints "done" and the run reports
"finished". The done-check `kill_switch_services_stopped` would notice, but only on a second run. This is part of S1's final
verification; at minimum re-run `loginctl show-user --property=Linger` after the call and fail when it is still `yes`.

### S5. Nothing stops two installer runs from overlapping

There is no lock file in `install.sh`, `uninstall.sh` or the libraries (`grep` for `flock` and lock files finds nothing). A
second run (an owner re-running install, an automation) interleaves with a revoke. M1's first fix makes the dangerous
interleaving harmless; still add one lock file under `$STATE_DIR` for install, uninstall and grant changes, and let the kill
switch take it with a short bounded wait and then go on regardless (the emergency command must never be blocked by a hung
install).

### S6. The kill switch cannot run on a real machine yet

`plan_real_apply_refusal` (`lib/plan.sh:317-329`) refuses every real apply outside a container, revoke included, and
`docs/PERMISSIONS.md` says so. That is a consistent alpha rule, but it means the emergency command is the one command that
cannot be used on a real host. Before this ships to a real machine, lift the gate for `revoke --all` on Linux (a revoke only
moves toward less access) after M1 to M4, and run it once on a real machine with Jose present.

### S7. "Already done" is decided once, before step 1, while the agent is alive

Each step's check is evaluated when the plan is built (`plan_step`, `lib/plan.sh`), and `plan_apply` (`lib/plan.sh:377-`) acts
on that stored status. In a rerun, or when the plan takes seconds to build on a large grant, a step judged done (keys gone, shell
already `nologin`) can stop being true before the earlier steps finish, for example a key file recreated by a still-live agent. The
lock, the expiry and the shell are independent layers, so the impact is small, but the comment at `lib/kill_switch.sh:250`
("the plan is read before the first step") shows this was known for one step and is true for all of them. Fix: evaluate the
check again immediately before each step runs. Not run; reasoned from the code.

## Nice to have

- **N1. Named pipe hang.** `count_keys` (`lib/kill_switch.py:55-63`) opens a key file read only after a `lstat` says it is
  regular. If the agent swaps in a named pipe in between, `open` blocks forever. Add `os.O_NONBLOCK` and check `fstat`. (400
  runs against a swapping agent did not hit the window, so this is theoretical.)
- **N2. A vanished name fails the step.** `os.unlink` in `command_remove_keys` raises on `FileNotFoundError` if the name goes
  away between the check and the call; 14 of 400 runs against a swapping agent exited 1 with `authorized_keys: No such file or
  directory`. Catch it and go on (only possible with a live agent, so this cannot happen after a successful sweep).
- **N3. Say what the agent left behind.** The agent's own files stay in the granted folders (`b2-residuals.sh`: a mode 0777
  folder, a script, a copy of a binary), and the kill switch is silent about them. Add to the plan, or to the final audit entry, a
  count and a list of files owned by the agent under the granted paths (`find -user`), flagged when setuid, setgid or world
  writable. Do not delete or change them.
- **N4. Look for other doors.** The kill switch does not look at `/etc/sudoers`, `/etc/sudoers.d` or `doas.conf` for entries
  naming the agent, or at its group list (`docker`, `adm`). The install refuses to make an administrator agent, but the owner can
  add one later. Print a warning from `sudo -l -U USER` and `id -nG USER`.
- **N5. The `nologin` path is hard-coded** (`lib/kill_switch.sh:20`) and the cut-off test compares strings; use
  `command -v nologin` and fall back to `/usr/sbin/nologin`, so Alpine (`/sbin/nologin`) and others work.
- **N6. Speed.** `kill_switch_user_units` forks `systemctl show` once per unit file, hundreds of times, and runs twice (the plan
  check and the action). `systemctl show -p Id,User '*.service'` does it in one call.
- **N7. Audit gaps.** The `reinstate` event (`install.sh:263-265`) has no outcome and is written before the plan is applied even
  if reinstating then fails; a refused revoke (exit 2) leaves no audit entry; `principal` is always "owner". Add an outcome and
  an entry for refusals.
- **N8. Coverage still missing:** macOS (plan output only), real systemd (S2), a running cron or `at` (S3), and scenarios 26
  and 27. Not tested: a kill signal sent while a single helper is half way through its own work (my kill points are between
  commands, so a helper that stops in the middle of one access-list restore is covered only by the existing scenarios 05, 18 and
  29), and two installer runs at the same time (S5, reasoned).

## What held up (evidence)

| Attack | Result |
|---|---|
| Exponential fork storm as the agent (`a1-forkstorm.sh`, limited to 60 processes for the agent's real user) | revoke exit 0 in 2 s, no process left by effective or real user |
| Existing session open, key login before, key login after, keys put back by hand (scenario 30, passes) | session ended, login refused, sshd says the account expired |
| Key file in a nonstandard `AuthorizedKeysFile` (`~/.mykeys`) with `UsePAM no` (`b3-sshd-variants.sh`) | login refused after revoke; the expiry holds without the keys being removed |
| `ControlMaster` socket | master process killed, socket gone |
| `~/.ssh/rc`, keys in other places | not reachable once login is refused |
| Link and named pipe swaps against the key helper, 400 runs with a live swapping agent (`b4-helper-race.sh`) | root's files untouched and unread every time; no hang |
| Revoke killed (signal to the whole process group, installer exit 137) before each of the 10 state-changing commands, then run again (`b1-kill-at-each-step.sh`, mode A) | every rerun reached the same end state as a clean run, exit 0. The audit log after each kill held `revoke_started` and one entry per finished step, and no `revoke_finished`, so an interrupted run is visible as such |
| Same kill points, then a plain install (mode B) | refused (exit 2) for kill points 6 to 10; **unlocked for kill points 2, 3, 4 and 5 (M1)** |
| Revoke twice, then uninstall, planted links, unreadable record (scenarios 31 to 35, 38) | pass |
| Install after revoke refused, `--reinstate` works, and the kill switch takes no `--reinstate` (scenario 37, `install.sh:176-178`) | pass |
| The agent triggering `--reinstate` | not possible: it is an installer option and needs root |
| Access lists after revoke | restored from snapshots; no entry for the agent remains (`b2`, `a1`) |

Items from the brief with no separate test: a setuid binary the agent owns runs as the agent, so the sweep by effective user
and real user (`e0906e2`) covers it; a process that changes both user numbers needs a flaw in a setuid root program, outside this
tool. `at` and `sudo`/`doas`: see S3 and N4.

## Refusal list verdict (brief item 5)

500 is wrong for Linux (M4). It is right for macOS, where the first ordinary user is 501, and the check does not run there
anyway (`lib/kill_switch.sh:198`: `--prefix` skips it; macOS apply is plan only).

## Verdict

**CHANGES REQUIRED.** Fix M1 to M4, add a harness scenario for each (stopped revoke then plain install; revoke from a granted
copy; `~/.ssh` as a regular file; system-account refusals), then re-review. S1, S2 and S6 should land before the kill switch is
allowed on a real machine.

Reviewed commit: `009137e1424d6dc8d797f180fa3ca0a29db953e8`. The commit that adds this document is on branch
`code-review-kill-switch-sir-32-thr_z2dqwmzswi`.

---

# Re-review, round 2

Reviewed: branch `sir-32-kill-switch-applies-revoke-all-thr_5bke6fw45a`, tip `7df24cb70cd5` (commits bc1f9df, 10d5c27, bb5f029, a92eccc,
7736aeb, 523e0fd, 7df24cb). Same limits as round 1, on the server ba-sing-se: `--memory 256m --memory-swap 256m
--pids-limit 256 --cpus 1 --network none`, one container at a time, available memory 1.1 GB or more before every run, no other
container touched. The run was interrupted once (the Mac running this thread went offline); nothing was lost, the server side
was untouched, and the local checks below were rerun after it.

**Verdict: CHANGES REQUIRED.** The four round 1 must-fix items are fixed and hold up. The new trust gate is the part that
fails: it can be steered to a folder the agent controls by editing one field in a file the agent can write, it is skipped in
cases the documentation tells the owner to use, and it checks one path and then runs another. Both severe ones were reported to
the parent when found.

## Round 1 items, rerun against the tip

| Round 1 item | Result at `7df24cb` |
|---|---|
| M1, plain install undoes a stopped revoke | **Fixed.** A real kill before each of the 8 state-changing commands (the sweep now has 8, the lock is one `usermod` call), then a plain install: refused with exit 2 every time, the account unchanged (`b1-kill-at-each-step.sh`, mode B). With a stopped unit (revoke exit 4) a plain install is refused (`a2`). Every rerun of revoke after a kill ends in the clean end state (mode A, all converge); the audit log after a kill holds `revoke_started` and the finished steps and no `revoke_finished`. The one `not ok` line in that run is my own predicate on kill point 1, where nothing had changed yet and the install was refused with exit 2. |
| M2, runs code from a folder the agent can write | **Fixed for the cases it was written for** (`d1`, scenario 40: the kept copy runs instead). Bypasses of the new gate are below (R2-M1, R2-M2, S-A to S-C). |
| M3, one planted name stops revoke | **Fixed.** `.ssh` as a regular file: revoke exit 0, the grant is undone, the name is removed (`a3`). A failing step no longer stops the others (scenario 41). |
| M4, refusal list at 500 | **Fixed.** `UID_MIN` from `/etc/login.defs`; user numbers 999, 700, 65534 and `nobody` refused with exit 2 and nothing changed (`a4`, scenario 42). |
| S1, no final check | **Fixed.** A supervisor that restarts the agent's work twice: the first re-sweep ends it and revoke exits 0 after "checked: no process of agent" (`e7a`). A supervisor that never stops: six sweeps, then exit 4, `revoke_finished outcome=failed`, the account still locked (`e7b`, `b2`), and the message says how to find what starts it. |
| S3, cron and at jobs | **Fixed.** Real `crontab` and `at` in the image: the agent's crontab and both at jobs removed, another account's crontab untouched, an audit entry written (`e8`, scenario 43). Not tested: a running cron daemon (round 1 could not get one to run jobs in a container). |
| S5, no lock | **Fixed in the normal case** (scenario 45, `e6`). See S-D and S-G for what is left. |
| S6, gate on real machines | **Done**, with a prompt (below). |
| S7, plan-time "already done" | **Fixed** (`PLAN_RECHECK`). Exercised by the sweep reruns; no separate attack. |
| S2, services | Re-read only: timers, sockets, paths and template instances are now listed (`lib/kill_switch.sh:88-131`). Still no real systemd in the harness, so stand-ins only (scenario 36). |
| N1, N2 (pipe hang, vanished name) | Fixed in `lib/kill_switch.py` (`O_NONBLOCK` plus `fstat`, `unlink_name`). The 400-run race against a swapping agent (`b4`) shows no root file touched and no hang. |

Also rerun and unchanged in outcome: fork storm (`a1`, exit 0 in 4 s, no process left), nonstandard key file and `UsePAM no` (`b3`,
refused), residuals (`b2`: agent-owned files in the granted folder remain, N3 still open).

## Checks run at the tip

- **Harness, under the caps:** scenarios 01 to 16, 18 to 21, 23 to 25 and 28 to 45 all exit 0 (41 scenarios, none skipped
  within that list; 39 to 45 are new). Not run: 17, 22 and 26 (fail on this server's file system for a reason unrelated to this
  branch, as in round 1) and 27 (needs 3 GB, above the cap).
- **`make lint`** (foreground): exit 2. `bash -n` clean on 67 files; shellcheck 28 findings, normalized and compared with
  `docs/research/qa/wave-3-shellcheck-baseline.txt`: identical, so **0 new findings, 28 baseline findings**.
- **`make test`** (foreground): exit 2, 464 passed, 4 failed. The four are the same as round 1: the three known macOS installer
  tests (`test_install_started_by_sh_says_to_use_bash`, `test_enter_twice_accepts_the_shown_defaults`,
  `test_input_that_ends_takes_the_defaults`) and `test_make_lint_passes_with_or_without_shellcheck` (fails only because of the
  baseline above). An earlier background run of both, before the interruption, gave the same figures.

## New attacks on the new parts

### R2-M1 (must fix). The gate takes the location of the kept copy from a file the agent can write

`lib/trust.sh:48-53` reads the package name from `$ROOT_DIR/project.json` and builds `pinned="/var/lib/$package/package"`.
`project.json` sits in the folder under test, which is the folder the agent was granted. The agent sets `"name": "../../tmp/evil"`.
`pinned` becomes `/var/lib/../../tmp/evil/package`, a copy the agent made. `lib/trust.sh:59` then judges that copy with **its own**
`lib/trust.py` (which the agent made answer yes), and line 64 `exec`s its `install.sh` as root.

Evidence (`e1c-name-traversal-full.sh`; the owner's `install.sh` in the granted folder is byte for byte unedited, only
`project.json` changed):
```
the owner's install.sh in /work/repo is unedited
revoke exit 0
running the kept copy /tmp/evil/package instead of /work/repo: root runs the root-owned copy ...
file made by the agent's code: -rw-r--r-- 1 root root 2 ... /tmp/ROOT-RAN-AGENT-CODE; uid recorded: 0
not ok  the agent's code did not run as root
```
With the agent's `trust.py` left honest (`e1b`), the redirect is still followed and the gate then refuses
("the kept copy /tmp/evil/package can be written by an account other than root ... owned by agent"), so the only barrier is the
agent's own copy of the checker.

This is not the stated limit (an edited entry script): the entry script is intact.
Fix: do not derive the location from the folder under test. Hard-code `/var/lib/sirven/package`, or accept the name only
when it matches `^[a-z0-9][a-z0-9-]*$` and the resulting path is the one `layout.sh` uses. Never run the checker from the folder
being judged to judge it: the entry scripts already read `trust.sh` from the fixed kept path, do the same for `trust.py`, and
check the fixed kept path with a checker that is itself root-owned by construction (`/var/lib` is root's). Add a scenario
with `project.json` edited.

### R2-M2 (must fix). The gate is skipped for `--dry-run`, `--help` and `--prefix`, and the libraries are then read from the agent's folder as root

`lib/trust.sh:32-34,44` returns before any check when those flags appear anywhere in the arguments. The entry scripts source every
library after the gate regardless, so the agent's edits run (top-level statements of a library run when it is read).

Evidence (`e2-gate-bypasses.sh`, kept copy present, agent appended `touch /tmp/ran.NNN` to `lib/kill_switch.sh`, the owner's
`install.sh` unedited): the edit ran as root with `revoke --all --dry-run`, `--help`, `install --dry-run`,
`revoke --prefix /tmp/fakeroot` and `revoke --prefix /`: 5 of 5. The last one is worse than a code run: `--prefix /` is
normalized to no prefix (`install.sh`, `PREFIX="${PREFIX%/}"`), so it is a **real** revoke with the gate skipped (the agent was cut off).
The documentation tells the owner to read the plan first with `--dry-run`, so the first command most owners type is a bypass.

Fix: run the gate whenever the process is root, whatever the flags (a dry run as root reads and evals the same code). Skip it
only for a non-root user, where the code can do no more than that user could. Resolve `--prefix` the way `install.sh` does
before deciding it is a fake root, and reject a prefix that resolves to `/`.

### S-A (should fix). The gate checks one path and then reads another

`install.sh:16`, `uninstall.sh:22` and `bin/sirven:38` set `ROOT_DIR` with a logical `pwd`; `lib/trust.sh:51` checks the physical
path (`pwd -P`) once; every library is then read through the logical `$ROOT_DIR`. If the owner starts the script through a
symbolic link that lives in a folder another account controls and points at a root-only copy, that account can retarget the link
between the check and the reads.
Evidence (`e11-symlink-race.sh`; install-only path, "runs from a trusted folder as an upgrade"): 25 installs through
`/home/swapper/link/install.sh` while `swapper` flipped the link between the real copy and its own: **its library ran as root in
18 of 25**, all 25 exited 0. Fix: set `ROOT_DIR` with `pwd -P` in all three scripts and read libraries only through it. The
case where the link points at the agent's copy from the start is the stated limit.

### S-B (should fix). The search path is trusted before the gate runs

`id`, `uname`, `sed`, `tr`, `head` and `python3` are found through the caller's `PATH` before anything is checked, also when the
owner follows the documentation and starts the kept copy. Evidence (`e3-path-injection.sh`, `PATH` with a folder the agent can
write in front): fake `id`, `uname`, `sed` and `python3` all ran as root. `sudo` normally resets `PATH`, so this needs `sudo -E`,
a kept `PATH`, or a root shell with a user folder on its path. Fix: first line of each entry script, before the gate:
`PATH=/usr/sbin:/usr/bin:/sbin:/bin; export PATH`, and `unset BASH_ENV ENV`.

### S-C (should fix). "A read-only mount counts as safe" is not safe

`lib/trust.py:61-66,84-85` treats a place on a read-only mount as writable by nobody. A read-only bind mount of a folder that
is read-write somewhere else says nothing about who can write the same files. Evidence (`ro-bind.sh`: one host folder mounted
read-write at `/rw` and read-only at `/ro`, mode 666, owned by another account): the gate accepted `/ro/pkg`, and root ran the
library the agent edited through `/rw`. The documentation states the rule, so this is a decision, not an oversight. Fix: drop the
shortcut and judge mode, owner and access lists as for any folder (a read-only squashfs or disc image is root-owned anyway).

### S-D (should fix). A state directory with the wrong mode is never corrected, and the agent can then hold the lock

`lib/layout.sh:192-193`: the step's check is `[ -d $state ]`, so a directory that already exists, made by hand or by an older
version, keeps its mode. Evidence (`e9-lock-agent-holds.sh`, state directory pre-made with mode 755): after install it is still
755, the agent runs `flock /var/lib/sirven sleep 300`, install refuses with exit 75 (a denial of service on the owner's
install, uninstall and rollback), and revoke waits the full 10 seconds, warns, goes on, ends the holder and finishes (exit
0). So the "agent holds the lock to stall the kill switch" case costs ten seconds and no more, which is the right outcome.
With the normal 0700 the agent cannot open the directory, create, list, delete or forge the marker, or take the lock (`e5`).
Fix: check the mode as well (`[ -d $state ] && [ "$(stat -c %a $state)" = 700 ]`) and `chmod 0700` in the action.

### S-E (should fix). One marker for every account

`agent-revoked.json` is a single file (`lib/kill_switch.sh:42-44`) and `kill_switch_account_cut_off` returns true for **any**
user while it exists (`:347-354`, the marker test comes before the user is looked at). Evidence (`e5`): after revoking `agent`,
`install --user bob` exits 2 as "cut off". `--reinstate` for either account removes the one marker, and `release` refuses for
every user while it is there. Fix: one marker per account (`agent-revoked-NAME.json`) or the user name checked inside it.
Deleting the marker as root does not make install think nothing happened: the expired-account test still refuses (`e5`).

### S-F (should fix). The documentation still gives the unsafe path first, and the stated limit has no mechanical help

The stated limit is real and cannot be closed from inside the script: if the entry script the owner starts was edited, nothing
in it can notice. What can be done is to make the safe path the only path the documentation offers. `README.md:26`,
`docs/WALKTHROUGH.md:73` and the `install.sh` usage examples (`./install.sh revoke --all --dry-run`) still give the relative path; README and WALKTHROUGH say `sudo bash install.sh revoke --all`, which from the repository
is the granted folder in the common case. `docs/PERMISSIONS.md`, `docs/BOOTSTRAP.md` and the new `AFTER_ALPHA_SESSIONS` text give the kept copy path, but only
after the first install. Fixes: (1) replace every `sudo bash install.sh revoke --all` with
`sudo bash /var/lib/sirven/package/install.sh revoke --all`; (2) have install create a root-owned launcher at an absolute path
(for example `/usr/local/sbin/sirven-revoke`, mode 0755, three lines: set `PATH`, `exec bash /var/lib/sirven/package/install.sh
revoke --all "$@"`) and print it at the end of the install, so the owner never types a path or depends on the current folder;
(3) in the install summary, say that the folder the package was unpacked in is writable by the agent when it was granted, and
should be deleted or the grant should exclude it. Also fix the wording in the gate's message: it prints "root and root" when the
owner is root.

### S-G (nice to have). Two small things from the lock and the stale plan

- A plain install that made its plan before a revoke and gets the lock after it (`e6`: lock held for 40 s, install waiting, revoke
  goes on after 10 s) now fails with exit 4 and leaves the account locked and expired and no access list entry back, as it
  should. It does leave a new grant record `agent.json` beside `agent.json.revoked` and a fresh `agent-quiesce.json`, and prints the
  hint "to give the account back now ... release", which `release` now refuses. Re-check the revoke marker after taking the lock
  in install and uninstall, and refuse there.
- `kill_switch_write_marker` is only written when the account exists or a marker already exists (`lib/kill_switch.sh:448`): a
  revoke on a machine without the account leaves no marker, which is the right choice, but then a later account of the same name is
  not refused. Fine to keep; say so in the plan note.

## The real-machine prompt

`kill_switch_confirm` (`lib/kill_switch.sh:412`) works as described: with no `--yes` and no terminal it exits 2 and changes nothing
(`e12`); `--dry-run` does not ask; `SIRVEN_YES=1` in the root environment answers it (documented in `lib/questions.sh`, same as
`--yes`). The agent cannot supply either. The prompt text names what will happen. One note: a bb or other automated caller must
pass `--yes`, which is the right trade for an emergency command that must also work non-interactively; say so in the usage text.

## The stated limit, and whether the documents make the safe path obvious

The limit as stated (an agent-edited entry script that the owner starts) is honest and, for an interpreted entry script, not
removable from the inside. Judged against the fixed items: the exposure is real in the default flow, because the installer's
default granted folder is the current folder, so the first copy the owner has is usually one the agent can write. The documents
do not yet make the safe path obvious (S-F). With R2-M1, R2-M2 and S-A to S-C fixed, the gate would close every route I tried
except that one, and the launcher in S-F would make the safe route the easiest one to type.

## Verdict

**CHANGES REQUIRED.** Fix R2-M1 and R2-M2 (each with a harness scenario: `project.json` edited; `--dry-run`, `--help` and
`--prefix /` from an edited copy), then S-A to S-F, then re-review. Everything else in this round passed, including all 41
harness scenarios run, the kill-point sweep, the re-sweep, cron and at removal, the prompt and the marker.

Reviewed commit: `7df24cb70cd5` (tip). The commit that adds this section is on branch
`code-review-kill-switch-sir-32-thr_z2dqwmzswi`.

---

# Re-review, round 3 (the gate redesign)

Reviewed: branch `sir-32-kill-switch-applies-revoke-all-thr_5bke6fw45a`, tip `ab3a90e` (038df65, 3b64977, ca882f6, 31136f0, 15fef6a, ab3a90e).
Run on this Mac (Docker Desktop is back), as the parent asked. My own attack scripts ran one container at a time with
`--memory 256m --memory-swap 256m --pids-limit 256 --cpus 1 --network none --cap-drop NET_RAW`; the project's own runner
(`tests/harness/run-linux.sh`) uses its own caps (256 MB, 256 processes, 3 GB for scenario 27). I created no image: the harness image
`sirven-harness-linux:6101e56669a0` was already here, and no container of mine is left. The Mac was under heavy load from other
threads (load average 7 to 12), so timings are long.

**Verdict: APPROVE**, with the should-fix items below to be tracked. No attack that needs only what an agent can do reached
root. The two round 2 must-fix items (R2-M1, R2-M2) and the three should-fix items about the gate (S-A, S-B, S-C) are closed,
and the structure is now sound: one identical text block, the trusted path a constant, the checker is that text, the folder
resolved once with `pwd -P`. What remains needs either a system folder the agent can already write (`/usr/local`) or a
strange value typed by the owner.

## Checks

- **Harness** (`bash tests/harness/run-linux.sh`, foreground to its end): **55 scenarios, 0 failed, exit 0**. This includes 17, 22,
  26 and 27, which did not run on the server in earlier rounds (the file system there refused the deep folders; here they pass),
  and the new 46 to 55.
- **`make lint`**: exit 2; `bash -n` clean on 67 files; shellcheck 28 findings, normalized and compared with
  `docs/research/qa/wave-3-shellcheck-baseline.txt`: identical, **0 new findings**.
- **`make test`**: exit 2; **472 passed, 4 failed**: the three known macOS installer tests and
  `test_make_lint_passes_with_or_without_shellcheck` (fails only because of the baseline above). Same four as rounds 1 and 2.
  The new `tests/unit/test_gate.sh` passes; I confirmed the three gate blocks are byte for byte equal (same checksum).

## Every earlier attack script, rerun at `ab3a90e`

| Script | Round 2 result | Now |
|---|---|---|
| `e1b`, `e1c` (name in `project.json` points at an agent folder) | root ran the agent's code, uid 0 | **closed.** `running the kept copy /var/lib/sirven/package`; nothing ran. The name must match the regex and is never used to find the kept copy. |
| `e2` (gate skipped for `--dry-run`, `--help`, `--prefix`, `--prefix /`) | agent edit ran as root 5 of 5 | **closed.** 0 of 5; `--prefix /` exits 64. Also `uninstall.sh` and `bin/sirven` with dry run, help, rollback, repair, inspect: 0 of 6 (`g1`). |
| `e3` (agent-writable folder first on `PATH`) | fake `id`, `uname`, `sed`, `python3` ran as root | **closed.** None ran, also with `BASH_ENV`, `ENV`, `LD_PRELOAD`, an exported function and a fake `bash` through the launcher (`f5`). |
| `e4` (trust claims) | all as designed | still as designed; the link to a world-writable folder inside the package that was accepted in round 2 is now refused (the whole tree is vetted). |
| `e5` (marker) | one marker blocked other accounts | **closed.** `install --user bob` after revoking `agent` is accepted; deleting the marker as root still leaves `agent` refused (the expired account). The agent cannot create the marker, list the state folder or take the lock. |
| `e6` (install that planned before a revoke, applies after) | exit 4, new grant record left behind | **better.** The install now exits 2: "the kill switch cut agent off while this run waited for the lock, and the plan above was made before that. nothing was changed." No grant record, no access list entry. |
| `e7`, `b2` (supervisor restarts the agent's work) | final check works | unchanged and good: twice-restarting supervisor ended by the re-sweep, exit 0; a supervisor that never stops gives exit 4, audit `failed`. |
| `e8` (cron, at) | fixed | still fixed. |
| `e9` (state folder pre-made at mode 755) | agent held the lock, install refused 75 | **closed.** Mode 700 after install; the agent cannot open it. |
| `e11` (link in an agent folder swapped after the check) | agent library ran as root 18 of 25 | **closed.** 0 of 25 (one install was refused when the swap landed in the check, which is the right way to fail). |
| `e12` (prompt) | as designed | unchanged. |
| `ro-bind` (`tests/harness/run-ro-bind.sh`) | gate trusted a read-only mount | **closed.** Refused: "/ro: writable by everyone ... /ro/pkg: owned by agent". |
| `a1`, `a3`, `a4`, `b3`, `b4`, `d1` | | all pass as in round 2; the sweep of real kills before each command (scenario 39, which replaces my `b1` because root now ignores a stub folder on `PATH`) passes. `a2` rewritten to put its stand-in `systemctl` in `/usr/sbin`: a plain install after a stopped revoke is refused. |

## The new surfaces

### (a) Can the agent make the vet of the kept copy fail, so the gate falls back to a folder it influences? No.

- A grant that covers the kept copy is refused by the grant compiler: `/var/lib/sirven` and `/var/lib/sirven/package` ("belongs to the
  package itself"), `/var/lib` ("never granted"), `/var` and `/` ("too broad"); after each the agent still cannot write the kept
  copy (`f1`, `f1b`). The state folder is forced to 0700 root, so there is no other way for the agent to change a mode, owner or
  access list there.
- The fallback only returns "go" for a folder that passes the same vet that a first install uses, so it adds no trust: it can
  only run a folder that nobody but root and the owner can write. With the kept copy untouched, a clean root-only folder and an
  agent-writable folder both end in the kept copy running (`f1` step 3); with it loosened by root, the clean folder runs with a
  warning and the agent-writable one is refused (scenario 54).
- A resource attack does not turn into a bypass: the vet fails closed. With the agent holding 205 MB of a 256 MB shared limit,
  the launcher still cut it off (`g2`). A failing fork would fail both vets, so the result is a refusal, never a run of an
  unvetted folder.
- Limit to know: if the kept copy is ever not trusted, the launcher cannot fall back (it starts the kept copy itself), so the
  owner has to start `install.sh revoke --all` from a root-only copy. The message tells them.

### (b) The whole-tree vet (`f2-vet-tree.sh`, 15 of 15 as expected)

Refused: a writable file 30 and 300 folders deep; a pipe, a socket and a device node with mode 666; a socket owned by the agent;
a hard link in the package to a file the agent owns (my first run of that case passed only because the file was root-owned, I fixed
the script); a link to a file outside the package; a world-writable folder; a hidden file owned by the agent. Accepted, correctly:
a pipe with mode 600 owned by root; links that stay inside the package; a package file that is also hard-linked from the agent's
folder (the inode is root's, and the agent cannot change it through its link, checked). A tree 1500 folders deep is refused,
but by a Python traceback (recursion limit), not a message (N-R3-1).

### (c) The name regex (`f3-name.sh`)

`../../tmp/evil`, `a/b`, `a b`, `-x`, `a.b`, `a_b`, an empty name, a combining accent and a name with an embedded newline are all
refused with a clear message and nothing changed; `Sirven`, `SIRVEN`, `9lives`, `x-` are accepted. Every path built from the name
(`/var/lib/NAME`, `/etc/NAME`, `/var/log/NAME`) is therefore a plain component. One mismatch (N-R3-2): a valid name other than
`sirven` installs into `/var/lib/NAME` while the gate and the launcher use the constant `/var/lib/sirven/package`: install
succeeds, the launcher then says "no kept copy ... nothing to run". The product name is fixed, so this only matters for a
renamed build.

### (d) The `/usr/local` ownership check (`f4-usr-local-race.sh`)

Works for real folders: `/usr/local/bin` writable by the agent, owned by the agent, holding a file owned by the agent, or under a
parent the agent owns, is left off root's path with a warning (scenario 55). A sticky parent (`1777`) is accepted, correctly.
One hole: **S-R3-1.** When `/usr/local/bin` is a symbolic link to a root-only folder and `/usr/local` (which holds the link) is
writable by the agent, the vet resolves the link, checks the target and its parents, and adds the **link path** to `PATH`.
`/usr/local` itself is not on the vetted path of the target. The agent swaps the link to its own folder after the vet.
Evidence: 20 dry runs as root while the agent flipped the link, **the agent's `tailscale` ran as root in 13**. It needs
`/usr/local` writable by the agent (a machine already in trouble), but the vet was written to catch exactly that for a real
folder. Fix: put the **resolved** path in `PATH` (`dir="$(cd -P "$dir" && pwd -P)"` before the vet and the append) and vet that
one. A race on a real folder is not possible (the parent check catches it).

### (e) The launcher (`f5-launcher.sh`, `f5b`)

Written at `/usr/local/sbin/sirven`, mode 755, owner root, content equal to the template; when `/usr/local/sbin` is root's
the agent cannot replace, remove or add beside it. It sets its own `PATH`, unsets the dangerous variables and runs `bash` on the
kept copy; a hostile environment did nothing. One hole: **S-R3-2.** When `/usr/local/sbin` is writable by the agent, install
lays the launcher down anyway, with no warning about the launcher (the gate only says that folder is not on root's search path), and
the agent replaces it with its own script (`chmod +x`, `mv -f`, allowed in a folder it can write): `sudo /usr/local/sbin/sirven
revoke --all`, the documented command, then runs the agent's script as root. Evidence: the file in place was agent-owned mode 755,
and `/tmp/ROOT-RAN-LAUNCHER` appeared. Fix: have the install vet `/usr/local/sbin` and every parent (the same checker, owner
root) before writing the launcher; if it fails, do not write it, say so in the plan and the summary, and have the docs and the
plan note name the kept-copy command instead. Also have install check on a re-run that the launcher is still root's (it does
compare content and mode and owner already).

### (f) `--prefix` normalization (`f6-prefix.sh`)

Refused with exit 64, in `install.sh`, `uninstall.sh` and `bin/sirven`: `/`, `//`, `///`, `/.`, `/./`, `/..`, `/../..`, `/tmp/..`,
`/tmp/../`, `/tmp/./..`, `/tmp//..`, a link to `/` (also with a trailing slash), `/proc/self/root`, `/proc/1/root`, and `--prefix=/`. Last flag
wins (`--prefix /tmp/real --prefix /` refused, `--prefix / --prefix /tmp/real` accepted, as written). Accepted and fine: real
folders, and `/tmp/real/..` or `/tmp/sublink/..` (they resolve to `/tmp` and `/tmp/real`). An empty prefix is the same as none.
One hole: **S-R3-3.** A path that does not exist yet and spells the root with `..` is accepted:
`--prefix /nonexist/..` and `/tmp/nonexist/../..`. The check resolves with `cd -P`, which fails for a missing folder, and the
text is then used as it stands. Evidence (`f6b`): a real run of `install.sh --yes --prefix /nonexist/..` created `/etc/sirven`,
`/var/lib/sirven` and `/nonexist` on the real machine (the `run` steps really execute; only `system` steps are recorded). Fix: refuse a
prefix with any `..` or `.` component, or resolve it with `realpath -m` first and compare the result with `/`. It needs the owner
to type it, so it is not an agent route.

### Other things I tried

- **The script started other than as a file** (`bash -s < install.sh`, `bash -c "$(cat install.sh)"`, `cat install.sh | bash -s`) with an agent-edited
  library in the current folder: the agent's code did not run, but only because `${BASH_SOURCE[0]}` is unset under `set -u` and the
  script dies with exit 1 before the gate or any library (`f7`). That is safe by accident. Make it explicit: run the gate unless the
  script is being sourced by a test, and refuse when `BASH_SOURCE[0]` is empty. (N-R3-3.)
- **`unset BASH_ENV ENV ...`** in the gate runs after bash has already read `BASH_ENV`, so for the entry script it does nothing
  (the launcher's `unset` is effective because it runs under `sh` before `exec bash`). `sudo` removes these variables and the agent cannot
  set root's environment, so this is not an agent route; keep the line for the cases where it works and say so in the comment. (N-R3-4.)
- **macOS:** the gate returns on anything but Linux, so on a Mac, root runs whatever the start folder holds. Apply on a Mac is
  not built yet; add the same check, with the folder owned by root or the owner, when it is.
- **Not tested:** a real systemd (stand-ins only, as before), a running cron daemon, the vet under a very large `/usr/local/bin`
  (it walks the whole folder; slow, not unsafe), and locales where `[a-z]` is not ASCII (macOS bash 3.2; the regex is checked on
  Linux bash 5.2 only).

## The stated limit and the documents

The limit (an entry script the owner starts that the agent itself edited cannot be noticed by that script) remains, and is now stated
once in the gate text and in `docs/PERMISSIONS.md`. The safe path is now also the easy one: `sudo /usr/local/sbin/sirven revoke --all`
is what the README, the walkthrough, `docs/PERMISSIONS.md`, the failure messages and the adopt messages say, and install prints a note
to delete the unpacked folder or grant a path that does not hold it. The only remaining first-run commands that start from the
unpacked folder (`sudo bash install.sh` in the README and walkthrough) are the first install, before there is a kept copy; the gate vets
that folder and refuses one the agent can write. S-R3-2 is the one place where the documented launcher can be made unsafe.

## Verdict

**APPROVE** at `ab3a90e`. Please fix S-R3-1 (resolved path in `PATH`), S-R3-2 (vet the launcher's folder before writing it) and S-R3-3
(reject `..` in `--prefix`) next, with a scenario each; they need a system folder the agent already controls or an odd value typed by the
owner, which is why they do not block. Then N-R3-1 to N-R3-4 whenever convenient.

Reviewed commit: `ab3a90e` (tip). The commit that adds this section is on branch `code-review-kill-switch-sir-32-thr_z2dqwmzswi`.
