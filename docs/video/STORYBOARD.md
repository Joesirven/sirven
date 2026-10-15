# Explainer video: script and storyboard v3

45 seconds, 1920x1080, 30 frames per second, exactly 1350 frames (0 through 1349).
This replaces the v2 visual and timing specification, including its short-hold exceptions.
Source: `video/`. Existing reference: `out/explainer-sirv.mp4` and `out/frames/`.
This document is the design handoff; implementation and rendering belong to the implementer.

## Brief

Show the target experience: text your agent from your phone, start a build on your own
machine, and receive the completed fix. Preserve the four chapters: infrastructure, setup,
what ships with it, and use cases. The positioning is the value in `project.json.positioning`:
“the shadcn of agent access: install it, own it, no hosted middleman”. Express ownership with
the machine and setup imagery; do not add this long positioning sentence to the end card.

The visual tone is minimalist, light, calm, and readable. One focal event at a time. Give
features individual reading time instead of accumulating a dashboard. The phone opens and
closes the story; it does not occupy a third of every technical scene.

## Audio decision

Stay silent, with burned-in captions. No narration, music, notification sounds, or typing
sounds. Every story point must work muted. Captions remain still while the demonstration
changes. The slogan is its own large caption; the end card has no caption.

## Honesty note

This is a concept explainer for the target experience. Commands are illustrative, not a
recording of a finished product. Installer flags and permission level names reflect the design
in `docs/SCOPE.md` and `docs/PERMISSIONS.md`. Some features on screen (Cloudflare transport,
friend invite, completed setup and revocation) are designed but not all are built on day one;
`docs/SCOPE.md` says which. The phone channel relies on an existing remote client; this
package does not build a messaging service. Setup is a compressed illustration, not a claim
that runtime login or administrator approval is unnecessary. Audit copy describes install and grant
changes only; session and command logging is planned, not built yet. The video is not published anywhere until
Jose reviews it.

Keep `Concept preview` visible in secondary text, 28px, at x=120, y=64 throughout beats
0–4. This label is static, not an animated watermark. Remove it for the slogan and end card.

## Brand data contract

All rendered brand strings come from repository-root `project.json`, through the existing
project data import. No literal name, subtitle, slogan, or fallback copies in video source.
Expected values, quoted here for design review only:

- `name`: `Sirv`
- `subtitle`: `secure agent access`
- `slogan`: `unlock your personal agent's full potential`

The implementer must add the missing `slogan` field to `project.json`; this document-only
handoff does not modify that file. Render the slogan from that value, with layout wrapping
only, no inserted punctuation or capitalization changes. If positioning is ever displayed,
read `positioning` from the same file. The fixed platform line is specified below.

## Visual system

### Palette

| Role | Hex | Use |
|---|---|---|
| Background | `#F7F6F2` | Warm-white full canvas |
| Surface | `#FFFFFF` | Phone, command sheet, single feature card |
| Hairline | `#D8D8D2` | 2px borders and diagram connectors |
| Text | `#202320` | All principal text and commands |
| Secondary text | `#60665F` | Labels, metadata, supporting copy |
| Accent | `#365BC4` | Selected builder outline/text, sent bubble, traveling dot |

Only one chromatic accent. No red is necessary: `denied` is explicit near-black text with a
small outlined lock, never encoded by color alone. There is exactly one denied example,
in per-path access. No amber, green, gradients, glow, colored window controls, or tinted
background wash. White text is permitted on the solid accent outgoing bubble. Success uses
a near-black check and plain language. No shadows anywhere.

### Typeface and formatting

One family: IBM Plex, using IBM Plex Sans and its matching IBM Plex Mono cut.
Bundle npm `@fontsource/ibm-plex-sans` weights 400 and 600 and
`@fontsource/ibm-plex-mono` weights 400 and 500. Import local package font assets and wait
for all used faces before rendering; no network font loading and no silent system fallback.

| Role | Size / line height | Face / weight |
|---|---|---|
| End name | 160px / 176px | Sans 600 |
| Slogan | 88px / 104px | Sans 600 |
| Caption | 64px / 76px | Sans 600 |
| Feature and use-case heading | 56px / 68px | Sans 600 |
| End subtitle | 48px / 60px | Sans 400 |
| Phone messages, feature body | 40px / 52px | Sans 400 |
| Diagram titles | 40px / 48px | Sans 600 |
| Commands, paths, log entries, level chips | 32px / 44px | Mono 400; selected level 500 |
| Diagram detail, setup output, end platform line | 32px / 44px | Sans 400 |
| Chapter label, concept label | 28px / 36px | Sans 400 |

Minimum anywhere is 28px in this design, exceeding the absolute 24px floor. Do not shrink
text to solve overflow. Wrap at the specified breaks or enlarge its container. Letter spacing
is 0 except name and slogan at -0.02em. Sentence case throughout, with literal command
identifiers preserved. Labels have no uppercase transformation or tracked-out styling.
Commands sit on a white bordered sheet with the same padding and radius as feature cards;
no fake traffic lights, prompt glyph, cursor, syntax colors, or character-by-character typing.

### Grid and composition

- Canvas safe area: x=120–1800, y=64–1008. Twelve columns within 1680px, each 118px,
  with eleven 24px gutters. Base spacing unit 8px; use 16, 24, 32, 48, 64, and 96px gaps.
- Static chapter label at x=120, y=120: `1 infra`, `2 setup`, `3 ships with`, or `4 use cases`.
  Show only the current label. No persistent progress pills or active-state animation.
- Main stage: x=120, y=192, width=1680, height=648. Captions centered in x=120–1800,
  y=896–1008. Caption line box starts at y=908. All regular captions fit one line at 64px.
- Phone: x=650, y=192, width=620, height=648; radius 40px, 2px hairline, white surface.
  Header `my agent` at 40px, secondary `on your machine` at 32px. Internal padding 40px.
  No status bar, app logo, keyboard, composer, or decorative avatar. Bubbles max width 500px,
  padding 24px, radius 20px, gap 24px. Hook and payoff use exactly the same geometry.
- Full command sheet: x=262, y=216, width=1396, height=600; padding 48px, radius 24px.
- Single feature or use-case card: x=404, y=280, width=1112, height=456;
  padding 48px, radius 24px. Titles above body with 24px separation. No card grid.
- Diagram: four 360px-wide nodes at x=120, 560, 1000, 1440; y=336, height=288.
  Node padding 24px, radius 24px. Connectors run between node edges at y=468.
  Their paths are static; the dot travels only in the gaps and is occluded behind nodes.
- Level chips: radius 12px, padding 12px 20px, 24px gaps. Builder uses accent outline and
  accent text on white, not a second fill color. All other outlines use hairline.

### Motion and sequencing

All frame ranges below are inclusive. Time-table endpoints are exclusive; for example,
0:04.0 begins frame 120. Interpolate entrance endpoints from the first to last listed frame.

An entrance is a 12-frame opacity reveal, 0 to 1, with cubic-bezier(0.22, 1, 0.36, 1).
No position, scale, spring, bounce, zoom, or background animation. One semantic object
may reveal as a unit (a bubble, a node with its labels, a single card); never stagger its
children. This is one animation track, not several coordinated tracks.

Every entrance is followed by at least 36 completely static frames (1.2 seconds) before
any next animation. Most complex copy gets longer. Caption, chapter label, and static
scene scaffolding appear by a hard cut at a beat boundary, before the first entrance
begins. No caption entrance/exit animation. No crossfades: outgoing content is removed
by a cut; the next object then reveals. Scene cuts are editorial boundaries, not extra
animation tracks. No looping dots, blinking cursor, animated counters, terminal typing,
auto-scrolling, or breathing highlights. Outside listed entrance/travel ranges, every pixel
must remain static. Retained content never animates while a new object enters.

## Beats

| # | Time | Frames | Beat |
|---|---|---|---|
| 0 | 0:00.0 to 0:04.0 | 0 to 119 | Hook: the text |
| 1 | 0:04.0 to 0:11.0 | 120 to 329 | The infra |
| 2 | 0:11.0 to 0:19.0 | 330 to 569 | Setup and onboarding |
| 3 | 0:19.0 to 0:29.0 | 570 to 869 | Ships with, auto-configured |
| 4 | 0:29.0 to 0:38.0 | 870 to 1139 | Use cases and the payoff |
| 5 | 0:38.0 to 0:42.0 | 1140 to 1259 | Slogan |
| 6 | 0:42.0 to 0:45.0 | 1260 to 1349 | End card |

### Beat 0. Hook: the text

Caption: **Text your agent from anywhere.**

1. Frames 0–11: static phone shell, header and caption. Empty conversation. Nothing animates.
2. Frames 12–23: reveal one accent outgoing bubble, white text:
   `fix the flaky login test` / `and push a branch`. Slash here and below denotes a visual
   line break, not a rendered character. No typing effect and no separate send animation.
3. Frames 24–119: hold the sent message completely still. No reply yet.

### Beat 1. The infra

Caption: **1 · A private path to your machine.**

1. Frames 120–131: cut to the diagram. First node is already static: `your phone`, detail
   `your existing remote client`. Chapter and caption are static. Connectors are static.
   Other node positions are empty. This is the opening reading pause, not an entrance.
2. Frames 132–143: reveal node two, `agent runtime`, detail `Claude Code · Codex · Pi`
   (wrap after `Code ·` if required; preserve text). Frames 144–179: hold.
3. Frames 180–191: reveal node three, `private tunnel`, details on separate lines
   `Tailscale · Cloudflare Tunnel` and `key-based access`. Wrap transport names onto two
   lines as needed. Frames 192–227: hold.
4. Frames 228–239: reveal node four, `your machine`, details `macOS · Linux` and
   `service user: agent` / `no administrator rights`. Frames 240–275: hold.
5. Frames 276–293: one 16px accent dot travels left to right along the connector path,
   from the phone's right edge to the machine's left edge, linear easing. No node lighting,
   line drawing, or label changes. At frame 294 the dot is occluded by the machine.
6. Frames 294–329: hold the complete diagram. This is a conceptual access path, not a
   deployment topology requiring the runtime to be hosted between the phone and tunnel.

### Beat 2. Setup and onboarding

Caption: **2 · Set up once. Connect with keys.**

All content accumulates on the command sheet; previous lines stay still. At frame 330,
cut to the empty sheet with static title `On your machine` at 32px with a 44px line height at y=264. The command starts at y=332.
Use the same reserved line positions throughout; no shifting when output arrives.

1. Frames 330–341: reveal the complete two-line command as one object:
   `./install.sh --runtime claude-code \` / `  --transport tailscale --level builder`.
   Frames 342–401: hold (60 frames).
2. Frames 402–413: reveal the next output line at y=452:
   `Approve this machine in your browser`.
   Frames 414–449: hold. No amber prompt or animated browser simulation.
3. Frames 450–461: reveal the next line at y=520:
   `Approved · future connections use keys`.
   Frames 462–497: hold. The earlier approval instruction remains unchanged.
4. Frames 498–509: reveal one completion block at y=588, three 44px lines:
   `Service user: agent · builder access to ~/code`
   / `Claude Code connected`
   / `Build started on your machine.`
   Frames 510–569: hold (60 frames). This explicit build-start status links the phone
   request to the eventual reply. Setup is explanatory context, not a live installation trace.

### Beat 3. Ships with, auto-configured

Caption: **3 · Safe defaults, configured for you.**

Each event replaces the previous card by a cut, then reveals one complete card. No phone,
no terminal remnant, no accumulating feature tiles. All text below is verbatim.

1. Frames 570–581: reveal `Preset levels`, with chips `observer`, `builder`, `operator`.
   Builder is selected from its first visible frame. Body: `Choose a level. Scope it to a path.`
   Frames 582–641: hold (60 frames).
2. Frames 642–653: reveal `Per-path access`, with two aligned rows:
   `~/code` paired with `read · write`; `~/.ssh` paired with `denied` and an outlined lock.
   Both rows use near-black text. Frames 654–713: hold (60 frames).
3. Frames 714–725: reveal `Audit log`, body `Install and grant changes, recorded.`
   Below, one Mono entry, explicitly broken across two lines:
   `12:04:07 agent` / `git checkout -b fix/login-flake`.
   Frames 726–785: hold (60 frames). No second denied example and no live log updates.
4. Frames 786–797: reveal `Kill switch`, Mono command `revoke --all`, then body
   `Revoke every key. End every session.` / `Lock the service user.`
   Frames 798–869: hold (72 frames). Show the capability; do not execute it or animate
   a toggle, which would contradict the still-running build and its later reply.

### Beat 4. Use cases and the payoff

Caption: **4 · Your agent, working on your machine.**

Each use case is one centered card with a single title (56px), no subtitle or decorative
number. Wrap titles to two lines where required; retain wording. The phone returns only
for the reply. The chapter label and caption remain still throughout.

1. Frames 870–881: reveal `Ship a fix from your phone`.
   Frames 882–917: hold (36 frames).
2. Frames 918–929: replace with `Run the nightly build on your own machine`.
   Frames 930–965: hold (36 frames).
3. Frames 966–977: replace with `Lend a friend's agent read-only access`.
   Frames 978–1013: hold (36 frames).
4. Frames 1014–1025: replace with `Triage logs on your home server`.
   Frames 1026–1061: hold (36 frames).
5. Frames 1062–1073: cut to the static phone shell and original outgoing message, in
   the same positions as the hook. Reveal only the incoming white, hairline-bordered
   bubble below it: `Done. 42 tests pass.` / `Pushed fix/login-flake.`
   A near-black check is part of this same bubble, not a separately animated mark.
   Frames 1074–1139: hold (66 frames). Keep the branch name in Sans, matching all chat text.

### Beat 5. Slogan

Caption (the sole on-screen text, sourced from `project.json.slogan`):
**unlock your personal agent's full potential**

1. Frames 1140–1151: cut away the phone and all chapter/concept/caption chrome. Reveal
   the slogan as one two-line text object, centered within x=240–1680, y=400–608:
   `unlock your personal agent's` / `full potential`. Sans 600, 88px, near-black.
   This replaces the bottom caption; do not repeat it at the bottom or add a product name.
2. Frames 1152–1259: hold (108 frames). No accent underline or additional flourish.

### Beat 6. End card

No caption. Fixed content only:

- `Sirv`, from `project.json.name`.
- `secure agent access`, from `project.json.subtitle`.
- `open source · macOS + Linux · Claude Code, Codex, Pi`.

1. Frames 1260–1271: cut away the slogan; reveal the complete centered end-card lockup
   as a single object. Name line box y=350–526 (160px), subtitle y=558–618 (48px), platform
   line y=658–702 (32px). All three centered on x=960; name and subtitle near-black,
   platform line secondary. No prefix glyph and no cursor, so there is no baseline defect.
2. Frames 1272–1349: hold the complete card (78 frames). End on the intact card without
   fading to black. No slogan, URL, install command, concept label, or additional call to action.

## Acceptance checks

- Implementation renders exactly 1350 frames, 0–1349, at 1920x1080 and 30 frames per
  second: 45.0 seconds. Seven beats cover every frame once, with no gaps or overlaps.
- Keep the beat table's four-column row syntax unchanged so the existing table reader can
  parse it. Update `video/src/timeline.js` and the old 450-frame assertion in
  `video/tests/timeline.test.mjs` during implementation. This document handoff intentionally
  precedes that code update; the old timeline tests will not match v3 yet.
- Caption values match the bold text above, exactly one per beat except the end card.
  The slogan caption value is derived from project data and rendered only in its hero position.
- `project.json` supplies name, subtitle, and slogan. Implementer adds the missing slogan,
  extends the brand-source checks to subtitle and slogan, and verifies no hard-coded brand
  strings or fallback copies enter video source.
- All fonts resolve from the specified npm packages with the network unavailable; verify
  font readiness for every weight. No Inter/JetBrains leftovers or substituted glyph fonts.
- Only one animation track is active at any frame. Validate listed event intervals, including
  cuts, and inspect transitions in motion; still frames alone cannot certify sequencing.
  Each reveal gets at least 36 static frames before the next event; no v2 hold exceptions.
- All specified colors, typography, dimensions, copy, and line breaks are followed. No text
  under 28px, no cropping, no clipped line boxes, and no unexplained abbreviations in copy.
- Inspect full-size stills and a 480px-wide preview for phone readability. Captions and primary
  messages must read without zooming. Supporting command details remain secondary;
  do not reduce type to pack in more text.
- Director should send stills at frames 60, 312, 540, 612, 684, 756, 834, 900, 948, 996,
  1044, 1110, 1200, and 1320 for design review. Also inspect boundary frame pairs
  119/120, 329/330, 569/570, 869/870, 1139/1140, and 1259/1260.
- Confirm the request, visible build-start status, and exact payoff branch form one story.
  Keep the concept qualification and scope limitations; do not depict revocation occurring
  during the successful build. Jose is the final reviewer. Nothing public.

## Deliberate trade-offs

The longer cut trades feed brevity for reading time. Removing the persistent phone and
multi-card feature grid gives each technical idea space. Commands reveal whole rather than
imitating typing. Use-case copy is reduced to one title per card. One accent and explicit
`denied` text remove the need for semantic traffic-light colors. The slogan receives four
seconds alone; the fixed end card remains uncluttered for three seconds.
