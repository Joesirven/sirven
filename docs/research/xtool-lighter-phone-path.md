# Lighter iPhone path: can xtool remove full Xcode? (task SIR-46)

**Verdict: PARTIAL.** Running WebDriverAgent without Xcode.app or `xcodebuild` is proven on this Mac, on a real iPhone, today. Getting a freshly signed runner onto the phone without Xcode is not proven, and xtool alone is not the answer for it.
The run-time half works with pymobiledevice3 (no root, no Xcode process). The signing half still needs Jose's Apple sign-in, plus one open question about xtool on macOS (see Risks).

Date: 2026-10-12. Mac: MacBook Pro, Apple silicon, macOS 26.6.2, Xcode.app installed. Phone: iPhone 12 Pro (iPhone13,3), iOS 26.6.1, developer mode on.

## Measured numbers: today versus proposed

| | Today (Xcode path) | Proposed (no Xcode at run time) |
|---|---|---|
| Disk: Xcode.app | 3.9 GB (`du -sk /Applications/Xcode.app` = 4,070,676 KB) | 0 needed |
| Disk: command line tools | 2.2 GB (`/Library/Developer/CommandLineTools` = 2,288,200 KB) | 0 needed |
| Disk: new tools | none | pymobiledevice3 environment 153 MB (python plus dependencies, in a scratch `uv tool` folder); prebuilt runner download 1.1 MB (2.9 MB unpacked). xtool.app 27 MB zip, 69 MB unpacked; go-ios 43 MB (alternative launcher, not recommended yet) |
| Long-running processes | `xcodebuild test` plus the helper processes it spawns (helpers not measured) | **2**: the tunnel process and the test-launcher process |
| Resident memory | **Not measured.** No `xcodebuild` was running (`pgrep -fl xcodebuild` printed nothing) and starting one needs a signed build, which needs Jose's Apple sign-in. This Mac has 4.9 GB total with about 1.3 GB free, so I did not start one | Tunnel process 18 MB (78 MB at startup, 18 MB once settled); launcher process 24 to 30 MB; total about 45 to 50 MB. Version-check runs: pymobiledevice3 68 MB peak, go-ios 35 MB peak |

Biggest win: Xcode.app (3.9 GB) and the command line tools (2.2 GB) are no longer needed at run time. Caveat: nothing here shows Xcode can be deleted from Jose's own Mac, only that the run path did not use it. I did not touch Xcode.

## What I tested (commands run, results)

Everything ran from `/tmp/sirven-xtool-spike`, no sudo, nothing outside user space.

1. `pymobiledevice3 remote start-tunnel --native` printed "native tunnel is up" and a device address, with no root. The source (`cli/remote.py`) says `--native` is the macOS default and uses the system pairing daemon; that daemon lives in `/System/Library/PrivateFrameworks/RemotePairingDevice.framework`, part of macOS and not Xcode.
2. The phone already had a runner installed from an earlier Xcode build: `com.josesirven.wda.runner.xctrunner`. I launched it with `pymobiledevice3 developer dvt xcuitest com.josesirven.wda.runner.xctrunner --rsd <address> <port>`. The log showed `didBeginExecutingTestPlan` and `testCaseDidStart: UITestingUITests/testRunner`.
3. Through `pymobiledevice3 usbmux forward 18100 8100`, every route family that `lib/phone_bridge.py` uses answered with HTTP 200: `/status` (`ready: True`), `/wda/locked`, `/wda/activeAppInfo`, `/screenshot` (a 445,867-byte image; I did not save or look at it), `POST /session`, `/session/<id>/window/size` (390 by 844), `/session/<id>/source?format=xml...` (22,803 bytes), `DELETE /session`. No taps, text, or app launches were sent.
4. I stopped the launcher, the forward, and the tunnel afterwards; no process from the scratch folder remained.

The bridge itself talks to port 8100 through the USB multiplexer directly (`UsbHTTPConnection`, `lib/phone_bridge.py:268`), so it does not care which tool launched the runner.

## Questions answered

**1. Footprint today.** See the table. Xcode.app and the command line tools are present; running `xcodebuild` memory could not be measured (reason in the table).

**2. What xtool does** (source: github.com/xtool-org/xtool, version 1.21.0 released 2026-10-05).
- (a) Build an XCTest user-interface runner: **no.** `xtool` builds SwiftPM packages into app bundles (`README.md`: "Build a SwiftPM package into an iOS app"); its subcommands are setup, auth, sdk, new, dev, ds, devices, install, uninstall, launch. Nothing builds or runs an XCTest bundle. WebDriverAgent is an Xcode project, not a SwiftPM package.
- (b) Sign an arbitrary prebuilt app or `.ipa`: **yes in principle.** `Sources/XToolSupport/InstallCommand.swift` takes "The path to a custom app/ipa to install" and passes it to `IntegratedInstaller`, which signs it using `AutoSigner` (`Sources/XKit/Signer/AutoSigner.swift`). It provisions through Apple Developer Services, rewrites the bundle identifier to a team-specific one, and replaces `embedded.mobileprovision`. Login is either a paid-account App Store Connect key, or an Apple ID and password through private interfaces, which works for free accounts (`Documentation/xtool.docc/Installation-macOS.md`). I could not confirm it signs a nested `.xctest` bundle and its framework inside `PlugIns` correctly, since that needs a real run.
- (c) Install to a device: yes (`xtool install`, through the installation proxy service). `xtool launch` starts an app through the debug server (`LaunchCommand.swift`), which is **not** an XCTest launch, so it cannot start WebDriverAgent as a test. The developer disk image mounter in xtool is compiled out (`DDIMounter.swift` begins with `#if false`).
- macOS install docs also say Xcode is a prerequisite "for the iOS SDK and toolchain", but that matters for building, not for `xtool install` of a prebuilt bundle.

**3. Candidate path.**
- Runner: appium/WebDriverAgent release asset `WebDriverAgentRunner-Runner.zip` (v16.15.0, 1.1 MB). I downloaded and inspected it: arm64 iOS app, bundle identifier `com.facebook.WebDriverAgentRunner.xctrunner`, runner minimum iOS 13, test bundle minimum iOS 15, built with the iOS 18.4 and 18.5 SDK, contains `PlugIns/WebDriverAgentRunner.xctest` with `WebDriverAgentLib.framework`. It carries Apple's build signature, so it must be re-signed for any new phone.
- Re-signing: xtool is the one cross-platform candidate for a free account. Alternative with a paid account: go-ios has `ios sign provision appstoreconnect` and `ios sign app` (help text in go-ios 1.3.2). Unproven here either way.
- Launching: pymobiledevice3 `developer dvt xcuitest` (proven above on iOS 26.6.1). Its tunnel needs no root on macOS. For phones older than iOS 17 no tunnel is needed in principle; I did not test that.
- go-ios `runwda` / `runtest` exist, but its iOS 17+ tunnel needs either `sudo ios tunnel start` or a userspace agent. When I ran it, its auto-started agent **spawned well over a hundred copies of itself** (load average reached 39) until I killed them all; the cause is not established (a different program held the port it tried first). Do not recommend go-ios until that is understood and tested in isolation.
- Developer disk image: this phone already had one mounted (go-ios `image list` showed an image signature). I did not test mounting. pymobiledevice3 has `mounter auto-mount`, which asks Apple's ticket service for iOS 17+ personalized images, and go-ios has `image auto`; both are untested here. Xcode normally keeps candidate images in `/Library/Developer/CoreDevice/CandidateDDIs`, installed by an Xcode package, so an Xcode-free Mac needs the tool to fetch them. That is a gap to test on a phone that has none mounted.

**4. Does the pinned commit matter?** No. The commit pinned in `lib/phone_bridge.py` (`d1778242...`) is the appium commit "chore(release): 16.14.0", dated 2026-10-04 (GitHub commits API). The runner on the phone reports build version 16.14.0, and all routes sirven uses answered. A release build is acceptable. Use the v16.14.0 release asset to match the pin exactly, or move the pin to a release tag (v16.15.0 is 8 commits ahead).

## Recommended path, step by step

1. Keep the existing runner if it still works (it does today). For a fresh phone, steps 2 to 4 are needed once.
2. On the phone: plug in, unlock, Trust; Developer Mode on and restart (as `sirven phone setup` says today).
3. Download the pinned release asset `WebDriverAgentRunner-Runner.zip` from appium/WebDriverAgent (v16.14.0), unzip.
4. Sign and install once. Either `xtool auth login` then `xtool install WebDriverAgentRunner-Runner.app` (free or paid account; open questions below), or the go-ios signing commands with a paid account key. Then on the phone: Settings, General, trust the developer certificate; Settings, Developer, user interface automation on.
5. Each session: `pymobiledevice3 remote start-tunnel --native` (leave running), then `pymobiledevice3 developer dvt xcuitest <runner bundle identifier> --rsd <address> <port>` (leave running). Then `sirven phone status`.
6. Change `command_setup` in `lib/phone_bridge.py` to print these steps instead of the Xcode and `xcodebuild` steps; the bridge itself needs no change.

## What still needs Jose

- Apple sign-in: step 4 needs his Apple account (free account: Apple ID, password, two-factor code, private interfaces, so a throwaway Apple ID is advised by xtool's own docs; paid: an App Store Connect Team Key with the App Manager role). I did not ask for or use credentials.
- Phone: plugged in and unlocked for the final signing and install test (he unlocked it for this spike; nothing was changed on it).
- xtool on macOS: the release `xtool.app` pops "Move this app into your Applications folder" when run from anywhere else, including a symlink or `~/Applications`, and the process waits on the dialog. Jose saw that dialog; it came from my test run and needs no action. To test xtool he can allow `brew install xtool-org/tap/xtool` (a cask that installs into `/Applications`) or drag it into `/Applications`. I did not do either, because the task limited me to scratch space.
- A phone with no developer disk image mounted, to test the Xcode-free image mount.

## Risks

- Signing half unproven: xtool cannot be run headless from scratch space, so `xtool install` of the runner was not tried. Nested test-bundle signing is unverified.
- The free-account path uses private Apple interfaces (xtool docs say so) and free profiles expire after 7 days, so the owner repeats signing weekly (Apple's published free-account limit; not tested here).
- pymobiledevice3's no-root tunnel relies on a private macOS framework (`RemotePairingDevice`), which could change with a macOS update. This Mac runs macOS 26.6.2; older macOS versions were not tested.
- Two long-running processes instead of one; if either dies, WebDriverAgent stops. A small supervisor script is advisable.
- pymobiledevice3 is a Python package of about 150 MB with dependencies; it is "lighter" than Xcode but not tiny. It needs Python 3.12 or newer (the scratch install used Python 3.14).
- go-ios process spawn storm (see above).
- Memory figures are single short observations (a 30-second run), not sustained use. Today's `xcodebuild` memory has no measurement.

## Follow-up suggested by Jose (not done)

Reverse-engineer xtool, or read its source, to find the minimal parts the iPhone path needs (signing, provisioning, install) and ship only those with the Sirven package instead of the whole tool. From the source layout, those parts would be `Sources/XKit/DeveloperServices`, `Sources/XKit/Signer`, and `Sources/XKit/Installation`. I did not start this.

## Sources

- xtool: https://github.com/xtool-org/xtool (README.md; `Documentation/xtool.docc/Installation-macOS.md`; `Sources/XToolSupport/InstallCommand.swift`, `LaunchCommand.swift`; `Sources/XKit/Integration/IntegratedInstaller.swift`; `Sources/XKit/Signer/AutoSigner.swift`; `Sources/XKit/Installation/DDIMounter.swift`); release 1.21.0 assets.
- WebDriverAgent releases: https://github.com/appium/WebDriverAgent/releases (v16.15.0 and v16.14.0 `WebDriverAgentRunner-Runner.zip`).
- go-ios: https://github.com/danielpaulus/go-ios (v1.3.2, README and `ios --help`).
- pymobiledevice3 11.28.2 (`developer dvt xcuitest --help`, `remote start-tunnel --help`, `mounter --help`, source `cli/remote.py`).
- Repository files: `lib/phone_bridge.py` (lines 61 to 70, 268 to 380, 1096 to 1120), `docs/phone-interface.md` (lines 44 to 52).
- Scratch evidence: `/tmp/sirven-xtool-spike` (logs `xcuitest.log`, `ptunnel.log`, `runwda.log`).
