# Menu bar copy: hiding Tailscale's own menu bar item

Status: drafted for Jose's review, 2026-10-11. Nothing here ships until Jose approves it.
The app reads these words from `macos/menu-bar/Sources/SirvenMenuCore/MenuCopy.swift`; change both
together. The onboarding wizard (where the menu bar app is introduced) should reuse this text
rather than write its own.

## Where it appears

The menu item "Hide Tailscale's menu bar item…" in Sirven's menu, and the onboarding step that
introduces the menu bar app. It is offered, never assumed: nothing changes unless the person
flips the switch in System Settings themselves.

## The consent moment (macOS 26 and later)

**Title:** Make Sirven your one menu bar item for Tailscale?

**Body:**

> Sirven already shows Tailscale's connection, this device, and your exit node. If you like, you
> can hide Tailscale's own menu bar item so there is one place to look.
>
> Sirven can't hide it for you. macOS leaves that choice to you: in System Settings, Menu Bar,
> turn Tailscale off under "Allow in the Menu Bar".
>
> Tailscale keeps running either way. For things Sirven doesn't show, like logging in, switching
> accounts, or sending files, choose Open Tailscale in Sirven's menu. To bring Tailscale's item
> back, turn it on in the same place.

**Buttons:** Open Menu Bar Settings (opens System Settings at the Menu Bar pane) · Not Now

## Older macOS (before 26)

> This Mac's version of macOS has no switch for other apps' menu bar items. Tailscale's item
> stays, and Sirven shows the same controls alongside it.

**Button:** Done

## Questions for Jose

1. Is "Make Sirven your one menu bar item for Tailscale?" the right framing, or should the title
   lead with what the person gains ("One place for your connection")?
2. The body names three things the person loses from Tailscale's own menu (logging in, switching
   accounts, sending files). Keep all three, or shorten to "everything else"?
