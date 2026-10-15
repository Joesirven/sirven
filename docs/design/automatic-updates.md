# Automatic updates: design note for Jose to decide on

Status: proposal, nothing built. Tracked as SIR-8. This note writes no product code and changes no
file outside `docs/design/`. It ends with the decisions only Jose can make.

## 1. What exists today, and the gap

- **Install.** `curl -fsSL https://cli.sirven.xyz | bash` serves `bootstrap/sirven-bootstrap.sh`. The
  script pins one git tag and one checksum (`SIRVEN_PINNED_TAG`, `SIRVEN_PINNED_SHA256`), downloads the
  archive attached to that GitHub release, compares the checksum before unpacking, and runs that
  release's `install.sh`. `bootstrap/release.sh` writes the pin and prints, but never runs, the upload.
  `docs/BOOTSTRAP.md` is the maintainer's procedure. Today the pin is `v0.2.0`.
- **Kept copy.** A real install keeps the package at `/var/lib/sirven/package` with a marker file
  named `PINNED-COPY` (`tag=`, `sha256=`; `lib/layout.sh:117`, `layout_stage_package`). The state
  directory around it is mode 0700 and owned by root (`lib/layout.sh:296-297`). A newer release replaces
  the copy by building `package.new` beside it, removing the old copy, then moving the new one into place
  (`layout_keep_package`, `lib/layout.sh:272-276`). Root commands
  run through the launcher `/usr/local/sbin/sirven`, which runs the kept copy
  (`docs/PERMISSIONS.md`, the root-trust gate described around the launcher). That gate decides whether
  the code about to run as root is writable by anyone but root and the owner, and `install.sh` is the
  one command allowed to replace the copy.
- **Confirmation.** `plan_confirm_real_apply` in `lib/plan.sh` makes the first change to a real machine
  never silent: `--yes` (or `SIRVEN_YES`), or the word `yes` typed on a terminal. With no terminal and no
  `--yes` it applies nothing and returns status 3. The kill switch passes its own typed word instead.
- **No update command, no signing key.** `bin/sirven` has `grant`, `runtime`, `awake`, `phone`, `add`
  and `remove` only (usage, `bin/sirven:247-262`), and nothing in the repository pins a signing key
  (a search for `ssh-keygen` and `allowed_signers` finds no use). A machine installed from `v0.2.0` therefore
  has neither the command nor the key; see the limits in section 3.
- **Mac apply is off.** A Mac does not apply an install by default (`SIRVEN_MACOS_REAL_APPLY=1` is the
  owner's switch; `docs/BOOTSTRAP.md`, last section). The command line on a Mac is plan-only today.
- **The app.** `app/macos` builds `Sirven.app`. A local build is ad-hoc signed and not notarized; the
  release path needs Jose's Apple credentials and has only been checked by dry run
  (`docs/DOWNLOAD-AND-ONBOARDING.md`, "signing and notarization", "honest notes").
- **npm.** `package.json` names `@joesirven/sirven` at 0.2.0. Publishing is parked for Jose.

**The gap.** Nothing on a machine can learn that a newer release exists. The only trust anchor for a
release is the checksum written into the script that cli.sirven.xyz serves. If that server or its
deploy path is compromised, the attacker serves a script with their own pin, and `curl | bash` runs it.
Putting that same mechanism on a timer would turn a one-time trust decision into a standing one.

## 2. What "automatic update" should mean

Three levels, in increasing order of power. These are plain descriptions, not names. Levels 2 and 3
are separate opt-ins.

1. **Level 1, check only** (on by default, but only when someone asks; see the trigger below). The
   machine reads a small signed manifest and says whether a newer verified release exists: a line in
   `sirven grant inspect` (the existing read-only command, `bin/sirven:250`; a new `sirven status`
   command is not needed), a line in install and uninstall output, an item in the menu bar. Nothing is
   downloaded beyond the manifest and nothing on the machine changes, so no consent is needed.
2. **Level 2, download and stage** (opt-in). The new archive is downloaded and verified and the update
   plan is computed and shown, but not applied. The owner applies it with one command that goes through
   the normal confirmation.
3. **Level 3, download and apply** (opt-in, narrow). The update is applied without a person present,
   only when it is the narrow kind described in section 5.

**Who fetches the manifest, and when.** At level 1 there is no background job. The manifest is fetched
only (a) when a person runs `sirven update --check`, and (b) by the menu bar app, which runs that same
command (not root) when it is opened and at most once a day while it stays open. Nothing starts at boot
or login on its own account. A scheduled job that fetches without anyone asking would be a startup item,
which needs a plan step and consent (section 4), so it is not part of level 1; whether to add one is
decision 2.

### Command-line install

`sirven update` (through the launcher, so it runs the kept copy) does: fetch the signed manifest, verify
it, download the archive for the named tag, verify its checksum from the manifest, unpack it into a
fresh root-owned temporary folder, and run that release's `install.sh` as an in-place upgrade. That is
the same path `bootstrap/sirven-bootstrap.sh` takes today, with the pin supplied by a verified manifest
instead of by the script. `install.sh` already knows how to replace the kept copy and rewrite the
launcher; the update adds a fetch-and-verify front end, not a new installer.

An npm install is a different channel. The npm client owns its upgrades (`npm update -g`), so
`sirven update` detects an npm-managed copy and only reports, never replaces it.

### Mac app

The app is a different artifact with a different channel: a signed disk image, not a package of shell
scripts. Its updates should be the standard Mac experience (Sparkle, section 7). The app and the command
line update independently, and each reports the other's version in its status line. The app never runs
`install.sh` itself and never gains root; changes to the machine stay with the command line and its
confirmation. The app's updater replaces only `Sirven.app`.

## 3. Trust chain for an update

Goal: a compromise of one place (the web server, the GitHub account, a laptop on the network) must not
be enough to run attacker code on a machine as root.

**Proposal: a signed release manifest, with the signing key held offline.**

- `release.sh` additionally produces `latest.json`: tag, archive checksum, a monotonically increasing
  release number, a "do not install below" release number, a list of revoked tags, and an expiry
  date a few weeks ahead. It is signed with an Ed25519 key (a modern public-key signature).
- Signing tool: `ssh-keygen -Y sign` and `-Y verify`. It is already on every Mac and nearly every Linux
  machine, so the updater gains no new dependency, and it supports hardware security keys, which is the
  best form of "held offline" for one maintainer. (minisign is the alternative; it adds an install step.)
- The public key is written in three places: inside the kept copy of the package, in the bootstrap
  script, and in the repository (printed in `docs/BOOTSTRAP.md` with its fingerprint). They are three
  copies of one key, not three independent anchors: whoever can change the repository can change all
  three for the next install. What they give is that each moment has its own copy (a new install, an
  existing install, a person comparing a fingerprint). The updater verifies with the copy it already
  trusts, never with a key fetched alongside the manifest. A non-root copy for the read-only check is in
  section 8.
- The manifest is published to the GitHub release and to cli.sirven.xyz. The updater may read either;
  signature verification, not the transport, is what makes it believable.

What each compromise now buys an attacker:

| Compromised | Can do | Cannot do |
|---|---|---|
| cli.sirven.xyz or its deploy | Serve a changed bootstrap script to new installs. Withhold or replay an old manifest to existing machines. | Make an existing install run an unsigned archive. Replay is bounded by the expiry date and the release number floor. |
| The GitHub account or release assets | Replace an archive, delete releases, change tags. | Produce a valid signature. A swapped archive fails its checksum from the signed manifest, and the update stops. |
| Both | Everything above, plus new installs run the attacker's script. | Update existing installs (they verify against the key they already hold). |
| The offline key | Everything. | n/a: this is why it stays offline and has a rotation path (below). |

Honest limits:

- **Machines installed before this exists cannot update themselves.** Nothing from `v0.2.0` carries a
  public key or an `update` command (section 1). Such a machine can never run the check. Moving it
  forward means running the bootstrap again, which is a fresh trust-on-first-use decision. This is
  decision 13.
- **A malicious change that Jose signs.** Signing proves who released, not that the release is good. A
  hostile pull request merged and then released, or a stolen laptop at signing time, produces a valid
  signature. The controls are the ordinary ones (review before merge, the critic step, the revoked list in
  section 6), not the signature.
- **First install is still trust on first use.** A new machine trusts whatever `curl` returns from
  cli.sirven.xyz over transport encryption. Signing does not fix that, because the script is what
  carries the key. Mitigation: the key fingerprint is also printed on the download page, in the
  repository, and in the npm package, so a careful person can compare. Pinning a stronger first-install
  story (for example install from npm, or from a Homebrew tap that locks a checksum) is a separate
  decision.
- **Key rotation and loss.** Needs a manifest signed by the old key that introduces the new one, and a
  documented recovery for a lost key (a new bootstrap and a fresh install; existing installs cannot
  be rescued remotely, by design). The rotation procedure should be written and rehearsed before the
  first signed release, not after.
- **Downgrade.** The updater refuses a release number lower than the installed one, so a replayed old
  manifest cannot reinstall a vulnerable build. Going back is always a local, owner-run action (section 6).
- **Freeze.** An attacker who blocks updates entirely is only caught by the expiry date. An expired
  manifest should make level 1 (check only) warn loudly ("no verified update information for N days"),
  not silently continue.

## 4. Consent: does an update go through the same confirmation?

Yes. An update changes the machine as an install does (it replaces root-run code), so it is a plan
and it ends in `plan_confirm_real_apply` like every other real change. Concretely:

- `sirven update --dry-run` prints the plan: from tag, to tag, the new files, and every step that
  differs from the installed record (new system steps, new permissions, new startup items).
- A person at a terminal types `yes`, or passes `--yes`. With no terminal and no `--yes` it applies
  nothing and exits with status 3, which is already the behavior of `plan_confirm_real_apply`.
- A changelog line from the signed manifest is shown with the plan, so the person is not approving a
  bare version number.

**How an unattended update squares with that.** The honest answer is that it does not, unless the
owner gave consent in advance, and that advance consent must be narrow:

- The owner turns on level 3 once, with a typed word (as `revoke` is typed for the kill switch). The
  grant is written to the audit log like any other grant change, shown by `sirven grant inspect` (which would list it), undone by
  `sirven update --auto off`, and removed by `revoke --all` and uninstall.
- It covers only **replacement of the kept copy by a newer verified release whose plan has the same
  step kinds as the installed record**: no new permissions, no new system user, no new network
  exposure, no new startup item, no change to what the agent may do. Any plan that adds one falls back
  to level 2: staged, announced, waiting for a typed `yes`.
- It never runs while the kill switch is engaged, never lowers any agent permission boundary, and never
  runs on a machine whose root-trust gate currently refuses the kept copy.
- The unattended runner itself is part of the install record (a scheduled job). A scheduled job is a
  startup item, so installing it is a plan step that needs the same confirmation, and uninstall removes it.

On a Mac, level 3 stays unavailable until the real macOS install check passes (parked for Jose), since
a Mac does not apply installs yet.

## 5. What the smallest unattended update looks like

Restating section 4 as a rule the code can check: *replace the kept copy and rewrite the launcher,
nothing else.* Everything else (new tier, new connector, new permission) is a plan the owner reads.
Releases that need more must say so in the signed manifest (`needs_review: true`), so the updater does
not have to infer it from a diff.

## 6. Rollback

- **Keep the previous kept copy.** Before moving the new copy into place, rename the old one to
  `/var/lib/sirven/package.previous` (complete, with its marker), keeping one generation. This changes
  two existing pieces, as a plan, not code:
  `layout_keep_package` today removes the old copy before moving the new one (`lib/layout.sh:275`), so
  that line becomes "remove any older `package.previous`, rename `package` to `package.previous`, move
  `package.new` into place", with a failure after the rename putting the old copy back. And uninstall
  removes only `package` (`layout_remove_package_copy`, `lib/layout.sh:324-325`) and removes the state
  directory only when it is empty (`layout_remove_directory`, `lib/layout.sh:300-307`), so without a
  matching undo step a leftover `package.previous` would keep the state directory on disk after
  uninstall. The install record gets a step for it, undone the same way. The existing
  rule that the kept copy must always be able to undo the install record (`docs/BOOTSTRAP.md`, "The copy
  kept after install") holds for both generations: a release may change the record only in ways it can
  also undo.
- **Health check, then commit.** After the swap, run the new copy's `grant inspect` (read-only, and the
  nearest thing to a status check that exists today). On failure,
  swap back automatically and report; the update counts as not applied. This is the only automatic
  rollback, and it only restores a copy that was working a minute earlier.
- **Owner-run rollback.** `sirven update --rollback` swaps back to `package.previous` with no network, still
  through the confirmation. This is deliberately separate from `sirven grant rollback`, which reverses
  an access grant (`bin/sirven`), so the two names must not be confused in help text.
- **Revocation.** The signed manifest's revoked list lets Jose retire a bad release: machines on it are
  told to move forward, and a rollback onto a revoked tag is refused.
- **App.** Sparkle has no built-in rollback. The appcast keeps previous disk images listed, the download
  page links the last known good one, and the app's saved data (`onboarding.json` carries a `version`)
  must stay readable by the previous release for one version.

## 7. What Sparkle would need for the app

Sparkle is the standard open-source updater for Mac apps outside the App Store. It needs:

1. **Developer ID signing and notarization.** This is the release path in `app/macos/build.sh` and
   `docs/DOWNLOAD-AND-ONBOARDING.md`; it is not available until Jose's Apple Developer membership,
   certificate, and notarization profile exist. An ad-hoc signed app can still verify Sparkle's own
   signatures, but Gatekeeper treats every first download as unknown, and I could not verify how Sparkle
   behaves on an unnotarized app in practice; it is not worth shipping to people in that state.
2. **The framework in the app.** Add Sparkle as a Swift package dependency of `app/macos/Package.swift`,
   embed and sign it with the hardened runtime in `build.sh`, and add an "update available" item to the
   menu bar (`app/macos/Sources/Sirven/MenuBarController.swift`). `Sirven.entitlements` is empty today
   (no exceptions); a non-sandboxed app needs none for Sparkle, but that must be checked on a real
   signed build. This adds third-party code to the app, which is a decision for Jose.
3. **An Ed25519 key for Sparkle** (`generate_keys`), separate from the manifest key in section 3. The
   public half goes in the app's property list (`SUPublicEDKey`); the private half stays in Jose's
   keychain. Every disk image in the appcast carries a signature made with it (`sign_update`).
4. **An appcast.** A static `appcast.xml` listing versions, minimum system version, the signed disk
   image URL and length, and release notes. Host it next to `site/download/` (the page already has a
   `release.json`; the appcast could be generated from the same data by `build.sh`). The feed URL
   (`SUFeedURL`) must be https and is hard to change once apps ship, like the bundle identifier
   (`xyz.sirven.app`, an open decision already).
5. **A consent surface that fits the app.** As I remember it, Sparkle asks the person whether to check
   automatically on the second launch, not the first, and offers to install each update (unverified: I did
   not read Sparkle's documentation or run it). That is the app's equivalent of section 4: the
   person says yes once, and updates replace only the app bundle, never the root-run package.

## 8. The smallest safe first step, with no Apple credentials

Ship level 1 for the command line, and a pointer for the app. No machine change, no Apple account.

1. `release.sh` writes and signs `latest.json` (needs only Jose's offline key, not Apple credentials).
2. **A place a non-root user can read.** The kept copy and its marker sit under the state directory,
   mode 0700 and owned by root (`lib/layout.sh:296-297`), so a non-root user and the menu bar app cannot
   read them. `install.sh` therefore also writes, as ordinary plan steps with undo, two small files in
   the policy directory `/etc/sirven`, which is mode 0755 and root-written (`lib/layout.sh:15,306`):
   `update/public-key` and `update/installed-release` (tag and release number). Root writes them at
   install and at every upgrade; uninstall removes them. They are read-only inputs to the check. The root
   `update` command never trusts them: it takes the key from the kept copy.
3. `sirven update --check`: fetch the manifest, verify the signature, expiry, and release number against
   those two files, and print "up to date" or "vX is available; to apply it: sudo
   /usr/local/sbin/sirven update". Read-only, no root, no confirmation needed. It is new; it does not
   exist today (section 1).
4. `sirven grant inspect` and install output show the line. The menu bar gets an "update available"
   item that runs the same check and opens the download page; the app does not download or install
   anything itself.
5. Tests: a fixed signed manifest in `tests/fixtures`, plus failure cases (bad signature, expired,
   lower release number, revoked tag, wrong signing namespace, file unreadable by the user). All can
   run in the existing harness without a real machine.

This delivers the part of "automatic" that matters most (a machine that cannot learn about a security
fix is the real risk) and also builds the trust chain every later level needs, while changing nothing
on any machine, except the two small files above on machines that install or upgrade after it ships.
It does not help machines installed from `v0.2.0` (section 3). Applying (levels 2 and 3), the app's
updater, and a scheduled job each come later.

## 9. Decisions only Jose can make

1. **Signing key.** Approve creating an Ed25519 release signing key, and say where it lives (hardware
   security key recommended) and who holds a backup. Nothing in sections 3, 6, or 8 can ship without it.
2. **Default level and trigger.** Is level 1 (check only) on by default, as proposed, fetching only when
   a person runs the check or the menu bar app is open? Or may there be a scheduled job that fetches on
   its own, which is a startup item and needs consent? Either way it makes a network request to
   cli.sirven.xyz or GitHub, a privacy choice as well as an engineering one.
3. **Is level 3 (unattended apply) wanted at all** before the real macOS install check, and if so is
   the "same step kinds only" rule in section 4 narrow enough?
4. **First install trust.** Accept trust on first use for `curl | bash`, or add a stronger first-install
   path (npm, or a Homebrew tap that locks a checksum)?
5. **Hosting of the manifest** (GitHub release, cli.sirven.xyz, or both), and who may deploy to
   cli.sirven.xyz.
6. **Rollback depth.** One kept previous generation, as proposed, or none or more?
7. **Apple Developer membership.** Approve the cost and set up the certificate and notarization profile
   (`docs/DOWNLOAD-AND-ONBOARDING.md`); Sparkle for the app is blocked on this.
8. **Sparkle itself.** Accept a third-party updater framework inside the app, or build a smaller
   check-and-open-the-download-page behavior and stay there?
9. **Bundle identifier and feed URL.** Final values for `xyz.sirven.app` and the appcast address, since
   both are hard to change after the first public release.
10. **npm channel.** When npm publishing is unparked, should an npm install ever self-update, or always
    defer to the npm client (proposed)?
11. **Revocation policy.** Who may add a tag to the revoked list, and does a revoked release force an
    announcement in the menu bar and `sirven grant inspect`?

12. **Manifest expiry window.** How long a signed manifest stays believable (a few weeks is proposed). Short
    catches a freeze sooner but warns loudly whenever Jose is away and cannot sign a fresh one.
13. **Existing installs.** Machines installed from `v0.2.0` have no key and no `update` command. Accept
    that they must re-run the bootstrap once (proposed), or ship a one-off `v0.2.x` bridge release that
    carries the key and the command, and say who is told.

## Not verified

No code was run for this note. These were not checked and should be before any of this is built:

- Sparkle on an unnotarized app, and when it asks about automatic checks (section 7).
- `ssh-keygen -Y` on every supported Linux distribution and on macOS. Signing needs a namespace chosen
  once (`-n`), and verifying needs an allowed-signers file plus the same namespace; neither is
  designed here.
- Whether `ssh-keygen -Y sign` can use a hardware security key for Ed25519 signing on Jose's machine
  (the key type that supports it is a security-key key type, not a plain Ed25519 file; the note's claim
  is untested).
- The exact step kinds in the install record (section 4); `lib/plan.sh:8-10` names two, `run` and `system`.
- That `grant inspect` is a sufficient health check for a rolled-forward copy (section 6).
