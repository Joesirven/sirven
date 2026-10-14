import React from "react";
import { useCurrentFrame, interpolate } from "remotion";
import { C, T } from "../theme.js";
import { easeOut } from "../animation.js";
import { NODE_SIZE } from "./Node.jsx";

const edgePath = (from, to) => {
  const dx = to.x - from.x;
  const sign = dx >= 0 ? 1 : -1;
  const startX = from.x + sign * (NODE_SIZE.w / 2);
  const endX = to.x - sign * (NODE_SIZE.w / 2);
  const midX = (startX + endX) / 2;
  return `M ${startX} ${from.y} C ${midX} ${from.y}, ${midX} ${to.y}, ${endX} ${to.y}`;
};

const sampleAt = (from, to, t) => {
  const dx = to.x - from.x;
  const sign = dx >= 0 ? 1 : -1;
  const sx = from.x + sign * (NODE_SIZE.w / 2);
  const ex = to.x - sign * (NODE_SIZE.w / 2);
  const x = sx + (ex - sx) * t;
  const y = from.y + (to.y - from.y) * t;
  return { x, y };
};

export function DiagramEdge({ edge, from, to, startFrame, drawFrames = 18 }) {
  const frame = useCurrentFrame();
  const d = edgePath(from, to);
  const progress = interpolate(frame, [startFrame, startFrame + drawFrames], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: easeOut,
  });
  // Measure path length with a sentinel; use strokeDasharray trick.
  const len = 1200;
  const stroke = edge.style === "dashed" ? C.dim : C.text;
  const dashArray = edge.style === "dashed" ? "10 8" : `${len}`;
  const offset = edge.style === "dashed" ? 0 : len * (1 - progress);
  const headVisible = progress > 0.9 ? 1 : 0;

  const labelOpacity = interpolate(frame, [startFrame + drawFrames, startFrame + drawFrames + 10], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const labelPos = sampleAt(from, to, 0.5);

  return (
    <g opacity={edge.style === "dashed" ? Math.min(progress * 1.2, 0.75) : 1}>
      <path
        d={d}
        stroke={stroke}
        strokeWidth={2.5}
        fill="none"
        strokeDasharray={dashArray}
        strokeDashoffset={offset}
        strokeLinecap="round"
      />
      <ArrowHead to={to} from={from} opacity={headVisible} color={stroke} />
      {edge.label && (
        <foreignObject x={labelPos.x - 160} y={labelPos.y - 36} width={320} height={32} opacity={labelOpacity}>
          <div style={{ ...T.label, color: C.dim, textAlign: "center", background: C.bg, padding: "0 8px", borderRadius: 4 }}>
            {edge.label}
          </div>
        </foreignObject>
      )}
    </g>
  );
}

function ArrowHead({ from, to, opacity, color }) {
  const dx = to.x - from.x;
  const sign = dx >= 0 ? 1 : -1;
  const tip = { x: to.x - sign * (NODE_SIZE.w / 2), y: to.y };
  const size = 10;
  const pts = `${tip.x},${tip.y} ${tip.x - sign * size * 1.4},${tip.y - size} ${tip.x - sign * size * 1.4},${tip.y + size}`;
  return <polygon points={pts} fill={color} opacity={opacity} />;
}
