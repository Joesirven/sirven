// Emit a Mermaid flowchart fence from a diagram in graph.mjs.
// Groups become subgraphs when more than one node shares a group.
// A dashed edge style renders as a dotted link ("-.->"). Everything is readable without colour.

const safe = (s) => String(s).replace(/"/g, "'");

const nodeShapeFor = (group) => {
  if (group === "person") return (id, label) => `  ${id}(("${safe(label)}"))`;
  if (group === "data") return (id, label) => `  ${id}[("${safe(label)}")]`;
  if (group === "gate" || group === "pending") return (id, label) => `  ${id}{{"${safe(label)}"}}`;
  if (group === "device" || group === "system") return (id, label) => `  ${id}[/"${safe(label)}"/]`;
  return (id, label) => `  ${id}["${safe(label)}"]`;
};

const edgeArrow = (style) => (style === "dashed" ? "-.->" : "-->");

export function toMermaid(diagram) {
  const lines = [];
  lines.push("flowchart LR");
  lines.push(`  %% ${safe(diagram.title)}`);

  const byGroup = new Map();
  for (const n of diagram.nodes) {
    if (!byGroup.has(n.group)) byGroup.set(n.group, []);
    byGroup.get(n.group).push(n);
  }

  for (const [group, nodes] of byGroup) {
    const sub = nodes.length > 1;
    if (sub) lines.push(`  subgraph g_${group}["${group}"]`);
    for (const n of nodes) {
      const shape = nodeShapeFor(n.group);
      lines.push(shape(n.id, n.label));
    }
    if (sub) lines.push("  end");
  }

  for (const e of diagram.edges) {
    const arrow = edgeArrow(e.style);
    if (e.label) lines.push(`  ${e.from} ${arrow}|${safe(e.label)}| ${e.to}`);
    else lines.push(`  ${e.from} ${arrow} ${e.to}`);
  }

  return lines.join("\n") + "\n";
}
