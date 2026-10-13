#!/usr/bin/env node
// Build the architecture diagrams from docs/architecture/graph.mjs.
//
// For each diagram in graph.mjs, emit a Mermaid source file under
// docs/architecture/diagrams/<id>.mmd, render it with pretty-mermaid to
// docs/architecture/rendered/<id>.svg, and verify that each README referenced
// in the manifest below contains the current Mermaid source inside its own
// ```mermaid fence. Fails loudly on any drift so "same diagram data" stays true.
//
// Usage:
//   node docs/architecture/build.mjs           # generate + render + verify
//   node docs/architecture/build.mjs --check   # verify only, no writes: the committed
//                                              # .mmd sources and .svg images must match
//                                              # graph.mjs, which needs pretty-mermaid
//                                              # (npm --prefix video install)

import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";
import { DIAGRAMS } from "./graph.mjs";
import { toMermaid } from "./mermaid.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "..", "..");

const diagramsDir = join(here, "diagrams");
const renderedDir = join(here, "rendered");

const archReadme = join(here, "README.md");
const README_MANIFEST = {
  "system-overview": [archReadme],
  "access-levels": [archReadme],
  "installer": [archReadme],
  "runtime-seam": [archReadme],
  "phone-bridge": [archReadme],
  "peer-routing": [archReadme],
  "ride-demo": [join(repoRoot, "demo/ride-to-the-barber/README.md"), join(repoRoot, "connectors/ride/README.md"), join(repoRoot, "docs/connector/README.md")],
  "concierge-ops": [join(repoRoot, "concierge-ops/README.md")],
  "keep-awake": [join(repoRoot, "macos/keep-awake/README.md")],
};

const BEGIN = (id) => `<!-- architecture:begin ${id} -->`;
const END = (id) => `<!-- architecture:end ${id} -->`;

const extractFence = (text, id) => {
  const begin = text.indexOf(BEGIN(id));
  const end = text.indexOf(END(id));
  if (begin < 0 || end < 0) return null;
  const inner = text.slice(begin, end);
  const m = inner.match(/```mermaid\n([\s\S]*?)\n```/);
  return m ? m[1] : null;
};

const check = process.argv.includes("--check");

const prettyMermaid = (() => {
  const candidates = [
    join(repoRoot, "video", "node_modules", ".bin", "pretty-mermaid"),
    join(repoRoot, "node_modules", ".bin", "pretty-mermaid"),
  ];
  for (const c of candidates) if (existsSync(c)) return c;
  return null;
})();

mkdirSync(diagramsDir, { recursive: true });
mkdirSync(renderedDir, { recursive: true });

const problems = [];
let wrote = 0, rendered = 0, verified = 0, images = 0;

if (check && !prettyMermaid) {
  problems.push("pretty-mermaid not installed, so the rendered images cannot be checked; run npm --prefix video install");
}

for (const d of DIAGRAMS) {
  const mmd = toMermaid(d);
  const mmdPath = join(diagramsDir, `${d.id}.mmd`);
  const svgPath = join(renderedDir, `${d.id}.svg`);

  if (!check) {
    writeFileSync(mmdPath, mmd);
    wrote++;
    if (prettyMermaid) {
      try {
        execFileSync(prettyMermaid, ["render", mmdPath, "-o", svgPath, "--theme", "light"], { stdio: ["ignore", "ignore", "pipe"] });
        rendered++;
      } catch (err) {
        problems.push(`${d.id}: render failed: ${err.message.split("\n")[0]}`);
      }
    }
  } else {
    // the committed source must be exactly what graph.mjs produces today
    const committedMmd = existsSync(mmdPath) ? readFileSync(mmdPath, "utf8") : null;
    if (committedMmd !== mmd) problems.push(`${d.id}: diagrams/${d.id}.mmd is stale; run build.mjs`);
    // and the committed image must be exactly what pretty-mermaid renders from that source
    if (prettyMermaid) {
      const scratch = mkdtempSync(join(tmpdir(), "architecture-check-"));
      try {
        const tmpMmd = join(scratch, `${d.id}.mmd`);
        const tmpSvg = join(scratch, `${d.id}.svg`);
        writeFileSync(tmpMmd, mmd);
        execFileSync(prettyMermaid, ["render", tmpMmd, "-o", tmpSvg, "--theme", "light"], { stdio: ["ignore", "ignore", "pipe"] });
        const fresh = readFileSync(tmpSvg, "utf8");
        const committedSvg = existsSync(svgPath) ? readFileSync(svgPath, "utf8") : null;
        if (committedSvg !== fresh) problems.push(`${d.id}: rendered/${d.id}.svg is stale; run build.mjs`);
        else images++;
      } catch (err) {
        problems.push(`${d.id}: render check failed: ${err.message.split("\n")[0]}`);
      } finally {
        rmSync(scratch, { recursive: true, force: true });
      }
    }
  }

  const readmes = README_MANIFEST[d.id] ?? [];
  for (const file of readmes) {
    if (!existsSync(file)) {
      problems.push(`${d.id}: ${file} missing`);
      continue;
    }
    const text = readFileSync(file, "utf8");
    const current = extractFence(text, d.id);
    if (current === null) {
      problems.push(`${d.id}: ${file} has no mermaid fence between ${BEGIN(d.id)} and ${END(d.id)}`);
    } else if (current.trimEnd() !== mmd.trimEnd()) {
      problems.push(`${d.id}: ${file} fence drifted; run docs/architecture/insert.mjs`);
    } else verified++;
  }
}

if (!prettyMermaid && !check) {
  console.warn("pretty-mermaid not installed; skipping render. Run `npm --prefix video install` first.");
}

console.log(`wrote=${wrote} rendered=${rendered} images=${images} verified=${verified} problems=${problems.length}`);
if (problems.length) {
  for (const p of problems) console.error(`  ${p}`);
  process.exit(1);
}
