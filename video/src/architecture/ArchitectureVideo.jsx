import React from "react";
import { Sequence } from "remotion";
import { DIAGRAMS } from "../../../docs/architecture/graph.mjs";
import { Scene } from "./Scene.jsx";
import { SCENE_LENGTH, scenesFor } from "./timeline.js";

export function ArchitectureVideo({ ids }) {
  const scenes = scenesFor(ids ?? DIAGRAMS.map((d) => d.id));
  return (
    <>
      {scenes.map((s) => (
        <Sequence key={s.diagram.id} from={s.from} durationInFrames={SCENE_LENGTH}>
          <Scene diagram={s.diagram} sceneFrom={0} />
        </Sequence>
      ))}
    </>
  );
}
