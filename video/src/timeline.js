// Frame plan for the explainer. Mirrors the beat table in docs/video/STORYBOARD.md.
export const VIDEO = { width: 1920, height: 1080, fps: 30, durationInFrames: 450 };

export const BEATS = [
  { id: "hook", from: 0, to: 44, caption: "Text your agent from anywhere." },
  { id: "infra", from: 45, to: 134, caption: "1 · The infra: a private path to your machine." },
  { id: "setup", from: 135, to: 224, caption: "2 · Set up once. Keys only after that." },
  { id: "features", from: 225, to: 329, caption: "3 · Safe defaults, configured for you." },
  { id: "usecases", from: 330, to: 404, caption: "4 · Your agent, working on your machine." },
  { id: "end", from: 405, to: 449, caption: null },
];

export const beat = (id) => BEATS.find((b) => b.id === id);
