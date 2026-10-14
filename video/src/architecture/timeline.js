// Timeline for the architecture video. Each diagram scene is a fixed length:
// the full video plays every diagram in DEFAULT_ORDER at 10 seconds each, and a draft renders two.
import { byId } from "../../../docs/architecture/graph.mjs";

export const FPS = 30;
export const SCENE_LENGTH = 300; // 10 seconds per scene

export function scenesFor(ids) {
  const scenes = [];
  let from = 0;
  for (const id of ids) {
    const diagram = byId(id);
    if (!diagram) throw new Error(`unknown diagram id: ${id}`);
    scenes.push({ diagram, from });
    from += SCENE_LENGTH;
  }
  return scenes;
}

export const DEFAULT_ORDER = [
  "system-overview",
  "installer",
  "access-levels",
  "runtime-seam",
  "phone-bridge",
  "ride-demo",
  "concierge-ops",
  "keep-awake",
  "peer-routing",
];

export const TOTAL_FRAMES = SCENE_LENGTH * DEFAULT_ORDER.length;
