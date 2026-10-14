# Real-install test harness (SIR-41, serving SIR-9, SIR-28, SIR-29, SIR-32, SIR-33)

Date: 2026-10-13. Author: architect thread thr_tzdqw4nudv on the MacBook Pro Omashu, for the orchestrator thr_4mddufbqcn. Branch: design-real-install-test-harness-sir-41-sir-9-thr_tzdqw4nudv. Nothing in product code changed. The prototype lives in `tests/harness/`.

## Summary

- A real Linux install is provable today, on Omashu, with no sudo and no new tool. Docker Desktop is already installed and running. The prototype ran the first real install ever: `install.sh` exited 0, created the service user, the permission lists, the install record and the audit log, and `uninstall.sh` removed them. Three scenarios: 29 checks pass and 7 more assertions are held as known defects (36 in all), in 3.5 seconds for the whole run (exit 0).
- The first real run found two defects the fake-root tests cannot see, both about the default access control list the grant puts on the folder: it makes new files ignore the owner's umask while the grant is in force (a world-readable file in a 755 folder), and uninstall leaves it behind (section 3). Task SIR-70 holds the second; the first needs adding to it.
- A local macOS virtual machine is not realistic on Omashu: 23 GiB of free disk and a Mac already swapping. The cheapest real macOS apply is a GitHub-hosted macOS runner. The repository is public, so runner minutes are free, and each runner is a fresh machine with passwordless sudo. This is unmeasured and is the first thing to try (section 5).
- Things only a real Mac can prove (lid-closed power setting, helper approval, privacy prompts, Tailscale app) stay a documented manual script on Jose's Mac.

## 1. Inventory (Omashu, measured 2026-10-13)

| Fact | Command | Result |
|---|---|---|
| Hardware | `sysctl hw.memsize; sysctl machdep.cpu.brand_string` | 17179869184 bytes (16 GiB), Apple M1 Pro, 8 cores (the engine virtual machine below also gets 8) |
| macOS | `sw_vers` | 26.6.2 (build 25G83) |
| Hypervisor allowed | `sysctl kern.hv_support` | 1 |
| Disk | `df -h /System/Volumes/Data` | 460 GiB total, 23 GiB free, 95% used |
| Memory now | `vm_stat` (16384-byte pages) | free 0.08 GiB, inactive 2.74, active 2.92, wired 3.88; "free percentage 38%" |
| Swap | `sysctl vm.swapusage` | 3072 MB total, 2100 MB used |
| Container engine | `docker version` | Docker Desktop 4.27.2, engine 25.0.3, linux/arm64, running (symlink `/usr/local/bin/docker`) |
| Engine virtual machine | `docker info` | 8 processor cores, 7.66 GiB memory ceiling; its host process used 913 MB resident when measured |
| Engine data | `du -sh ~/Library/Containers/com.docker.docker/Data` | 6.3 GB. Five images of Jose's (3.0 GB) and a stopped Postgres container were here before; the harness never touches them. |
| Not installed | `which colima podman orbstack container tart lima limactl qemu-system-aarch64 multipass vagrant` | none found |
| Not installed (apps) | `ls /Applications` | no UTM, Parallels, VMware, VirtualBuddy |
| Tart | `brew info tart` | not in Homebrew core (it needs the `cirruslabs/cli` tap; not tapped) |
| Swift toolchain | `which swift xcodebuild` | present (Xcode), so Apple's Virtualization framework could be driven by a hand-written program; not attempted |
| Server ba-sing-se | not touched | very low memory; the design never runs containers there |

Measured cost of one container (warm engine, because Docker Desktop was already running):

| Step | Time | Disk |
|---|---|---|
| `docker pull debian:12-slim` | 5.4 s | 97 MB |
| `docker build` of `tests/harness/Dockerfile.linux` (adds bash, python3, acl, passwd, procps, util-linux) | 6.5 s | image 145 MB |
| `docker run --rm IMAGE true`, three runs | 1.29 s, 0.70 s, 0.32 s | none kept |
| One scenario (install, checks, uninstall) | 1 to 2 s | none kept |
| All three scenarios, `bash -c 'time bash tests/harness/run-linux.sh; echo exit=$?'` on the committed, digest-pinned image | 3.46 s wall, `exit=0` (an earlier unpinned run took 4.3 s) | none kept |
| Memory cap per container | 256 MB (never reached; peak not measured) | |
| Cold start of Docker Desktop itself | not measured (already running) | the engine virtual machine holds about 0.9 GB while up |

Not measured, and why: a macOS virtual machine. No tool is installed; a guest image is about 20 GB or more (a published figure I could not confirm, see Sources), which does not fit in 23 GiB of free disk, and a guest wants 4 GB of memory or more on a Mac that is already in swap. Recorded as not feasible here rather than estimated.

Nothing was installed with sudo. Installed or changed on this Mac: the images `debian:12-slim` and `sirven-harness-linux` (about 240 MB together). Remove them with `docker rmi sirven-harness-linux:<tag> debian:12-slim`.

Exit statuses of the harness itself (observed, run with bash; this shell is zsh, which has no `PIPESTATUS`, so earlier readings were taken again):

| Situation | Command | Observed exit |
|---|---|---|
| All scenarios pass (known defects included) | `bash tests/harness/run-linux.sh` | 0 |
| No container engine running or found | `SIRVEN_HARNESS_ENGINE=nonexistent bash tests/harness/run-linux.sh` | 77, with a skip message |
| Filter matches no scenario | `bash tests/harness/run-linux.sh zzz` | 2 |
| A known defect starts passing | first run of scenario 03 before the precondition was added: "now passes, so remove the marker" | 1 (seen once, then fixed on purpose) |

## 2. What the first real run showed

Command (a fresh container; the repository mounted read only; no network):

```
docker run --rm --network none -v "$PWD":/src:ro sirven-harness-linux bash -c \
  'cd /src && bash install.sh --yes --level observer --transport none --path /srv/app'
```

| Check | Result |
|---|---|
| `install.sh` real apply | exit 0; 19 steps applied; step 15 (paste the agent's public key) is the owner's, as designed |
| Service user | user number 1000, `agent`, password field `*`, not in sudo, wheel or admin, `.ssh` mode 0700, empty `authorized_keys` mode 0600 |
| Permission lists | `agent` can read `/srv/app`, cannot write it, cannot read `/root`; new files inherit read access through a default list (which has a side effect, section 3) |
| Records | `/var/lib/sirven/install-record.tsv` (0600 root), pinned copy in `/var/lib/sirven/package`, audit log with a `finished` entry |
| Re-run | exit 0; "applied 1 steps, skipped 18" (the one step tagged `always`) |
| `install.sh revoke --all` (now `sudo /usr/local/sbin/sirven revoke --all`) | exit 3, "not yet", nothing changed at the time of this first run; applied since SIR-32, see scenarios 03 and 30 to 44 |
| `uninstall.sh` from the pinned copy | exit 0; user, group, files, directories removed; home folder and audit log kept on purpose |
| Real apply as an ordinary user | exit 3, "applying needs root"; nothing changed |
| `--transport tailscale` real apply | exit 3, refused because step 24 (`tailscale up`) is plan only |

## 3. Defects found by the harness (not previously known)

Both come from one cause: the grant sets a default access control list on the granted folder (`setfacl -d -m u:agent:rX`), and a default list overrides the umask of everyone who creates a file there. When it is created, its base entries (`group::`, `other::`) are copied from the folder's own mode, not from the umask.

**A. While the grant is in force (measured).** Folder `/srv/app` mode 755, grant in force, an owner with umask 077 runs `touch /srv/app/x`: the file is mode 0644, readable by every account on the machine. The same `touch` in a plain 755 folder gives 0600. So the grant itself widens access beyond the agent, for any file anyone creates there. A 700 folder is safe: its default base entries are all `---` (the `640` that `stat` shows there is the mask, not a real group grant; `getfacl` shows `group::---` and `other::---`). Scenario 01 holds this as a known defect. This is not in SIR-70 yet and is the larger of the two. Fix options for the product owner: write explicit `default:group::` and `default:other::` entries that match the umask intent, drop the default list and refresh the grant on a schedule, or document it and refuse 755 folders without confirmation.

**Status (2026-10-14, SIR-70 branch).** Both A and B are fixed on this branch and the known-defect
lines are now assertions. A is asserted as effective access (group and other entries empty, another
account cannot read the file), because a named entry makes stat show the mask, so a literal 0600 is
not reachable while the agent has inherited read. The design is in `docs/PERMISSIONS.md`.

**B. After uninstall (measured).** `uninstall.sh` exits 0 and removes the user, the group and the files, but the granted folder keeps the default list (base entries), and every file inside and the parent folder `/srv` keep a mask entry (`ls -l` shows a `+`). The new-file effect of A therefore outlasts the uninstall. Cause: the undo uses `setfacl -x u:agent`, which removes one entry, not the list. Fix direction: the undo runs `setfacl -R -k` (remove the default list) and `-b` on files that had no list before, or the install records the earlier lists and restores them. Task: **SIR-70** (found with this harness, created by the orchestrator). Scenario 02 holds two known-defect lines for it.

Both are product changes and are not made here. Each known-defect line fails the run, on purpose, the moment the product passes it, so the marker cannot be forgotten.

## 4. Design

### 4.1 Which applies run where

| Level | Where it runs | What it can prove | What it cannot | Cost per run | Status |
|---|---|---|---|---|---|
| 1. Linux container | Omashu (Docker Desktop) or any Docker host, including the free GitHub ubuntu runner | service user, permission lists, layout, install record, audit log, idempotency, uninstall, revoke, refusals, ordinary-user refusal; with a layer added: key login through sshd, Tailscale join in userspace mode, `cloudflared` | systemd, a real macOS, a lid, a graphical session | 1 to 2 s per scenario, 145 MB image once | **built (prototype)** |
| 2. Throwaway macOS machine | GitHub-hosted `macos-15` runner (arm64), fresh per job, passwordless sudo | `dscl` account creation, hidden account, `chmod +a` lists, `createhomedir`, bash 3.2 behaviour, `launchd` daemons, the one-line bootstrap against `cli.sirven.xyz` (SIR-48) | a machine without the command line tools (the runner has them, so the python3 placeholder path of SIR-50 is not reachable), the lid, graphical approvals | free on a public repository; a start of about a minute or two is typical but **not measured**; nothing local | designed, **unverified**: whether a runner allows `dscl` account creation and Remote Login changes must be tried first |
| 3. Local macOS virtual machine | Tart or Apple's Virtualization framework | the fresh-Mac and python3-placeholder path, a clean user account | same graphical limits; no lid | needs 80 GB or more free disk and 8 GB of memory free; not possible on Omashu today | deferred; only if level 2 proves inadequate |
| 4. Jose's real Mac | manual script `tests/harness/manual/real-mac.sh` (to write) plus a checklist | the lid-closed power setting, the helper approval, privacy prompts, the Tailscale app, a real iPhone | repeatability | about 15 minutes of Jose's time | designed |

Rule that holds at every level: the real installer is only ever started inside a machine that is thrown away or an account that has a written, tested rollback. It is never started on Omashu itself. The harness never calls `install.sh` on the host.

### 4.2 Starting, isolating, tearing down

Linux container (built):

- Start: `bash tests/harness/run-linux.sh [filter]`. The image tag is the checksum of `Dockerfile.linux`, so a changed recipe rebuilds and an unchanged one reuses. One fresh container per scenario.
- Isolation: repository mounted read only at `/src` and nothing else from the host; `--network none`; no `--privileged`; default capabilities only (useradd and setfacl need chown, setuid and similar); `--memory 256m --pids-limit 256`; the Docker socket is never mounted. Scenario paths such as `/srv/app` are inside the container, because lists on a folder shared from the Mac are a different file system and prove nothing.
- Teardown: `--rm`, plus an exit trap that removes any container carrying the run's label, so an interrupted run leaves none. A leak check is `docker ps -a --filter label=sirven-harness`.
- No engine running: exit 77 with a skip message, never a false pass.
- Not part of `make test`: that target stays free of Docker.

GitHub runner (designed): a workflow on `pull_request` and manual dispatch with two jobs, `ubuntu-latest` (runs the same `run-linux.sh`, Docker is preinstalled) and `macos-15` (runs `tests/harness/run-macos.sh`, the same scenario shapes with macOS commands). Teardown is the runner being discarded. Secrets for transport tests are repository secrets, never printed, and are not available to pull requests from forks.

Real Mac (designed): `real-mac.sh` refuses to run unless a sentinel is set (`SIRVEN_REAL_MAC_TEST=I-understand`), uses a reserved account name (`sirven-test-agent`) and a reserved folder, takes a before snapshot, installs, runs the same assertions, then revokes and uninstalls in an exit trap and diffs against the snapshot. It prints the manual recovery commands first. It is written and run only with Jose present.

### 4.3 Assertions

Four kinds, all in `tests/harness/lib/world.sh`:

1. Exit statuses: `check_exit NAME WANTED COMMAND` (0 applied, 3 refused, 2 stopped by a rule, 4 a step failed).
2. Effects: ownership, modes, group membership, a login attempt as the agent (`runuser -u agent -- cat ...`), a running process owned by the agent.
3. Whole-machine diff for "revoke leaves nothing behind": snapshots of files (path, type, owner, mode), accounts (passwd, group, shadow without hashes) and permission lists before and after; the diff must be empty except named, allowed leftovers (the agent's home folder and the audit log, kept by design; the system's own backup copies of account files).
4. Known defects: `known_defect NAME TASK COMMAND`. Reports `known` while the product fails the assertion; fails the run when it passes. This turns each open task into an acceptance test that is written before the fix. None are open today (scenarios 37 and 38 cover install after revoke and uninstall after planted links): the lines for SIR-70 and SIR-32 are plain assertions now (scenario 03 and scenarios 30 to 36 for the kill switch). A known defect line must have a matching positive precondition (scenario 03 starts a process as the agent first), or it can "fail" for the wrong reason. The same holds for a "left it alone" assertion: it passes for a command that did nothing, so the kill switch scenarios pair each with proof that it ran (`world_unchanged_if`).

Output uses the same `ok` / `not ok` lines as `tests/run.sh`, plus `known`.

### 4.3b Running it on this Mac

Docker Desktop on Omashu runs the same scenarios: `bash tests/harness/run-linux.sh`. The runner mounts the repository read only at
`/src` and copies it inside the container to `/srv/pkg`, owned by root, because the installer (rightly) refuses, as root, to run code
from a folder owned by the host user. The scenarios run that copy (`SRC=/srv/pkg`). The read-only mount case needs two mounts of one
folder and has its own runner: `bash tests/harness/run-ro-bind.sh`.

### 4.3a Running it on a server

Docker Desktop on Omashu may not start (task SIR-76). The same scenarios run on the server ba-sing-se over SSH, one container at a
time and capped: `--memory 256m --memory-swap 256m --pids-limit 256 --cpus 1 --network none --cap-drop NET_RAW`, with available
memory checked before every run (stop below 800 MB), existing containers never touched, and every container and image the run
made removed afterwards. Scenario 27 asks for 3 GB and is skipped there. Scenarios 17, 22 and 26 carry the header `# harness-apparmor: unconfined`: on ba-sing-se the default AppArmor profile fails their deep chains with ENAMETOOLONG (errno 36), so those three containers run with `--security-opt apparmor=unconfined`. Nothing else about them changes (no host folder, no network, the same caps and memory cap). Docker Desktop on Omashu has no AppArmor and runs them as before. The image now also holds `openssh-server`,
`openssh-client`, `cron` and `at`, so key logins, cron jobs and at jobs are real; systemd is not there, so scenario 36 uses stand-ins
for `systemctl` and `loginctl`.

### 4.4 Invocation from make

Proposed Makefile additions (not applied; the Makefile is product code and `tests/unit/test_makefile.sh` checks it):

```
test-real-linux:           # a real install in a throwaway container; skips (exit 77) without Docker
	bash tests/harness/run-linux.sh
test-real-macos:           # runs only on a throwaway Mac (a GitHub runner) or by hand with the sentinel
	bash tests/harness/run-macos.sh
test-real: test-real-linux
```

Exit 77 should be mapped to a printed skip by the target, so a machine without Docker reads "skipped", not "passed". `make test` stays as it is.

### 4.5 Cost per run

| Run | Time | Money | Memory and disk |
|---|---|---|---|
| Linux container scenario set | about 5 s on Omashu | none | 256 MB cap per container; 240 MB of images once |
| Same on a GitHub ubuntu runner | about 1 minute including setup | none (public repository) | none local |
| macOS runner job | unmeasured; minutes | none (public repository); private repositories pay a multiplier on macOS minutes | none local |
| Real Mac manual run | about 15 minutes | none | none |
| Tailscale scenario | tens of seconds | none on a free test tailnet | one temporary device, removed at the end |

## 5. Order of work

Sizes: small is a day or less, medium a few days, large a week or more.

| # | Item | Size | Depends on | Needs Jose |
|---|---|---|---|---|
| 1 | Land the Linux container harness: move the prototype into the branch to merge, make it pass `tests/unit/test_language.sh`, add the three make targets, document in the README | small | none | merge approval |
| 2 | Pin the image base by digest and add an sshd layer plus a scenario: the agent logs in with a generated key and cannot leave its grant (the heart of SIR-9) | small | 1 | none |
| 3 | Fix the default access control list defects (SIR-70, both A and B) and apply the kill switch (SIR-32), each driven by the existing `known_defect` lines, which become plain assertions | medium | 1 | none |
| 4 | GitHub workflow: ubuntu job running item 1, plus a macOS **discovery** job that only prints what the runner allows (`dscl` create, `chmod +a`, Remote Login, the python3 placeholder) before any scenario is written | small | 1 | approval to add a workflow file; no secret |
| 5 | macOS scenarios (`run-macos.sh`): service user by `dscl`, lists by `chmod +a`, revoke, uninstall, the one-line bootstrap (after SIR-49 pins it) | medium | 4 shows it is allowed; SIR-49 for the bootstrap | none |
| 6 | Fault-injection scenarios: make one command fail partway (a shim for `useradd` or `setfacl` earlier on the path), then check the documented re-run recovery; plus an upgrade scenario from an older pinned copy | medium | 1 | none |
| 7 | Tailscale scenario (SIR-33): second image layer with Tailscale (1.104.1 installed and ran in userspace mode with no tunnel device in the probe), `tailscale up` with an ephemeral tagged key supplied by `bb secret`, assert the device appears with `tag:agent`, revoke removes it. Needs one scenario run with network allowed | medium | 1, and the product `tailscale up` step (replace plan-only) | a **test tailnet** (a separate free one, not the real one) with a policy that has `tagOwners` for `tag:agent`, and either an OAuth client limited to the auth keys scope (preferred, it can mint a one-use key per run) or an ephemeral, tagged, pre-approved key; stored with `bb secret`. Keys expire in 90 days or less. |
| 8 | Real Mac manual script and checklist (lid, helper approval, privacy prompts, Tailscale app) | medium | 3, 5 | Jose present for each run; which Mac (his own, or a spare account) |
| 9 | Cloudflare scenario (SIR-2, SIR-34): `cloudflared` layer, create and delete a tunnel and a service token | large | product code for it; 1 | a Cloudflare account, a test zone, a token scoped to tunnel and name-record edit on that zone only |
| 10 | Local macOS virtual machine (Tart) | large | only if 4 and 5 prove inadequate | at least 80 GB free disk, 8 GB free memory, tapping `cirruslabs/cli`; probably an external drive |

## 6. Recommended first three work items

1. **Land the Linux container harness** (item 1, then the sshd scenario of item 2). It is built, it ran, and it already holds acceptance tests for SIR-70 and SIR-32.
2. **Fix the default access control list defects (SIR-70) and apply the kill switch (SIR-32)** (item 3), starting from the failing `known_defect` lines. Both are product changes, and each now has a pass or fail test before the first line of code.
3. **Add the workflow with the macOS discovery job** (item 4). It answers, for free and without installing anything, whether level 2 is real, before anyone writes macOS scenarios or buys a disk.

## 7. What needs Jose

- Nothing for items 1 to 3 and 6, except merge approval.
- Approval to add `.github/workflows/` (item 4). Free on the public repository.
- A test tailnet and a way to mint keys (item 7). A separate free tailnet, policy with `tagOwners` for `tag:agent`. Provide the secret through `bb secret`, never in chat.
- A Cloudflare account, a test zone and a scoped token (item 9).
- A decision on which Mac runs the manual script (item 8), and his time.
- Only if item 10 is ever wanted: free disk, memory and a tap. Updating Docker Desktop (4.27.2 is from February 2024 and works here) would need his administrator password; not needed now. A user-space fallback if Docker Desktop is ever removed: `brew install colima docker` (no sudo; not tried here).
- Nothing in this design needs sudo.

## 8. Limits and challenges (the second look)

- A container is not a server. No systemd, no sshd, no login-module stack unless added. Item 2 adds sshd; systemd-dependent steps (a Tailscale service, a firewall) are not proven by this level.
- The container gate. The product's refusal allows a real apply when it sees a container as root. The harness satisfies that honestly. The refusal is a guard against accidents, not a security boundary: anyone can run it in a container that mounts their real folders. The harness mounts only the repository, read only.
- Lists on shared folders. On Docker Desktop, folders shared from the Mac use a different file system that may not support lists. Scenarios use paths inside the container. Granting a Mac folder from a Linux container is untested and meaningless anyway.
- Known-defect lines can pass or fail for the wrong reason. Mitigated by a positive precondition beside each; review each new marker for it.
- The base image floats. `debian:12-slim` was pulled at digest `sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587`; item 2 pins it. Package versions inside still float with the Debian repository.
- Container start was measured warm. A cold Docker Desktop start was not measured.
- Docker Desktop on Omashu is Jose's own, shared with his database container. The harness uses only labelled containers and its own image tag, and never prunes.
- Omashu is under memory pressure (swap 2.1 of 3 GiB). One 256 MB container is fine; do not run macOS guests or several engines at once.
- The GitHub macOS runner claim is unverified. It is known that runners are fresh machines with passwordless sudo; whether they allow creating accounts and changing Remote Login is exactly what item 4 checks.
- Only the smallest level, `observer`, with `--transport none` was applied for real. `builder` and `operator` add write access; their scenarios are cheap to add after item 1, but were not run.
- The one real run cannot show the cost of a real server's differences (for example a different default group setup in `useradd`). The same scenarios are meant to run on a disposable cloud server at some point; that is not planned here.

## Sources

- Tailscale auth keys and OAuth clients for automation: https://tailscale.com/kb/1085/auth-keys and https://tailscale.com/kb/1276/tailscale-github-action
- Tart (virtual machines through Apple's Virtualization framework, images from a container registry): described in the Packer plugin documentation at https://developer.hashicorp.com/packer/integrations/cirruslabs/tart/latest/components/builder/tart ; the size of the vanilla macOS images was not confirmed from an official page.
