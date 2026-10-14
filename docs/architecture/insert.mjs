#!/usr/bin/env node
// One-shot helper. For each README listed in build.mjs's manifest, append or
// update the fenced architecture block, insert the vector image reference, and
// write the file. Use build.mjs --check afterwards to verify the fence content
// still matches graph.mjs.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join, resolve, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { DIAGRAMS } from "./graph.mjs";
import { toMermaid } from "./mermaid.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "..", "..");
const renderedDir = join(here, "rendered");

const archReadme = join(here, "README.md");
const MANIFEST = {
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

for (const d of DIAGRAMS) {
  const files = MANIFEST[d.id] ?? [];
  if (files.length === 0) continue;
  const mmd = toMermaid(d).trimEnd();
  for (const file of files) {
    if (!existsSync(file)) {
      console.error(`skip missing ${file}`);
      continue;
    }
    const text = readFileSync(file, "utf8");
    const svgSource = join(renderedDir, `${d.id}.svg`);
    const svgRel = relative(dirname(file), svgSource);
    const block = `${BEGIN(d.id)}\n\n## Architecture: ${d.title}\n\n${d.caption}\n\n![${d.title}](${svgRel})\n\nDiagram source, generated from \`docs/architecture/graph.mjs\`:\n\n\`\`\`mermaid\n${mmd}\n\`\`\`\n\n${END(d.id)}`;
    const begin = text.indexOf(BEGIN(d.id));
    const end = text.indexOf(END(d.id));
    let next;
    if (begin >= 0 && end > begin) {
      next = text.slice(0, begin) + block + text.slice(end + END(d.id).length);
    } else {
      // Insert after the first level-1 heading paragraph, or at end of file.
      const m = text.match(/^#\s[^\n]*\n/);
      if (m) {
        const idx = m.index + m[0].length;
        next = text.slice(0, idx) + "\n" + block + "\n" + text.slice(idx);
      } else {
        next = text + "\n\n" + block + "\n";
      }
    }
    if (next !== text) {
      writeFileSync(file, next);
      console.log(`updated ${file}`);
    }
  }
}
