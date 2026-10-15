# Docs claims audit, 2026-10-15

Checked against origin/main at commit 1cc13bb, on the branch docs-truth-pass-2026-10-15 cut from origin/main. Successor to `docs/status/2026-10-14-docs-claims.md` (checked against 713659b, before the Linux apply, the macOS apply switch, the kill switch apply on Linux, the Tailscale transport, and release v0.2.0).

Part of the bb task SIR-40 (W13: Docs, demo, video).

## How to read the verdicts

- **TRUE**: the proof shows the claim.
- **TRUE, WITH A QUALIFICATION**: true, but a condition the document leaves out changes the reading.
- **FALSE**: the proof contradicts the claim. The fix is listed in the findings section.
- **STALE**: was true when written, is not true now (for example a version number or a file that moved).
- **NOT VERIFIED HERE**: needs a macOS build, a real phone, a real Linux apply, a real release, or an outside service that this check did not run. The reason is given.
- **NOT CHECKED**: a quotation of a decision, or an operational note. No code claim to test.
- **PARKED**: a point Jose reserved (the license file, the Sleepless credit link, npm). Reported, not changed.

Claim IDs are per file: R (README.md), W (docs/WALKTHROUGH.md), B (docs/BOOTSTRAP.md), D (docs/DOWNLOAD-AND-ONBOARDING.md), P (docs/PERMISSIONS.md), K (docs/COMPONENTS.md), S (docs/SCOPE.md), Q (docs/peer-routing.md), H (docs/phone-interface.md), I (install.sh --help), U (uninstall.sh --help), G (bin/sirven --help). Where a block of text makes one claim, it is one row. Commands are in the table at the end, numbered C1 to C27, with exit status. README.md line numbers are for the baseline 1cc13bb unless marked (branch). The branch adds two lines after line 39, so the branch README shifts by two from there on.

Terms used below: npm is the Node package manager. gh is the GitHub command line tool. A dry run is a run with `--dry-run`, which prints a plan and changes nothing.

## Findings fixed on this branch

1. **Plain dry run refuses on a Tailscale machine** (README.md:35; the new paragraph is README.md:40 on the branch). On this Mac, `bash install.sh --dry-run` exits 2 and prints no plan, because the machine is logged in to Tailscale without `tag:agent`. Fixed: the Quick start now says so and names `--transport none` and `--prefix` as the ways to read the plan.
2. **"Nothing else on the machine changes"** (docs/WALKTHROUGH.md:67). False: the plan also creates the state and policy folders, the audit folder, the kept copy of the package, the launcher `/usr/local/sbin/sirven`, and (with the default transport) joins the tailnet. Fixed with the real list.
3. **`--with-bb` "has nothing left to install"** (docs/WALKTHROUGH.md:14). Ambiguous. The help says it adds a note to the plan, plan only for now. Fixed to say that.
4. **Mac apply "stops before any change"** (docs/WALKTHROUGH.md:48). True by default, not without the owner's switch. Fixed to name `SIRVEN_MACOS_REAL_APPLY=1` and the root requirement.
5. **Pinned release example is v0.1.0** (docs/BOOTSTRAP.md:66-73). STALE. origin/main and the served script at cli.sirven.xyz pin v0.2.0, checksum 7750941c45a627f353362dda0a7f54e5b589cdf4e5b0f6bef78ba5e00beeb6ad (matches the release asset). Fixed.
6. **Maintainer release steps name v0.2.0** (docs/BOOTSTRAP.md:87-108). v0.2.0 is already tagged and published. Fixed to use a version placeholder.
7. **"The consumer install path: a Mac app you download from the sirven website"** (docs/DOWNLOAD-AND-ONBOARDING.md:3-5). FALSE today. https://sirven.xyz/download/release.json returns an HTML page (HTTP 200, text/html), not a manifest, so the download is not live. Fixed to say it is planned and not yet published.
8. **"The release plan, visible with `--dry-run`"** (docs/DOWNLOAD-AND-ONBOARDING.md:93-97). False without the two signing credentials: `build.sh --release --dry-run` exits 2 and prints only the error. Fixed.
9. **Repository name** (docs/SCOPE.md:11-13). FALSE: project.json and origin both say Joesirven/sirven. Fixed.
10. **`docs/DEMO.md` outline** (docs/SCOPE.md:75). The file does not exist. Fixed to say so.
11. **Tailscale and `--with-bb` status cells** (docs/SCOPE.md:68, :71). W6 said the Tailscale path was never run; the Linux container join and logout exist (harness scenario 62). W9 said `--with-bb` installs bb; it adds a plan note. Fixed.
12. **Stale file path** (docs/peer-routing.md:33, :35). `cli.mjs` is at `lib/attestation/cli.mjs`. Fixed.
13. **Garbled sentence on readiness** (docs/peer-routing.md:47-48). Duplicated words. Fixed with the same meaning.
14. **"Runtime interface was not in the repository"** (docs/phone-interface.md:202-206). STALE: docs/runtime-interface.md exists. Fixed: the reconciliation is now the open item.

## Code findings (not fixed here, out of scope or code, not docs)

- **lib/peer_routing.py:20-23** (the module docstring) says `peer_routing_available` "is false on every node today, whatever readiness finds". The code at line 64 sets `TRANSPORT_BUILT = True`, and line 259 sets `peer_routing_available` to `components_ready and TRANSPORT_BUILT`. The docstring is stale. The docs (docs/peer-routing.md:47-48) match the code.
- **Parked, not changed**: the Sleepless upstream address (https://github.com/itskoosh/Sleepless) returns HTTP 404 (C16; see the PARKED rows). The README has no link to it. Baseline README.md:73 names Sleepless without a link, and :161-162 says none is linked (branch :75 and :163-164). The credit is Jose's to decide. `package.json` says `"license": "MIT"` and no LICENSE file is tracked (`git ls-files` finds none). The npm package is still 0.1.0, while the release is v0.2.0.
- **Lint note, not a claim**: docs/phone-interface.md's result table (lines 165-178) omits `not_loopback` (HTTP 500, lib/phone_bridge.py:292), which the code can return when `SIRVEN_WEBDRIVERAGENT_URL` is not loopback. The table is incomplete, not false. Not changed.

## README.md

| # | Claim | Where | Verdict | Proof |
|---|---|---|---|---|
| R1 | The agent runs as a local user you own; no hosted middleman | :7 | TRUE | The service user `agent` is step 12 of the prefix dry run (C2). |
| R2 | Three levels; operator is builder today; none gets root or sudo | :24 | TRUE | levels/operator.json: `capabilities.designed_not_built` lists the two operator capabilities. The Linux grant compiled for builder and operator is identical (C12). root and sudo are in every level's denied list. |
| R3 | Nothing granted by default; system folders, home folder, credential folders refused | :25 | TRUE, WITH A QUALIFICATION | `paths.default_grants` empty, `deny_exact` lists /home and /Users, `deny_within` lists /etc and /usr, `deny_components` lists .ssh, in every level file. No refusal was run. |
| R4 | `sirven grant inspect` shows what is in force; `grant rollback` reverses the last change | :26 | TRUE | `grant inspect --prefix` exits 0 (C1). `grant rollback --dry-run` exits 1 with "no audit log ... no grant change to roll back" on a fake root with no install (C1). |
| R5 | `sudo /usr/local/sbin/sirven revoke --all` cuts the agent off and keeps the records | :26 | TRUE on Linux as root; plan output on macOS | lib/kill_switch.sh:443 (`plan_kill_switch_linux`) applies the steps. The macOS plan is `plan_kill_switch_macos` (:426), applied only as plan output (`revoke --all --dry-run` exits 0; applying on macOS is refused, install.sh:552). Linux apply has harness scenarios 03, 36, 44, 60 (names only, not re-run in this pass). |
| R6 | Installer prints its full plan first; `--dry-run` changes nothing | :27 | TRUE, WITH A QUALIFICATION | `--dry-run --prefix ... --yes` prints the plan, exit 0 (C2). Plain `--dry-run` on this Mac refuses, exit 2, before any plan (C3). Fixed in the Quick start. |
| R7 | Adopts what it finds (Tailscale, bb, an earlier run) and does not replace it | :28 | TRUE | install.sh --help (I2); lib/adopt.sh. Adopt tests in the make test run (see gates). |
| R8 | Quick start: `bash install.sh --dry-run` "read the plan first; this changes nothing" | :35 | FALSE on this Mac (fixed) | Exit 2 on this Mac (C3). The plan prints with `--transport none` (C4) and with `--prefix` (C2). |
| R9 | `sudo bash install.sh` asks two questions: level and folder | :36 | TRUE | install.sh --help (I1); lib/questions.sh:4-5, prompt format `N/2 access level [default]`. |
| R10 | `bash bin/sirven grant inspect` | :37 | TRUE | Exit 0 with a fake root (C1). |
| R11 | Applying the plan to a real Linux machine: root, a plan printed, a typed yes; no terminal means nothing applied, exit 3, unless `--yes` | :45-46 | TRUE | lib/plan.sh:460-474 (typed yes, no-terminal refusal returns 3); install.sh:552 (`DIE_STATUS=3`). |
| R12 | "A container, or a machine that merely looks like one, is asked too" | :45-46 | TRUE (by code) | The refusal checks root and the platform only (lib/plan.sh:378-387), not for a container. |
| R13 | On macOS the installer stops before any change, unless the owner's real install check is switched on (`SIRVEN_MACOS_REAL_APPLY=1`, as root) | :46-47 | TRUE | lib/plan.sh:367-373; uninstall.sh:473-474 uses the same gate. |
| R14 | `sudo bash uninstall.sh` removes what the install created | :47 | TRUE (by code) | `uninstall.sh --dry-run --prefix` exits 0 (C4). A real removal was not run. The install record is the list (help). |
| R15 | `npm install -g @joesirven/sirven` puts `sirven` on your path | :48 | TRUE, WITH A QUALIFICATION, PARKED | The npm package is 0.1.0 (npm view, C15), not v0.2.0. The package still installs `bin/sirven` (0.1.0 pack check in the earlier pass). npm publishing is parked for Jose; not changed. |
| R16 | Applying to a macOS machine is not verified; kill switch applies on Linux as root and is plan output on macOS; `uninstall.sh` is the way to undo an install on macOS, behind the same switch | :53-55 | TRUE | Same evidence as R5 and R13. |
| R17 | The audit log covers the install and every grant change | :55 | TRUE (by code), NOT VERIFIED HERE for an applied run | lib/audit.sh writes install and grant entries. An applied install is needed to see them. |
| R18 | Per-session and per-command logging through a forced-command wrapper: designed, not built | :55 | TRUE | lib/audit.sh:79 says "designed, built after alpha" (grep count 1). |
| R19 | Kernel-level auditing: designed, not built | :55 | TRUE | `audit.file_changes` is false in every level file (C7). |
| R20 | Operator's service restarts and log reads: designed, not built | :55 | TRUE | `owner_listed` is `{services: [], logs: []}` and read by nothing (grep of lib finds no reader). |
| R21 | Lets your agent drive your plugged-in iPhone, opt in per session | :56-57 | TRUE | `sirven phone` help (C6); lib/phone_bridge.py consent commands. |
| R22 | Built and tested against a fake phone; not run on a real phone | :62-63 | TRUE | docs/phone-interface.md:3-4, :238-240 (status); `sirven phone detect` reports no iPhone here (C6). |
| R23 | `sirven add crm` sets up Twenty; sirven never needs it | :64-65 | TRUE | `add --list` (C10); `add crm --dry-run` exits 0 (C10). |
| R24 | Peer routing is not yet available; the runtime refuses it and the ship gate is closed | :59-60 | TRUE | lib/sirven_runtime/seam.py:99 (`peer_routing_not_built`); lib/policy_engine.py:67 (`"closed"`). |
| R25 | `sirven awake` keeps the Mac awake while work is in flight, and only then; holds a macOS power assertion | :70-86 | NOT VERIFIED HERE | Needs the macOS build (`make keep-awake`). On this Mac `sirven awake` says "not built yet" (C5). The strings match the code: macos/keep-awake/Sources/SirvenKeepAwake/Identity.swift:13 (the assertion name), macos/keep-awake/README.md:23 (the 12-hour lease). |
| R26 | Awake commands list | :91-100 | NOT VERIFIED HERE | Needs the built binary. |
| R27 | Sample output of `sirven awake status` | :104-113 | NOT VERIFIED HERE | Illustration, labelled as such in the text. |
| R28 | Lid-closed helper approval flow (Service Management framework, System Settings path) | :121-141 | NOT VERIFIED HERE | macOS-only, signed app. The document says so (:140-141). |
| R29 | The setting used is `pmset disablesleep`, which Apple's manual does not document | :154-157 | NOT VERIFIED HERE | macOS-only. |
| R30 | Keep-awake is inspired by Sleepless by itskoosh | :73, :161-162 | PARKED | The README has no link to Sleepless: :73 names it without a link, and :161-162 says none is linked. Its upstream address returns HTTP 404 (curl, C16). Jose parked the credit. Not changed. |
| R31 | iPhone integration follows iPhone-use by ZHONG XIN (MIT) | :166-169 | TRUE | The repository license is MIT (gh api, C16). |
| R32 | WebDriverAgent is from the Appium project, under the BSD license; not bundled | :170-172 | TRUE | The LICENSE file text is the BSD License (gh api, C16). GitHub's license detector reports "NOASSERTION", which is a detector result, not a different license. |
| R33 | `make keep-awake` builds the program; developer details in macos/keep-awake/README.md | :117-119 | TRUE | `make -n keep-awake` exits 0 and shows `swift build` (C5); the file exists. |
| R34 | Links to docs/WALKTHROUGH.md and the other docs | :51, :59-65 | TRUE | Each linked path exists (ls, C17). |

## docs/WALKTHROUGH.md

| # | Claim | Where | Verdict | Proof |
|---|---|---|---|---|
| W1 | An agent already running stays as it is; sirven connects the missing pieces | :9-11 | TRUE | install.sh --help (I2). |
| W2 | Tailscale: tags read from `tailscale status --json`; a tagged machine is adopted; sirven never logs in or re-keys in an adopt path | :13 | TRUE (by code) | lib/adopt.sh and the Tailscale adopt tests (earlier pass). The status command was not re-read in this pass. |
| W3 | bb found on the path is kept; `--with-bb` "has nothing left to install" | :14 | FALSE as worded (fixed) | The help says `--with-bb` "adds the bb install note to the plan (plan only for now)" (I8). |
| W4 | An earlier run's grant, policy copy, audit log, and install record are kept | :15 | TRUE (by tests) | Adopt tests (make test). |
| W5 | Conflicts stop the run before any change, and say what to do | :17-22 | TRUE | The Tailscale conflict text (C3, `--dry-run` on this Mac) matches :19. |
| W6 | A plain re-run keeps the earlier level and path; a different one is a grant change | :24 | TRUE (by tests) | Adopt tests. |
| W7 | With `--yes` nothing is asked: observer, no path; `--dry-run` changes nothing | :46-51, :63 | TRUE, WITH A QUALIFICATION | `--yes` prints "using defaults (--yes): level observer, paths none" (C2, the prefix run). A plain `--dry-run` can refuse on a conflicting machine, see R6. |
| W8 | A Mac without developer tools: stop and ask for `xcode-select --install` | :48 | TRUE (by code) | The placeholder check (lib/preflight.sh). Not run here: developer tools are present on this Mac. |
| W9 | Applying an install to a Mac is not verified; a real run stops before any change | :48 | TRUE, WITH A QUALIFICATION (fixed) | lib/plan.sh:367-373: the owner's switch `SIRVEN_MACOS_REAL_APPLY=1` as root lifts the refusal. |
| W10 | The one-line command installs a pinned release, checked against its checksum | :50 | TRUE | The served script equals the repository copy (C9, cmp exit 0). The pinned checksum matches the release asset (C8). The command itself was not run, because it installs. |
| W11 | Confirming applies the plan: creates the service user, sets the level, writes an audit record. "Nothing else on the machine changes." | :65-67 | FALSE as worded (fixed) | The prefix dry run lists 22 steps, including the state and policy folders, the audit folder, the kept package copy, the launcher, and the tailnet join (C2). |
| W12 | Live per-session and per-command logging through the forced-command wrapper: designed, not built | :71 | TRUE | lib/audit.sh:79. |
| W13 | `sirven grant inspect` and `sirven grant rollback --dry-run` | :75-80 | TRUE | C1. |
| W14 | `sudo /usr/local/sbin/sirven revoke --all`: cuts the agent off now, ends its processes, locks and expires its account, removes keys, services and jobs, takes back every grant | :84-92 | TRUE on Linux as root | lib/kill_switch.sh steps (PERMISSIONS.md:344-357 lists them; the functions exist: kill_switch_remove_keys, kill_switch_stop_services, kill_switch_remove_jobs, kill_switch_mark_revoked). Linux apply has harness scenarios (names only). |
| W15 | A plain install will not turn the account back on; `install.sh --reinstate` does | :92 | TRUE | install.sh --help (I9 area; `--reinstate`). |
| W16 | Today the audit log covers the install record and grant changes | :96 | TRUE (by code) | lib/audit.sh; NOT VERIFIED HERE for an applied run. |
| W17 | macOS protects Desktop, Documents, Downloads; grant paths outside them | :97 | TRUE | `paths.macos_privacy_folders` in every level file (C7). |
| W18 | Tests prove plans, not effects; real user creation verified in throwaway environments only | :98 | TRUE (status) | docs/SCOPE.md:147-148 says the same. |
| W19 | Friend invite ships last: read-only by default, with mandatory expiry | :99 | TRUE (as a plan statement) | install.sh:375 says "revoking one invite is designed, not built"; no `invite` command in bin/sirven (C6 help). |

## docs/BOOTSTRAP.md

| # | Claim | Where | Verdict | Proof |
|---|---|---|---|---|
| B1 | `curl -fsSL https://cli.sirven.xyz \| bash` runs a script that installs one pinned release | :3-4 | TRUE | The served script is the repository copy (C9). |
| B2 | Downloads the release archive over https only, with timeouts; checks the checksum before unpacking or running | :10-14 | TRUE | bootstrap/sirven-bootstrap.sh:90 (`--proto '=https'`, `--connect-timeout 20`, `--max-time 900`). Checksum order by tests. |
| B3 | A mismatch, a failed download, or a cut-off download runs nothing; a script with no pin refuses | :16-19 | TRUE (by code and tests) | bootstrap/sirven-bootstrap.sh:104-107 (the no-pin refusal); the bootstrap tests. |
| B4 | The pin is two lines near the top of bootstrap/sirven-bootstrap.sh | :26-33, :66-71 | TRUE (structure) | bootstrap/sirven-bootstrap.sh:24-25. |
| B5 | The example pin values | :66-73 | STALE (fixed) | The pin on main is v0.2.0 (:24-25), not v0.1.0. |
| B6 | The served script carries its own pin; only bootstrap/release.sh writes the two lines | :75-76 | TRUE | bootstrap/release.sh:87-91 writes both lines. The served copy has the pin (C9). |
| B7 | The archive is built with `git archive` from the tag's commit | :78-80 | TRUE | bootstrap/release.sh:6, :31. |
| B8 | Maintainer release steps | :84-111 | STALE (fixed) | The steps named v0.2.0, which is tagged (b04dc45) and published (C8). Replaced with a version placeholder. |
| B9 | The served script equals the repository copy (`curl ... \| cmp`) | :113-118 | TRUE | `cmp` exit 0 (C9). The `bash -s -- --dry-run` line was not run, because it runs the served script. |
| B10 | Until the deploy step is done, cli.sirven.xyz serves what was deployed last | :122-124 | TRUE (as a process note) | The served copy matches main today. |
| B11 | Keeps a copy under /var/lib/sirven/package with install.sh, uninstall.sh, bin, lib, levels, components, project.json | :128-131 | TRUE | Plan step 6 (C2). |
| B12 | Revoke from the copy: `sudo /usr/local/sbin/sirven revoke --all`; Linux applies; Mac applies are plan output and exit 3 | :142-147 | TRUE | install.sh:552 (`DIE_STATUS=3`), plan.sh:367-373; the Mac apply was not run (only the dry run, C4). |
| B13 | A Mac does not apply an install by default, so no copy is made on a Mac | :149-152 | TRUE | plan.sh:367-373 (gate). |
| B14 | Uninstall via `sudo /usr/local/sbin/sirven uninstall` | :138-141 | TRUE (by code) | Plan note (C2) names the launcher; uninstall help (U). |

## docs/DOWNLOAD-AND-ONBOARDING.md

| # | Claim | Where | Verdict | Proof |
|---|---|---|---|---|
| D1 | The consumer path: a Mac app you download from the sirven website | :3-5 | FALSE today (fixed: now "planned") | https://sirven.xyz/download/ returns 200; /download/release.json returns 200 text/html, not a manifest (C18). |
| D2 | macOS 13 or newer, Apple silicon and Intel | :9 | TRUE (minimum version); NOT VERIFIED HERE (both architectures) | Platform declared in app/macos/Package.swift (earlier pass). The universal release build needs the credentials (D10). |
| D3 | Component paths exist: app/macos, copy/onboarding-wizard.json, app/macos/build.sh, site/download | :7-12 | TRUE | ls (C17). |
| D4 | One static page, no build step, no third-party scripts | :12, :110 | TRUE (by earlier pass) | site/download/index.html loads download.js only. Not re-read here. |
| D5 | The wizard is three steps plus a confirmation; the tests fail if that changes | :14-18 | TRUE (by test names) | Test names from the earlier pass. `make app-test` was not run in this pass (macOS Swift tests). |
| D6 | Two optional permissions; nothing requested until Allow | :24-26 | TRUE (by test names) | Earlier pass. |
| D7 | Neighborly and Co-op visible but closed; the ship gate keeps them closed | :21-23, :46-52 | TRUE | copy/onboarding-wizard.json has `"available": false` for both (C17: two matches). |
| D8 | `make app` and `build.sh --dry-run` print the plan and build nothing | :54-63 | TRUE | `build.sh --dry-run` exits 0 and says "dry run: nothing was built" (C11). The real build was not run. |
| D9 | Verified on 2026-10-11 on Apple silicon, macOS 26.6, with a universal compile | :65-67 | NOT VERIFIED HERE | Historical. Not repeated. |
| D10 | `build.sh --release` checks credentials before building and stops with exit 2 | :71-74 | TRUE | `--release` with the two variables unset exits 2, no dist folder (C11). |
| D11 | Credential variables; default bundle identifier | :76-80 | TRUE | The refusal names both variables (C11). app/macos/build.sh:59 (`xyz.sirven.app`). |
| D12 | "The release plan, visible with `--dry-run`" | :93-97 | FALSE without credentials (fixed) | `--release --dry-run` with the variables unset exits 2 and prints only the error (C11). |
| D13 | Download button disabled until the manifest loads; "not available" if it cannot load; sha256 shown | :99-110 | TRUE (by earlier pass) | site/download/download.js. Not re-read here. |
| D14 | The page says when a build is not notarized and how to open it anyway | :107-108 | NOT VERIFIED HERE | The page text was not read in this pass. |
| D15 | Preview with `python3 -m http.server` | :114-116 | NOT RUN | Not needed for the claim. |
| D16 | A test fails if the sample manifest drifts from the fields build.sh writes | :124-125 | TRUE (by test name) | Earlier pass. |
| D17 | Menu bar wiring; `Sirven --reset-onboarding` shows the wizard again | :126-131 | TRUE | app/macos/Sources/Sirven/main.swift:14 (help text) and :100 (handler). |
| D18 | Result and endpoint files in Application Support: onboarding.json and runtime.json | :134-143 | TRUE (by earlier pass) | app/macos/Sources/SirvenOnboarding/OnboardingStore.swift. |
| D19 | Bundle identifier xyz.sirven.app is a placeholder | :149 | TRUE | app/macos/build.sh:59. |
| D20 | Real permission prompts not exercised end to end | :159-161 | TRUE (status) | The Swift tests use the demo broker. |

## docs/PERMISSIONS.md

| # | Claim | Where | Verdict | Proof |
|---|---|---|---|---|
| P1 | Levels are data in `levels/*.json`; `lib/grant_compiler.py` turns a level into commands | :3-4 | TRUE | `grant_compiler.py validate` exits 0 for the three files; `compile` works (C12). |
| P2 | Three levels; the installer defaults to the smallest | :9-10 | TRUE | install.sh --help: observer (default). |
| P3 | Write rights: observer no, builder yes, operator yes | :12-15 | TRUE | `write_allowed` false, true, true (C12). |
| P4 | Friend invites: observer 7 days by default, 30 at most; builder 3 and 7; operator none | :20-21 | TRUE | `expiry.friend_invite` in the level files: observer 7/30 default observer, builder 3/7, operator not allowed (C12). |
| P5 | Every level denies root and sudo, among others | :22-27 | TRUE | `capabilities.denied` in each level file (C12). |
| P6 | Sessions and commands always logged; the agent cannot read or write the log | :40 | TRUE as a level field | `audit.every_command`, `agent_can_read_log`, `agent_can_write_log` in each level file (C7). The wrapper is not built (R18). |
| P7 | `grant_compiler.py describe` prints the subset install.sh reads | :81-83 | TRUE | Output lines match (C12). |
| P8 | `grant_compiler.py validate` refuses a broken level file | :87-88 | NOT VERIFIED HERE | Validation of the real files passes. No broken file was tried. |
| P9 | Refused paths: relative, too broad, system folders, credential folders, whole home folders, macOS privacy folders | :110-122 | TRUE (by deny lists); refusal not run | The lists in each level file (C7). |
| P10 | Compiled output is pinned by golden files | :124-128 | TRUE (by the test suite) | tests/golden is part of `make test` (see gates). |
| P11 | Linux grant commands (the snapshot helper, setfacl-equivalent) | :134-147 | TRUE for the text | `compile --with-undo` emits the `access_control_snapshot.sh` commands (C12). |
| P12 | Grant record at /etc/<package>/grants/<user>.json, owned by root | :195-209 | TRUE for the path; NOT VERIFIED HERE for the contents | The plan's grants folder is /etc/sirven/grants (C2, step 5). |
| P13 | Setup prompts: `sirven setup: press enter ...`, `1/2 access level [observer]`, `2/2 path to grant` | :223-227 | TRUE | lib/questions.sh:171 and :64 (the prompt format). |
| P14 | A re-run adopts the grant in force | :228-232 | TRUE (by tests) | Adopt tests. |
| P15 | A grant that would widen another account's access is refused before any change | :240-253 | TRUE (by tests) | The named test in the earlier pass. |
| P16 | Snapshot and undo numbers: 300,000 entries, 15 MB, 48 open folders, 30,000 levels, 30 seconds | :254-310 | TRUE for the constants (48, 30000, 30 seconds); NOT VERIFIED HERE for the timings and sizes | lib/access_control_snapshot.py:150 (`HELD = 48`), :151 (`MAX_DEPTH = 30000`), :858 (30 seconds). The 300,000-entry sizes and times need a scale run on Linux. |
| P17 | Rollback reverses the newest grant entry | :336-340 | TRUE (command); reversal NOT VERIFIED HERE | C1 (refusal on a fake root). |
| P18 | Kill switch runs the same undo and renames the grant record | :340-342 | TRUE | lib/kill_switch.sh (restore and rename steps). |
| P19 | Friend invites: designed, not built | :350-363 | TRUE | install.sh:375; no `invite` command (C6). |
| P20 | macOS entries are plan output only; a real apply needs a macOS virtual machine first | :367-378 | TRUE | lib/plan.sh:367-373. |
| P21 | Operator compiles to the same entries as builder | :402 and :484-485 | TRUE (Linux) | The Linux compiles are identical (C12). macOS entries not compared. |
| P22 | Retention is not enforced | :403-405 and :486 | TRUE | `audit_retention_days` is printed by describe only, and nothing reads it to trim (lib/grant_compiler.py:513). |
| P23 | Kill switch steps (0) to (9) | :343-357 | TRUE (by code) | lib/kill_switch.sh: marker (:43), one `usermod` lock-expire-nologin call (:336 is its unfinished-warning line; the call is the same family), service and job removal, `lib/kill_switch.py` for the keys. |
| P24 | `--user` refuses root, the owner, the sudo user, nobody, and any account below UID_MIN | :364-365 | TRUE | lib/kill_switch.sh:397-410 (`kill_switch_refuse_unsafe_user`). |
| P25 | Every root command runs the kept copy; the launcher is the safe route; the gate block is the same in install.sh, uninstall.sh, bin/sirven | :391-417 | TRUE (by tests and scenarios) | tests/unit/test_gate.sh and tests/unit/test_portability.sh check the block; scenarios 46 to 53 exist (ls). Not re-run. |
| P26 | macOS real apply is switched off until tests/macos/real-install-check.sh has passed on a real Mac | :447-461 | TRUE | lib/plan.sh:368; tests/macos/real-install-check.sh and docs/research/qa/macos-real-apply-prep.md exist (ls). |

## docs/COMPONENTS.md

| # | Claim | Where | Verdict | Proof |
|---|---|---|---|---|
| K1 | Core works with no components folder (test `test_core_works_with_no_components_folder`) | :4-6 | TRUE | The test name is in tests/unit/test_components.sh (count 1). |
| K2 | `sirven add` copies files you own; running `add` again never overwrites a file that is there | :8-10 | NOT VERIFIED HERE | The overwrite rule was not tested. |
| K3 | `sirven add --list`, `add crm --dry-run`, `remove crm --dry-run` | :12-17 | TRUE | All three exit 0 (C10). |
| K4 | Applying needs the audit log; a real macOS machine is refused unless the owner switches it on | :19-24 | TRUE | lib/components.sh:251 (refusal), :254 (audit log required). |
| K5 | Folder is `~/.config/sirven/components/NAME` | :31 | TRUE (by code) | components.sh default folder; the plan output names the folder (C10). |
| K6 | Registry: one file per component under components/ | :41-44 | TRUE | components/crm.sh exists. |
| K7 | Twenty is an open source customer relationship manager run with Docker Compose | :48-49 | TRUE for the self-host route; the "open source" part NOT VERIFIED HERE | docs.twenty.com page describes Docker Compose self-hosting (C13). |
| K8 | Quoted guidance from Twenty's guide: at least 2 gigabytes, `openssl rand -base64 32`, `openssl rand -hex 32` | :53-70 | TRUE (paraphrase matches) | The page as fetched 2026-10-15 has "at least 2GB of RAM", `openssl rand -base64 32` and `openssl rand -hex 32` in code blocks (C13). The earlier pass found no "openssl rand" because the markup splits the words; this pass searched the text with the tags removed. |
| K9 | Compose file pinned to Twenty v2.46.0; port 3000 answers on 127.0.0.1 only | :77-81 | TRUE | components/crm.sh:13 (`CRM_TWENTY_VERSION`), :64 (`127.0.0.1:3000:3000`). |
| K10 | Dotenv holds the two generated keys; values never printed or logged | :82-84 | NOT VERIFIED HERE | Needs an applied add. components/crm.sh names the keys. |
| K11 | Remove stops containers, keeps volumes and the dotenv unless `--remove-data` | :93-99 | TRUE | components/crm.sh:235 (`down --volumes` only with `--remove-data`), :242-252 (kept notes). |
| K12 | Waits up to 5 minutes for Twenty at /healthz; the first start sets up the database | :87-88 | TRUE | components/crm.sh:163-166 (loop, 5-minute message), :218 (plan text). |

## docs/SCOPE.md

| # | Claim | Where | Verdict | Proof |
|---|---|---|---|---|
| S1 | Status: draft for Jose's review, 2026-10-09 | :3 | TRUE (as a dated statement) | Added a status note (fixed). |
| S2 | Working name Sirven; known name collisions | :8-9 | NOT CHECKED | Outside claim about other products. |
| S3 | The GitHub repository is still `Joesirven/secure-agent-access`; rename pending | :11-13 | FALSE (fixed) | project.json:6 says `Joesirven/sirven`; origin is https://github.com/Joesirven/sirven.git (C20). |
| S4 | W5 kill switch: built on Linux (applies in a container and on a real machine as root) | :67 | TRUE | Section R5. |
| S5 | W6 Tailscale: "never run against a real tailnet in tests" | :68 | TRUE for a real tailnet; STALE for the container path (fixed) | The join and logout run in a Linux container (harness scenario 62, `tailscale-live-join-and-logout`, name only). |
| S6 | W7 Cloudflare Tunnel: documented second path, plan output only | :69 | TRUE | `--transport cloudflare` apply says "not yet" (test name in the earlier pass). |
| S7 | W9 phone channel: `--with-bb` installs bb | :71 | FALSE as worded (fixed) | `--with-bb` adds a plan note only (I8). |
| S8 | W13: README with diagram, `docs/DEMO.md` outline, 15-second explainer | :75 | FALSE for docs/DEMO.md (fixed) | The file is not in the repository (ls). The video folder exists. |
| S9 | Alpha cut table: Tailscale apply and teardown in a Linux container; live against a test tailnet needs a test key | :120 | TRUE | Harness scenario 62 (name only). |
| S10 | Alpha cut table: `--with-bb` flag: plan | :128 | TRUE | I8. |
| S11 | License: project.json says MIT; confirm | :158 | TRUE (project.json:7); PARKED (no LICENSE file) | project.json:7; `git ls-files` finds no license file (C19). |
| S12 | Operational note: all builds and tests run on the MacBook; the server only coordinates | :149 | NOT CHECKED | Operational, not a product claim. |

## docs/peer-routing.md

| # | Claim | Where | Verdict | Proof |
|---|---|---|---|---|
| Q1 | Attestation, site review, policy engine, reciprocity ledger work end to end; carrier built and tested on loopback | :3-9 | TRUE | `python3 -m unittest discover -s tests/peer_routing` exits 0, 32 tests OK (C14). |
| Q2 | Runtime refuses any peer route with `peer_routing_not_built` | :11-15 | TRUE | lib/sirven_runtime/seam.py:99. |
| Q3 | Ship gate `SHIP_GATE_AUTHENTICATED_PEER_TRAFFIC` stays "closed" | :16-19 | TRUE | lib/policy_engine.py:67. |
| Q4 | Jose's quoted ship gate sentence | :21-24 | NOT CHECKED | A quotation of a decision. |
| Q5 | Component table: allowlist review, identity signing, refresh, sign, carry, reciprocity, readiness | :30-38 | TRUE with a path fix (fixed) | lib/allowlist_review.py, lib/peer_routing.py, lib/reciprocity.py exist. The attestation command is lib/attestation/cli.mjs (ls). |
| Q6 | "Twenty-six end-to-end cases" | :42 | TRUE | tests/peer_routing/test_end_to_end.py has 26 `def test_` (C14); test_transport.py has 6. |
| Q7 | A fresh machine is not ready; a configured carrying machine reports `peer_routing_available: true` | :47-48 | TRUE (by code), garbled wording (fixed) | lib/peer_routing.py:259 (`components_ready and TRANSPORT_BUILT`), :64 (`TRANSPORT_BUILT = True`). The readiness run needs a state folder, so it was not run here. The module docstring contradicts this (see code findings). |
| Q8 | Carrier listens on loopback with a bearer token; `POST /v1/carry` | :52-60 | TRUE | lib/peer_transport.py:57 (`CARRIER_PATH`), :258 (127.0.0.1 bind). |
| Q9 | Version one carries GET only; other methods return `unsupported_method` | :68-69 | TRUE | lib/peer_transport.py:217. |
| Q10 | No inter-machine authentication yet; Tailscale wiring open | :64-67 | TRUE (as a status statement) | Not implemented in lib/peer_transport.py. |
| Q11 | Verify lock: file name, automatic clearing rules, the 10-second wait, `lock_unavailable` | :78-98 | TRUE | lib/attestation/verify-lock.mjs:35 (24 hours), :36 (10 seconds); lib/attestation/cli.mjs:376 (`lock_unavailable`). The 10-minute boot rule was not tested. |
| Q12 | Open items: no approved entries; three pending; signing key is a file; votes unsigned | :120-133 | TRUE for the registry counts (C21); votes unsigned NOT VERIFIED HERE | allowlist/registry.json: `approved` is empty; three entries say "pending reviewer approval". |
| Q13 | Decisions for Jose to confirm | :135-144 | NOT CHECKED | Decisions. |
| Q14 | Monthly cap of 5,000,000,000 bytes | :37, :48 | TRUE (earlier pass) | lib/reciprocity.py:44 and :50-54 (earlier pass; not re-read here). |

## docs/phone-interface.md

| # | Claim | Where | Verdict | Proof |
|---|---|---|---|---|
| H1 | Built and tested against a fake phone; not run against a real iPhone | :3-4, :238-240 | TRUE | tests/unit/test_phone.sh exists; the make test run covers it (gates). |
| H2 | Refuses to drive when more than one phone is plugged in | :11-12 | TRUE (by test names) | Earlier pass. |
| H3 | Uses only the Python standard library | :14 | TRUE | lib/phone_bridge.py:8. |
| H4 | Detection never prints the serial number or the pairing record | :28-31 | TRUE (by test names) | Earlier pass. |
| H5 | No analytics; sends nothing anywhere | :36-37 | TRUE, WITH A QUALIFICATION | lib/phone_bridge.py:8 says so. The only web address in the module is the WebDriverAgent repository constant (:69). |
| H6 | `sirven phone setup` prints the plan and never runs it | :41-42 | TRUE | `sirven phone --help`: "it only prints; the owner runs it" (C6). |
| H7 | Consent commands: `allow [--minutes N] [--allow-submit]`, `stop`, `holds`, `approve`, `deny`, `log` | :56-65 | TRUE | `sirven phone --help` (C6). |
| H8 | Sessions default to 30 minutes and at most 240 | :60 | TRUE | lib/phone_bridge.py:64-65. |
| H9 | Session and hold files in ~/.sirven/phone, mode 0700 | :67-68 | TRUE | lib/phone_bridge.py:135-136. |
| H10 | With no open session every action is refused before anything reaches the phone | :76-78 | TRUE (by test names) | Earlier pass. |
| H11 | Typing into a secure field is refused; a locked phone is reported, not unlocked | :82-84 | TRUE | lib/phone_bridge.py:654 (secure field, 403), :557 (phone locked, 409). |
| H12 | Money-like taps are held; a price inside a request button is held; swipes are not gated | :88-98 | TRUE | lib/phone_bridge.py:74 (the money words), :612 (labels under the tap point). |
| H13 | The phone's own payment approval makes the bridge refuse every action | :105-113 | TRUE | lib/phone_bridge.py:415 (`owner_approving_on_phone`). |
| H14 | Onboarding builds a semantic map at ~/.sirven/phone/map.json and keeps no private content | :115-133 | TRUE (by test names) | Earlier pass. |
| H15 | Local interface on loopback, bearer token; port 47817; token file mode 0600 | :143-149 | TRUE | lib/phone_bridge.py:63 (`DEFAULT_PORT = 47817`), :146 (token written with mode 0600). |
| H16 | Result codes in the table | :162-178 | TRUE for the codes shown; one code is missing (see code findings) | lib/phone_bridge.py: `unauthorized` (:796, 401), `bad_request` (:500, 400), `not_found` (:516, 404), `not_approved` (:527, 403), `phone_locked` (:557, 409), `screen_unreadable` (:597, 409), `webdriveragent_error` (:312, 502), `webdriveragent_not_running` (:306, 503). |
| H17 | Log at ~/.sirven/phone/actions.jsonl, mode 0600 | :184-188 | TRUE | lib/phone_bridge.py:479 (mode 0600). |
| H18 | "docs/runtime-interface.md was not in the repository when this was written" | :200-206 | STALE (fixed) | docs/runtime-interface.md exists (ls). |
| H19 | Ride backend at connectors/ride/ride_phone | :208-217 | TRUE | ls (C17). |
| H20 | `sirven phone detect` honestly reports that no iPhone is plugged in | :223-226 | TRUE | Exit 1, "no iPhone is plugged in over USB" (C6). |
| H21 | Not yet verified against a real iPhone | :238-240 | TRUE (as a status) | |
| H22 | Credits: iPhone-use (MIT), WebDriverAgent (BSD) | :242-247 | TRUE | gh api (C16). |

## install.sh --help

| # | Claim | Verdict | Proof |
|---|---|---|---|
| I1 | Asks at most two questions, each with its default shown | TRUE | Help text; lib/questions.sh. |
| I2 | Adopts a Tailscale login, a bb install, and an earlier grant, policy, and audit log | TRUE | Help text; adopt tests. |
| I3 | `--prefix` records commands that need root instead of running them | TRUE | `--dry-run --prefix ... --yes` exits 0; plan says "recorded not run under --prefix" (C2). |
| I4 | `--transport` accepts tailscale (default), cloudflare, or none | TRUE | Plan shows `transport: tailscale` (C2); `--transport none --dry-run` exits 0 (C4). The cloudflare apply says "not yet" (earlier pass). |
| I5 | `--owner` defaults to you | TRUE | Plan shows the owner (C2). |
| I6 | `--yes` asks nothing and uses the defaults (observer, no path) | TRUE | C2 ("using defaults (--yes): level observer, paths none"). |
| I7 | A real machine is changed only when run as root, with a typed yes | TRUE | lib/plan.sh:460-474. |
| I8 | `--with-bb` adds a plan note only, for now | TRUE | Help text; the plan shows the note. |
| I9 | Examples: `./install.sh --dry-run`, `sudo /usr/local/sbin/sirven revoke --all --dry-run` | TRUE | `revoke --all --dry-run --prefix` exits 0 (C4). The plain `--dry-run` example is subject to R6. |

## uninstall.sh --help

| # | Claim | Verdict | Proof |
|---|---|---|---|
| U1 | `--dry-run` prints the removal plan and changes nothing | TRUE | `uninstall.sh --dry-run --prefix` exits 0 (C4). |
| U2 | Only steps recorded in the install record are reversed; the service user's home folder is kept | TRUE (by code and help) | No install record on this Mac: "nothing it may remove" (C4). |
| U3 | `--remove-audit-log` removes the audit log; kept by default | TRUE (by help) | Option exists in the help text. |

## bin/sirven --help

| # | Claim | Verdict | Proof |
|---|---|---|---|
| G1 | `grant inspect`, `grant rollback`, `grant repair` | TRUE | `inspect` exits 0, `rollback --dry-run` exits 1 with no install (C1). `repair` not run. |
| G2 | `sirven runtime serve\|status\|fetch\|classify\|decisions\|exec` | TRUE | `sirven runtime --help` exits 0 (C6). |
| G3 | `sirven awake [command]` keeps the Mac awake | NOT VERIFIED HERE (needs `make keep-awake`) | Exits with "not built yet" here (C5). |
| G4 | `sirven phone COMMAND` | TRUE | Help exits 0 (C6). |
| G5 | `sirven add --list`, `add NAME`, `remove NAME` | TRUE | Exit 0 for list, add dry run, and remove dry run (C10). |
| G6 | `--prefix` reads a fake root that install.sh was applied to | TRUE | `grant inspect --prefix` exits 0 (C1). |
| G7 | Rollback reverses the newest grant entry and refuses when the record does not match | TRUE | Refusal path (C1). |

## Gates

Run on the tree before the fixes (baseline, 1cc13bb) and again after them (this branch):

- `make lint`: exit 0 both times. 73 files pass `bash -n`; shellcheck passed.
- `make test`: exit 0 both times. 562 `ok` lines and 0 `not ok` lines both times. The language suite (tests/unit/test_language.sh) is part of that run. Its list covers README.md, docs/DOWNLOAD-AND-ONBOARDING.md, and docs/phone-interface.md among the edited files. docs/WALKTHROUGH.md, docs/BOOTSTRAP.md, docs/SCOPE.md, docs/peer-routing.md, and this status file are outside that list, so they were scanned by hand for the banned terms and for em-dashes: no hits, no em-dashes.
- Not run in this pass: `bash tests/harness/run-linux.sh`. This branch changes no shell product code and no harness file, so the parent's rule does not require it. The Linux revoke, Tailscale join, and launcher claims above rest on the named harness scenarios existing (C17), not on a harness run here.
- Not run: `make app-test` (macOS Swift tests), `make test-keep-awake`, and any real apply, Tailscale join, or macOS install check.

## Commands run, with exit status

Commands ran from the worktree on branch docs-truth-pass-2026-10-15 unless noted. Scratch files went to /tmp/sirven-docs-check. Downloaded files were only read, hashed, or grepped, never run. No install, uninstall, or bin/sirven command ran as root or for real; every root-capable command ran with `--dry-run`, `--prefix`, or both.

| Code | Command | Exit | Note |
|---|---|---|---|
| C1 | `bin/sirven grant inspect --prefix P`; `bin/sirven grant rollback --dry-run --prefix P` | 0; 1 | Fake root with no install: "no audit log ... no grant change to roll back" |
| C2 | `bash install.sh --dry-run --prefix P --yes` | 0 | 22 steps; 17 to do, 4 by the owner, 1 plan only |
| C3 | `bash install.sh --dry-run` (plain) | 2 | Refused: Tailscale login without tag:agent; the message names the two ways out |
| C4 | `bash install.sh revoke --all --dry-run --prefix P`; `bash install.sh revoke --all --dry-run`; `bash install.sh --dry-run --transport none`; `bash install.sh --dry-run --level builder --path /srv/app --prefix P`; `SIRVEN_LEVEL=builder SIRVEN_PATH=/srv/app bash install.sh --yes --dry-run --prefix P`; `bash uninstall.sh --dry-run --prefix P`; `bash uninstall.sh --dry-run` | 0 each | Plain revoke dry run prints "applying would be refused on this machine" for macOS |
| C5 | `bin/sirven awake --help`; `make -n keep-awake` | 1 (earlier pass, "not built yet"); 0 | |
| C6 | `bin/sirven phone --help`; `bin/sirven phone detect`; `bin/sirven runtime --help` | 0; 1 ("no iPhone is plugged in over USB"); 0 | |
| C7 | Level files read with python3 -I (fields listed in the claims) | 0 | levels/observer.json, builder.json, operator.json |
| C8 | `curl -fsSL` of the v0.2.0 release asset to a fresh folder; `shasum -a 256` | 0; checksum 7750941c45a627f353362dda0a7f54e5b589cdf4e5b0f6bef78ba5e00beeb6ad | Matches the pin in bootstrap/sirven-bootstrap.sh:25 |
| C9 | `curl -fsSL https://cli.sirven.xyz` to a scratch file; grep; `cmp` against bootstrap/sirven-bootstrap.sh | 0; 0; 0 | Served copy equals the repository copy, pin v0.2.0 |
| C10 | `bin/sirven add --list`; `bin/sirven add crm --dry-run`; `bin/sirven remove crm --dry-run` | 0 each | |
| C11 | `bash app/macos/build.sh --dry-run`; `env -u SIRVEN_SIGNING_IDENTITY -u SIRVEN_NOTARY_PROFILE bash app/macos/build.sh --release --dry-run`; same without `--dry-run` | 0; 2; 2 | No dist folder created by the refused run |
| C12 | `python3 -I lib/grant_compiler.py validate levels/*.json`; `describe --level levels/builder.json`; `compile --level ... --with-undo` for builder and operator, then `diff` | 0; 0; 0 each; diff identical | |
| C13 | `curl -fsSL` of the Twenty guide page; text search with tags stripped | 0 | "openssl rand -base64 32", "openssl rand -hex 32", "at least 2GB of RAM" present |
| C14 | `python3 -m unittest discover -s tests/peer_routing -v` | 0 | Ran 32 tests, OK |
| C15 | `npm view @joesirven/sirven version` | 0 | 0.1.0 |
| C16 | `gh api repos/zhongerxin/iPhone-use --jq .license.spdx_id`; `gh api repos/appium/WebDriverAgent --jq .license.spdx_id`; `gh api repos/appium/WebDriverAgent/contents/LICENSE`; `curl -sS -o /dev/null https://github.com/itskoosh/Sleepless` | 0 each; 404 for Sleepless | MIT; NOASSERTION (detector); LICENSE text is BSD |
| C17 | `ls` of every path the claims name | 0 | All present except docs/DEMO.md |
| C18 | `curl -sS` of https://sirven.xyz/download/ and /download/release.json | 0; 200 and 200 text/html | The manifest path returns HTML |
| C19 | `git ls-files \| grep -i '^license'` | 1 (no match) | No tracked license file |
| C20 | `git remote -v`; project.json repository | 0 | origin is Joesirven/sirven |
| C21 | Registry counts in allowlist/registry.json | 0 | approved 0; pending 3 |
| C22 | `bash install.sh --help`; `bash uninstall.sh --help`; `bin/sirven --help` | 0, 0, 0 | |
| C23 | `make lint` | see gates | |
| C24 | `make test` | see gates | |
| C25 | `gh release view v0.2.0 --repo Joesirven/sirven --json ...` | 0 | Not a draft; one asset; published 2026-10-15T01:38:57Z; targets main |
| C26 | `git fetch origin` | 0 | origin/main is 1cc13bb |
| C27 | `bb tasks show SIR-40` | 0 | Task is in_review |
