# SIR-46 final acceptance review: a lighter iPhone path for sirven

Reviewed: branch `sir-46-acceptance-review-xcode-free-iphone-path-thr_im7w5pne9v`, head 9f9f0c0, against `origin/main`. Inputs: the research note `docs/research/xtool-lighter-phone-path.md`, the implementation (`git diff origin/main...HEAD`), the code review (`git show fb8f06c:docs/research/qa/sir-46-code-review.md`) and the partial phone test (`git show b05eef0:docs/research/qa/sir-46-phone-qa.md`). Date 2026-10-12, on Omashu (the MacBook Pro the research note measured; `du -sk /Applications/Xcode.app` gives the same 4,070,676 KB). The phone was not touched. No product code was changed.

**Verdict: ACCEPT WITH CONDITIONS.** The run-time half of Jose's request is delivered and well built. Two documentation gaps make the path fail for exactly the owner it is meant for (a fresh phone, no Xcode), so they are merge conditions. The signing half still needs Xcode or an unproven xtool route, and the whole path is unproven on a real phone, so the product is not done.

## 1. Does it deliver "make the iPhone use much less"?

### Today versus now, from the evidence

| | Today (Xcode path) | Now (this branch, at run time) | Source |
|---|---|---|---|
| Xcode.app | 4,070,676 KB (3.9 GB), needed | not needed at run time | `du -sk`, research note and this review |
| Device symbols Xcode copied for this phone | `~/Library/Developer/Xcode/iOS DeviceSupport/iPhone13,3 26.6.1 (23G83)`: 5,825,692 KB (5.6 GB), dated Oct 11 17:42 | not created (nothing in the new path writes there) | `du -sk`, `ls -ld` in this review |
| Command line developer tools | 2.2 GB, needed | **still needed**, by sirven itself | see correction below |
| New tools | none | pymobiledevice3 environment 140 MB (`du -sh ~/.local/share/uv/tools/pymobiledevice3`) plus the uv-managed Python it runs on, 57 MB (`cpython-3.14.2`); runner download 1.1 MB, 2.9 MB unpacked (route A only); xtool 69 MB unpacked (route A only) | this review, research note |
| Long-running processes | `xcodebuild test` plus its helpers (helpers not counted) | **3**: the supervisor (`sirven phone start`), the tunnel, the launcher | `lib/phone_bridge.py` `RunnerSupervisor` |
| Resident memory | **not measured** (no signed build could be started without Jose's Apple sign-in) | tunnel about 18 MB and launcher 24 to 30 MB (research note, one 30 second observation on the real phone), plus the supervisor at 21 MB under macOS's Python 3.9.6 and 29 MB under Python 3.12 (this review, measured with fake children). Total about 63 to 77 MB (18 plus 24 to 30 plus 21 to 29) | research note, this review |

**Correction to the research note.** Its table counts the command line developer tools (2.2 GB) as no longer needed. On sirven's documented macOS install path that saving does not exist: `/usr/bin/python3` is the developer tools stub (its checksum, c36f8dd9…, is identical to `/usr/bin/git` and `/usr/bin/clang`), `lib/preflight.sh:71` already tells macOS owners to run `xcode-select --install` for python3, and `bin/sirven phone` needs python3. The honest disk saving is Xcode.app plus the device symbols Xcode copies per phone and iOS version: about 9.5 GB on this Mac, less the new tools: about 200 MB on route B (pymobiledevice3 140 MB plus its Python 57 MB) and about 270 MB on route A (adding xtool, 69 MB, and the 2.9 MB runner). Simulators (about 20 GB here) and the derived build folder (1.3 GB, no WebDriverAgent entry in it today) are not counted, because they belong to other Xcode work.

**Memory.** The new path's run-time cost is measured (about 63 to 77 MB across three processes). Today's `xcodebuild test` is not, so "much less memory" is not yet shown by a number. The cheapest way to get the baseline: when Jose next runs route B, read `ps -o rss= -p <pid>` of `xcodebuild` and its children before pressing Ctrl-C.

### What is still Xcode-dependent

- **Signing for a fresh phone, and re-signing.** Route B (full Xcode) is the only route proven to produce a runner (the runner on Jose's phone came from it). Route A (xtool) is labelled experimental, correctly.
- **The 7-day expiry.** A free Apple account's signature lasts 7 days (Apple's published limit, cited in the research note, not tested here). On a free account, route B means Xcode stays installed or is reinstalled weekly, so the 3.9 GB saving only materialises with route A working, or with a paid account. The documentation states the 7 days under route A only (`docs/phone-interface.md:64`), not under route B.
- **The developer disk image.** On the spike phone it had been mounted earlier by Xcode. Nothing in the new path mounts it (finding M1).

**Answer to question 1:** yes for run time (no Xcode process, no Xcode at run time, a measured 63 to 77 MB), partly for disk (Xcode can only be removed once signing no longer needs it), not yet for a fresh phone.

## 2. The owner walk: a new owner on a Mac with no Xcode

I followed `sirven phone setup` (printed with `--team ABCDE12345 --bundle com.example.Runner` and a scratch home folder) and `docs/phone-interface.md` steps 1 to 7.

| Step | Works as written? | Evidence |
|---|---|---|
| Install pymobiledevice3 with uv | Yes if uv is installed; nothing says how to get uv | `grep` of README, WALKTHROUGH and `install.sh` finds no uv install line |
| Download and check the runner (document version) | **Yes**, exit 0, `runner.zip: OK` | ran the exact line from `docs/phone-interface.md` with a scratch home; checksum matches the live v16.14.0 asset |
| Download and check the runner (printed setup version) | **Yes**, exit 0, `OK` | ran the printed line with a scratch home |
| Route A: `xtool install`, then the runner identifier | **No** (finding M2) | see below |
| Route B: `xcodebuild ... test`, Ctrl-C | Plausible, needs full Xcode | unchanged from today apart from the folder |
| `sirven phone start` on a fresh phone | **No** without a mounted developer disk image (finding M1) | see below |
| `sirven phone status` | Yes, says running or not running | measured here with fake children: `{'tunnel': 'running', 'launcher': 'running'}`, then a clean stop with no leftover processes |
| Missing pymobiledevice3 | Clear message with the install line | `lib/preflight.sh` `preflight_phone`, three passing tests |

### M1 (merge condition). Nothing mounts the developer disk image

pymobiledevice3's own help for the `developer` command group (`cli/developer/__init__.py`, installed 11.28.2) says: "These commands require the DeveloperDiskImage.dmg to be mounted on the device prior to execution." The launcher is `pymobiledevice3 developer dvt xcuitest`. The automatic mount exists only in `pymobiledevice3 mounter auto-mount` (`cli/mounter.py:173`); the `developer` commands do not call it. Neither the setup plan, the document, nor the supervisor runs it. The research note lists this as an untested gap; the implementation did not carry it into the owner steps.

A fresh phone on route A has never had Xcode attached, so no image has ever been mounted. The launcher then fails every time, and the supervisor loops: three quick failures, a tunnel restart, backoff capped at 30 seconds, forever. The tunnel refusal text (`lib/phone_bridge.py:730`) names plugging in, unlocking, and Developer Mode, not the image. Whether an image mounted by Xcode survives a phone restart was not tested here.

Fix: add `pymobiledevice3 mounter auto-mount` to the setup plan and the document, and name the image in the launcher-failure guidance. Phones on iOS 17 and later get a personalized image (`PERSONALIZED_IMAGE_MIN_VERSION = 17.0`); from iOS 27 the source refuses without the tunnel (`CRYPTEX_IMAGE_MIN_VERSION = 27.0`, `RSDRequiredError` in `auto_mount_personalized`), so the step should pass the tunnel's `--rsd` address. Running it from the supervisor before each launch is better but optional; its source says an already mounted image succeeds, so it is safe to repeat.

### M2 (merge condition). Route A tells the owner the wrong runner identifier

The downloaded runner's bundle identifier is `com.facebook.WebDriverAgentRunner.xctrunner` (`plutil` on the unzipped `Info.plist`). xtool rewrites every identifier it provisions to `XTL-<identity prefix>.<original>` (`Sources/XKit/Utilities/ProvisioningIdentifiers.swift`, `identifier(fromSanitized:)`; used at `DeveloperServicesAddAppOperation.swift` line 46; identical in the 1.21.0 release that Homebrew installs and at main, commit d802c71). Setup step 7 (`lib/phone_bridge.py:1459`, `runner_identifier = bundle + ".xctrunner"`) and `docs/phone-interface.md:76` tell every owner to use "the bundle name you gave setup, with `.xctrunner` added". For a route A owner that value is wrong, and `sirven phone start` would loop as in M1. Setup also refuses to print anything without `--team` and `--bundle`, which route A never uses, and the `--team` message (`:1452`) points to a developer account membership page that a free-account owner may not have (not verified).

Fix (text only): for route A, tell the owner to use the identifier xtool prints after install (or the one the phone lists), and make `--team` and `--bundle` route B only, or say route A owners can pass placeholders.

### Should fix (not blocking)

- **S1. No route to uv.** Say how to install it once (for example Homebrew, or uv's own installer), and that uv can supply a Python 3.12 or newer itself: on this Mac pymobiledevice3 runs on a uv-managed Python 3.14 (`~/.local/share/uv/python/cpython-3.14.2-macos-aarch64-none`) while `/usr/bin/python3` is 3.9.6. "Needs Python 3.12 or newer" alone will send a new owner looking for a Python they do not need to install.
- **S2. `~/.local/bin` not on PATH.** After `uv tool install`, preflight only repeats the install line. Add "if it is installed but not found, run `uv tool update-shell`".
- **S3. Homebrew assumed.** Route A's `brew install xtool-org/tap/xtool` assumes Homebrew is installed.
- **S4. Route B and the 7 days.** Now merge condition 3: say under route B that a free account means signing again every 7 days, so Xcode stays on the Mac; a paid account's development profile lasts much longer (Apple's limit, not tested here).
- **S5. Throwaway Apple account advice.** The research note records xtool's own advice to use a separate Apple ID for the free-account route (it sends the password through private Apple interfaces). `docs/phone-interface.md` does not pass that on.
- **S6. An expired or missing runner is silent.** The supervisor prints the launcher's last five lines on each restart, which is the right mechanism, but no sirven text says "if the launcher keeps failing, the runner may have expired, not be installed, or the user interface automation switch may be off". One sentence in the start guidance.

Everything else in the walk is coherent, with one exception in condition 3 ("once"): README and document agree on run time without Xcode, routes A and B are clearly alternatives ("ONE of the two routes, not both"), route A is labelled experimental in both places, and every refusal I triggered is in plain words.

## 3. Architecture and risk

- **pymobiledevice3 private-framework tunnelling.** The no-root tunnel uses macOS's `RemotePairingDevice` private framework (research note, `cli/remote.py`). A macOS update could break it; then the tunnel refuses with a plain message and route B's Xcode still works as a fallback for running too, by hand. Accept, with pymobiledevice3 pinned (`==11.28.2`, version-pinned, not hash-pinned).
- **Free-account 7-day expiry.** Inherent to Apple's free signing and unchanged from today's Xcode path. Accept, with S4 and S6.
- **Supervisor robustness.** Read the code and checked against the code review's resolved findings: one supervisor at a time through an exclusive lock that the system releases on a hard kill (`:508`); leftovers from a killed run block a new start (`:668`); terminate and hang-up stop both children with nested cleanup (`:463`); three quick launcher failures restart the tunnel for a fresh address (`:692`); the device identifier is filtered from printed output (`:537`, R1 fixed in 2920b47, with a test). I ran the supervisor here with fake children under both macOS's Python 3.9.6 and Python 3.12: it started, recorded process identifiers, reported running, and on a terminate signal stopped both children, removed `runner.json`, exited 0, and left no process behind. Residual gaps accepted by the code review (a microsecond window around child start, now closed by 9f9f0c0; reused process identifiers in the leftover message; Ctrl-C ignored when started in the background) are low and I accept them. The supervisor is not a login item, so it runs only while a terminal holds it; that is a deliberate scope choice.
- **Security of downloads.** The runner zip is pinned by SHA-256 (`:81`) and checked before unzip in both the document and the printed plan, with `curl -fL`; I verified the digest against the live release asset (exit 0, `OK`). R2 (the quoted tilde) is fixed in c4eb910 and the document command now works. xtool comes from a third-party Homebrew tap, unpinned; acceptable for an experimental route, worth a version pin later. When M1 is fixed, note that pymobiledevice3 fetches the disk image from its own repository ("download the Personalized image from our repository", `services/mobile_image_mounter.py:610`) and has Apple sign the personalization (`services/cryptexd.py` around line 543), so the phone only mounts what Apple's signing service approved.
- **Nested test bundle under xtool.** xtool's provisioning scans `PlugIns` and `Extensions` for `.appex` only (`DeveloperServicesAddAppOperation.swift` line 242 in the 1.21.0 release). The runner's plug-in is `PlugIns/WebDriverAgentRunner.xctest`, so xtool gives it no app identifier, profile, or `Info.plist` rewrite. Whether its signer still signs that bundle and `WebDriverAgentLib.framework` correctly is unverified. This is why route A is not proven; it does not block merge because route A is labelled experimental.
- **Nothing here blocks merge** beyond M1 and M2.

## 4. My own verification runs (head 9f9f0c0)

| Command | Exit status | Result |
|---|---|---|
| `python3 -B -m unittest tests.phone.test_phone_runner` | 0 | 27 tests OK in 10.7 seconds, foreground; one `ResourceWarning` about an unclosed file, not a failure |
| `make test` | 2 | 379 passed, 3 failed: `test_install_started_by_sh_says_to_use_bash`, `test_enter_twice_accepts_the_shown_defaults`, `test_input_that_ends_takes_the_defaults`. The phone tests pass (`test_phone_runner_unit_tests_pass`, three `test_phone_start_*`). That these three fail on `origin/main` too comes from the phone test report's run at 418133c; I did not rerun `origin/main` myself |
| `make lint` | 0 | `bash -n` clean on 55 files; shellcheck not installed, skipped |
| Document download line, scratch home | 0 | `runner.zip: OK`, unzipped `WebDriverAgentRunner-Runner.app` |
| Printed setup download line, scratch home | 0 | `OK` |
| Supervisor with fake children, Python 3.9.6 and 3.12 | 0 each | started, status running, clean stop, no leftovers; supervisor resident memory 21,344 KB and 28,976 KB |

The fixes for R1 (2920b47) and R2 (c4eb910), the quick-failure reset (676d5b0), the default interrupt handler in tests (d21c771), and the child-start interrupt window (9f9f0c0) are each covered by a passing test or, for R2, by the command run above.

## 5. Conditions

### For merge

1. **M1:** add the developer disk image mount step (`pymobiledevice3 mounter auto-mount`, with the tunnel address, which iOS 27 and later require) to the setup plan and `docs/phone-interface.md`, and mention the image in the launcher-failure guidance.
2. **M2:** fix the route A runner identifier text in the setup plan and the document (use the identifier xtool prints), and stop route A owners needing a real `--team` and `--bundle`.
3. **"Once" is not true on a free Apple account.** The README says "a one-time sign and install", and step 4 of both the document and the setup plan says "sign and install the runner once". With a free account it is once, then again every 7 days, for route A and route B alike (with route B that keeps Xcode on the Mac). Say so in all three places (this absorbs S4). Keep the claim scoped to run time, as it is now, and keep the "not yet verified against a real iPhone" line until the conditions below are met.

S1 to S3, S5 and S6 are recommended in the same pass but not required.

### For calling the product done

The real-phone test (steps 3 to 7 of the phone test plan, still not run) must show, with commands and exit statuses recorded:

1. With Xcode not running (`pgrep -fl xcodebuild` prints nothing for the whole run), `sirven phone start` brings up the tunnel and the launcher, and `sirven phone status` says both are running and WebDriverAgent is ready.
2. Screen capture, the accessibility tree, and the active app answer through `sirven phone serve`, and one harmless tap is logged by `sirven phone log`.
3. Killing the tunnel, then the launcher, each recovers on its own; recovery times recorded.
4. Ctrl-C leaves no tunnel, launcher, or `runner.json` behind.
5. Resident memory of the supervisor, tunnel, and launcher sampled over two minutes; and, if Jose runs route B, the `xcodebuild test` baseline measured the same way, so "much less memory" is a measured number.
6. **A phone restart, then `sirven phone start` again with no Xcode involved**, recovers (this tests M1's fix; it is the case the current path has never shown).
7. Route A either proven end to end on a phone (xtool install, the runner identifier it prints, the nested test bundle launching) or left documented as experimental with route B as the stated route. Route A proven, or a paid account, is what lets Xcode actually leave the Mac.
8. No device identifier or serial number in any captured output.

**Verdict: ACCEPT WITH CONDITIONS** (merge after M1, M2 and condition 3; done after the real-phone test above).
