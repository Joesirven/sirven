import "@fontsource/ibm-plex-sans/400.css";
import "@fontsource/ibm-plex-sans/600.css";
import "@fontsource/ibm-plex-mono/400.css";
import "@fontsource/ibm-plex-mono/500.css";

import React, { useEffect, useState } from "react";
import { AbsoluteFill, Easing, continueRender, delayRender, interpolate, useCurrentFrame } from "remotion";
import { PROJECT } from "./project.js";
import { REVEAL_EASING, beatAt, event } from "./timeline.js";
import { C, F, G, T } from "./theme.js";

// Wait for every face the design uses (Sans 400/600, Mono 400/500); never fall back silently.
const FACES = [
  `400 32px ${F.sans}`,
  `600 40px ${F.sans}`,
  `400 32px ${F.mono}`,
  `500 32px ${F.mono}`,
];

const useFonts = () => {
  const [handle] = useState(() => delayRender("fonts"));
  useEffect(() => {
    Promise.all(FACES.map((f) => document.fonts.load(f, "abc·~/ 0")))
      .then(() => {
        const missing = FACES.filter((f) => !document.fonts.check(f, "abc·~/ 0"));
        if (missing.length) throw new Error(`fonts not ready: ${missing.join(", ")}`);
        continueRender(handle);
      })
      .catch((e) => {
        throw e;
      });
  }, [handle]);
};

// ---------- timing, all read from EVENTS ----------

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" };
const ease = Easing.bezier(...REVEAL_EASING);

// Opacity 0 to 1 over the event's inclusive frame range.
const revealOf = (frame, id) => {
  const e = event(id);
  return interpolate(frame, [e.from, e.to], [0, 1], { ...clamp, easing: ease });
};
const startedBy = (frame, id) => frame >= event(id).from;
// Linear 0 to 1 over the event's range (the dot travel).
const travelOf = (frame, id) => {
  const e = event(id);
  return interpolate(frame, [e.from, e.to], [0, 1], clamp);
};
// Among `ids` (replace-by-cut sequence), the latest that has started, with its reveal opacity.
const currentOf = (frame, ids) => {
  const started = ids.filter((id) => startedBy(frame, id));
  const id = started.at(-1);
  return id ? { id, opacity: revealOf(frame, id) } : { id: null, opacity: 0 };
};

// ---------- shared pieces ----------

const abs = (x, y, w, h) => ({ position: "absolute", left: x, top: y, width: w, height: h });

// A 2px hairline border sits inside the stated padding so content starts exactly `pad` from the outer edge.
const surface = (x, y, w, h, radius, pad, extra) => ({
  ...abs(x, y, w, h),
  boxSizing: "border-box",
  background: C.surface,
  border: `2px solid ${C.hair}`,
  borderRadius: radius,
  padding: pad - 2,
  color: C.text,
  ...extra,
});

const Caption = ({ text }) => (
  <div
    style={{
      ...abs(G.caption.x, G.caption.y, G.caption.w, G.caption.h),
      ...T.caption,
      color: C.text,
      textAlign: "center",
      whiteSpace: "nowrap",
    }}
  >
    {text}
  </div>
);

const Label = ({ y, children }) => (
  <div style={{ position: "absolute", left: 120, top: y, ...T.label, color: C.dim, whiteSpace: "nowrap" }}>
    {children}
  </div>
);

const Check = () => (
  <svg width="36" height="36" viewBox="0 0 36 36" style={{ flex: "none" }}>
    <path d="M6 19 L14 27 L30 9" fill="none" stroke={C.text} strokeWidth="4" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
);

const Lock = () => (
  <svg width="36" height="40" viewBox="0 0 36 40" style={{ flex: "none" }}>
    <rect x="5" y="17" width="26" height="19" rx="4" fill="none" stroke={C.text} strokeWidth="3" />
    <path d="M10 17 V12 a8 8 0 0 1 16 0 V17" fill="none" stroke={C.text} strokeWidth="3" />
  </svg>
);

// ---------- phone ----------

const bubble = { boxSizing: "border-box", maxWidth: 500, padding: 24, borderRadius: 20, ...T.body, whiteSpace: "nowrap" };

const Phone = ({ outgoingOpacity, incomingOpacity }) => (
  <div style={surface(G.phone.x, G.phone.y, G.phone.w, G.phone.h, 40, 40)}>
    <div style={{ ...T.diagramTitle, color: C.text }}>my agent</div>
    <div style={{ ...T.detail, color: C.dim }}>on your machine</div>
    <div style={{ marginTop: 32, display: "flex", flexDirection: "column", gap: 24 }}>
      <div style={{ opacity: outgoingOpacity, alignSelf: "flex-end" }}>
        <div style={{ ...bubble, background: C.accent, color: "#FFFFFF" }}>
          fix the flaky login test
          <br />
          and push a branch
        </div>
      </div>
      {incomingOpacity !== null && (
        <div style={{ opacity: incomingOpacity, alignSelf: "flex-start" }}>
          <div style={{ ...bubble, background: C.surface, border: `2px solid ${C.hair}`, color: C.text }}>
            <div style={{ display: "flex", alignItems: "center", gap: 16 }}>
              <span>Done. 42 tests pass.</span>
              <Check />
            </div>
            Pushed fix/login-flake.
          </div>
        </div>
      )}
    </div>
  </div>
);

// ---------- diagram ----------

const NODES = [
  { id: null, title: "your phone", lines: ["your existing remote client"] },
  { id: "infra-runtime", title: "agent runtime", lines: ["Claude Code ·", "Codex · Pi"] },
  { id: "infra-tunnel", title: "private tunnel", lines: ["Tailscale ·", "Cloudflare Tunnel", "key-based access"] },
  { id: "infra-machine", title: "your machine", lines: ["macOS · Linux", "service user: agent", "no administrator rights"] },
];

const NODE_EDGE = (i) => [G.nodeXs[i], G.nodeXs[i] + G.node.w];
const DOT = 16;

const Diagram = ({ frame }) => {
  const travel = startedBy(frame, "infra-dot") ? travelOf(frame, "infra-dot") : null;
  // Dot centre runs from the phone's right edge to inside the machine, where its node occludes it.
  const x0 = NODE_EDGE(0)[1] + DOT / 2;
  const x1 = NODE_EDGE(3)[0] + DOT / 2 + DOT;
  return (
    <>
      {[0, 1, 2].map((i) => (
        <div
          key={i}
          style={{
            ...abs(NODE_EDGE(i)[1], G.connectorY - 1, G.nodeXs[i + 1] - NODE_EDGE(i)[1], 2),
            background: C.hair,
          }}
        />
      ))}
      {travel !== null && (
        <div
          style={{
            ...abs(x0 + (x1 - x0) * travel - DOT / 2, G.connectorY - DOT / 2, DOT, DOT),
            borderRadius: DOT / 2,
            background: C.accent,
          }}
        />
      )}
      {NODES.map((n, i) => (
        <div
          key={n.title}
          style={{
            ...surface(G.nodeXs[i], G.node.y, G.node.w, G.node.h, 24, 24),
            opacity: n.id ? revealOf(frame, n.id) : 1,
          }}
        >
          <div style={{ ...T.diagramTitle }}>{n.title}</div>
          {n.lines.map((l) => (
            <div key={l} style={{ ...T.detail, color: C.dim }}>
              {l}
            </div>
          ))}
        </div>
      ))}
    </>
  );
};

// ---------- setup command sheet ----------

const Sheet = ({ frame }) => {
  const line = (id, top, children) => (
    <div style={{ position: "absolute", left: 46, top: top - G.sheet.y - 2, opacity: revealOf(frame, id), whiteSpace: "pre" }}>
      {children}
    </div>
  );
  return (
    <div style={surface(G.sheet.x, G.sheet.y, G.sheet.w, G.sheet.h, 24, 48)}>
      <div style={{ ...T.detail, lineHeight: "32px", color: C.dim, whiteSpace: "nowrap" }}>On your machine</div>
      {line("setup-command", 296, <div style={T.mono}>{"./install.sh --runtime claude-code \\\n  --transport tailscale --level builder"}</div>)}
      {line("setup-approve", 424, <div style={T.detail}>Approve this machine in your browser</div>)}
      {line("setup-approved", 492, <div style={T.detail}>Approved · future connections use keys</div>)}
      {line(
        "setup-complete",
        560,
        <div style={T.detail}>
          {"Service user: agent · builder access to ~/code\nClaude Code connected\nBuild started on your machine."}
        </div>,
      )}
    </div>
  );
};

// ---------- cards ----------

const Card = ({ opacity, children, center }) => (
  <div
    style={{
      ...surface(G.card.x, G.card.y, G.card.w, G.card.h, 24, 48, { opacity }),
      ...(center ? { display: "flex", alignItems: "center", justifyContent: "center", textAlign: "center" } : {}),
    }}
  >
    {children}
  </div>
);

const Title = ({ children }) => <div style={{ ...T.heading, marginBottom: 24 }}>{children}</div>;
const Body = ({ children }) => <div style={T.body}>{children}</div>;

const Chip = ({ children, selected }) => (
  <div
    style={{
      ...(selected ? T.monoSelected : T.mono),
      boxSizing: "border-box",
      padding: "12px 20px",
      borderRadius: 12,
      background: C.surface,
      border: `2px solid ${selected ? C.accent : C.hair}`,
      color: selected ? C.accent : C.text,
    }}
  >
    {children}
  </div>
);

const Row = ({ path, access, lock }) => (
  <div style={{ display: "flex", alignItems: "center", height: 52 }}>
    <div style={{ ...T.mono, width: 280 }}>{path}</div>
    <div style={{ ...T.body, display: "flex", alignItems: "center", gap: 16 }}>
      {access}
      {lock && <Lock />}
    </div>
  </div>
);

const FEATURES = {
  "feature-levels": (
    <>
      <Title>Preset levels</Title>
      <div style={{ display: "flex", gap: 24, marginBottom: 24 }}>
        <Chip>observer</Chip>
        <Chip selected>builder</Chip>
        <Chip>operator</Chip>
      </div>
      <Body>Choose a level. Scope it to a path.</Body>
    </>
  ),
  "feature-paths": (
    <>
      <Title>Per-path access</Title>
      <div style={{ display: "flex", flexDirection: "column", gap: 24 }}>
        <Row path="~/code" access="read · write" />
        <Row path="~/.ssh" access="denied" lock />
      </div>
    </>
  ),
  "feature-audit": (
    <>
      <Title>Audit log</Title>
      <div style={{ marginBottom: 24 }}>
        <Body>Sessions and submitted commands, recorded.</Body>
      </div>
      <div style={{ ...T.mono, whiteSpace: "pre" }}>{"12:04:07 agent\ngit checkout -b fix/login-flake"}</div>
    </>
  ),
  "feature-kill": (
    <>
      <Title>Kill switch</Title>
      <div style={{ ...T.mono, marginBottom: 24 }}>revoke --all</div>
      <div style={{ ...T.body, whiteSpace: "pre" }}>{"Revoke every key. End every session.\nLock the service user."}</div>
    </>
  ),
};

const USE_CASES = {
  "use-ship": "Ship a fix from your phone",
  "use-nightly": "Run the nightly build on your own machine",
  "use-friend": "Lend a friend's agent read-only access",
  "use-triage": "Triage logs on your home server",
};

// ---------- composition ----------

export const Explainer = () => {
  useFonts();
  const frame = useCurrentFrame();
  const b = beatAt(frame);
  const showReply = b.id === "usecases" && startedBy(frame, "use-reply");
  const featureNow = currentOf(frame, Object.keys(FEATURES));
  const useNow = currentOf(frame, Object.keys(USE_CASES));

  let stage = null;
  if (b.id === "hook") stage = <Phone outgoingOpacity={revealOf(frame, "hook-bubble")} incomingOpacity={null} />;
  else if (b.id === "infra") stage = <Diagram frame={frame} />;
  else if (b.id === "setup") stage = <Sheet frame={frame} />;
  else if (b.id === "features" && featureNow.id) stage = <Card opacity={featureNow.opacity}>{FEATURES[featureNow.id]}</Card>;
  else if (showReply) stage = <Phone outgoingOpacity={1} incomingOpacity={revealOf(frame, "use-reply")} />;
  else if (b.id === "usecases" && useNow.id) {
    stage = (
      <Card opacity={useNow.opacity} center>
        <div style={{ ...T.heading, textWrap: "balance" }}>{USE_CASES[useNow.id]}</div>
      </Card>
    );
  }

  return (
    <AbsoluteFill style={{ background: C.bg, fontFamily: F.sans, color: C.text }}>
      {b.n <= 4 && (
        <div style={{ position: "absolute", left: G.concept.x, top: G.concept.y, ...T.label, color: C.dim, whiteSpace: "nowrap" }}>
          Concept preview
        </div>
      )}
      {b.chapter && <Label y={G.chapter.y}>{b.chapter}</Label>}
      {b.caption && <Caption text={b.caption} />}
      {stage}
      {b.id === "slogan" && (
        <div
          style={{
            ...abs(G.slogan.x, G.slogan.y, G.slogan.w, G.slogan.h),
            display: "flex",
            justifyContent: "center",
            opacity: revealOf(frame, "slogan"),
          }}
        >
          <div style={{ ...T.slogan, width: G.slogan.wrap, textAlign: "center" }}>{PROJECT.slogan}</div>
        </div>
      )}
      {b.id === "end" && (
        <div style={{ position: "absolute", inset: 0, opacity: revealOf(frame, "endcard"), textAlign: "center" }}>
          <div style={{ position: "absolute", left: 0, right: 0, top: G.endName.y, ...T.endName }}>{PROJECT.name}</div>
          <div style={{ position: "absolute", left: 0, right: 0, top: G.endSubtitle.y, ...T.endSubtitle }}>{PROJECT.subtitle}</div>
          <div style={{ position: "absolute", left: 0, right: 0, top: G.endPlatform.y, ...T.detail, color: C.dim }}>
            open source · macOS + Linux · Claude Code, Codex, Pi
          </div>
        </div>
      )}
    </AbsoluteFill>
  );
};
