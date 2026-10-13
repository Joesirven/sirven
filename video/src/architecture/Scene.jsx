import React from "react";
import { useCurrentFrame } from "remotion";
import { C, T, G } from "../theme.js";
import { reveal, layoutScene, schedule } from "../animation.js";
import { DiagramNode } from "./Node.jsx";
import { DiagramEdge } from "./Edge.jsx";

const BOUNDS = { x: 160, y: 240, w: 1600, h: 640 };

export function Scene({ diagram, sceneFrom }) {
  const frame = useCurrentFrame();
  const positions = layoutScene(diagram, BOUNDS);
  const { nodeAt, edgeAt } = schedule(diagram, sceneFrom + 12, 18);

  const titleOpacity = reveal(frame, sceneFrom);
  const captionOpacity = reveal(frame, sceneFrom + 8);

  return (
    <div style={{ position: "absolute", inset: 0, background: C.bg }}>
      <svg width={G.canvas.w} height={G.canvas.h} viewBox={`0 0 ${G.canvas.w} ${G.canvas.h}`}>
        {diagram.edges.map((e, i) => (
          <DiagramEdge
            key={`edge-${i}`}
            edge={e}
            from={positions[e.from]}
            to={positions[e.to]}
            startFrame={edgeAt[i].startFrame}
          />
        ))}
        {diagram.nodes.map((n) => (
          <DiagramNode key={n.id} node={n} pos={positions[n.id]} startFrame={nodeAt[n.id]} />
        ))}
      </svg>
      <div style={{ position: "absolute", left: G.chapter.x, top: G.chapter.y, color: C.dim, ...T.label, opacity: titleOpacity }}>
        architecture
      </div>
      <div style={{ position: "absolute", left: G.chapter.x, top: G.chapter.y + 36, color: C.text, ...T.diagramTitle, opacity: titleOpacity }}>
        {diagram.title}
      </div>
      <div style={{ position: "absolute", left: G.caption.x, top: G.caption.y, width: G.caption.w, color: C.dim, ...T.detail, opacity: captionOpacity }}>
        {diagram.caption}
      </div>
    </div>
  );
}
