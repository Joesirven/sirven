// Light checks that need no browser: the frame plan matches the storyboard, and the project
// name reaches the video only through the repository-root project.json.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { VIDEO, BEATS } from "../src/timeline.js";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..", "..");
const project = JSON.parse(readFileSync(join(root, "project.json"), "utf8"));
const storyboard = readFileSync(join(root, "docs", "video", "STORYBOARD.md"), "utf8");

test("video is 1920x1080 at 30 frames per second, exactly 450 frames", () => {
  assert.deepEqual(VIDEO, { width: 1920, height: 1080, fps: 30, durationInFrames: 450 });
});

test("beats are contiguous and cover every frame once", () => {
  assert.equal(BEATS[0].from, 0);
  for (let i = 1; i < BEATS.length; i++) assert.equal(BEATS[i].from, BEATS[i - 1].to + 1, BEATS[i].id);
  assert.equal(BEATS.at(-1).to, VIDEO.durationInFrames - 1);
});

test("beat frame ranges match the storyboard table", () => {
  for (const b of BEATS) {
    assert.match(storyboard, new RegExp(`\\| ${b.from} to ${b.to} \\|`), `${b.id} ${b.from}-${b.to}`);
  }
});

test("captions match the storyboard", () => {
  for (const b of BEATS.filter((x) => x.caption)) {
    assert.ok(storyboard.includes(`**${b.caption}**`), b.caption);
  }
});

test("project name is not hard-coded anywhere in video source", () => {
  const src = join(here, "..", "src");
  for (const f of readdirSync(src).filter((x) => /\.jsx?$/.test(x))) {
    const text = readFileSync(join(src, f), "utf8");
    assert.ok(!text.includes(project.name), `${f} hard-codes the project name`);
  }
  assert.match(readFileSync(join(src, "project.js"), "utf8"), /project\.json/);
});
