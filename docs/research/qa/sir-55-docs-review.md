# SIR-55 architecture docs review

Reviewed commit 25bbdd7 (one commit on origin/main 1b286d4). Reviewer: quality control thread, inline verification.

## Verdict: CHANGES REQUIRED

## Must fix

1. The peer routing diagram understates what is built. `docs/architecture/graph.mjs` (peer-routing) labels the node "transport (not built)", its title says "transport in progress", and its caption says the transport "is being built by a separate thread". On main, `lib/peer_transport.py` exists (commit 4e840a8, "peer transport, carrier side: real bytes between two local processes") and `docs/peer-routing.md` lines 5 and 48 say it is built and tested end to end on loopback. The ship gate is still closed, and `lib/sirven_runtime/seam.py` still refuses peer routes. Correct the node, title, caption, the "Ship gate" paragraph in `docs/architecture/README.md`, regenerate the fences with `insert.mjs`, re-render the image, and update the video scene (it reads the same graph module). Suggested wording: carrier transport built on loopback; user-side wiring in the seam, host authentication between two machines, and the ship gate still open. Keep "would carry" dashed for real traffic.

## Should fix

2. The drift check (`build.mjs --check`) compares only README fences against `graph.mjs`. It does not compare `diagrams/*.mmd` or `rendered/*.svg`, so a stale image can pass. Add a check that each `.mmd` equals the generated source, and record in the README that images need `build.mjs` (without `--check`) after pretty-mermaid is installed.
3. Node labels such as `runtime/client.py` omit the `lib/sirven_runtime/` prefix, while other labels use full `lib/` paths. Use the real paths.

## Evidence

- Accuracy spot-check against the working tree (equal to origin/main for these files): every file named in the system overview, access levels, installer, runtime seam, phone bridge, peer routing, and concierge-ops diagrams exists (loop over `[ -e path ]`), with the exception of the short `runtime/*.py` labels noted above, which live under `lib/sirven_runtime/`. Checked in detail: `sirven grant rollback` reads the audit log (`bin/sirven` line 5, `last-grant` and `revoke --record` in `lib/grant_compiler.py`); phone bridge has `allow`, hold tokens, and `holds/` (`lib/phone_bridge.py`); keep-awake default lease is `12 * 60 * 60` (`macos/keep-awake/Sources/SirvenKeepAwake/Client.swift:39`); `sirven awake` is macOS only (`bin/sirven`); peer routing seam refusal (`lib/sirven_runtime/seam.py`). Only peer routing was wrong (item 1). The ship gate and "would carry" are correctly dashed or marked closed.
- Public safety: `git show 25bbdd7 | grep -n '/Users/'` found nothing (exit 1). No tokens, secrets, addresses, or tailnet names in the added files. The only owner references are the allowed quoted decisions ("Jose's decision of October 11, 2026" and the verbatim ship gate quote). The commit adds nothing about the sunsirven project; grep for it in the changed files found nothing.
- Drift check: baseline `node docs/architecture/build.mjs --check` exit 0 (verified=11). After changing one label in `graph.mjs` (scratch edit, restored with no diff afterward), exit 1 with two drift messages. It does fail on README drift, within the limit in item 2.
- Dependency: `pretty-mermaid` 0.1.0 is under `devDependencies` of `video/package.json` only, exactly pinned, with its own lockfile in `video/`. Nothing at the repository root changes, so installing or running sirven is unaffected. Its optional native canvas package needs Node 22 or newer, only for rendering.
- Gates, foreground: `node docs/architecture/build.mjs --check` exit 0; `npm --prefix video test` exit 0 (9 tests pass); `make lint` exit 0 (shell syntax check on 54 files; the shell linter is not installed on this Mac, so that part was skipped). Video node modules were not installed, so I did not render the images or the video.

## Result

CHANGES REQUIRED: fix item 1 (and preferably 2 and 3), then re-review.

Commit: see the commit that adds this file on branch docs-review-architecture-diagrams-and-video-sir-thr_pq9t36ssr7.

## Re-review of c387460

Checked in a scratch worktree of c387460 (single commit on origin/main 1b286d4), with the video dependencies installed there (`npm --prefix video ci`, exit 0), then discarded.

Must fix (peer routing): resolved.
- `graph.mjs`, `diagrams/peer-routing.mmd`, the architecture README fence and caption, and the `rendered/peer-routing.svg` text all now show `lib/peer_transport.py (carrier, loopback)` as built, and show the user wiring in `lib/sirven_runtime/seam.py`, host authentication between machines, and the ship gate (closed) as pending. Real traffic stays dashed ("would carry real traffic").
- No remaining "not built", "in progress", or "separate thread" wording in `docs/architecture` or `video/src` (grep, empty). The README "Ship gate" paragraph names the carrier transport. The video scene reads `graph.mjs`, so it follows automatically.

Should fix 2 (drift check coverage): resolved.
- `build.mjs --check` now compares each `.mmd` to what `graph.mjs` generates and re-renders each image and compares it byte for byte. Tested: appending a comment to `rendered/keep-awake.svg` gave exit 1 ("rendered/keep-awake.svg is stale"); editing `diagrams/keep-awake.mmd` gave "diagrams/keep-awake.mmd is stale" with problems=1. Both were reverted.
- It fails closed when pretty-mermaid is not installed (exit 1 with an instruction), so a bare checkout cannot pass silently. Worth one sentence in the contributing notes, but not blocking.

Should fix 3 (path labels): resolved. The runtime seam diagram now uses `lib/sirven_runtime/client.py` and so on; no `label: "runtime/` remains.

Gates, foreground:
- `node docs/architecture/build.mjs --check` with dependencies installed: exit 0 (images=9 verified=11 problems=0). Without them: exit 1 by design.
- `npm --prefix video test`: exit 0 (9 pass, 0 fail).
- `git show c387460 | grep -n '/Users/'`: empty.

Verdict: APPROVE

Commit: see the commit that adds this section (reported in the thread reply).
