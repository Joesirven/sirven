import { Composition } from "remotion";
import { Explainer } from "./Explainer.jsx";
import { VIDEO } from "./timeline.js";
import { ArchitectureVideo } from "./architecture/ArchitectureVideo.jsx";
import { DEFAULT_ORDER, TOTAL_FRAMES, FPS } from "./architecture/timeline.js";

export const Root = () => (
  <>
    <Composition
      id="Explainer"
      component={Explainer}
      durationInFrames={VIDEO.durationInFrames}
      fps={VIDEO.fps}
      width={VIDEO.width}
      height={VIDEO.height}
    />
    <Composition
      id="ArchitectureVideo"
      component={ArchitectureVideo}
      durationInFrames={TOTAL_FRAMES}
      fps={FPS}
      width={VIDEO.width}
      height={VIDEO.height}
      defaultProps={{ ids: DEFAULT_ORDER }}
    />
    <Composition
      id="ArchitectureDraft"
      component={ArchitectureVideo}
      durationInFrames={600}
      fps={FPS}
      width={VIDEO.width}
      height={VIDEO.height}
      defaultProps={{ ids: ["system-overview", "peer-routing"] }}
    />
  </>
);
