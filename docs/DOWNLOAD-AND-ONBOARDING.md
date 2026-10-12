# download and onboarding

The consumer install path: a Mac app you download from the sirven website, open, and set up in
three steps and a confirmation. The command line install path (`docs/WALKTHROUGH.md`) stays
available for people who prefer it.

| Piece | Where | What it is |
|---|---|---|
| The app | `app/macos/` | A Swift package. `SirvenOnboarding` is the wizard (a library the menu-bar app links); `Sirven` is the executable inside `Sirven.app`. macOS 13 or newer, Apple silicon and Intel. |
| The wizard's words | `copy/onboarding-wizard.json` | Every word the wizard shows, in one file, so review is one read. |
| The build pipeline | `app/macos/build.sh` | Builds the app, signs it, wraps it in a disk image, notarizes it (release only), and writes `release.json`. |
| The download page | `site/download/` | One static page with one button. It reads `release.json` and has no build step and no third-party scripts. |

## the wizard

Jose's bar: connecting a personal agent is two or three steps plus a confirmation. The wizard is
exactly three steps and a confirmation, and both the Swift tests and `tests/run.sh` fail if that
changes.

1. **Welcome.** What sirven is, in one sentence.
2. **Tier.** Solo, Neighborly, Co-op, in plain language. Solo is selected by default. Bandwidth
   lent and agent autonomy sit on one line per tier, because they travel together. Neighborly and
   Co-op are visible but closed, with a note saying why (see the ship gate below).
3. **Permissions.** Two, both optional, each with its reason: notifications (so the agent can ask
   before it books, buys, or sends anything) and open at login (so the menu bar is there when the
   agent needs it). Nothing is requested until the person presses Allow. The privileged helper is
   not part of onboarding: it asks lazily, the first time a feature needs it (the keep-awake
   work, thread 14).
4. **Confirmation.** "Here is what is now true", built from the real state rather than from what
   was hoped for: the tier, that the agent asks before every real-world action, whether
   notifications and open at login are actually on, and where to point the agent. It then
   introduces the menu bar: the mark at the top of the screen, no dock icon, and what the menu
   controls (tier, agent, keep awake, network, settings).

Run it without touching your real settings:

```bash
make app-test                                    # the wizard's Swift tests
swift run --package-path app/macos Sirven --demo # the wizard against test data
swift run --package-path app/macos Sirven --snapshot /tmp/sirven-wizard  # each step as an image
```

`--demo` uses a fake permission broker and a sample endpoint and saves nothing to your real
Application Support folder.

### ship gate in the wizard

"Do not ship any peer routing of authenticated traffic until the attestation layer and the
site-allowlist review workflow are both working end to end." Neighborly and Co-op both route peer
traffic, so `available` is `false` for both in `copy/onboarding-wizard.json`, the model refuses
to select a closed tier, and a test pins both. Opening them is a one-line change to the copy file
plus removing that test, and should happen only when the gate clears.

## building the app

```bash
make app                          # same as: bash app/macos/build.sh
bash app/macos/build.sh --dry-run # print the plan, build nothing
```

A local build is this Mac's architecture only, ad-hoc signed (`codesign --sign -`), not
notarized, and needs no credentials. It writes `dist/macos/Sirven.app`,
`dist/macos/Sirven-<version>.dmg`, and `dist/macos/release.json`. `dist/` is ignored by git.

Verified on 2026-10-11 on an Apple silicon Mac running macOS 26.6: the local build signs and
passes `codesign --verify --strict`, the disk image is about 0.6 megabytes, and the universal
(Apple silicon and Intel) compile that `--release` uses succeeds.

## signing and notarization

The release build is the one the website offers. It needs Jose's Apple Developer credentials,
which never live in this repository. `build.sh --release` checks for both before it builds
anything, and stops with exit status 2 naming whichever is missing. It never falls back to an
unsigned release.

| Input | What it is |
|---|---|
| `SIRVEN_SIGNING_IDENTITY` | The full name of the Apple certificate for distributing apps outside the App Store, exactly as `security find-identity -v -p codesigning` lists it. |
| `SIRVEN_NOTARY_PROFILE` | The name of a notarytool keychain profile. The profile holds the notarization login in the keychain, so no password is ever passed on a command line or stored in a file. |
| `SIRVEN_BUNDLE_ID` (optional) | The bundle identifier. Default `xyz.sirven.app`; see open decisions. |

One-time setup, all on Jose's Mac, all Jose's:

1. Membership in the Apple Developer Program. This costs money, so it waits for Jose's explicit
   approval if the account does not already have it.
2. In Xcode, Settings, Accounts, Manage Certificates: add the certificate for distributing
   outside the App Store. It lands in the login keychain.
3. Store the notarization login once:
   `xcrun notarytool store-credentials sirven-notary --apple-id <Jose's Apple account email> --team-id <team>`,
   then enter an app-specific password into the prompt (made at account.apple.com).
4. Build: `SIRVEN_SIGNING_IDENTITY="<certificate name>" SIRVEN_NOTARY_PROFILE=sirven-notary bash app/macos/build.sh --release`.

The release plan, visible with `--dry-run`: a universal build; hardened runtime signing with a
secure timestamp and `app/macos/Sirven.entitlements` (empty, meaning no exceptions); verification;
the disk image; signing the image; `notarytool submit --wait`; `stapler staple`; and a Gatekeeper
check with `spctl`. `release.json` then records `"signing": "developer-id"` and
`"notarized": true`.

## the download page

`site/download/index.html`, `download.css`, `download.js`, and a sample `release.json`.

- One button, "Download for Mac". Until `release.json` loads, the button is disabled and says it
  is checking; if it cannot load, the page says the download is not available rather than
  guessing a link.
- System requirements come from the manifest: macOS version, processors, installed size.
- If the build is not notarized, the page says so and says exactly what macOS will show and how to
  open it anyway (System Settings, Privacy and Security, Open Anyway).
- No automatic downloads, no countdowns, no email gate, no trackers, nothing loaded from another
  site. The sha256 of the disk image is shown for anyone who wants to check it.
- It also says how to leave: quit from the menu bar, drag to the Trash, and the one settings
  folder that stays behind.

Preview it: `cd site/download && python3 -m http.server 8000`, then open
`http://127.0.0.1:8000/`. The page uses `fetch`, so opening the file directly does not load the
manifest.

## integration seams

- **Website.** No website thread existed when this was built, so the page lives in
  `site/download/` as plain static files. To publish: copy the folder into the site, put the
  release disk image next to it, and replace the sample `release.json` with the one
  `build.sh --release` writes. If the image is hosted elsewhere, add a `"url"` field to
  `release.json` and the button uses it instead of `"file"`. A test fails if the sample manifest
  drifts from the fields `build.sh` writes.
- **Menu-bar app (thread 15).** `main.swift` installs a placeholder menu bar item (show welcome
  again, quit). The menu-bar app replaces that menu and keeps the launch logic: show
  `OnboardingView` when `OnboardingStore.standard.load()` is nil. The wizard's last screen
  promises five menu items: tier, agent, keep awake, network, settings. If the menu changes,
  update `menuBarItems` in `copy/onboarding-wizard.json`. If thread 15 finds a supported way to
  hide Tailscale's own menu bar item, its consent line belongs in the permissions step as an
  optional third item; the step count stays three.
- **Runtime (thread 01).** The confirmation reads the agent endpoint from `agentEndpoint` in
  `~/Library/Application Support/sirven/runtime.json`. Until the runtime writes that file, the
  confirmation says the details appear in the menu bar once sirven is running. If
  `docs/runtime-interface.md` settles on a different location, change
  `OnboardingStore.runtimeEndpoint()`.
- **Tier dial (thread 06).** The wizard writes its result to
  `~/Library/Application Support/sirven/onboarding.json`
  (`version`, `completedAt`, `tier`, `notifications`, `openAtLogin`). The tier dial owns tier
  changes after onboarding and should treat this file as the starting tier only.
- **Privileged helper (thread 14).** Deliberately absent from onboarding. The permissions step
  tells the person that keeping the Mac awake with the lid closed asks for one system approval
  the first time they turn it on.

## open decisions for Jose

- **Bundle identifier.** `xyz.sirven.app` is a placeholder built from the sirven.xyz domain. It
  is hard to change after the first public release, because macOS ties permissions and login items
  to it.
- **Where the disk image is hosted** (next to the page, or a release host), which sets
  `"url"` in `release.json`.
- **The name.** `docs/SCOPE.md` calls Sirven a working name; the app, icon, and page all use it.
- **The wizard's words.** `copy/onboarding-wizard.json` is drafted for review.

## honest notes

- The wizard has been rendered and walked through with test data (`--snapshot`, `--demo`). The
  real permission prompts (notifications, open at login) need a signed app launched from
  Applications and have not been exercised end to end yet.
- The release path has been checked by dry run only, since the credentials are Jose's.
- The app forces the light appearance for now; a dark appearance is not designed yet.
