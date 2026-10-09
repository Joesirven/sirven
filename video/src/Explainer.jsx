import "@fontsource/inter/400.css";
import "@fontsource/inter/600.css";
import "@fontsource/inter/700.css";
import "@fontsource/jetbrains-mono/400.css";
import "@fontsource/jetbrains-mono/700.css";

import { useEffect, useState } from "react";
import {
  AbsoluteFill,
  continueRender,
  delayRender,
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { PROJECT } from "./project.js";
import { BEATS, beat } from "./timeline.js";
import { C, F } from "./theme.js";

// Layout: phone in the left third (the through line), work area in the right two thirds.
const PHONE = { x: 110, y: 100, w: 420, h: 800 };
const WORK = { x: 620, y: 150, w: 1190, h: 740 };
const CAPTION_Y = 935;

const clamp = { extrapolateLeft: "clamp", extrapolateRight: "clamp" };
const fade = (frame, start, dur = 8) => interpolate(frame, [start, start + dur], [0, 1], clamp);
const fadeOut = (frame, end, dur = 8) => interpolate(frame, [end - dur, end], [1, 0], clamp);
// Visible from `from` (fading in) until `to` (fading out). Used for whole beats.
const visible = (frame, from, to, dur = 8) => Math.min(fade(frame, from, dur), fadeOut(frame, to + 1, dur));

const usePop = (start) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  return spring({ frame: frame - start, fps, config: { damping: 200, mass: 0.6 } });
};

const useFonts = () => {
  const [handle] = useState(() => delayRender("fonts"));
  useEffect(() => {
    Promise.all([
      document.fonts.load('600 60px "Inter"'),
      document.fonts.load('400 30px "Inter"'),
      document.fonts.load('700 30px "Inter"'),
      document.fonts.load('400 30px "JetBrains Mono"'),
      document.fonts.load('700 30px "JetBrains Mono"'),
    ]).then(() => continueRender(handle));
  }, [handle]);
};

// ---------- persistent chrome ----------

const BEAT_LABELS = [
  ["infra", "1 infra"],
  ["setup", "2 setup"],
  ["features", "3 ships with"],
  ["usecases", "4 use cases"],
];

const BeatCounter = () => {
  const frame = useCurrentFrame();
  const opacity = visible(frame, beat("infra").from, beat("usecases").to);
  return (
    <div style={{ position: "absolute", top: 40, right: 110, display: "flex", gap: 14, opacity }}>
      {BEAT_LABELS.map(([id, label]) => {
        const b = beat(id);
        const active = frame >= b.from && frame <= b.to;
        return (
          <div
            key={id}
            style={{
              fontFamily: F.sans,
              fontWeight: 600,
              fontSize: 24,
              padding: "8px 18px",
              borderRadius: 999,
              color: active ? C.bg : C.dim,
              background: active ? C.green : "transparent",
              border: `2px solid ${active ? C.green : C.hair}`,
            }}
          >
            {label}
          </div>
        );
      })}
    </div>
  );
};

const Caption = () => {
  const frame = useCurrentFrame();
  return BEATS.filter((b) => b.caption).map((b) => {
    const opacity = visible(frame, b.id === "hook" ? 10 : b.from, b.to, 6);
    const y = interpolate(fade(frame, b.from, 8), [0, 1], [16, 0]);
    return (
      <div
        key={b.id}
        style={{
          position: "absolute",
          left: 0,
          right: 0,
          top: CAPTION_Y,
          textAlign: "center",
          fontFamily: F.sans,
          fontWeight: 600,
          fontSize: 60,
          letterSpacing: "-0.01em",
          color: C.ink,
          opacity,
          transform: `translateY(${y}px)`,
        }}
      >
        {b.caption}
      </div>
    );
  });
};

// ---------- phone (through line) ----------

const Bubble = ({ start, out, children }) => {
  const p = usePop(start);
  return (
    <div
      style={{
        alignSelf: out ? "flex-end" : "flex-start",
        maxWidth: 320,
        padding: "16px 22px",
        borderRadius: 28,
        background: out ? C.blue : C.surfaceHi,
        color: out ? "#FFFFFF" : C.ink,
        fontFamily: F.sans,
        fontSize: 30,
        lineHeight: 1.3,
        opacity: p,
        transform: `translateY(${(1 - p) * 24}px) scale(${0.96 + 0.04 * p})`,
        transformOrigin: out ? "bottom right" : "bottom left",
      }}
    >
      {children}
    </div>
  );
};

const Typing = ({ from, to }) => {
  const frame = useCurrentFrame();
  if (frame < from || frame > to) return null;
  const opacity = visible(frame, from, to, 5);
  return (
    <div
      style={{
        alignSelf: "flex-start",
        display: "flex",
        gap: 10,
        padding: "20px 24px",
        borderRadius: 28,
        background: C.surfaceHi,
        opacity,
      }}
    >
      {[0, 1, 2].map((i) => (
        <div
          key={i}
          style={{
            width: 14,
            height: 14,
            borderRadius: 7,
            background: C.dim,
            opacity: 0.4 + 0.6 * Math.abs(Math.sin((frame + i * 5) / 6)),
          }}
        />
      ))}
    </div>
  );
};

const OUTGOING = "fix the flaky login test and push a branch";

const Phone = () => {
  const frame = useCurrentFrame();
  const opacity = fadeOut(frame, beat("end").from + 6, 10);
  const enter = usePop(0);
  // Message types into the compose field, then sends at frame 22.
  const typed = Math.round(interpolate(frame, [2, 20], [0, OUTGOING.length], clamp));
  const sent = frame >= 22;
  const usecases = beat("usecases").from;
  return (
    <div
      style={{
        position: "absolute",
        left: PHONE.x,
        top: PHONE.y,
        width: PHONE.w,
        height: PHONE.h,
        borderRadius: 64,
        border: `3px solid ${C.hair}`,
        background: C.surface,
        boxShadow: "0 40px 120px rgba(0,0,0,0.55)",
        opacity: opacity * enter,
        transform: `translateY(${(1 - enter) * 30}px)`,
        display: "flex",
        flexDirection: "column",
        overflow: "hidden",
      }}
    >
      <div
        style={{
          padding: "44px 28px 22px",
          borderBottom: `2px solid ${C.hair}`,
          display: "flex",
          alignItems: "center",
          gap: 16,
        }}
      >
        <div
          style={{
            width: 52,
            height: 52,
            borderRadius: 26,
            background: C.green,
            color: C.bg,
            fontFamily: F.mono,
            fontWeight: 700,
            fontSize: 26,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
          }}
        >
          {">_"}
        </div>
        <div>
          <div style={{ fontFamily: F.sans, fontWeight: 600, fontSize: 30, color: C.ink }}>my agent</div>
          <div style={{ fontFamily: F.sans, fontSize: 24, color: C.green }}>on your machine</div>
        </div>
      </div>
      <div style={{ flex: 1, padding: 24, display: "flex", flexDirection: "column", justifyContent: "flex-end", gap: 16 }}>
        {sent && <Bubble start={22} out>{OUTGOING}</Bubble>}
        <Typing from={beat("features").from + 6} to={usecases - 1} />
        {frame >= usecases + 4 && (
          <Bubble start={usecases + 4}>
            <span style={{ color: C.green, fontWeight: 700 }}>✓ Done.</span> 42 tests pass. Pushed{" "}
            <span style={{ fontFamily: F.mono, fontSize: 26 }}>fix/login-flake</span>
          </Bubble>
        )}
      </div>
      <div
        style={{
          margin: "0 20px 30px",
          padding: "16px 22px",
          borderRadius: 30,
          border: `2px solid ${C.hair}`,
          fontFamily: F.sans,
          fontSize: 26,
          color: sent ? C.dim : C.ink,
          minHeight: 34,
          lineHeight: 1.3,
        }}
      >
        {sent ? "Message" : OUTGOING.slice(0, typed)}
        {!sent && <span style={{ color: C.blue }}>|</span>}
      </div>
    </div>
  );
};

// ---------- beat 1: infra ----------

const NODES = [
  { title: "agent runtime", lines: ["Claude Code", "Codex · Pi"] },
  { title: "private tunnel", lines: ["Tailscale", "Cloudflare Tunnel"] },
  { title: "your machine", lines: ["macOS", "Linux"] },
];
const NODE_W = 310;
const NODE_H = 200;
const NODE_GAP = (WORK.w - NODE_W * 3) / 2;
const ROW_Y = 230; // relative to WORK
const LINE_Y = ROW_Y + NODE_H / 2;

const Infra = () => {
  const frame = useCurrentFrame();
  const { from, to } = beat("infra");
  const opacity = visible(frame, from, to);
  // The path starts at the phone's right edge (in work-area coordinates) and ends at the machine.
  const startX = PHONE.x + PHONE.w - WORK.x;
  const endX = WORK.w - NODE_W / 2;
  const draw = interpolate(frame, [from + 2, from + 30], [0, 1], clamp);
  const dot = interpolate(frame, [from + 34, from + 66], [startX, endX], {
    ...clamp,
    easing: (t) => 1 - Math.pow(1 - t, 3),
  });
  const arrived = frame >= from + 66;
  return (
    <AbsoluteFill style={{ left: WORK.x, top: WORK.y, width: WORK.w, height: WORK.h, opacity }}>
      <div
        style={{
          position: "absolute",
          left: startX,
          top: LINE_Y - 2,
          height: 4,
          width: (endX - startX) * draw,
          background: `linear-gradient(90deg, ${C.blue}, ${C.green})`,
          borderRadius: 2,
        }}
      />
      {NODES.map((n, i) => {
        const p = interpolate(frame, [from + 6 + i * 7, from + 16 + i * 7], [0, 1], clamp);
        const lit = i === 2 && arrived;
        return (
          <div
            key={n.title}
            style={{
              position: "absolute",
              left: i * (NODE_W + NODE_GAP),
              top: ROW_Y,
              width: NODE_W,
              height: NODE_H,
              boxSizing: "border-box",
              borderRadius: 24,
              background: C.surface,
              border: `3px solid ${lit ? C.green : C.hair}`,
              padding: "28px 30px",
              opacity: p,
              transform: `translateY(${(1 - p) * 20}px)`,
            }}
          >
            <div style={{ fontFamily: F.sans, fontWeight: 700, fontSize: 36, color: C.ink, marginBottom: 14 }}>
              {n.title}
            </div>
            {n.lines.map((l) => (
              <div key={l} style={{ fontFamily: F.sans, fontSize: 28, color: C.dim, lineHeight: 1.35 }}>
                {l}
              </div>
            ))}
          </div>
        );
      })}
      <div
        style={{
          position: "absolute",
          left: dot - 14,
          top: LINE_Y - 14,
          width: 28,
          height: 28,
          borderRadius: 14,
          background: C.green,
          boxShadow: `0 0 30px ${C.green}`,
          opacity: frame >= from + 34 && !arrived ? 1 : 0,
        }}
      />
      <div
        style={{
          position: "absolute",
          left: NODE_W + NODE_GAP,
          width: NODE_W,
          top: ROW_Y + NODE_H + 28,
          textAlign: "center",
          fontFamily: F.mono,
          fontSize: 26,
          color: C.green,
          opacity: fade(frame, from + 24),
        }}
      >
        key-based · no open ports
      </div>
      <div
        style={{
          position: "absolute",
          left: 2 * (NODE_W + NODE_GAP) - 40,
          width: NODE_W + 40,
          top: ROW_Y + NODE_H + 28,
          boxSizing: "border-box",
          padding: "16px 18px",
          borderRadius: 16,
          border: `2px dashed ${arrived ? C.green : C.hair}`,
          fontFamily: F.mono,
          fontSize: 25,
          lineHeight: 1.4,
          color: C.ink,
          textAlign: "center",
          opacity: fade(frame, from + 40),
        }}
      >
        service user <b>agent</b>
        <div style={{ color: C.dim }}>no sudo</div>
      </div>
    </AbsoluteFill>
  );
};

// ---------- beat 2: setup ----------

const Terminal = ({ title, children, style }) => (
  <div
    style={{
      borderRadius: 22,
      background: "#0F1216",
      border: `2px solid ${C.hair}`,
      boxShadow: "0 30px 90px rgba(0,0,0,0.5)",
      overflow: "hidden",
      ...style,
    }}
  >
    <div
      style={{
        display: "flex",
        alignItems: "center",
        gap: 10,
        padding: "16px 22px",
        background: C.surface,
        borderBottom: `2px solid ${C.hair}`,
      }}
    >
      {["#FF5F57", "#FEBC2E", "#28C840"].map((c) => (
        <div key={c} style={{ width: 16, height: 16, borderRadius: 8, background: c }} />
      ))}
      <div style={{ marginLeft: 14, fontFamily: F.mono, fontSize: 24, color: C.dim }}>{title}</div>
    </div>
    <div style={{ padding: "26px 32px", fontFamily: F.mono, fontSize: 30, lineHeight: 1.55, color: C.ink }}>
      {children}
    </div>
  </div>
);

const CMD1 = "./install.sh --runtime claude-code \\";
const CMD2 = "    --transport tailscale --level builder";

const SETUP_LINES = [
  { at: 34, text: "one-time: approve this machine in your browser", interactive: true },
  { at: 46, text: "tunnel up · auth key stored, key-based from now on" },
  { at: 54, text: "created service user  agent" },
  { at: 62, text: "applied level  builder  to ~/code" },
  { at: 70, text: "runtime  claude-code  connected" },
];

const Setup = () => {
  const frame = useCurrentFrame();
  const { from, to } = beat("setup");
  const t = frame - from;
  const opacity = visible(frame, from, to);
  const typed = Math.round(interpolate(t, [2, 24], [0, CMD1.length + CMD2.length], clamp));
  const l1 = CMD1.slice(0, typed);
  const l2 = CMD2.slice(0, Math.max(0, typed - CMD1.length));
  const approved = t >= 44;
  return (
    <div style={{ position: "absolute", left: WORK.x, top: WORK.y + 40, width: WORK.w, opacity }}>
      <Terminal title="you@your-machine: ~">
        <div>
          <span style={{ color: C.green }}>$ </span>
          {l1}
        </div>
        <div style={{ minHeight: 46 }}>{l2}</div>
        <div style={{ height: 18 }} />
        {SETUP_LINES.map((l) => {
          const show = fade(t, l.at, 5);
          const pending = l.interactive && !approved;
          return (
            <div key={l.text} style={{ opacity: show, color: pending ? C.amber : C.ink }}>
              <span style={{ color: pending ? C.amber : C.green, fontWeight: 700 }}>{pending ? "◆" : "✓"} </span>
              {l.text}
            </div>
          );
        })}
      </Terminal>
    </div>
  );
};

// ---------- beat 3: features ----------

const Tile = ({ start, title, children, style }) => {
  const p = usePop(start);
  return (
    <div
      style={{
        position: "absolute",
        boxSizing: "border-box",
        borderRadius: 24,
        background: C.surface,
        border: `2px solid ${C.hair}`,
        padding: "26px 32px",
        opacity: p,
        transform: `translateY(${(1 - p) * 26}px)`,
        ...style,
      }}
    >
      <div
        style={{
          fontFamily: F.sans,
          fontWeight: 600,
          fontSize: 24,
          letterSpacing: "0.12em",
          textTransform: "uppercase",
          color: C.dim,
          marginBottom: 18,
        }}
      >
        {title}
      </div>
      {children}
    </div>
  );
};

const Chip = ({ on, children }) => (
  <span
    style={{
      display: "inline-block",
      marginRight: 14,
      padding: "8px 20px",
      borderRadius: 999,
      fontFamily: F.mono,
      fontSize: 28,
      color: on ? C.bg : C.dim,
      background: on ? C.green : "transparent",
      border: `2px solid ${on ? C.green : C.hair}`,
    }}
  >
    {children}
  </span>
);

const Row = ({ left, right, color }) => (
  <div style={{ display: "flex", justifyContent: "space-between", fontFamily: F.mono, fontSize: 28, lineHeight: 1.6 }}>
    <span style={{ color: C.ink }}>{left}</span>
    <span style={{ color }}>{right}</span>
  </div>
);

const Features = () => {
  const frame = useCurrentFrame();
  const { from, to } = beat("features");
  const opacity = visible(frame, from, to);
  const half = (WORK.w - 30) / 2;
  const killOn = frame >= from + 70;
  return (
    <div style={{ position: "absolute", left: WORK.x, top: WORK.y, width: WORK.w, height: WORK.h, opacity }}>
      <Tile start={from + 2} title="Preset levels" style={{ left: 0, top: 0, width: half, height: 210 }}>
        <Chip>observer</Chip>
        <Chip on>builder</Chip>
        <Chip>operator</Chip>
      </Tile>
      <Tile start={from + 8} title="Per-path access" style={{ left: half + 30, top: 0, width: half, height: 210 }}>
        <Row left="~/code" right="read · write" color={C.green} />
        <Row left="~/.ssh" right="denied" color={C.red} />
      </Tile>
      <Tile start={from + 14} title="Audit log · every action" style={{ left: 0, top: 240, width: WORK.w, height: 220 }}>
        <div style={{ fontFamily: F.mono, fontSize: 28, lineHeight: 1.6 }}>
          <div style={{ opacity: fade(frame, from + 22, 4) }}>
            <span style={{ color: C.dim }}>12:04:07 agent </span> git checkout -b fix/login-flake
            <span style={{ color: C.green }}>  ok</span>
          </div>
          <div style={{ opacity: fade(frame, from + 34, 4) }}>
            <span style={{ color: C.dim }}>12:04:09 agent </span> read ~/.ssh/id_ed25519
            <span style={{ color: C.red, fontWeight: 700 }}>  DENIED</span>
          </div>
        </div>
      </Tile>
      <Tile
        start={from + 20}
        title="Kill switch"
        style={{ left: 0, top: 490, width: WORK.w, height: 170, display: "flex", flexDirection: "column" }}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 26 }}>
          <div
            style={{
              width: 84,
              height: 44,
              borderRadius: 22,
              background: killOn ? C.red : C.hair,
              position: "relative",
            }}
          >
            <div
              style={{
                position: "absolute",
                top: 5,
                left: killOn ? 45 : 5,
                width: 34,
                height: 34,
                borderRadius: 17,
                background: C.ink,
              }}
            />
          </div>
          <span style={{ fontFamily: F.sans, fontSize: 32, color: C.ink }}>
            One command revokes every key and stops the agent.
          </span>
        </div>
      </Tile>
    </div>
  );
};

// ---------- beat 4: use cases ----------

const USE_CASES = [
  ["Ship a fix from your phone", "the build runs on your own machine"],
  ["Run the nightly build", "on the box under your desk"],
  ["Lend a friend's agent access", "read-only, one path, revocable"],
  ["Triage logs on your server", "observer level, nothing writable"],
];

const UseCases = () => {
  const frame = useCurrentFrame();
  const { from, to } = beat("usecases");
  const opacity = visible(frame, from, to);
  const w = (WORK.w - 30) / 2;
  const h = 200;
  return (
    <div style={{ position: "absolute", left: WORK.x, top: WORK.y + 120, width: WORK.w, opacity }}>
      {USE_CASES.map(([title, sub], i) => (
        <Tile
          key={title}
          start={from + 2 + i * 5}
          title={`use case ${i + 1}`}
          style={{ left: (i % 2) * (w + 30), top: Math.floor(i / 2) * (h + 30), width: w, height: h }}
        >
          <div style={{ fontFamily: F.sans, fontWeight: 700, fontSize: 36, color: C.ink, lineHeight: 1.2 }}>{title}</div>
          <div style={{ fontFamily: F.sans, fontSize: 26, color: C.dim, marginTop: 8 }}>{sub}</div>
        </Tile>
      ))}
    </div>
  );
};

// ---------- beat 5: end card ----------

const EndCard = () => {
  const frame = useCurrentFrame();
  const { from } = beat("end");
  const p = usePop(from + 6);
  const cursorOn = Math.floor((frame - from) / 8) % 2 === 0;
  return (
    <AbsoluteFill
      style={{
        alignItems: "center",
        justifyContent: "center",
        flexDirection: "column",
        opacity: p,
        transform: `scale(${0.97 + 0.03 * p})`,
      }}
    >
      <div style={{ fontFamily: F.mono, fontWeight: 700, fontSize: 104, color: C.ink, letterSpacing: "-0.02em" }}>
        <span style={{ color: C.green }}>{">"} </span>
        {PROJECT.name}
        <span style={{ color: C.green, opacity: cursorOn ? 1 : 0 }}>█</span>
      </div>
      <div style={{ fontFamily: F.sans, fontSize: 44, color: C.ink, marginTop: 30 }}>{PROJECT.tagline}</div>
      <div style={{ fontFamily: F.sans, fontSize: 30, color: C.dim, marginTop: 26 }}>
        open source · macOS + Linux · Claude Code, Codex, Pi
      </div>
    </AbsoluteFill>
  );
};

export const Explainer = () => {
  useFonts();
  const frame = useCurrentFrame();
  return (
    <AbsoluteFill style={{ background: C.bg }}>
      <AbsoluteFill
        style={{
          background: `radial-gradient(1200px 700px at 70% 40%, rgba(61,220,132,0.07), transparent 70%)`,
        }}
      />
      {frame < beat("end").from + 16 && <Phone />}
      {frame >= beat("infra").from && frame <= beat("infra").to && <Infra />}
      {frame >= beat("setup").from && frame <= beat("setup").to && <Setup />}
      {frame >= beat("features").from && frame <= beat("features").to && <Features />}
      {frame >= beat("usecases").from && frame <= beat("usecases").to && <UseCases />}
      {frame >= beat("end").from && <EndCard />}
      <BeatCounter />
      <Caption />
    </AbsoluteFill>
  );
};
