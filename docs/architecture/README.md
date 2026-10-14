# Architecture diagrams

<!-- architecture:begin system-overview -->

## Architecture: System overview

The runtime seam asks the policy engine, which reads the compiled levels and writes to audit.

![System overview](rendered/system-overview.svg)

Diagram source, generated from `docs/architecture/graph.mjs`:

```mermaid
flowchart LR
  %% System overview
  subgraph g_person["person"]
  owner(("Owner"))
  agent(("Personal agent"))
  end
  subgraph g_core["core"]
  runtime["lib/sirven_runtime"]
  policy["lib/policy_engine.py"]
  levels["levels/"]
  audit["lib/audit.sh"]
  kill["lib/kill_switch.sh"]
  end
  subgraph g_edge["edge"]
  phone["lib/phone_bridge.py"]
  connectors["connectors/ride"]
  concierge["concierge-ops"]
  end
  tailscale["lib/tailscale.sh"]
  owner -->|chat| agent
  agent -->|request| runtime
  runtime -->|ask| policy
  policy -->|read grant| levels
  policy -->|log| audit
  runtime --> phone
  runtime --> connectors
  runtime --> concierge
  runtime --> tailscale
  owner -->|stop| kill
```

<!-- architecture:end system-overview -->

Every diagram in sirven comes from one source: `docs/architecture/graph.mjs`. The build in
`docs/architecture/build.mjs` emits Mermaid source under `diagrams/`, renders a hand-drawn vector
image under `rendered/` with the `pretty-mermaid` package, and verifies that every README fence
still matches the source. If a fence drifts, the build fails.

The Remotion architecture video in `video/src/architecture/` reads the same graph module and lays
each diagram out on the same column grid. There is one formatting language across the written
docs and the video.

- Package used to render: `pretty-mermaid@0.1.0` by `kamranahmedse`, pinned in `video/package.json`.
  Why this one, not plain Mermaid styling: the maintainer chose the package. It is a renderer for Mermaid
  source that writes vector images with a hand-drawn stroke (through `roughjs`) and the Balsamiq
  Sans Neue face, and it reads the same `flowchart` and `sequenceDiagram` dialects, so one source
  of truth stays one source of truth. The committed vector images show that style on viewers that
  do not render Mermaid themselves; the fence stays in every README, as the project requires.

## Build

```
npm --prefix video install
node docs/architecture/build.mjs           # write, render, and verify
node docs/architecture/build.mjs --check   # verify only, no writes
```

The check also compares each `diagrams/*.mmd` source and `rendered/*.svg` image with a fresh build
of `graph.mjs`, so a stale image fails the check too. Both need pretty-mermaid. After changing
`graph.mjs`, run `node docs/architecture/insert.mjs` for the README fences, then
`node docs/architecture/build.mjs` (without `--check`) to regenerate the sources and images, and
commit them together.

## Topics not covered by a README

These four topics do not have a README of their own; the diagram source and rendered vector
image live here. The fenced Mermaid source is the authority. For written detail, follow the file
names on the nodes.

<!-- architecture:begin access-levels -->

## Architecture: Access levels, grant audit, and rollback

The three level files under levels/ compile into grants; every apply writes to the audit log; `sirven grant rollback` reverses one change by reading that log; the kill switch removes every entry.

![Access levels, grant audit, and rollback](rendered/access-levels.svg)

Diagram source, generated from `docs/architecture/graph.mjs`:

```mermaid
flowchart LR
  %% Access levels, grant audit, and rollback
  subgraph g_level["level"]
  observer["levels/observer.json"]
  builder["levels/builder.json"]
  operator["levels/operator.json"]
  end
  subgraph g_core["core"]
  compiler["lib/grant_compiler.py"]
  control["lib/access_control.sh"]
  audit["lib/audit.sh"]
  end
  subgraph g_action["action"]
  rollback["sirven grant rollback"]
  kill["lib/kill_switch.sh"]
  end
  observer --> compiler
  builder --> compiler
  operator --> compiler
  compiler -->|plan| control
  control -->|step and grant entries| audit
  rollback -->|last-grant| audit
  rollback -->|revoke --record| compiler
  kill -->|revoke --all| control
```

<!-- architecture:end access-levels -->

<!-- architecture:begin installer -->

## Architecture: Plan-first installer

install.sh runs preflight and questions, writes a plan, and only then adopts, lays out, and installs components.

![Plan-first installer](rendered/installer.svg)

Diagram source, generated from `docs/architecture/graph.mjs`:

```mermaid
flowchart LR
  %% Plan-first installer
  install["install.sh"]
  subgraph g_check["check"]
  preflight["lib/preflight.sh"]
  questions["lib/questions.sh"]
  end
  plan["lib/plan.sh"]
  review(("owner reviews plan"))
  subgraph g_apply["apply"]
  adopt["lib/adopt.sh"]
  layout["lib/layout.sh"]
  components["lib/components.sh"]
  end
  install --> preflight
  preflight --> questions
  questions -->|write plan| plan
  plan --> review
  review -->|approve| adopt
  adopt --> layout
  layout --> components
```

<!-- architecture:end installer -->

<!-- architecture:begin runtime-seam -->

## Architecture: Runtime seam and policy decisions

Every fetch crosses one seam. The policy engine reads the compiled grants and writes a decision to the log.

![Runtime seam and policy decisions](rendered/runtime-seam.svg)

Diagram source, generated from `docs/architecture/graph.mjs`:

```mermaid
flowchart LR
  %% Runtime seam and policy decisions
  client["lib/sirven_runtime/client.py"]
  subgraph g_core["core"]
  seam["lib/sirven_runtime/seam.py"]
  server["lib/sirven_runtime/server.py"]
  policy["lib/policy_engine.py"]
  end
  subgraph g_data["data"]
  grants[("compiled grants")]
  log[("lib/sirven_runtime/decision_log.py")]
  end
  fetch["lib/sirven_runtime/fetch.py"]
  client -->|request| seam
  seam --> server
  server -->|decide| policy
  policy -->|read| grants
  policy -->|write| log
  server -->|if allowed| fetch
```

<!-- architecture:end runtime-seam -->

<!-- architecture:begin phone-bridge -->

## Architecture: iPhone bridge and consent gates

The owner opts in per session (`sirven phone allow`), the bridge speaks only to a plugged-in phone through WebDriverAgent, every money-bearing tap waits on a hold token, and every event lands in actions.jsonl as plain words. The bridge never touches the phone's own Face ID or Apple Pay prompts.

![iPhone bridge and consent gates](rendered/phone-bridge.svg)

Diagram source, generated from `docs/architecture/graph.mjs`:

```mermaid
flowchart LR
  %% iPhone bridge and consent gates
  owner(("Owner"))
  subgraph g_gate["gate"]
  consent{{"sirven phone allow (session)"}}
  hold{{"money hold (approve or deny)"}}
  pay{{"phone's own Face ID or Apple Pay"}}
  end
  subgraph g_core["core"]
  bridge["lib/phone_bridge.py"]
  crawler["lib/phone_crawler.py"]
  wda["WebDriverAgent"]
  end
  subgraph g_data["data"]
  map[("lib/phone_map.py")]
  audit[("actions.jsonl")]
  end
  phone[/"plugged-in iPhone (cable)"/]
  owner -->|typed yes| consent
  consent -->|unlock| bridge
  bridge --> crawler
  crawler -->|once a day| map
  bridge --> wda
  wda -->|cable only| phone
  bridge -->|money-bearing tap| hold
  hold -->|approve or deny| owner
  bridge -.->|wait, read only| pay
  bridge -->|plain words| audit
```

<!-- architecture:end phone-bridge -->

<!-- architecture:begin peer-routing -->

## Architecture: Peer routing: policy, attestation, and carrier transport built, ship gate closed

Policy, attestation, the site review workflow, and the carrier transport are built and tested on loopback. Still open: the user-side wiring in lib/sirven_runtime/seam.py, authentication between two machines, and the ship gate, which stays closed.

![Peer routing: policy, attestation, and carrier transport built, ship gate closed](rendered/peer-routing.svg)

Diagram source, generated from `docs/architecture/graph.mjs`:

```mermaid
flowchart LR
  %% Peer routing: policy, attestation, and carrier transport built, ship gate closed
  requester(("requesting device"))
  envelope["signed envelope"]
  subgraph g_built["built"]
  attestation["lib/attestation"]
  review["lib/allowlist_review.py"]
  registry["signed registry"]
  peer["lib/peer_routing.py"]
  policy["lib/policy_engine.py"]
  reciprocity["lib/reciprocity.py"]
  transport["lib/peer_transport.py (carrier, loopback)"]
  end
  subgraph g_pending["pending"]
  seam{{"lib/sirven_runtime/seam.py (user wiring open)"}}
  auth{{"host authentication between machines (open)"}}
  gate{{"ship gate (closed)"}}
  end
  requester -->|sign one request| envelope
  envelope -->|verify| attestation
  review -->|publish| registry
  registry -->|sign version| attestation
  attestation --> peer
  peer -->|decision table| policy
  peer -->|reserve bytes| reciprocity
  seam -.->|wiring open| peer
  peer -.->|would carry real traffic| transport
  auth -.->|open| transport
  transport -.-> gate
```

<!-- architecture:end peer-routing -->

## Ship gate

The peer routing diagram shows what is built and what is not. Jose's own words, carried verbatim
from `docs/peer-routing.md`:

> Do not ship any peer routing of authenticated traffic until the attestation layer and the
> site-allowlist review workflow are both working end to end.

Policy, attestation, the site review workflow, and the carrier transport (`lib/peer_transport.py`)
are built and tested on loopback. Still open: the user-side wiring in `lib/sirven_runtime/seam.py`,
authentication between two machines, and the ship gate. So this diagram marks the real-traffic edge
dashed and the gate node closed. This document never claims peer routing works.
