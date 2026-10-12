# The menu bar app

Sirven on macOS lives in the menu bar and nowhere else: no Dock icon, no main window. One click
on the menu bar item opens a small menu with Sirven's state and the Tailscale settings Sirven
cares about. The menu ships inside the one signed app, `Sirven.app` from `app/macos/` (see
`docs/DOWNLOAD-AND-ONBOARDING.md`); there is no separate menu bar app. `macos/menu-bar/` is a Swift
package holding the library `SirvenMenuCore` (the Tailscale client, the state provider, and the
menu model) and its tests. The AppKit side, `MenuBarController`, lives in the signed app at
`app/macos/Sources/Sirven/MenuBarController.swift`.

## What the menu shows

```
# Sirven
  Tier: Solo >                      Solo checked; Neighborly and Co-op shown, not choosable yet
  Agent: working on comparing flights
  Keep awake: on for comparing flights, since 2:00 PM
  ---
  Tailscale: connected
  This device: laptop >             copy the tailnet name or an address; tailnet and login shown
  Exit node: home-server >          No exit node, then each device that offers to be one
  Disconnect                        Connect when disconnected; Log in with Tailscale when logged out
  ---
  Keep awake settings…
  Hide Tailscale's menu bar item…
  Open Tailscale
  ---
  Quit Sirven
```

`Sirven --print-menu` (the signed app's executable) prints exactly this from live state, read-only, and exits.

Design: the native macOS menu, system font, one semibold heading, quiet gray lines for state and
plain items for actions. No custom colors or ornament. The menu bar icon is a template image, a
ring with a dot at its center, the same mark the onboarding wizard and the app icon draw, so macOS
tints it for every menu bar appearance.

## Tailscale: read and change through its own command-line tool

Sirven never scrapes Tailscale's interface, edits its preferences or policies, or modifies its
installation. Every read and change goes through Tailscale's command-line tool:

| What | Command |
|---|---|
| Connection, this device, exit nodes | `tailscale status --json` (standard output only; the version warning on standard error is ignored) |
| Connect, disconnect | `tailscale up`, `tailscale down` |
| Choose an exit node, stop using one | `tailscale set --exit-node=<address>`, `tailscale set --exit-node=` |

The tool is found in this order: `SIRVEN_TAILSCALE` (tests point it at a fake), the copy inside
`/Applications/Tailscale.app` (it always matches the running Tailscale), then `tailscale` in
`/opt/homebrew/bin` or `/usr/local/bin`. Calls run off the main thread on one serial queue with an
eight-second timeout. The menu refreshes when it opens and after every change. When Tailscale
refuses a change, the menu shows Tailscale's own words on a "That did not work:" line.

Tailscale's local API was considered and not used directly: the command-line tool already
handles each Tailscale build's local interface, so Sirven depends on one documented surface.

The app must not be sandboxed: a sandboxed app cannot start Tailscale's command-line tool. The
download and onboarding pipeline needs to sign it with the hardened runtime and without the App
Sandbox entitlement.

## Hiding Tailscale's own menu bar item: the gap and the options

Jose's goal is that Sirven is the single menu bar surface for this. One app cannot remove
another app's menu bar item, so the question was whether a supported switch exists.

**What was checked (2026-10-11, Tailscale 1.102.4, macOS 26.6.2):**

- Tailscale's documented system policies ([kb/1315](https://tailscale.com/kb/1315/mdm-keys)) have
  `HideDockIcon` (the Dock icon, not the menu bar item), `ExitNodesPicker`, and `TestMenu`. None
  hides the menu bar item.
- Tailscale's own app modes are "menu bar only" and "app plus menu bar". Both keep the menu bar
  item. There is no mode without it.
- Tailscale's preference keys on this Mac hold onboarding and window state only, nothing for the
  menu bar item.
- macOS 26 added a user-facing switch: System Settings, Menu Bar, "Allow in the Menu Bar", one
  switch per app. Only the person can flip it; there is no supported interface for another app to
  flip it.

**What is built:** the supported route. "Hide Tailscale's menu bar item…" opens a consent moment
(copy in `copy/menu-bar-tailscale.md`) that explains the switch, what the person keeps and loses,
and how to undo it, then opens System Settings at the Menu Bar pane
(`x-apple.systempreferences:com.apple.ControlCenter-Settings.extension`). On macOS before 26 it says
plainly that the item stays. "Open Tailscale" stays in Sirven's menu so logging in, switching
accounts, and sending files are one click away once Tailscale's item is hidden.

**What is not done and will not be:** stopping Tailscale's process, writing Tailscale's or
Control Center's preferences, setting Tailscale's administrator policies, or driving System
Settings through accessibility scripting. Each is either unsupported, a change to Tailscale's
configuration, or trickery against another app's interface.

**Options for Jose:**

1. **Ship the assisted step as built** (recommended). One switch, flipped by the person, with
   consent copy. Works today on macOS 26 and later.
2. **Ask Tailscale for a supported setting.** A draft request is below, held for Jose's review;
   it has not been posted.
3. **Accept the duplicate on macOS before 26.** Sirven shows the same controls next to
   Tailscale's item. Requiring macOS 26 just for this is not worth it.

Draft feature request to Tailscale (not sent):

> **macOS: a supported setting to hide the menu bar item.** Apps that build on Tailscale, like a
> personal agent's network layer, show Tailscale's connection and exit node in their own menu bar
> item through the command-line tool. Today Tailscale's own item can only be hidden through
> System Settings, Menu Bar, so these people see two items for one connection. A system policy
> key (for example `HideMenuBarItem`, alongside `HideDockIcon`) or an app setting would let them
> keep one, with Tailscale still reachable from the app itself.

## Tier, agent, and keep-awake state

The menu reads these through one small provider (`SirvenStateProvider`), so the runtime and the
keep-awake feature plug in their own sources without the menu changing. Until they land, the app
reads a JSON file, `~/Library/Application Support/sirven/menu-state.json` (or `SIRVEN_MENU_STATE`).
A missing file reads as a fresh install: Solo, agent not connected, keep awake off.

```json
{
  "tier": "solo",
  "agent": { "activity": "working", "task": "comparing flights" },
  "keepAwake": { "held": true, "reason": "comparing flights", "since": "2026-10-11T14:00:00Z" }
}
```

`activity` is one of `not-connected`, `idle`, `working`, `waiting-for-you`. `tier` is one of
`solo`, `neighborly`, `co-op`.

Only Solo is choosable in the tier submenu. Neighborly and Co-op carry other people's traffic, and
the ship gates hold peer routing back until attestation and the site-allowlist review workflow
work end to end. "Tier settings…" and "Keep awake settings…" are the entry points for the tier
dial and the keep-awake status surface. Until those surfaces exist, each opens a short note that
it is coming.

## Build, test, run

```
make app                builds dist/macos/Sirven.app, the one signed bundle, menu included (ad hoc signature locally)
make test-menu-bar      swift test: parsing, the command-line tool calls against a fake, and the menu as text
open dist/macos/Sirven.app
```

The bundle identifier is the signed app's: `xyz.sirven.app`, a placeholder until Jose chooses
the final one (see the open decisions in `docs/DOWNLOAD-AND-ONBOARDING.md`). The keep-awake helper
trusts that same identifier as its host app. The menu copy in `MenuCopy.swift` still says
"Sirven" in prose.

Changing actions (connect, disconnect, exit node) are tested against
`Tests/SirvenMenuCoreTests/Fixtures/fake-tailscale.sh`, never against a real tailnet. The
fixtures are synthetic: no real device names, addresses, or logins.

## Verified so far

- 23 Swift tests pass on the MacBook.
- `--print-menu` against the real Tailscale 1.102.4 reads connection, this device, tailnet,
  login, and the one exit node offered (read-only).
- The built app runs, and macOS reports it as an agent app (`lsappinfo` type `UIElement`): no
  Dock icon.

Not yet verified by hand, for Jose to check on his Mac (the build machine reaches the
coordinator over the same tailnet, so changing Tailscale was not run here):

1. Open the app. The ring icon appears in the menu bar, the menu opens, and each submenu (Tier,
   This device, Exit node) draws.
2. Choose an exit node, and see Tailscale's own app agree. Choose No exit node.
3. Disconnect, then Connect.
4. Choose "Hide Tailscale's menu bar item…", then Open Menu Bar Settings. System Settings opens
   at the Menu Bar pane.
5. In that pane, Tailscale appears under "Allow in the Menu Bar", and turning it off hides
   Tailscale's item. The whole suppression route depends on this step.
6. Choose Open Tailscale, and Tailscale's window opens.
