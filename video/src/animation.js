// Small reusable animation library for the architecture video.
// Every function returns a plain number driven by useCurrentFrame(); never set
// up time-based motion with CSS transitions in a Remotion composition.
import { interpolate, spring, Easing } from "remotion";
import { REVEAL_EASING } from "./timeline.js";

export const easeOut = Easing.bezier(...REVEAL_EASING);

export const reveal = (frame, from, duration = 12) =>
  interpolate(frame, [from, from + duration], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: easeOut,
  });

export const rise = (frame, from, distance = 24, duration = 12) =>
  interpolate(frame, [from, from + duration], [distance, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: easeOut,
  });

export const nodeAppear = (frame, from, duration = 12) => ({
  opacity: reveal(frame, from, duration),
  translateY: rise(frame, from, 16, duration),
});

export const springFloat = (frame, from, fps) =>
  spring({
    frame: frame - from,
    fps,
    config: { damping: 20, mass: 0.8, stiffness: 140 },
  });

// Deterministic column layout for a diagram scene. Nodes are grouped by their
// graph.mjs `group`; each group becomes a column; node y-positions stack within.
export function layoutScene(diagram, bounds) {
  const groups = [];
  const seen = new Set();
  for (const n of diagram.nodes) {
    if (!seen.has(n.group)) {
      groups.push(n.group);
      seen.add(n.group);
    }
  }
  const columns = groups.length;
  const colWidth = bounds.w / columns;
  const positions = {};
  for (let i = 0; i < groups.length; i++) {
    const members = diagram.nodes.filter((n) => n.group === groups[i]);
    const rowHeight = bounds.h / (members.length + 1);
    for (let j = 0; j < members.length; j++) {
      positions[members[j].id] = {
        x: bounds.x + colWidth * i + colWidth / 2,
        y: bounds.y + rowHeight * (j + 1),
      };
    }
  }
  return positions;
}

// Reveal schedule: each node gets a start frame; each edge starts after its source and target.
export function schedule(diagram, firstFrame, step = 18) {
  const nodeAt = {};
  diagram.nodes.forEach((n, i) => (nodeAt[n.id] = firstFrame + i * step));
  const edgeAt = diagram.edges.map((e) => {
    const base = Math.max(nodeAt[e.from] ?? firstFrame, nodeAt[e.to] ?? firstFrame);
    return { ...e, startFrame: base + Math.round(step / 2) };
  });
  const lastNode = Math.max(...Object.values(nodeAt));
  const lastEdge = edgeAt.length ? Math.max(...edgeAt.map((e) => e.startFrame)) : lastNode;
  return { nodeAt, edgeAt, lastFrame: Math.max(lastNode, lastEdge) + 12 };
}
