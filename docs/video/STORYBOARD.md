# Explainer video: script and storyboard

15 seconds, 1920x1080, 30 frames per second, exactly 450 frames. Source: `video/`. Render: `out/explainer.mp4`.

The project name on screen is a placeholder read from `project.json` (`name`). Renaming the project
re-renders the video with no source edits.

## Brief

Jose's direction (iMessage, 2026-10-09 11:35): show (1) the infra, (2) what setup and onboarding
feel like, (3) a demo of the features it ships with and auto-configures, (4) a few use cases agents
can do with it. Through line: you text your agent from your phone, and it starts a build on your
machine. Everything has to stay legible inside 450 frames, so each beat gets one idea, one caption,
and large type.

## Audio decision

Silent, with burned-in captions. Music is not trivial here (licensing plus a mix pass), and most
people watch a 15-second clip muted in a feed or a README anyway. Captions carry the story.

## Honesty note

This is a concept explainer for the target experience. The installer flags and permission level
names shown match the design in `docs/SCOPE.md` and `docs/PERMISSIONS.md`. Some features on screen
(Cloudflare transport, friend invite) are designed for the alpha but not all are built on day one;
`docs/SCOPE.md` says which. The video is not published anywhere until Jose reviews it.

## Visual system

- Background: near-black graphite `#0B0D10`, one raised surface `#14181D`, hairlines `#262C33`.
- Ink: `#E8ECEF` primary, `#8A949E` secondary.
- One accent, signal green `#3DDC84` (connected, allowed, passing). Red `#FF5C5C` only for "denied".
  Amber `#F5B544` only for the one-time interactive step.
- Type: Inter (captions, labels), JetBrains Mono (terminal, commands, audit log). Bundled from npm
  (`@fontsource`), so rendering never depends on system fonts.
- Minimum on-screen size: captions 60px, body 34px, terminal 30px. Nothing smaller than 24px.
- Persistent layout: phone on the left third (the through line), the working area on the right two
  thirds. A beat counter (`1 infra · 2 setup · 3 ships with · 4 use cases`) sits top-right and
  highlights the current beat.
- Motion: spring-in and fade, no spins or bounces. Text holds at least 1.2 seconds once fully in.

## Beats

| # | Time | Frames | Beat |
|---|---|---|---|
| 0 | 0:00.0 to 0:01.5 | 0 to 44 | Hook: the text |
| 1 | 0:01.5 to 0:04.5 | 45 to 134 | The infra |
| 2 | 0:04.5 to 0:07.5 | 135 to 224 | Setup and onboarding |
| 3 | 0:07.5 to 0:11.0 | 225 to 329 | Ships with, auto-configured |
| 4 | 0:11.0 to 0:13.5 | 330 to 404 | Use cases and the payoff |
| 5 | 0:13.5 to 0:15.0 | 405 to 449 | End card |

### Beat 0. Hook: the text (frames 0 to 44)

- Visual: phone on the left, a chat with "my agent". A blue outgoing bubble types in and sends:
  "fix the flaky login test and push a branch". Right side is empty, dark.
- On-screen caption (bottom): **Text your agent from anywhere.**
- Timing: bubble fully in by frame 24, caption in at frame 10.

### Beat 1. The infra (frames 45 to 134)

- Visual: a left-to-right path draws on the right side, four nodes connected by a line:
  `your phone` → `agent runtime` (sub-label `Claude Code · Codex · Pi`) → `private tunnel`
  (sub-label `Tailscale · Cloudflare Tunnel`) → `your machine` (sub-label `macOS · Linux`).
  Under `your machine`, a small locked box: `service user: agent (no sudo)`.
  A green dot (the message from beat 0) travels the line from phone to machine.
- Small label under the tunnel node: `key-based · no open ports`.
- Caption: **1 · The infra: a private path to your machine.**
- Beat counter highlights "1 infra".

### Beat 2. Setup and onboarding (frames 135 to 224)

- Visual: the right side becomes a terminal window. One command types in:
  `./install.sh --runtime claude-code --transport tailscale --level builder`
  Output lines appear one per ~8 frames:
  - `◆ one-time: approve this machine in your browser` (amber, then turns green ✓)
  - `✓ tunnel up · auth key stored, key-based from now on`
  - `✓ created service user  agent`
  - `✓ applied level  builder  to ~/code`
  - `✓ runtime  claude-code  connected`
- Caption: **2 · Set up once. Keys only after that.**
- Beat counter highlights "2 setup".

### Beat 3. Ships with, auto-configured (frames 225 to 329)

- Visual: the terminal shrinks to the top; below it, four feature tiles pop in, staggered by 6 frames:
  - **Preset levels**: chips `observer` `builder` `operator`, `builder` lit.
  - **Per-path access**: `~/code  read · write` (green) and `~/.ssh  denied` (red).
  - **Audit log**: two live lines, `12:04 agent  git checkout -b fix/login-flake` and
    `12:04 agent  read ~/.ssh/id_ed25519  DENIED`.
  - **Kill switch**: a toggle that reads `revoke all access: one command`.
- Phone (left) shows a typing indicator from the agent: work is happening.
- Caption: **3 · Safe defaults, configured for you.**
- Beat counter highlights "3 ships with".

### Beat 4. Use cases and payoff (frames 330 to 404)

- Visual: the phone receives the agent's reply bubble (grey, incoming):
  "Done. 42 tests pass. Pushed fix/login-flake." with a green check.
  The right side shows four use-case cards in a 2x2 grid, staggered by 5 frames:
  - `Ship a fix from your phone`
  - `Run the nightly build on your own box`
  - `Lend a friend's agent read-only access`
  - `Triage logs on your home server`
- Caption: **4 · Your agent, working on your machine.**
- Beat counter highlights "4 use cases".

### Beat 5. End card (frames 405 to 449)

- Visual: everything fades out except a centered wordmark: the project name (from `project.json`)
  in JetBrains Mono with a blinking block cursor. Below: the tagline from `project.json`.
  Below that, small: `open source · macOS + Linux · Claude Code, Codex, Pi`.
- No URL on screen (nothing is public yet).

## Acceptance checks

- `video/` renders exactly 450 frames at 1920x1080, 30 frames per second.
- At least six extracted frames (one per beat) inspected for legibility, alignment, cropping, pacing.
- The project name appears only through `project.json`.
