// Light checks that need no browser: the frame plan matches the storyboard, every animated
// interval is data, and brand strings reach the video only through the repository-root project.json.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { VIDEO, BEATS, EVENTS, REVEAL_FRAMES, MIN_HOLD_FRAMES } from "../src/timeline.js";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..");
const srcDir = join(here, "..", "src");
const project = JSON.parse(readFileSync(join(root, "project.json"), "utf8"));
const storyboard = readFileSync(join(root, "docs", "video", "STORYBOARD.md"), "utf8");
const sources = readdirSync(srcDir)
  .filter((x) => /\.jsx?$/.test(x))
  .map((f) => [f, readFileSync(join(srcDir, f), "utf8")]);

const mmss = (frame) => {
  const seconds = frame / VIDEO.fps;
  return `${Math.floor(seconds / 60)}:${(seconds % 60).toFixed(1).padStart(4, "0")}`;
};

// Rows of the four-column beat table: | # | Time | Frames | Beat |
const tableRows = [...storyboard.matchAll(/^\| (\d) \| ([^|]+) \| (\d+) to (\d+) \| ([^|]+) \|$/gm)].map((m) => ({
  n: Number(m[1]),
  time: m[2].trim(),
  from: Number(m[3]),
  to: Number(m[4]),
  name: m[5].trim(),
}));

test("video is 1920x1080 at 30 frames per second, exactly 1350 frames", () => {
  assert.deepEqual(VIDEO, { width: 1920, height: 1080, fps: 30, durationInFrames: 1350 });
});

test("beats are contiguous and cover every frame once", () => {
  assert.equal(BEATS[0].from, 0);
  for (let i = 1; i < BEATS.length; i++) assert.equal(BEATS[i].from, BEATS[i - 1].to + 1, BEATS[i].id);
  assert.equal(BEATS.at(-1).to, 1349);
  assert.equal(BEATS.at(-1).to, VIDEO.durationInFrames - 1);
});

test("every beat row matches the storyboard table", () => {
  assert.equal(tableRows.length, BEATS.length);
  for (const b of BEATS) {
    const row = tableRows.find((r) => r.n === b.n);
    assert.ok(row, `table row ${b.n}`);
    assert.equal(row.from, b.from, `${b.id} from`);
    assert.equal(row.to, b.to, `${b.id} to`);
    assert.equal(row.name, b.name, `${b.id} name`);
    assert.equal(row.time, `${mmss(b.from)} to ${mmss(b.to + 1)}`, `${b.id} time`);
  }
});

test("every non-null caption appears in bold in its own storyboard beat section", () => {
  for (const b of BEATS.filter((x) => x.caption)) {
    const start = storyboard.indexOf(`### Beat ${b.n}.`);
    assert.ok(start >= 0, `section for beat ${b.n}`);
    const next = storyboard.indexOf("### Beat ", start + 1);
    const section = storyboard.slice(start, next < 0 ? undefined : next);
    assert.ok(section.includes(`**${b.caption}**`), b.caption);
  }
  assert.ok(BEATS.filter((x) => !x.caption).map((x) => x.id).join() === "slogan,end");
});

test("the storyboard contains the project.json slogan in bold", () => {
  assert.ok(project.slogan && project.slogan.length > 0);
  assert.ok(storyboard.includes(`**${project.slogan}**`));
});

test("events have unique ids, valid ranges, and sit inside one beat", () => {
  assert.equal(new Set(EVENTS.map((e) => e.id)).size, EVENTS.length);
  for (const e of EVENTS) {
    const b = BEATS.find((x) => x.id === e.beat);
    assert.ok(b, `${e.id} beat`);
    assert.ok(e.from <= e.to, e.id);
    assert.ok(e.from >= b.from && e.to <= b.to, `${e.id} lies within beat ${b.id}`);
    if (e.kind === "reveal") assert.equal(e.to - e.from + 1, REVEAL_FRAMES, `${e.id} is a 12-frame reveal`);
    else assert.equal(e.kind, "travel");
  }
});

test("only one animation at a time, with at least 36 static frames after each event", () => {
  const sorted = [...EVENTS].sort((a, b) => a.from - b.from);
  for (let i = 0; i < sorted.length; i++) {
    const e = sorted[i];
    const nextStart = i + 1 < sorted.length ? sorted[i + 1].from : VIDEO.durationInFrames;
    assert.ok(nextStart > e.to, `${e.id} does not overlap the next event`);
    assert.ok(nextStart - e.to - 1 >= MIN_HOLD_FRAMES, `${e.id} holds ${nextStart - e.to - 1} frames`);
  }
});

test("brand strings are not hard-coded anywhere in video source", () => {
  for (const [f, text] of sources) {
    for (const key of ["name", "subtitle", "slogan"]) {
      assert.ok(!text.includes(project[key]), `${f} hard-codes the project ${key}`);
    }
  }
  assert.match(readFileSync(join(srcDir, "project.js"), "utf8"), /import .* from "\.\.\/\.\.\/project\.json"/);
});

test("no Inter or JetBrains font references remain", () => {
  const pkg = readFileSync(join(here, "..", "package.json"), "utf8");
  for (const [f, text] of [...sources, ["package.json", pkg]]) {
    assert.ok(!/\bInter\b|fontsource\/inter|JetBrains|jetbrains/i.test(text), `${f} references Inter or JetBrains`);
  }
  assert.match(pkg, /@fontsource\/ibm-plex-sans/);
  assert.match(pkg, /@fontsource\/ibm-plex-mono/);
});
