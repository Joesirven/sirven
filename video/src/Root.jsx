import { Composition } from "remotion";
import { Explainer } from "./Explainer.jsx";
import { VIDEO } from "./timeline.js";

export const Root = () => (
  <Composition
    id="Explainer"
    component={Explainer}
    durationInFrames={VIDEO.durationInFrames}
    fps={VIDEO.fps}
    width={VIDEO.width}
    height={VIDEO.height}
  />
);
