# Review: the Tailscale transport (SIR-1 and SIR-33)

Reviewed: branch `sir-1-sir-33-tailscale-transport-apply-and-teard-thr_egyw4b7y3f`, tip `0b9f6d5`, against its base `5e86f4d`
(`git diff 5e86f4d..0b9f6d5`, 21 files). Reviewer thread: thr_kq6fyieabf. Product code was not changed.
Where it ran: Docker Desktop on the machine `Joses-MacBook-Pro-4.local` (arm64), the engine this checkout had. The brief said Omashu;
I did not confirm that this host is Omashu, so the container runs below are on this host's Docker.

## Verdict: CHANGES REQUIRED

The key never leaks: not on a command line, not in a committed file, not in any output or log, not in the pushed history. Apply and
teardown behave as the design says in every case I tried except the ones listed below. Three findings need a fix before this goes to
the integrator (F1, F2, F3); two more should be fixed (F4, F5). None of them leaks the key from a correctly set up install, which is
why I did not stop the parent with a severe alarm, but F1 and F2 are the kind of thing a review is for, so I told the parent.

## Findings

### F1 (must fix, medium): the key file is used without checking who owns it or who can read or write it

`lib/tailscale_node.sh:172` takes `key_file` when it is a plain file and not a link, and nothing else. The docs say "owned by root, mode
0600" (`docs/WALKTHROUGH.md`, the plan text in `lib/tailscale.sh`) but nothing checks it.
Evidence, `attack t1`: a key file owned by `nobody`, mode 0666, in `/etc/sirven/`, was accepted and `install.sh` joined the tailnet
with it (exit 0, node state Running).
Why it matters: an owner who writes the file with `echo key > /etc/sirven/tailscale-auth-key` gets mode 0644, so the agent's own
account can read the key until the join removes it; a file anyone can write lets a local user choose which tailnet the machine joins.
Fix: refuse (exit 2, nothing changed) unless the file is a regular file owned by root with no group or other permission bits, and run
the same check in `tailscale_key_available` so the refusal comes before the first change. Add the case to `test_tailscale.sh`.

### F2 (must fix, medium): a join that logs in but does not reach Running is not undone by uninstall, and uninstall says nothing

When `tailscale up` leaves the node in a state other than Running (`NeedsMachineAuth` is the real case: a tagged key that is not
pre-approved), `node_join` writes the record and then fails (`lib/tailscale_node.sh`, the `S_BACKEND != Running` branch). A failed
step is never added to the install record (`_plan_record` runs only after success), so the record has no undo line for the join.
Evidence, `attack t3`: install exits 4 with the node logged in and `tailscale-node.json` written; `uninstall.sh` then exits 0, prints
nothing about Tailscale, and the node is still `NeedsMachineAuth` and logged in afterwards. `revoke --all` is fine because it reads
the record file directly; only uninstall is blind. Running install again heals it (the node is found tagged, the step succeeds, the
undo line is recorded), but an owner who walks away and uninstalls is left with a live login.
Fix, either: make uninstall (or the install record) also run `leave` when `tailscale-node.json` exists, or have the not-Running branch
log the node out and remove the record, as the two failure branches just below it already do.

### F3 (must fix, medium): the live scenario hands the whole dotenv file to a container that has a network, on the shared bridge

`tests/harness/run-linux.sh`, the `harness-tailscale` block. Two separate problems:
1. `--env-file "$secrets_file"` passes every line of the file, but only `SIRVEN_TAILSCALE_AUTHKEY` is wanted (the `grep` only checks
   that this line exists). Any other secret kept in the same dotenv file goes into a container that can reach the internet and runs
   the code under test. Fix: write the one line to a private temporary file (mode 0600, removed on exit) and pass that file.
2. The commit message says "a network for that scenario only", but the code sets `network=bridge`, which is Docker's default shared
   bridge: the scenario container can reach other containers on it (for example another harness run). Fix: create and remove a network
   per run (`docker network create`), or reword the claim.

### F4 (should fix, low): "refused before any change" is not true for a too-old tailscale or a malformed key

Two refusals happen at step 22, after 21 earlier steps have changed the machine, while the message says "nothing was changed" and
`docs/WALKTHROUGH.md` lists them under "Refused before any change":
- a tailscale whose `up --help` has no `file:` (`attack t7`, part D: install exit 4, 74 files changed before the refusal);
- a key with a carriage return or other odd character, such as a key file saved with Windows line ends (`attack t6`: exit 4, the
  files list differs from the empty machine by the account, package copy and install record).
The first can be caught earlier in `tailscale_refuse_before_apply` (it already runs the tailscale command for status); the second by
checking the key's characters there too. If that is more than you want, change the wording in the message and the document, since a
re-run does finish the job. Note also that `PREFLIGHT_MINIMUM_TAILSCALE` is 1.60.0; I could not find which release added `file:`
(the public documentation does not say), so the in-script help check is the right test and the preflight number may be too low.

### F5 (should fix, low): a killed join leaves a copy of the key, and nothing ever cleans it

The private copy is `/var/lib/sirven/.tailscale-key.<pid>` (root only, mode 0600, in a mode 0700 folder; no `mktemp`, but the folder
makes the predictable name safe). It is removed on a normal end, an error, SIGTERM, SIGINT and SIGHUP (`attack t2`: nothing left).
After SIGKILL (or a power loss) it stays, and a later join, `leave` and uninstall all leave it (`attack t2`, last lines). It is
root-only, so this is low. Fix: remove `.tailscale-key.*` at the start of `join`, in `leave`, and in uninstall.

## Checks you asked for, with evidence

### 1. Secret handling: pass, with F1 and F5

- Not on any command line: the wrapper in `attack t5` recorded tailscale's own arguments: `up --auth-key=file:/var/lib/sirven/.tailscale-key.1367 ...`
  (a path, never the key). Scenario 60 also asserts the fake never saw `--auth-key=<key>`. The shell variable holding the key is not
  exported, and both environment variables are unset before any child runs: tailscale's own environment held neither
  (`attack t5`, `environ-has-key: 0`). The key does stay in the environment of the installer process and its root-only children
  until the install ends; no step runs as another account (`git grep` for `su`, `sudo`, `runuser`, `setpriv` in `lib`, `install.sh`,
  `uninstall.sh` finds only a comment), so the agent's account never sees it.
- Not in a committed file or the history: `git log -p --all | grep -E 'tskey-[A-Za-z]+-[A-Za-z0-9]{8,}'` finds 0 matches across all
  refs; the test keys are written split (`"tskey""-auth-..."`) so even the literal prefix is absent. The long hex strings in the diff
  are the image digest and the two pinned tailscale checksums. I downloaded the amd64 tailscale 1.104.1 archive into a fresh
  folder: its checksum matches the pinned value (the arm64 pin passed `sha256sum -c` in the image build here).
- Not in any log or output: scenario 60 asserts no key under `/etc /var /root /home /usr/local`, in the install output and in
  `/var/log/sirven/audit.jsonl`; `attack t5` extends the file search to `/usr` and the output (clean). Tailscale's own output goes
  through `safe_print`, which blanks the key (unit test with `FAKE_TS_ECHO_KEY`). The record, the golden files and the install record
  line (`bash .../tailscale_node.sh leave <marker>`) hold no key.
- The private temporary file: created in a subshell with `umask 077` (mode 0600 root), next to the record in the root-only state
  folder, removed with `rm -f` right after `up` and by an `EXIT` trap. See F5 for SIGKILL. Not `mktemp` (name is `.tailscale-key.$$`).

### 2. Apply correctness: pass, with F1, F2 and F4

- Arguments (`attack t5`): `--advertise-tags=tag:agent --hostname=agent-<host> --ssh=false --accept-dns=false --accept-routes=false --reset --timeout=60s`.
  No `--advertise-exit-node`, no `--advertise-routes`, no `--exit-node`; `--reset` clears any earlier setting. Scenario 60 asserts SSH off and no exit node.
- Host name: odd seeds (`-evil`, spaces and a non-ASCII letter, `a..b`, 100 characters, `../../etc`) all become plain lowercase names of at most 63 characters (`attack t6`).
- Idempotent: a second apply exits 0, does not run `up` again, changes no file, needs no key (scenario 60, three assertions).
- Record: `/var/lib/sirven/tailscale-node.json`, mode 0600 root, fields `node_id`, `host_name`, `tag`, `joined_at`; no key (scenario 60 asserts the mode and `node_id`; `write_marker` shows the fields).
- Refusals, end to end through `install.sh` (`attack t7`): tailscaled down is stopped by preflight with nothing changed; a login without
  the tag is refused (exit 2, nothing changed, zero `up` calls, never re-tagged, and revoke and uninstall never log it out); an owner's
  own `tag:agent` node is adopted and never logged out; no key is refused up front (scenario 60 and 61); tailscale missing and a
  too-old tailscale are covered by unit tests, with the F4 caveat for too-old.

### 3. Teardown: pass, with F2

- `revoke --all` and uninstall log out only when the machine's own `Self` entry has the recorded node id and `tag:agent`
  (`node_leave`; unit tests `test_leave_leaves_a_login_that_is_no_longer_the_recorded_node`, scenario 60 part 5). Only the machine's
  own entry is read, so the second `tag:agent` peer the fake always lists cannot answer for it (`attack t7`, part E: exactly one logout).
  `tailscale logout` acts on this machine only, so no other tailnet node can be touched.
- A planted or linked record is not trusted (unit test); a record that cannot be read does nothing.
- Failure is loud and repeatable (`attack t4`, logout made to fail): `revoke --all` exits 4 and names the step; the other kill switch
  steps still run; the record stays; uninstall exits 4 with the same error and keeps the pinned copy and the install record; after the
  cause is fixed, a second uninstall exits 0 and the node is logged out.
- Scenarios 30, 31 and 32 are not edited by this branch and pass unchanged (13, 14 and 14 passed, exit 0).

### 4. Gate: pass

The join is `plan_step system` with a check (`adopt_tailscale_is_agent_node`), an action and a recorded undo, run by the ordinary
`plan_apply` loop; `lib/tailscale.sh` and `lib/tailscale_node.sh` contain no prompt, `read` from a terminal, or confirmation of their
own. On macOS the join stays `plan_planonly`, so the existing real-apply refusal stands. `plan_confirm_real_apply` does not exist in
this tree or on the shared confirmation gate branch I looked at, so there is nothing to wire yet; when it lands, the join is covered
by it as any other step. The one new refusal, `tailscale_refuse_before_apply`, exits 2 before the first change and is not a prompt.

### 5. `run-linux.sh` and SIR-82

The two branches conflict textually in `tests/harness/run-linux.sh`: confirmed by a throwaway merge of
`sir-82-harness-long-name-failures-on-ba-sing-se-thr_57qwu88297` (tip `cd05aa3`, same base `5e86f4d`) into `0b9f6d5` in a temporary
worktree (since removed): one conflict, in the block just before the `docker run` command. It is not destructive. Resolution for the
integrator: keep both comment blocks and both variable setups (`apparmor_option` from SIR-82; `image`, `network` and the positional
arguments from SIR-1 and SIR-33), and make the final command read
`--network "$network" --memory "${memory:-256m}" --pids-limit 256 --cap-drop NET_RAW $apparmor_option "$@"` followed by the
`"$image"` line. Two points: SIR-82's comment says "--network none" for every container, which is no longer true for scenario 61 (only
the AppArmor option is relevant to scenarios 17, 22 and 26, so it stays correct for them); and this branch's `set --` replaces the
positional parameters inside the loop, which is safe because `FILTER` is read first. SIR-82 also edits scenarios 17, 22, 26 and
`docs/design/real-install-harness.md`; this branch touches none of those.

### 6. Runs (foreground, exit statuses)

| Command | Exit | Result |
| --- | --- | --- |
| `make lint` | 0 | `bash -n` on 69 files, `shellcheck passed` |
| `bash tests/run.sh tailscale` | 0 | 25 passed, 0 failed |
| `make test` | 2 | 502 passed, 3 failed: `test_install_started_by_sh_says_to_use_bash`, `test_enter_twice_accepts_the_shown_defaults`, `test_input_that_ends_takes_the_defaults` (the 3 known failures; same names as the baseline note) |
| `bash tests/harness/run-linux.sh 60` | 0 | 30 passed, 0 failed, 0 skipped |
| `bash tests/harness/run-linux.sh 61` | 0 | 9 passed, 0 failed, 2 skipped (no test key; the two skips are the live join and the live second apply and revoke) |
| scenarios 30, 31, 32 | 0, 0, 0 | 13, 14 and 14 passed |

Scenario 61 did reach the real control server: a wrong key makes the real tailscale fail (installer exit 4, "tailscale up failed",
nothing recorded, key in no output), which also shows the real tailscale 1.104.1 passes the `file:` help check.
**Not verified:** the happy path against a real tailnet (the join, the `Self.Tags` and node number fields of the real status output,
the second apply and the logout) did not run, because no test key was available. Run scenario 61 once with a test key before relying
on it.

## Attack scripts

`docs/research/qa/sir-1-33-review-attacks/` (run each in a throwaway container like the scenarios; `common.sh` installs a thin wrapper
around the fake tailscale). Two results that came out wrong in my first run were mistakes in my own scripts (SIGINT ignored by a
background job; my check matched the harness's own exported test variables), and are fixed in the committed versions.

| Script | What it tried | Result |
| --- | --- | --- |
| `t1-key-file-trust.sh` | key file owned by nobody, mode 0666 | accepted (F1) |
| `t2-signals.sh` | TERM, INT, HUP, KILL during `up` | first three clean; KILL leaves the copy (F5) |
| `t3-failed-join-then-uninstall.sh` | join ends NeedsMachineAuth, then uninstall | node left logged in, exit 0 (F2) |
| `t4-logout-fails-loudly-and-repeats.sh` | logout fails in revoke and uninstall | loud, record kept, repeatable: pass |
| `t5-key-visibility.sh` | argv, environment, folder and files while `up` runs | pass |
| `t6-odd-inputs.sh` | odd host names; key file with a carriage return | names clean; CRLF refused mid-apply (F4) |
| `t7-refusals-end-to-end.sh` | tailscaled down, login without tag, owner's agent node, too-old tailscale, peer with the same tag | pass, with F4 for too-old |
