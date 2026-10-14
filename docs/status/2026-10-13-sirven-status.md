# Sirven status: where we are and what is missing

Date: 2026-10-13. Auditor: thread thr_hdrfxfe5xt on the MacBook Pro Omashu, for the orchestrator thr_4mddufbqcn. Audited commit: origin/main at 1b286d4 (fetched; origin/main was not ahead of it). Nothing in product code or any task status was changed. Method: the capacity reading for Omashu is "cannot be judged" (bb reports memory only for the server ba-sing-se), so I did not start a workflow. I worked inline: the evidence pass first, then a separate verification pass that re-ran every command quoted below.

## 1. Health of origin/main (1b286d4)

Run in a scratch worktree under /tmp, foreground, outside the sandbox (the sandbox fakes the phone failures, see the memory note on sandboxed runs).

| Command | Exit | Result |
|---|---|---|
| `make lint` | 0 | `bash -n` clean on 54 files. shellcheck is not installed, so it was skipped. |
| `make test` | 2 | 375 passed, 3 failed |
| `make test-menu-bar` | 0 | 23 Swift tests, 0 failures |
| `make app-test` | 0 | 9 Swift tests, 0 failures |
| `make test-keep-awake` | 0 | 20 Swift tests, 0 failures |

Failing tests (all three installer tests, all macOS-only):
- `test_install_started_by_sh_says_to_use_bash` (tests/unit/test_install.sh): expects `sh install.sh --help` to exit 1, gets 0. On macOS `sh` is bash 3.2, so the guard never trips.
- `test_enter_twice_accepts_the_shown_defaults` and `test_input_that_ends_takes_the_defaults` (tests/unit/test_questions.sh): expect the default path prompt to show the working folder (`/private/var/folders/...`), get `[none]`. Likely the macOS `/var` versus `/private/var` folder alias; I did not confirm the cause. They are not caused by recent work: the SIR-4 comment records them passing on Linux, and the phone quality report found them failing on an earlier commit.

The two phone tests reported on 1b286d4 (`test_phone_map.sh` onboarding, `test_phone.sh` loopback) both PASSED in this run. They only fail inside the sandbox, so they are an environment artifact, not a defect. The Linux sandbox run recorded on SIR-4 had a different pair of failures (a macOS-form `stat` call), also an artifact.

Integration branch check: merging origin/integration/sir-46-xcode-free-phone into origin/main merges cleanly (no conflicts), and `make test` on the merge gives 380 passed, 3 failed (the same three), `make lint` exit 0.

Gaps in what the suite proves: nothing runs a real install. `lib/plan.sh` refuses a real apply outside a throwaway Linux container as root, so every install test is against a fake root. No container or virtual machine test exists. No shellcheck run exists.

## 2. Unmerged work

| Branch / worktree | Holds | Where it lives | Recommendation |
|---|---|---|---|
| integration/sir-46-xcode-free-phone (a61b7aa, 37 commits) | The Xcode-free iPhone path: `sirven phone start` supervisor over pymobiledevice3, setup plan, preflight, 27 runner tests, research note, code review, acceptance review, partial phone test. Contains all five sir-46-* child branches. | origin and Omashu | Merge after conditions M1, M2 and condition 3 from the acceptance review (docs/research/qa/sir-46-acceptance.md): add the developer disk image mount step, fix the route A runner identifier text, and say the free-account signature lasts 7 days (the word "once" is wrong). The newest commits (416e6a0, b993d9f) address a disk-image retry and wording, so check M1 against the branch head before merging. Do not call it done until the real-phone test (SIR-57) runs. |
| keep-awake-bb-watcher (2da19df, 2 commits) | The watcher that holds the Mac awake only while bb has work (SIR-53). Its LaunchAgent is live on Jose's Mac and runs from this code. | Was Omashu only. **Pushed to origin on 2026-10-13** (tip 2da19df confirmed with `git ls-remote`) after a diff scan found no secrets, tokens or personal data. | Merge to main (SIR-53, SIR-56). Not yet merged. |
| architecture-docs-mermaid-remotion-parent-thr_ujwbskpf6t (f2ee785, 1 commit, 40 files) | Ten architecture diagrams, a drift check, a Remotion video scene per diagram, README inserts. | Omashu only. **Deliberately not pushed.** | Hold. Before any push: (a) `docs/architecture/graph.mjs` and a second build file hard-code a personal absolute path to a sibling project folder on the owner's Mac; (b) one diagram and caption describe the sunsirven dictation project, which appears nowhere on main; (c) the pretty-mermaid dependency decision and the edits it made to the sunsirven repository are still open. Fix the paths to relative or environment values, decide on the sunsirven content, then merge. |
| rescue/partner-applications-drafts (8b1d7df, 2 commits) | Uber for Business and Lyft Business application drafts (467 lines in 2 files), held for review. SIR-21 is canceled. | Omashu only. **Not pushed, by instruction.** | Keep as a record, do not merge. A self-contained bundle now exists at ~/sirven-backups/partner-applications-drafts-2026-10-13.bundle (`git bundle verify` exit 0, complete history). The local branch partner-program-applications-for-uber-for-busine-thr_hfvp4mbf9k points at the same commit 8b1d7df. |
| 04-reciprocity-accounting (main checkout at ~/Projects/sirven) | Nothing unmerged (0 commits ahead). But the checkout is stale: it sits on an old branch with `M Makefile` and untracked `lib/allowlist_policy.py`, `lib/attestation/`, `runtime/`, leftovers that main has since replaced. | Omashu | Not mine to change. Switch it to main after checking those four items are safe to drop. |
| env_zcuewt4wnr worktree (understand-and-build-face-id) | Branch tip dc761fd is already on main. One untracked file, `docs/faceid-research.md`. The orchestrator log records declining a biometric-bypass build, so check what the note holds before deleting. | Omashu | Read it, then keep or delete. Nothing to merge. |
| Other worktrees at 418133c, c3a4b7f (sunsirven exports, acli check, bb agent infrastructure, sunsama replica) | No commits beyond main (sunsama replica thr_z6frwgmkzf is at c3a4b7f, already on main). | Omashu and ba-sing-se mounts | Archive when their threads are done. |
| All other local feature branches (adopt-existing-setup, runtime, attestation, policy, and so on) | Already merged into main; each exists on origin. | origin | Safe to delete after Jose agrees (no deletions made). |

Finding to flag: the "done" tasks SIR-52, SIR-58, SIR-59, SIR-60 describe work that is on the integration branch, not on main. Their status is accurate for the threads' deliverables, but the product does not have the Xcode-free path until that branch merges.

## 3. Open tasks: evidence on main and recommended status

Evidence marked "verified" I re-ran at 1b286d4 in this audit. Evidence marked "recorded" comes from the 2026-10-12 reconciliation comments at c3a4b7f and was not re-run, though main has only gained the peer transport (418133c) and two README commits since.

Archived-thread "in review" tasks: every one except SIR-10, SIR-53, SIR-55 has its work on main (verified by the files, the test run above and the commit ancestry). The three exceptions are called out below.

### V0 scope tasks
| Task | Now | Recommend | Reason |
|---|---|---|---|
| SIR-1 Tailscale transport | in progress | in progress | Verified: `lib/tailscale.sh` plans only, `tailscale apply` prints "not yet"; the menu-bar panel is on main (23 Swift tests pass). A real tailnet has never been changed. Needs a hand check on Jose's Mac. |
| SIR-2 Cloudflare Tunnel transport | todo | to do | Verified: `lib/cloudflare.sh` documents only; no tunnel or token creation. Needs Jose's Cloudflare account. |
| SIR-3 Personal agent, chief of staff | backlog | to do, blocked on Jose | No acceptance criteria exist anywhere. Jose must say what it does on day one. |
| SIR-4 Short install | in progress | in progress | install.sh, two questions, `--dry-run` on main; real apply refused outside a container; one-liner never verified on a real Mac (SIR-48). |
| SIR-5 Twenty CRM component | in review | in review | `components/crm.sh`, `sirven add crm`, 12 tests recorded; never run with a real container. Jose decisions: the Affero licence against sirven's MIT licence; the port binding. |
| SIR-6 Adopt existing setup | in review | in review | `lib/adopt.sh` and 18 tests recorded; Tailscale, bb and an earlier sirven run adopted. Verified: no Cloudflare in `lib/adopt.sh`. Jose decision: refuse with exit 2 or keep the login when a Mac is already on Tailscale. |
| SIR-7 Single package | in review | **in progress** | One package ships, but no notarized build exists (verified: `site/download/release.json` is sample data, ad-hoc signing, notarized false), the bundle identifier is a placeholder, and SIR-49 and SIR-51 are open. |
| SIR-8 Automatic updates | todo | to do | Verified: no update code (grep for Sparkle and update finds nothing). |
| SIR-9 Fresh-user install | todo | to do | Never run on a clean machine or account. Depends on a container or virtual machine run, SIR-48, SIR-50. |

### Work packages and installer tasks
| Task | Now | Recommend | Reason |
|---|---|---|---|
| SIR-28 W1 Installer core | in progress | in progress | Core and fake-root tests exist; real apply refused. |
| SIR-29 W2 Service user | in progress | in progress | `lib/service_user.sh` plans only; no container run. |
| SIR-31 W4 Audit log | in progress | in progress | `lib/audit.sh` works (8 tests); the per-session forced-command wrapper is unverified. |
| SIR-32 W5 Kill switch | in progress | in progress | Plan output; `revoke` apply prints "not yet". |
| SIR-33 W6 Tailscale | in progress | in progress | Same as SIR-1. |
| SIR-34 W7 Cloudflare | todo | to do | Same as SIR-2. |
| SIR-35 W8 Runtime adapters | todo | to do | No adapters beyond the macOS runtime. |
| SIR-36 W9 Phone-to-agent channel | backlog | to do, blocked on Jose | By design relies on bb; Jose's open question 3 and the `--with-bb` spec. Not the same as the iPhone path. |
| SIR-37 W10 Friend invite | todo | to do | Nothing built. |
| SIR-38 W11 Multi-machine | backlog | backlog | No design yet; peer routing transport is related, not the same. |
| SIR-39 W12 Advanced config | backlog | backlog | Nothing built. |
| SIR-40 W13 Docs, demo, video | in review | in review | Docs and video exist; Jose has not reviewed them; the architecture diagrams are on the held branch (SIR-55). |
| SIR-41 W14 Test harness | in progress | in progress | Fake-root and golden tests run (375 of 378 pass); no container or virtual machine tests. |

### Features, decisions and recent items
| Task | Now | Recommend | Reason |
|---|---|---|---|
| SIR-10 iMessage side panel spike | in review | **to do, blocked on Jose** | Nothing was built (the verdict was "not tonight"). There is no work to review. Jose chooses: read-only live panel, or accept the extra macOS permission. |
| SIR-11 iPhone-use integration | in review | in review | Bridge, crawler, map and ride backend are on main, 63 phone tests recorded; only a fake phone was ever used by tests on main. Real-phone proof comes from SIR-57. |
| SIR-12 Signed downloadable app | in review | in review | App, wizard and download page are on main; needs Jose's signing and notarization credentials. |
| SIR-13 Menu-bar Tailscale app | in review | in review | On main, 23 tests pass; waiting for the exit node, connect and disconnect check on Jose's Mac. |
| SIR-14 Keep-awake | in review | **done** | Merged (98604c7); 20 Swift tests pass here, 9 shell tests recorded. The lid-closed install and hardening are tracked in SIR-53 and SIR-56. |
| SIR-15 Ride demo | in review | in review | Runs against an in-memory phone with substitutions marked; the concierge ship gate is closed. |
| SIR-18 Concierge operations | in review | in review | Packet on main (16 tests recorded); Jose must approve the monitoring and trust-and-safety drafts. |
| SIR-22 Interface | in review | in review | On main and wired to the live runtime; nobody has opened it in a real browser; three known display defects. |
| SIR-27 macOS runtime | in review | in review | On main; the Swift fetch helper ran on a Mac per the thread. Jose decision: the HTTPS proxy cannot require approval before a POST. |
| SIR-43 Peer routing decision | in progress | in progress | End-to-end wiring (dfb1f18) and the loopback transport carrier (4e840a8, merged at 54aa04a, verified on main: `lib/peer_transport.py`) are done. The ship gate is closed; opening it is Jose's call. The task text saying the carrier is unmerged is stale. |
| SIR-44 Decision: adopt is day 1 | in review | in review | Implemented for Tailscale and bb; Cloudflare is not (verified). |
| SIR-45 Decision: single package | in review | in review | Same as SIR-7. |
| SIR-46 Lighter iPhone path | in progress | in progress | Everything is on the unmerged integration branch. |
| SIR-48 Verify the one-liner on a real Mac | backlog | to do, needs Jose | I confirmed `https://cli.sirven.xyz` answers HTTP 200 (a header check only; I did not run the pipe to bash, which a safety check had denied). Jose or Iroh runs the two commands in the task. |
| SIR-49 Pin the bootstrap | backlog | to do | The bootstrap fetches the main branch, so any merge reaches strangers at once. Public-facing risk. |
| SIR-50 Fresh-Mac python3 guidance | backlog | to do | Small. The phone acceptance review reconfirms the python3 stub. |
| SIR-51 Local copy after install | backlog | to do | Revoke and uninstall need the repository again. |
| SIR-53 Keep-awake install | in review | in review | Code is now on origin as keep-awake-bb-watcher but not merged. Lid-closed proof needs Jose's five steps (allow the helper, pmset check). |
| SIR-54 Transport carrier | in review | **done** | Verified on main: `lib/peer_transport.py`, merged at 54aa04a. The task text says "not merged", which is stale. |
| SIR-55 Architecture docs | in review | in progress | Not on main or origin; blocked on the path fix, the sunsirven content decision and the pretty-mermaid decision. |
| SIR-56 Harden keep-awake helper | backlog | to do | Small, after SIR-53 merges. |
| SIR-57 Real iPhone test | in progress | in progress | Steps 2 and 8 passed; steps 3 to 7 not run because no phone was attached. Needs the phone plugged in, unlocked, in Developer Mode, and Jose's Apple team. |

Decisions recorded as done (SIR-42, SIR-47, SIR-16, SIR-20, SIR-23 to SIR-26, SIR-30): their artifacts are on main (components, docs/connector, allowlist-review, reciprocity, attestation, PERMISSIONS, and the cli.sirven.xyz endpoint answers). Canceled SIR-17, SIR-19, SIR-21 match the coordinator log: the partner backend and Stripe Issuing were removed from the booking path (`lib/issuing` stays on disk, dormant and excluded from the package).

## 4. What is missing for V0

Ordered next work. Size: small (a day or less), medium (a few days), large (a week or more).

1. **Merge the Xcode-free phone path after M1, M2 and the "once" wording** (small). Depends on: nothing. Needs Jose: nothing to merge it. The branch merges cleanly and keeps the suite at 380 passed with the same 3 failures.
2. **Real-iPhone test, SIR-57** (small, but gated by hardware). Depends on item 1. Needs Jose: the phone plugged in, unlocked, with Developer Mode on, and his Apple team identifier. Also decides whether route B is the stated route.
3. **Pin the bootstrap and keep a local copy, SIR-49 and SIR-51** (medium). Depends on: nothing. Needs Jose: choose the release tag or commit rule. Reason: this is the only public exposure today, since anything merged reaches strangers' machines.
4. **Verify the one-liner on a real Mac, SIR-48, and add the fresh-Mac python3 guidance, SIR-50** (small). Depends on SIR-49 for a stable target. Needs Jose or Iroh to run the commands.
5. **Real apply: tests in a throwaway container or virtual machine, then Tailscale and kill switch apply (SIR-9, W2, W5, W6)** (large). The installer proves plans, not effects. Depends on a Linux container harness first (W14) so the first real apply is safe. Needs Jose: the tailnet and the agent tag decision (exit 2 or keep the login on an already-joined Mac).
6. **Cloudflare Tunnel (SIR-2 and W7)** (large). Depends on item 5's harness. Needs Jose: Cloudflare account and a scoped token; also whether adopting an existing Cloudflare setup is required on day 1 (SIR-44).
7. **Notarized signed build and automatic updates (SIR-12, SIR-7, SIR-8)** (large). Depends on items 3 and 5. Needs Jose: Apple developer account and signing credentials, the final bundle identifier (xyz.sirven.app is a placeholder), the Sparkle or alternative decision.
8. **Define "chief of staff" for day one (SIR-3)** (small for Jose, then medium). Nothing can be scoped until Jose writes the acceptance criteria. Includes the phone-to-agent channel question (SIR-36).
9. **Merge the held branches** (small each): keep-awake-bb-watcher (ready), then architecture docs after the path fix.

## 5. Branch handling record (2026-10-13)

- keep-awake-bb-watcher: diff scanned for credentials, tokens, personal details and home paths (only `$HOME`-relative Library paths); pushed to origin with no force and no pull request; `git ls-remote` shows tip 2da19df, equal to the local branch.
- architecture-docs-mermaid-remotion-parent-thr_ujwbskpf6t: scan found a personal absolute path to a sibling project folder hard-coded in `docs/architecture/graph.mjs` and a second build file; not pushed; reported to the orchestrator.
- rescue/partner-applications-drafts: not pushed. Bundle written to ~/sirven-backups/partner-applications-drafts-2026-10-13.bundle, 189,518 bytes, `git bundle verify` exit 0, complete history, one ref (8b1d7df).
- The two scratch worktrees under /tmp were removed after the runs.
