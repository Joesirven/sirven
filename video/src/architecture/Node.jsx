import React from "react";
import { useCurrentFrame } from "remotion";
import { C, T } from "../theme.js";
import { nodeAppear } from "../animation.js";

const SHAPES = {
  person: "ellipse",
  pipeline: "rect",
  core: "rect",
  edge: "rect",
  data: "cylinder",
  gate: "diamond",
  pending: "diamond",
  device: "parallelogram",
  system: "parallelogram",
  level: "rect",
  action: "rect",
  doc: "rect",
  plan: "rect",
  check: "rect",
  apply: "rect",
  entry: "rect",
  built: "rect",
  crypto: "rect",
  transport: "rect",
};

const W = 300;
const H = 108;

function Shape({ group, children }) {
  const kind = SHAPES[group] ?? "rect";
  const stroke = group === "pending" ? C.dim : C.text;
  const dashed = group === "pending";
  const common = {
    fill: C.surface,
    stroke,
    strokeWidth: 2,
    strokeDasharray: dashed ? "6 6" : undefined,
  };
  const content = (
    <foreignObject x={-W / 2 + 12} y={-H / 2 + 8} width={W - 24} height={H - 16}>
      <div
        style={{
          ...T.detail,
          color: C.text,
          width: "100%",
          height: "100%",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          textAlign: "center",
          lineHeight: "32px",
          wordBreak: "break-word",
        }}
      >
        {children}
      </div>
    </foreignObject>
  );
  if (kind === "ellipse") return <g><ellipse rx={W / 2} ry={H / 2} {...common} />{content}</g>;
  if (kind === "diamond") {
    const pts = `0,-${H / 2} ${W / 2},0 0,${H / 2} -${W / 2},0`;
    return <g><polygon points={pts} {...common} />{content}</g>;
  }
  if (kind === "cylinder") {
    const r = 14;
    return (
      <g>
        <rect x={-W / 2} y={-H / 2 + r} width={W} height={H - r * 2} {...common} />
        <ellipse cx={0} cy={-H / 2 + r} rx={W / 2} ry={r} {...common} />
        <ellipse cx={0} cy={H / 2 - r} rx={W / 2} ry={r} fill={C.surface} stroke={stroke} strokeWidth={2} />
        {content}
      </g>
    );
  }
  if (kind === "parallelogram") {
    const skew = 16;
    const pts = `${-W / 2 + skew},-${H / 2} ${W / 2},-${H / 2} ${W / 2 - skew},${H / 2} -${W / 2},${H / 2}`;
    return <g><polygon points={pts} {...common} />{content}</g>;
  }
  return <g><rect x={-W / 2} y={-H / 2} width={W} height={H} rx={14} ry={14} {...common} />{content}</g>;
}

export function DiagramNode({ node, pos, startFrame }) {
  const frame = useCurrentFrame();
  const { opacity, translateY } = nodeAppear(frame, startFrame);
  return (
    <g transform={`translate(${pos.x}, ${pos.y + translateY})`} opacity={opacity}>
      <Shape group={node.group}>{node.label}</Shape>
    </g>
  );
}

export const NODE_SIZE = { w: W, h: H };
