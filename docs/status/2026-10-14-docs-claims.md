# Docs claims audit, 2026-10-14

Checked against origin/main at commit 713659b (Pin the bootstrap to release v0.1.0), on the branch v0.2-docs-truth cut from origin/main. This note changes no document. The README and the walkthrough are rewritten in a later step, after the v0.2.0 facts arrive.

Part of the v0.2.0 item "it really installs" (bb task SIR-40, W13: Docs, demo, video).

## How to read the verdicts

- **TRUE**: the proof on origin/main shows the claim.
- **TRUE, WITH A QUALIFICATION**: true, but a condition the document leaves out changes the reading.
- **FALSE**: the proof contradicts the claim.
- **NOT VERIFIED HERE**: needs a macOS build, a real phone, an applied install, a real release, or an outside service that this check did not run. The reason is given.

Terms used below: npm is the Node package manager. gh is the GitHub command line tool. bb is the agent workspace product this repository is managed from.

Proof codes (C1 to C58) point to the command list at the end, with exit status. Each row cites the file and line. The audit covers the factual claims: behavior, status, versions, links, credits, and the commands a reader is told to run. Pure design intent is checked only as far as the code shows it is absent.

## Findings to fix in the rewrite (not changed here)

1. **`sudo bash install.sh revoke --all` "revokes every grant"** (README.md:26, docs/WALKTHROUGH.md:73-76). FALSE in this alpha. The revoke plan is plan-only (lib/kill_switch.sh, C44), and an applied run is refused with exit status 3 (install.sh:302, C45). The dry run lists 6 plan-only steps (C16).
2. **The pinned tag example is stale** (docs/BOOTSTRAP.md:31 shows `SIRVEN_PINNED_TAG="v0.2.0"`). The pin on origin/main and on the served script at cli.sirven.xyz is v0.1.0 (bootstrap/sirven-bootstrap.sh:24, C8, C10). The v0.1.0 release asset exists and its checksum matches the pin (C12, C13).
3. **`--dry-run` "changes nothing and shows the plan"** (README.md:27, :35, :40-42; docs/WALKTHROUGH.md:51). On this Mac the plain dry run exits with status 2 and prints no plan. It refuses because this Mac is logged in to Tailscale without `tag:agent` (C14, C17). The prefix form prints the full plan (C15). The documents do not mention this refusal.
4. **Download page "from the sirven website"** (docs/DOWNLOAD-AND-ONBOARDING.md:3-5). Not live as far as this check shows. The page's manifest path returns an unrelated web page (C40), and the manifest in the repository is sample data (`notarized: false`, zero checksum; site/download/release.json).
5. **`--release --dry-run` "shows the release plan"** (docs/DOWNLOAD-AND-ONBOARDING.md:93-97). Without the two signing credentials it exits with status 2 and shows only the error (C26, C27).
6. **Sleepless credit link** (README.md:154, :66). The link returns HTTP 404 (C30). The MIT license claim cannot be verified.
7. **Missing license file** (package.json:33 says `"license": "MIT"`). No license file is tracked in git (C42).
8. **Stale file path** (docs/peer-routing.md:33, :35 name `cli.mjs`). The file is at lib/attestation/cli.mjs (C46).
9. **Stale statement** (docs/phone-interface.md:202-206 says docs/runtime-interface.md "was not in the repository when this was written"). The file exists now (C46).
10. **Twenty guide quote** (docs/COMPONENTS.md:53-70, "read on 2026-10-11"). The phrase "openssl rand" does not appear in the guide page as fetched on 2026-10-14 (C41). Either the page changed or the quote needs a re-read by the maintainer.
11. **Initialism in the package description** (package.json:4 uses the initialism for artificial intelligence). The language rule bans it. Spell it out in the rewrite.
12. **Ambiguous `--with-bb` wording** (docs/WALKTHROUGH.md:14 says it "has nothing left to install"). The help text says it adds a bb install note to the plan and is "plan only for now" (C6).
13. **Gate**: `make test` exits 2 on this Mac (458 passed, 3 failed). The failures are macOS-specific test assumptions, not documentation claims. The same suite passes on Linux (461 passed). See the Gates section.
14. **Stale test count** (docs/peer-routing.md:42 says "Twenty cases"). The end-to-end suite has 26 tests (C54).

## README.md

| # | Claim | Where | Verdict | Proof |
|---|---|---|---|---|
| R1 | The agent runs as a local user you own; no hosted middleman | :7 | TRUE | The service user `agent` appears in the plan (C15). The user is created only by an applied install (lib/plan.sh:317-328). |
| R2 | Three levels; operator is builder today; none gets root or sudo | :24 | TRUE | levels/*.json deny lists contain root and sudo (C43). operator write_allowed true, observer false (C43). |
| R3 | Nothing granted by default; system folders, home folder, and credential folders refused | :25 | TRUE, WITH A QUALIFICATION | default_grants empty and deny lists in levels/*.json (PERMISSIONS.md:37-38). The refusal of a specific path was not run. |
| R4 | `sirven grant inspect` shows what is in force; `grant rollback` reverses the last change | :26 | TRUE | Both commands exist (C21, C22). On a fresh fake root rollback exits 1 with "no audit log ... no grant change to roll back" (expected before any install). |
| R5 | `sudo bash install.sh revoke --all` revokes everything | :26 | FALSE | Plan-only in the alpha (C16, C44, C45). |
| R6 | Installer prints its full plan first; `--dry-run` changes nothing | :27 | TRUE, WITH A QUALIFICATION | Prefix dry run prints the plan, exit 0 (C15). On this Mac the plain dry run refuses, exit 2 (C14). |
| R7 | Adopts what it finds (Tailscale, bb, an earlier run) and does not replace it | :28 | TRUE | Install help (C6). The adopt tests pass (C35: `adopt-linux-builder-tailscale-bb`). |
| R8 | Quick start: `bash install.sh --dry-run` "read the plan first" | :35 | TRUE, WITH A QUALIFICATION | Same as R6 (C14, C15). |
| R9 | `sudo bash install.sh` asks two questions: level and folder | :36 | TRUE | Install help (C6). The prompt text matches the captured output of the prompt tests (C36). |
| R10 | `bash bin/sirven grant inspect` | :37 | TRUE | Exit 0 with a fake root (C21). |
| R11 | Applies only inside a Linux container run as root; refuses on any other machine before changing anything | :40-41 | TRUE | Refusal logic (lib/plan.sh:317-328, install.sh:301-302). Refusal tests pass (C35: `test_real_apply_on_macos_is_refused`, `test_real_apply_is_refused_outside_a_container`). |
| R12 | "`--dry-run` still shows the full plan" on any machine | :41-42 | TRUE, WITH A QUALIFICATION | Full plan with a fake root (C15). On this Mac, refused (C14). |
| R13 | `npm install -g @joesirven/sirven` puts `sirven` on your path | :42 | TRUE (as packaged) | The 0.1.0 tarball contains bin/sirven, install.sh, package.json (C33). The package.json `bin` field maps sirven to bin/sirven. A global install was not run. |
| R14 | Applying to a regular Linux or macOS machine is not verified; the installer stops before any change | :48 | TRUE | lib/plan.sh:321-322. |
| R15 | The audit log covers the install and every grant change | :48 | NOT VERIFIED HERE | Needs an applied install. The audit code exists (lib/audit.sh). |
| R16 | Per-session and per-command logging comes through a forced-command wrapper: designed, not built | :48 | TRUE | lib/audit.sh:79 and bin/sirven:17, :55 say "designed, built after alpha". |
| R17 | Kernel-level auditing and operator's service restarts and log reads: designed, not built | :48 | TRUE | levels/*.json `audit.file_changes` false and operator `owner_listed` (PERMISSIONS.md:17-18, :75). |
| R18 | Lets your agent drive your plugged-in iPhone, opt in per session | :55-56 | TRUE, WITH A QUALIFICATION | Built and tested against a fake phone (C35, phone tests). Not run on a real phone (phone-interface.md:3-4, :238). `sirven phone detect` reports no phone here (C20). |
| R19 | `sirven add crm` sets up Twenty; sirven never needs it | :57-58 | TRUE | `add --list` shows crm as optional (C18). The add plan prints (C23). Apply not run. |
| R20 | Peer routing is not yet available; what still stands before it ships | :59-60 | TRUE | Runtime refusal `peer_routing_not_built` (lib/sirven_runtime/seam.py:99). Gate constant `closed` (lib/policy_engine.py:67). |
| R21 | `sirven awake` keeps the Mac awake while work is in flight, and only then; holds a macOS power assertion; lid-closed is separate and off by default | :64-80 | NOT VERIFIED HERE | Needs the macOS build. `sirven awake` says "not built yet" (C19, C29). The watcher's tests pass (C35). |
| R22 | The command list under "Commands" | :84-93 | NOT VERIFIED HERE | Subcommands are listed only after the build. |
| R23 | Sample output of `sirven awake status` | :97-106 | NOT VERIFIED HERE | Illustration. Needs a built binary. |
| R24 | Lid-closed helper approval flow (SMAppService, System Settings path) | :120-134 | NOT VERIFIED HERE | macOS-only, signed app. The document itself says so (:133-134). |
| R25 | The setting used is `pmset disablesleep`; Apple's manual does not document it | :147-150 | NOT VERIFIED HERE | macOS-only. |
| R26 | Keep-awake is inspired by Sleepless by itskoosh (MIT), with a link | :154 | FALSE (broken link) | github.com/itskoosh/Sleepless returns HTTP 404 (C30). The MIT claim is not verified. |
| R27 | iPhone integration follows iPhone-use by ZHONG XIN (MIT) | :159-162 | TRUE (license) | Repository license is MIT (C31). The author name was not checked. |
| R28 | WebDriverAgent is from the Appium project, under the BSD license; you fetch and sign it yourself; sirven does not bundle it | :163-165 | TRUE | BSD License text (C32). No WebDriverAgent file is tracked in git (C50). |
| R29 | `make keep-awake` builds the program; developer details in macos/keep-awake/README.md | :110-112 | TRUE | Target exists (C24). The file exists (`ls`, C46). |
| R30 | Link to docs/WALKTHROUGH.md and the other docs | :44, :52-60 | TRUE | All linked files exist (C46). |

## docs/WALKTHROUGH.md

| # | Claim | Where | Verdict | Proof |
|---|---|---|---|---|
| W1 | Already-running agents: sirven connects the missing pieces and does not replace yours | :9-11 | TRUE | Adopt behavior (C6, C35). |
| W2 | Tailscale: tags read from `tailscale status --json`; a tagged machine is adopted; never logs in or re-keys | :13 | TRUE (by code and tests) | Adopt tests pass (C35). The status command was not read. |
| W3 | bb: found on the path is kept; `--with-bb` "has nothing left to install" | :14 | UNCLEAR | Help says `--with-bb` "add[s] the bb install note to the plan (plan only for now)" (C6). The wording must match. |
| W4 | Earlier run: grant, policy copy, audit log, and install record are kept | :15 | TRUE (by tests) | Adopt tests (C35). |
| W5 | Conflicts stop the run before any change, and say what to do | :17-22 | TRUE | The Tailscale conflict text matches line :19 (C14). |
| W6 | A plain re-run keeps the earlier level and path; a different one is a grant change | :24 | TRUE (by tests) | Adopt tests (C35). |
| W7 | Mac without developer tools: stop and ask for `xcode-select --install` | :36 | TRUE (by code) | Placeholder detection (lib/preflight.sh:71-75). Not run here (developer tools present). |
| W8 | Applying an install to a Mac is not verified; a real run stops before any change | :36 | TRUE | lib/plan.sh:322. |
| W9 | The one-line command installs a pinned release, checked against its checksum | :38 | TRUE | Served script equals the repository copy (C10). Release asset checksum matches the pin (C13). Checksum tests pass (C35). The served command itself was not run, because it installs. |
| W10 | Two questions, each with a default; `--yes` asks nothing (observer, no path); `--dry-run` changes nothing | :46-51 | TRUE | Install help (C6). Prefix dry run with `--yes` (C15). |
| W11 | Confirming applies the plan: creates the service user, sets the level, writes an audit record, changes nothing else | :53-55 | NOT VERIFIED HERE | Needs an applied install, which refuses on this Mac (C14, C27 pattern). |
| W12 | Per-session logging through the forced-command wrapper: designed, not built | :59 | TRUE | lib/audit.sh:79. |
| W13 | `sirven grant inspect` and `sirven grant rollback --dry-run` | :63-68 | TRUE (commands exist) | C21 (exit 0), C22 (exit 1 with no install). The page does not say rollback needs a prior install. |
| W14 | `sudo bash install.sh revoke --all`: "Revokes every grant in one shot" | :73-76 | FALSE | Same as R5 (C16, C44, C45). |
| W15 | Today the audit log covers the install record and grant changes | :80 | NOT VERIFIED HERE | Needs an applied install. |
| W16 | macOS protects Desktop, Documents, Downloads; grant paths outside them | :81 | TRUE | levels/observer.json:90-94 (`macos_privacy_folders`). |
| W17 | Tests prove plans, not effects; real user creation verified only in throwaway environments | :82 | NOT VERIFIED HERE | Unit tests pass (C35). The throwaway environment runs were not reproduced. |
| W18 | Friend invite ships last | :83 | TRUE (as a plan statement) | install.sh:173 "revoking one invite is designed, not built". |

## docs/BOOTSTRAP.md

| # | Claim | Where | Verdict | Proof |
|---|---|---|---|---|
| B1 | `curl -fsSL https://cli.sirven.xyz \| bash` runs a script that installs one pinned release | :3-4 | TRUE | Served script fetched (C10, C47). It matches the repository copy byte for byte (C10 `cmp`). |
| B2 | Downloads the release archive over https with timeouts; checks checksum before unpacking or running | :10-14 | TRUE (by tests) | Checksum-order and download tests pass (C35: `test_the_checksum_is_checked_before_the_archive_is_unpacked`, `test_mismatched_checksum_runs_nothing`). The https-only and timeout code was not read. |
| B3 | A mismatch, a failed download, or a cut-off download runs nothing; a script with no pin refuses | :16-19, :17 | TRUE (by tests) | `test_a_failed_download_runs_nothing`, `test_unpinned_bootstrap_downloads_and_runs_nothing`, `test_a_download_cut_off_in_its_last_line_runs_nothing` (C35). |
| B4 | The pin is two lines near the top of bootstrap/sirven-bootstrap.sh | :26-33 | TRUE (structure) | Lines 24-25 (C8). |
| B5 | The example pin `SIRVEN_PINNED_TAG="v0.2.0"` | :31 | FALSE for origin/main | The pin is `v0.1.0` (bootstrap/sirven-bootstrap.sh:24; served copy line 24) (C8, C10). |
| B6 | The served script carries its own pin; only bootstrap/release.sh writes the two lines | :35-36 | TRUE | The served copy has the pin (C10). The writer is bootstrap/release.sh:87 (C48). |
| B7 | The archive is built with git archive from the tag's commit | :38-40 | TRUE | bootstrap/release.sh:6, :31 (C48). |
| B8 | Maintainer release steps (tag v0.2.0, release.sh v0.2.0, gh release create) | :47-68 | NOT RUN | These would publish. The current published release is v0.1.0 (C12). |
| B9 | The served script equals the repository copy; `curl … \| cmp` check | :73-79 | TRUE | C10. The `bash -s -- --dry-run` line was not run, because it executes the served script. |
| B10 | Until the deploy step is done, cli.sirven.xyz serves what was deployed last | :82-84 | TRUE (as a process note) | Consistent with C10. |
| B11 | Keeps a copy under /var/lib/sirven/package with install.sh, uninstall.sh, bin, lib, levels, components, project.json | :88-91 | TRUE | Plan step 5 lists the same files (C15). |
| B12 | Uninstall with `sudo bash /var/lib/sirven/package/uninstall.sh`, no download | :98-102 | NOT VERIFIED HERE | Needs an installed copy. |
| B13 | Revoke from the copy is not available; `install.sh revoke --all` prints its plan and exits 3 when applied | :104-106 | TRUE (by code) | install.sh:302 (`DIE_STATUS=3`). The dry run exits 0 (C16). The applied exit was not run. |
| B14 | A Mac does not apply an install, so no copy is made on a Mac | :108-109 | TRUE | lib/plan.sh:321-322. |

## docs/PERMISSIONS.md

| # | Claim | Where | Verdict | Proof |
|---|---|---|---|---|
| P1 | Levels are data in levels/*.json; lib/grant_compiler.py turns a level into access control commands | :3-4 | TRUE | Files exist (C46). |
| P2 | Three levels; the installer defaults to the smallest | :9-10 | TRUE | Install help: observer is the default (C6). |
| P3 | Write rights: observer no, builder yes, operator yes | :12-15 | TRUE | `write_allowed` in levels/*.json (C43). |
| P4 | Friend invites: observer 7 days default, 30 at most; builder 3 and 7; operator none | :21 | TRUE | `default_days` and `maximum_days` in levels/*.json (C43). Operator is 0 and 0. |
| P5 | Every level denies root and sudo, among other things | :22-27 | TRUE for root and sudo | levels/*.json (C43). The other denied items were not each checked. |
| P6 | Sessions and commands are always logged; the agent cannot read or write the log | :40 | TRUE as a level field | The wrapper that writes the entries is not built (R16). |
| P7 | `grant_compiler.py describe` prints the subset install.sh reads | :81-83 | TRUE | C43 (exit 0). |
| P8 | `grant_compiler.py validate` refuses a broken level file | :87-88 | NOT VERIFIED HERE | Validation of the three real files passes (C43). No broken file was tried. |
| P9 | Refused paths: relative, too broad, system folders, credential folders, whole home folders, macOS privacy folders | :110-122 | NOT VERIFIED HERE (refusals) | The deny lists exist in levels/*.json. No refusal was run. |
| P10 | Compiled output is pinned by golden files in tests/golden | :124-128 | TRUE | Golden compile tests pass (C35: `compile-linux-*`, `compile-macos-*`). |
| P11 | Linux and macOS grant commands as written (setfacl and chmod +a examples) | :134-185 | TRUE for the text | Golden tests pass (C35). The effects on a real system were not checked. |
| P12 | Grant record at /etc/<package>/grants/<user>.json, owned by root | :195-209 | NOT VERIFIED HERE | Needs an applied install. The plan's grants folder is /etc/sirven/grants (C15). |
| P13 | Setup example prompts (`sirven setup: press enter ...`, `1/2 access level [observer]`, `2/2 path to grant`) | :223-227 | TRUE, WITH A QUALIFICATION | Prompt text matches the captured output (C36). The default folder is the current folder only when the policy accepts it. A temporary folder gets `none` (C36). |
| P14 | A re-run adopts the grant in force | :228-232 | TRUE (by tests) | Adopt tests (C35). |
| P15 | A grant that would widen another account's access is refused before any change | :240-253 | TRUE (by tests) | `test_only_an_entry_the_mask_switches_off_is_refused` (C35). |
| P16 | Snapshot and undo details, including the numbers (300,000 entries, 15 megabytes, 48 open folders, 30,000 levels) | :254-310 | NOT VERIFIED HERE | Needs a Linux apply. The named tests pass (C35). The numbers were not measured again. |
| P17 | Rollback reverses the newest grant entry | :336-340 | TRUE (command) / NOT VERIFIED HERE (reversal) | C22. The reversal needs an applied install. |
| P18 | Kill switch runs the same undo and renames the grant record, in plan output | :341-342 | TRUE | C16 (plan). |
| P19 | Friend invites: designed, not built | :350-363 | TRUE | install.sh:173 (C6 help: "revoking one invite is designed, not built"). |
| P20 | macOS entries are plan output only; apply needs a macOS virtual machine first | :367-378 | TRUE | lib/plan.sh:322. |
| P21 | Operator compiles to the same entries as builder | :402 | NOT VERIFIED HERE | The golden files were not compared. |
| P22 | Retention is not enforced; reinstalling with new paths does not remove the old entries | :403-405 | NOT VERIFIED HERE | Not tested. |

## docs/COMPONENTS.md

| # | Claim | Where | Verdict | Proof |
|---|---|---|---|---|
| K1 | Core works with no components folder (test `test_core_works_with_no_components_folder`) | :4-6 | TRUE | Test passes (C35). |
| K2 | `sirven add` copies files you own; running `add` again never overwrites a file that is there | :8-10 | NOT VERIFIED HERE | The overwrite rule was not tested. |
| K3 | `sirven add --list`, `add crm --dry-run`, `remove crm --dry-run` | :12-17 | TRUE for list and add dry run; NOT RUN for remove | C18, C23. |
| K4 | Adding applies with `--prefix` or in a throwaway Linux container; needs the audit log | :19-24 | TRUE (by code) | components.sh:245 uses the same refusal as install.sh (lib/plan.sh:317). |
| K5 | Folder is `~/.config/sirven/components/NAME` | :31 | TRUE | C23 output names that folder for crm. |
| K6 | Registry: one file per component under components/ | :41-44 | TRUE | components/crm.sh exists (C46). |
| K7 | Twenty is an open source customer relationship manager run with Docker Compose | :48-49 | NOT VERIFIED HERE | External claim. Not checked. |
| K8 | Quoted guidance from Twenty's own guide (read 2026-10-11) | :53-70 | NOT VERIFIED HERE | The phrase "openssl rand" is absent from the page fetched 2026-10-14 (C41). See finding 10. |
| K9 | Compose file pinned to Twenty v2.46.0; port 3000 answers on 127.0.0.1 only | :77-81 | TRUE | components/crm.sh:13, :64 (`127.0.0.1:3000:3000`), :200. |
| K10 | Dotenv holds the two generated keys; values never printed or logged | :82-84 | NOT VERIFIED HERE | Needs an applied add. The keys are named in components/crm.sh:54-55, :67. |
| K11 | Remove stops containers, keeps volumes and the dotenv unless `--remove-data` | :93-99 | NOT VERIFIED HERE | Remove was not run. |

## docs/phone-interface.md

| # | Claim | Where | Verdict | Proof |
|---|---|---|---|---|
| H1 | Built and tested against a fake phone; not run against a real iPhone | :3-4, :238 | TRUE | Phone tests pass (C35). |
| H2 | Refuses to drive when more than one phone is plugged in | :11-12 | TRUE | `test_detect_is_honest_about_no_phone_an_untrusted_phone_and_several` (C35). |
| H3 | lib/phone_bridge.py uses only the Python standard library | :14 | TRUE | Imports at lib/phone_bridge.py:44-55 are standard library modules (C48). |
| H4 | Detection reads the pairing record without printing, storing, or logging it; the serial number never appears | :28-31 | TRUE (by tests) | `test_detect_never_prints_the_serial_or_the_pair_record` (C35). |
| H5 | No analytics; sends nothing anywhere | :36-37 | TRUE, WITH A QUALIFICATION | No analytics code found by search (C48). The only web address in the module is the WebDriverAgent repository constant (lib/phone_bridge.py:69). The full network path was not traced. |
| H6 | `sirven phone setup` prints the plan and never runs it | :41-42 | TRUE | Help: "it only prints; the owner runs it" (C28). |
| H7 | Consent commands: `allow [--minutes N] [--allow-submit]`, `stop`, `holds`, `approve`, `deny`, `log` | :56-65 | TRUE | Help (C28). |
| H8 | Sessions default to 30 minutes and at most 240 | :60 | TRUE | lib/phone_bridge.py:64 (`DEFAULT_MINUTES = 30`), :65 (`LONGEST_SESSION_MINUTES = 240`). |
| H9 | Session and hold files in ~/.sirven/phone, mode 0700 | :67-68 | TRUE | Default folder (lib/phone_bridge.py:33), mode 0700 (:135-136). |
| H10 | With no open session every action is refused before anything reaches the phone | :76-78 | TRUE (by tests) | `test_an_expired_session_is_no_session`, `test_allow_needs_the_owner_at_a_terminal` (C35). |
| H11 | Typing into a secure field is refused; a locked phone is reported, not unlocked | :82-84 | TRUE (by tests) | `test_a_locked_phone_is_reported_not_unlocked` (C35). The secure-field refusal was not matched to a test name. |
| H12 | Money-like taps are held; a price inside a request button is held; swipes are not gated | :88-98 | TRUE (by tests) | `test_a_money_bearing_tap_waits_for_the_owner_then_works_once`, `test_a_tap_on_a_price_inside_a_request_button_is_held` (C35). |
| H13 | The phone's own payment approval makes the bridge refuse every action | :105-113 | TRUE (by code) | lib/phone_bridge.py:415, :582. |
| H14 | Onboarding builds a semantic map at ~/.sirven/phone/map.json and keeps no private content | :115-133 | TRUE (by tests) | `test_onboarding_maps_the_ride_apps_and_keeps_nothing_private` (C35). |
| H15 | Local interface at /v1/phone on loopback, bearer token | :143-149 | TRUE, WITH A QUALIFICATION | Route prefix at lib/phone_bridge.py:807-809. The port 47817 and the token file were not checked. |
| H16 | Result codes such as `owner_approving_on_phone` | :162-178 | TRUE for the codes checked | lib/phone_bridge.py:415. Other codes not each checked. |
| H17 | Log at ~/.sirven/phone/actions.jsonl | :184-188 | TRUE (path) | lib/phone_bridge.py:36, :478. The file mode was not checked. |
| H18 | docs/runtime-interface.md "was not in the repository when this was written" | :200-206 | STALE | The file exists on origin/main (C46). |
| H19 | Ride backend lives at connectors/ride/ride_phone | :208-217 | TRUE | Path exists (C46). Test `test_phone_ride` passes (C35). |
| H20 | `sirven phone detect` honestly reports that no iPhone is plugged in | :223-226 | TRUE | C20 output: "no iPhone is plugged in". |
| H21 | Not yet verified against a real iPhone | :238-240 | TRUE (as a status) | Status statement. Nothing here verifies a real phone. |
| H22 | Credits: iPhone-use (MIT) and WebDriverAgent (BSD) | :242-247 | TRUE | C31 (MIT), C32 (BSD). |

## docs/peer-routing.md

| # | Claim | Where | Verdict | Proof |
|---|---|---|---|---|
| Q1 | Attestation, site review, policy engine, and ledger work end to end; carrier built and tested on loopback | :3-9 | TRUE (by tests) | Peer routing suite passes, 32 tests ok (C54), including the 6 transport tests. |
| Q2 | Runtime refuses any peer route with `peer_routing_not_built` | :11-15 | TRUE | lib/sirven_runtime/seam.py:99. |
| Q3 | Ship gate `SHIP_GATE_AUTHENTICATED_PEER_TRAFFIC` stays "closed" | :17-19 | TRUE | lib/policy_engine.py:67. |
| Q4 | Jose's quoted ship gate sentence | :21-24 | NOT CHECKED | A quotation of a decision, not a code claim. |
| Q5 | Component table: allowlist review, identity signing, refresh, sign, carry, reciprocity, readiness | :30-38 | TRUE, WITH A FIX | lib/allowlist_review.py exists. `peer_routing.py` has refresh, carry, readiness (C48). The command `cli.mjs` is at lib/attestation/cli.mjs, not at the root (C46). |
| Q6 | "Twenty cases, each through the real code" in tests/peer_routing | :42-47 | FALSE (stale count) | tests/peer_routing/test_end_to_end.py has 26 tests, all ok (C54). Twenty is out of date. |
| Q7 | Fresh machine not ready; configured carrying machine reports `peer_routing_available: true` | :48 | NOT VERIFIED HERE | `readiness` exists (C48) but was not run against a configured state. |
| Q8 | Carrier listens on loopback with a bearer token; endpoint POST /v1/carry; response fields | :52-60 | TRUE | lib/peer_transport.py:57 (`CARRIER_PATH = "/v1/carry"`), :294 (127.0.0.1 default). The transport suite passes (C54). |
| Q9 | Version one carries GET only; other methods return `unsupported_method` | :62-69 | TRUE | lib/peer_transport.py:217. |
| Q10 | No inter-machine authentication yet; Tailscale wiring open | :64-67 | TRUE (as a status statement) | Not implemented in lib/peer_transport.py. |
| Q11 | Verify lock file, automatic clearing rules, the 10-second wait, and `lock_unavailable` | :78-118 | TRUE for the file and reason name; the timing rules NOT VERIFIED HERE | The lock lives in lib/attestation/verify-lock.mjs, and the reason `lock_unavailable` is set at lib/attestation/cli.mjs:376 (C55). The clearing rules and the 10-second wait were not tested. |
| Q12 | Open items: no approved entries; three pending; signing key is a file; votes unsigned | :120-133 | NOT VERIFIED HERE | Registry data not read. |
| Q13 | Decisions for Jose to confirm | :135-144 | NOT CHECKED | Decisions, not code claims. The tier cap in lib/reciprocity.py:50-54 matches the 5 gigabyte statement. |
| Q14 | Monthly cap of 5,000,000,000 bytes | :37 (table) and :48 context | TRUE | lib/reciprocity.py:44 (`GIGABYTE = 1000 ** 3`), :50-54 (`5 * GIGABYTE` for neighborly and co-op). |

## docs/DOWNLOAD-AND-ONBOARDING.md

| # | Claim | Where | Verdict | Proof |
|---|---|---|---|---|
| D1 | The consumer path: a Mac app you download from the sirven website | :3-5 | FALSE today (not live) | sirven.xyz/download/ returns HTTP 200, but its release.json path returns an unrelated web page (C40). |
| D2 | Package is macOS 13 or newer, Apple silicon and Intel | :9 | TRUE (minimum version); NOT VERIFIED HERE (both architectures) | Platform `.macOS(.v13)` (app/macos/Package.swift:10). The universal release build is refused without credentials (C26). |
| D3 | Component files exist: app/macos, copy/onboarding-wizard.json, app/macos/build.sh, site/download | :7-12 | TRUE | Paths exist (C46). |
| D4 | Download page: one static page, no build step, no third-party scripts | :12, :99-101, :110 | TRUE | index.html:64 loads only download.js; no external script (C48). |
| D5 | The wizard is three steps plus a confirmation; both Swift tests and tests/run.sh fail if that changes | :14-18 | TRUE | `testStepCountHonorsTwoOrThreeStepsPlusConfirmation` (C39), `test_wizard_is_three_steps_plus_a_confirmation` (C35). |
| D6 | Two optional permissions; nothing requested until Allow | :24-26 | TRUE (by tests) | `testNothingIsRequestedUntilTheUserAsks` (C39). |
| D7 | Neighborly and Co-op are visible but closed; the ship gate keeps them closed | :21-23, :46-52 | TRUE | `available: false` for both in copy/onboarding-wizard.json:28, :37. Tests pass (C35, C39). |
| D8 | `make app` and `build.sh --dry-run` print the plan and build nothing | :54-63 | TRUE (dry run) / NOT RUN (build) | C25 (exit 0, "nothing was built"). |
| D9 | Verified on 2026-10-11 on Apple silicon, macOS 26.6, with a universal compile | :65-67 | NOT VERIFIED HERE | Historical. Not repeated. |
| D10 | `build.sh --release` checks credentials before building and stops with exit 2 | :71-74 | TRUE | C27 (exit 2, nothing built, no dist folder). |
| D11 | Credential variables and the optional bundle identifier | :76-80 | TRUE | Error text names the two variables (C26). Default bundle identifier at app/macos/build.sh:59. |
| D12 | "The release plan, visible with `--dry-run`" | :93-97 | FALSE without credentials | `--release --dry-run` exits 2 and prints only the error when the credentials are unset (C26). |
| D13 | Download button disabled until the manifest loads; "not available" if it cannot load; sha256 shown | :99-110 | TRUE | site/download/download.js:41, :53, :60. |
| D14 | The page says when a build is not notarized and how to open it anyway | :107-108 | NOT VERIFIED HERE | The page text was not read. |
| D15 | Preview with `python3 -m http.server` | :114-116 | NOT RUN | Not needed for the claim. |
| D16 | A test fails if the sample manifest drifts from the fields build.sh writes | :124-125 | TRUE | `test_sample_manifest_has_every_field_the_build_writes` (C35). |
| D17 | Menu bar wiring; `Sirven --reset-onboarding` shows the wizard again | :126-131 | TRUE | app/macos/Sources/Sirven/main.swift:14, :100 (C48). |
| D18 | Result, endpoint, and tier files: onboarding.json and runtime.json in Application Support | :134-143 | TRUE | app/macos/Sources/SirvenOnboarding/OnboardingStore.swift:19-20. |
| D19 | Bundle identifier xyz.sirven.app is a placeholder | :149 | TRUE | app/macos/build.sh:59 (default value). |
| D20 | Real permission prompts not exercised end to end | :159-161 | TRUE (status) | The Swift tests use the demo broker (C39). |

## install.sh --help

| # | Claim | Verdict | Proof |
|---|---|---|---|
| I1 | Asks at most two questions, each with its default shown | TRUE | C6, and the prompt tests (C35). |
| I2 | Adopts a Tailscale login, a bb install, and an earlier grant, policy, and audit log | TRUE | C6, adopt tests (C35). |
| I3 | `--prefix` records commands that need root instead of running them | TRUE | C15 plan; `test_system_steps_are_recorded_not_run_under_prefix` (C35). |
| I4 | `--transport` accepts tailscale (default), cloudflare, or none | TRUE | C15 shows `transport: tailscale`. Cloudflare apply says "not yet" (`test_cloudflare_apply_says_not_yet`, C35). |
| I5 | `--owner` defaults to you | TRUE | C15 shows the owner name of the account running it. |
| I6 | `--yes` asks nothing and uses the defaults (observer, no path) | TRUE | C15 ("using defaults (--yes): level observer, paths none"). |
| I7 | Nothing is applied to a real machine except inside a Linux container as root | TRUE | lib/plan.sh:317-328. |
| I8 | `--with-bb` adds a plan note only, for now | TRUE | C6 help text. |
| I9 | Examples, including `./install.sh revoke --all --dry-run` | TRUE | C16 (exit 0). The other examples have the same form as C15. |

## bin/sirven --help

| # | Claim | Verdict | Proof |
|---|---|---|---|
| S1 | `sirven grant inspect`, `grant rollback`, `grant repair` | TRUE (`inspect` and `rollback` run; `repair` not run) | C21, C22. |
| S2 | `sirven runtime` with serve, status, fetch, classify, decisions, exec | TRUE | Help lists these six (C49). |
| S3 | `sirven awake [command]` | TRUE, WITH A QUALIFICATION | Dispatch exists, but awake says "not built yet" until `make keep-awake` (C19, C29). |
| S4 | `sirven phone COMMAND` | TRUE | C28. |
| S5 | `sirven add --list`, `add NAME`, `remove NAME` | TRUE (list and add dry run); remove not run | C18, C23. |
| S6 | `--prefix` reads a fake root that install.sh was applied to | TRUE | C21. |
| S7 | Rollback reverses the newest grant entry and refuses when the record does not match | TRUE (refusal path) | C22 (refuses with no audit log). |

## package.json

| # | Claim | Where | Verdict | Proof |
|---|---|---|---|---|
| J1 | Description: "Secure access levels for your personal AI agent. Install it, own it, no hosted middleman." | :4 | TRUE, WITH A QUALIFICATION, and a language fix | "Install it" is qualified (R11). The text uses the initialism for artificial intelligence. See finding 11. |
| J2 | Name and version 0.1.0 | :2-3 | TRUE | npm reports 0.1.0 (C9). |
| J3 | `bin` maps sirven to bin/sirven | :5-7 | TRUE | Tarball contains package/bin/sirven (C33). |
| J4 | `files` lists bin, lib (except lib/issuing), app, copy, connectors, levels, components, docs (except the issuing drafts), install.sh, uninstall.sh, README.md, project.json, Makefile | :8-25 | TRUE (paths exist) | C46. The exclusions exist (lib/issuing, docs/stripe-issuing*.md). |
| J5 | `"license": "MIT"` | :33 | NOT SUPPORTED IN THE REPOSITORY | No license file is tracked in git (C42). |
| J6 | `os`: darwin and linux | :29-32 | NOT VERIFIED HERE | npm metadata. |
| J7 | `scripts.test` runs `make test` | :26-28 | TRUE (the command) | `make test` exits 2 on this Mac (C35). |
| J8 | Repository is github.com/Joesirven/sirven | :34-37 | TRUE | `gh release view` reads the repository (C12). |

## Gates

The branch commit changes no code, so the Mac results below are the same baseline as origin/main.

- **make lint, Mac: exit 0** (C34). 65 files pass `bash -n`, and shellcheck 0.11.0 passes.
- **make lint and make test, Linux container: exit 0 and exit 0** (C57). Ubuntu 24.04 on arm64, shellcheck 0.11.0, Node 18.19.1, curl. Result: 461 passed, 0 failed.
- **Language suite with this note in the tree: exit 0, 3 of 3** (C51). The language suite scans a fixed list of shipped paths, and docs/status is not on that list. So the note was also checked by hand against the same banned-term pattern and for em-dashes (C52). No hits, and zero em-dashes.
- **make test, Mac: exit 2** (C52). 458 passed, 3 failed. These are the same three failures as on origin/main:
  - `test_install_started_by_sh_says_to_use_bash` (tests/unit/test_preflight.sh:119): on this Mac `/bin/sh` is bash 3.2 (BASH_VERSION is set), so the guard at install.sh:9 does not fire and the test's expected exit status 1 does not happen. Reproduced through the runner (C37).
  - `test_enter_twice_accepts_the_shown_defaults` and `test_input_that_ends_takes_the_defaults` (tests/unit/test_questions.sh): the test folder is under $TMPDIR, which on macOS is /var/folders, which resolves to /private/var. The grant policy's `deny_within` list includes /private/var (levels/observer.json), so the default folder becomes `none`. With TMPDIR set to /private/tmp, the suite passes 22 of 22 (C38). Reproduced through the runner (C36).
  - None of the three involves a document.
- **make app-test, Mac: exit 0** (C39). 9 XCTest tests passed, 0 failures. The run ends with a line reporting "0 tests in 0 suites" from the newer Swift Testing runner. That line is harmless.
- **Peer routing suite, run directly: exit 0, 32 tests ok** (C54). 26 in tests/peer_routing/test_end_to_end.py and 6 in tests/peer_routing/test_transport.py.

An earlier Linux container attempt with Ubuntu's own packages gave lint exit 2 and 21 test failures (C58). The shellcheck from Ubuntu 24.04 is 0.9, and its info-level messages (SC2119, SC2015) flag lines the 0.11 build does not. The curl and Node commands were missing from the bare image. Installing those tools cleared all of it (C57), so the failures came from the container, not the repository.

## Commands run, with exit status

Commands are run from the worktree unless noted. Scratch files went to fresh folders under the system temporary directory. Downloaded files were only read or hashed, never run, except where a test runner ran the repository's own tests.

| Code | Command | Exit | Note |
|---|---|---|---|
| C1 | `git merge-base --is-ancestor 98604c7 origin/main` | 0 | SIR-14 evidence |
| C2 | `git merge-base --is-ancestor 54aa04a origin/main` | 0 | SIR-54 evidence |
| C3 | `git cat-file -e origin/main:lib/peer_transport.py` | 0 | SIR-54 evidence |
| C4 | `git fetch origin` | 0 | origin/main = 713659b |
| C5 | `bb tasks show` for SIR-14, SIR-54, SIR-10, SIR-40 | 0 each | Reads |
| C5a | `bb tasks comment` SIR-14, SIR-54, SIR-10 (body from files); `bb tasks update SIR-14 --status done`; `bb tasks update SIR-54 --status done` | 0 each | SIR-10 status left at todo |
| C6 | `bash install.sh --help` | 0 | |
| C7 | `bin/sirven --help` | 0 | |
| C8 | `grep -n SIRVEN_PINNED bootstrap/sirven-bootstrap.sh` | 0 | v0.1.0 |
| C9 | `npm view @joesirven/sirven version` | 0 | 0.1.0 |
| C10 | `curl -fsSL https://cli.sirven.xyz` to a scratch file; grep pins; `cmp` against the repository copy | 0, 0, 0 | Served copy equals repository copy |
| C11 | `which shellcheck` | 0 | /opt/homebrew/bin/shellcheck |
| C12 | `gh release view v0.1.0 --repo Joesirven/sirven --json …` | 0 | Not a draft; one asset; published 2026-10-14T18:15:33Z |
| C13 | `curl` the v0.1.0 asset to a scratch folder; `shasum -a 256` | 0, 0 | 556ce5fb…2718, matches the pin |
| C14 | `bash install.sh --dry-run` | 2 | Refused: Tailscale conflict; nothing changed |
| C15 | `bash install.sh --dry-run --prefix <scratch> --yes` | 0 | Full plan printed |
| C16 | `bash install.sh revoke --all --dry-run --prefix <scratch>` | 0 | 6 plan-only steps |
| C17 | `bash install.sh --dry-run --yes` | 2 | Same refusal as C14 |
| C18 | `bin/sirven add --list` | 0 | crm listed as optional |
| C19 | `bin/sirven awake about` | 1 | "not built yet" |
| C20 | `bin/sirven phone detect` | 1 | "no iPhone is plugged in" |
| C21 | `bin/sirven grant inspect --prefix <scratch>` | 0 | |
| C22 | `bin/sirven grant rollback --dry-run --prefix <scratch>` | 1 | No audit log, nothing to roll back |
| C23 | `bin/sirven add crm --dry-run` | 0 | Plan printed |
| C24 | `make -n keep-awake` | 0 | Shows the build command only |
| C25 | `bash app/macos/build.sh --dry-run` | 0 | Nothing built |
| C26 | `env -u SIRVEN_SIGNING_IDENTITY -u SIRVEN_NOTARY_PROFILE bash app/macos/build.sh --release --dry-run` | 2 | Credentials named as missing |
| C27 | Same without `--dry-run` | 2 | Refused before building; no dist folder |
| C28 | `bin/sirven phone --help` | 0 | |
| C29 | `bin/sirven awake --help` | 1 | "not built yet" |
| C30 | `curl -sS -o /dev/null https://github.com/itskoosh/Sleepless`; `gh api repos/itskoosh/Sleepless` | 0 (HTTP 404); 1 | Link is broken |
| C31 | `gh api repos/zhongerxin/iPhone-use` | 0 | License MIT |
| C32 | `gh api repos/appium/WebDriverAgent/contents/LICENSE` | 0 | BSD License |
| C33 | `npm pack @joesirven/sirven@0.1.0` into a scratch folder; `tar -tzf` | 0, 0 | bin/sirven, install.sh, package.json present |
| C34 | `make lint` | 0 | 65 files; shellcheck passed |
| C35 | `make test` | 2 | 458 passed, 3 failed |
| C36 | `bash tests/run.sh questions` | 1 | 20 passed, 2 failed |
| C37 | `bash tests/run.sh preflight` | 1 | 20 passed, 1 failed |
| C38 | `TMPDIR=/private/tmp bash tests/run.sh questions` | 0 | 22 passed |
| C39 | `make app-test` | 0 | 9 XCTest tests passed |
| C40 | `curl` https://sirven.xyz/download/ and https://sirven.xyz/download/release.json | 0, 0 (HTTP 200 both) | The manifest path returns a web page, not JSON |
| C41 | `curl` https://docs.twenty.com/developers/self-host/capabilities/docker-compose; search for "openssl rand" | 0; count 0 | Phrase not found |
| C42 | `git ls-files \| grep -i licen` | 1 | No tracked license file |
| C43 | `python3 -I lib/grant_compiler.py describe --level levels/observer.json`; `validate levels/observer.json levels/builder.json levels/operator.json` | 0, 0 | |
| C44 | `grep -n planonly lib/kill_switch.sh` | 0 | Plan-only revoke steps |
| C45 | `grep -n 'DIE_STATUS' install.sh` | 0 | install.sh:302 |
| C46 | Existence checks (`ls`, `git ls-files`) for every path the audit names | 0 or 1 as noted | cli.mjs missing at root; lib/attestation/cli.mjs present; runtime-interface.md present; LICENSE absent |
| C47 | `curl -sS -o /dev/null https://cli.sirven.xyz` | 0 (HTTP 200) | |
| C48 | Read-only greps and reads of named lines (pins, constants, imports, strings, writers) | 0 each | Line numbers as cited |
| C49 | `bin/sirven runtime --help` | 0 | |
| C50 | `git ls-files \| grep -ci webdriver` | 0 (count 0) | No vendored WebDriverAgent |
| C51 | `bash tests/run.sh language` | 0 | 3 passed |
| C52 | `make test` on v0.2-docs-truth with this note in the tree | 2 | 458 passed, 3 failed, the same three as origin/main; manual banned-term and em-dash scan of the note: no hits |
| C53 | `git switch -c v0.2-docs-truth`; `git ls-remote origin v0.2-docs-truth` | 0, 0 | The remote branch did not exist before the push |
| C54 | `python3 -m unittest discover -s tests/peer_routing -v` | 0 | Ran 32 tests, ok: 26 in test_end_to_end, 6 in test_transport |
| C55 | `grep -rn lock_unavailable lib`; `grep -rln verify.lock lib` | 0, 0 | lib/attestation/cli.mjs:376; lib/attestation/verify-lock.mjs |
| C56 | `docker info` | 0 | Docker client 25.0.3, daemon responding |
| C57 | Clone of the committed branch into a scratch folder; `docker run ubuntu:24.04` with make, git, python3, curl, xz-utils, nodejs; shellcheck 0.11.0 for aarch64 from its GitHub release; `make lint`; `make test` | 0, 0 | Lint ok; 461 passed, 0 failed; Python 3.12, Node 18.19.1, sqlite3 present |
| C58 | Earlier container run with Ubuntu's own packages (no curl, no Node, shellcheck 0.9) | 2, 2 | Lint flags info messages SC2119, SC2015; 21 test failures from missing curl and node; not a repository defect |
