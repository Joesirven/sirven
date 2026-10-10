# Design language reference - transitions.dev (standing standard for all projects)

Source: https://transitions.dev + https://transitions.dev/builder. Jose's directive (Oct 10, 3:08pm): "use this for future design work for all of my projects and work, including for the remotion videos." Standing standard, not a one-off. Applies to every site, app, deck, and video we design or build for Jose.

## What it is
transitions.dev is a motion system: a library of 43+ crafted UI transitions, named motion tokens, a component builder, and an agent/CI that scores motion quality. Its philosophy and token scale are the extractable standard; the library itself (npx transitions-agent) is usable tooling for web projects.

## Motion principles (the core)
- Every state gets motion. Nothing appears, disappears, or snaps without a transition.
- Name the animated properties. Never `transition: all`.
- Animate transform and opacity only (compositor). Animating layout or paint properties (mask-position, blur on repaint chains) is a defect.
- Every animation ships a prefers-reduced-motion fallback.
- Transitions are origin-aware: menus open from their trigger, cards resize from their own center.
- Close faster than open (e.g. 250ms open, 150ms close).
- Stagger grouped elements by 40ms, not all at once.
- Motion earns its place: it communicates structure, cause, or state - never decoration for its own sake.

## Token scale (use these exact values)
- Durations: stagger 40ms, micro 80ms, quick 150ms, fast 250ms, medium 350ms, slow 400ms, very-slow 500ms.
- Easings: smooth-out cubic-bezier(0.22, 1, 0.36, 1) (default for entrances); bounce cubic-bezier(0.34, 1.36, 0.64, 1) (playful pop); standard ease-out for exits; ease-in-out for state swaps.
- Distances: micro 4px, small 6px, base 8px, medium 12px, large 30px. Small travel distances; motion is felt, not watched.
- Scales: enter from 0.96-0.99, never from 0 or 0.5 for UI elements.
- Blurs: 2px, 3px, 8px - used sparingly as enter/exit softening, always paired with opacity.

## Visual language
- Type: Inter for body (16px, normal line-height). Display/headline: geometric sans ("Saans" on their site, 46px, weight 500, letter-spacing -0.23px). Roboto Mono for code and technical labels.
- Two moods, same system:
  - Light product surfaces: background #fdfdfd / stage #f9f9f9, text #0d0d0d, muted grays #6c6c6c / #767676 / #8f8f8f, white cards with hairline border rgba(0,0,0,0.06) and soft layered shadow (0 1px 3px rgba(0,0,0,0.04); larger: 0 4px 42px rgba(0,0,0,0.06) + 0 2px 6px rgba(0,0,0,0.05) + 1px ring).
  - Dark presentation shell: background #121212, white type, muted gray support text.
- One accent: blue #0073e5, hover #0064c8, soft tint rgba(0,115,229,0.09). Error #e23014. No gradient rainbows on UI chrome (gradients only as soft ambient washes in hero/marketing areas).
- Shapes: pill buttons, rounded cards, hairline dividers (#eeeeee range on light). Lots of space; dense ornament is a defect.
- Mood: precise, calm, crafted. The interface demonstrates quality through motion, not through decoration.

## Applied to Remotion videos
- Map the token scale to springs/easings: default entrance = smooth-out curve over 250-400ms; exits 150ms; stagger 40ms between grouped elements; travel distances 8-12px; enter scale 0.96-0.98.
- Type: Inter (body/captions) + geometric sans for display beats, weight 500, slight negative tracking.
- Panels: white cards, hairline borders, soft layered shadows, on either the light stage or the dark shell. One blue accent.
- Combines with docs/INSTALL-CLIP-BAR.md (Jose's reference video): that doc owns pacing and story structure; this doc owns motion tokens, type, and color. Together they are the demo standard.
