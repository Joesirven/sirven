// Palette, type scale and geometry from docs/video/STORYBOARD.md (Visual system).
export const C = {
  bg: "#F7F6F2",
  surface: "#FFFFFF",
  hair: "#D8D8D2",
  text: "#202320",
  dim: "#60665F",
  accent: "#365BC4",
};

export const F = {
  sans: '"IBM Plex Sans"',
  mono: '"IBM Plex Mono"',
};

const t = (family, weight, size, lh, extra) => ({
  fontFamily: family,
  fontWeight: weight,
  fontSize: size,
  lineHeight: `${lh}px`,
  letterSpacing: 0,
  ...extra,
});

export const T = {
  endName: t(F.sans, 600, 160, 176, { letterSpacing: "-0.02em" }),
  slogan: t(F.sans, 600, 88, 104, { letterSpacing: "-0.02em" }),
  caption: t(F.sans, 600, 64, 76),
  heading: t(F.sans, 600, 56, 68),
  endSubtitle: t(F.sans, 400, 48, 60),
  body: t(F.sans, 400, 40, 52),
  diagramTitle: t(F.sans, 600, 40, 48),
  mono: t(F.mono, 400, 32, 44),
  monoSelected: t(F.mono, 500, 32, 44),
  detail: t(F.sans, 400, 32, 44),
  label: t(F.sans, 400, 28, 36),
};

export const G = {
  canvas: { w: 1920, h: 1080 },
  concept: { x: 120, y: 64 },
  chapter: { x: 120, y: 120 },
  caption: { x: 120, y: 908, w: 1680, h: 76 },
  phone: { x: 650, y: 192, w: 620, h: 648 },
  sheet: { x: 262, y: 216, w: 1396, h: 600 },
  card: { x: 404, y: 280, w: 1112, h: 456 },
  nodeXs: [120, 560, 1000, 1440],
  node: { y: 336, w: 360, h: 264 },
  connectorY: 468,
  // wrap is the text measure that breaks the slogan after "agent's" (layout wrapping only, no inserted characters).
  slogan: { x: 240, y: 400, w: 1440, h: 208, wrap: 1200 },
  endName: { y: 350 },
  endSubtitle: { y: 558 },
  endPlatform: { y: 658 },
};
