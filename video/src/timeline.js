// Frame plan for the explainer. Mirrors the beat table and motion rules in docs/video/STORYBOARD.md.
// Every animated interval lives in EVENTS; Explainer.jsx reads only from here, so the data is the truth.

export const VIDEO = { width: 1920, height: 1080, fps: 30, durationInFrames: 1350 };

// Frame ranges are inclusive. A null caption means the beat has no bottom caption:
// the slogan beat renders the project data slogan as its hero text (see Explainer.jsx), the end card has no text caption.
export const BEATS = [
  { id: "hook", n: 0, from: 0, to: 119, name: "Hook: the text", caption: "Text your agent from anywhere.", chapter: null },
  { id: "infra", n: 1, from: 120, to: 329, name: "The infra", caption: "1 · A private path to your machine.", chapter: "1 infra" },
  { id: "setup", n: 2, from: 330, to: 569, name: "Setup and onboarding", caption: "2 · Set up once. Connect with keys.", chapter: "2 setup" },
  { id: "features", n: 3, from: 570, to: 869, name: "Ships with, auto-configured", caption: "3 · Safe defaults, configured for you.", chapter: "3 ships with" },
  { id: "usecases", n: 4, from: 870, to: 1139, name: "Use cases and the payoff", caption: "4 · Your agent, working on your machine.", chapter: "4 use cases" },
  { id: "slogan", n: 5, from: 1140, to: 1259, name: "Slogan", caption: null, chapter: null },
  { id: "end", n: 6, from: 1260, to: 1349, name: "End card", caption: null, chapter: null },
];

export const REVEAL_FRAMES = 12;
export const MIN_HOLD_FRAMES = 36;
export const REVEAL_EASING = [0.22, 1, 0.36, 1];

// Every animated interval, inclusive. "reveal" is a 12-frame opacity reveal; "travel" is the dot.
export const EVENTS = [
  { id: "hook-bubble", beat: "hook", kind: "reveal", from: 12, to: 23 },
  { id: "infra-runtime", beat: "infra", kind: "reveal", from: 132, to: 143 },
  { id: "infra-tunnel", beat: "infra", kind: "reveal", from: 180, to: 191 },
  { id: "infra-machine", beat: "infra", kind: "reveal", from: 228, to: 239 },
  { id: "infra-dot", beat: "infra", kind: "travel", from: 276, to: 293 },
  { id: "setup-command", beat: "setup", kind: "reveal", from: 330, to: 341 },
  { id: "setup-approve", beat: "setup", kind: "reveal", from: 402, to: 413 },
  { id: "setup-approved", beat: "setup", kind: "reveal", from: 450, to: 461 },
  { id: "setup-complete", beat: "setup", kind: "reveal", from: 498, to: 509 },
  { id: "feature-levels", beat: "features", kind: "reveal", from: 570, to: 581 },
  { id: "feature-paths", beat: "features", kind: "reveal", from: 642, to: 653 },
  { id: "feature-audit", beat: "features", kind: "reveal", from: 714, to: 725 },
  { id: "feature-kill", beat: "features", kind: "reveal", from: 786, to: 797 },
  { id: "use-ship", beat: "usecases", kind: "reveal", from: 870, to: 881 },
  { id: "use-nightly", beat: "usecases", kind: "reveal", from: 918, to: 929 },
  { id: "use-friend", beat: "usecases", kind: "reveal", from: 966, to: 977 },
  { id: "use-triage", beat: "usecases", kind: "reveal", from: 1014, to: 1025 },
  { id: "use-reply", beat: "usecases", kind: "reveal", from: 1062, to: 1073 },
  { id: "slogan", beat: "slogan", kind: "reveal", from: 1140, to: 1151 },
  { id: "endcard", beat: "end", kind: "reveal", from: 1260, to: 1271 },
];

export const beat = (id) => BEATS.find((b) => b.id === id);
export const beatAt = (frame) => BEATS.find((b) => frame >= b.from && frame <= b.to);
export const event = (id) => EVENTS.find((e) => e.id === id);
