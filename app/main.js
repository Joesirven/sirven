// the tier dial, the consent moment, the site list, and the usage meter. every word on
// screen comes from copy/consent-moment.md or copy/surfaces.md, so Jose reviews one place.
// data comes from /api/state (runtime), /api/ledger (reciprocity ledger), and
// /api/registry (site registry); the shapes are in docs/app-interfaces.md.
"use strict";

const TIERS = ["solo", "neighborly", "coop"];
const OPEN_TIERS = new Set(["solo", "neighborly"]);
// lending and autonomy rise together, one notch per tier. the bars show that link.
const LEVELS = {
  solo: { lend: 0, autonomy: 1 / 3 },
  neighborly: { lend: 0.5, autonomy: 2 / 3 },
  coop: { lend: 1, autonomy: 1 },
};
const NEAR_CAP = 0.9;
const COPY = {};
const app = { state: null, ledger: null, registry: null, preview: "solo", view: "dial", asked: false };

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

// copy files: "## key" starts an entry, the lines under it are the text, ">" lines are
// review notes and never shown, and headings with spaces are section titles for the reader.
function parseCopy(markdown) {
  let key = null;
  for (const line of markdown.split("\n")) {
    const heading = line.match(/^#{1,6}\s+(.*)$/);
    if (heading) {
      key = /^[a-z][a-z0-9_.]*$/.test(heading[1].trim()) ? heading[1].trim() : null;
      if (key) COPY[key] = "";
      continue;
    }
    if (!key || line.startsWith(">") || !line.trim()) continue;
    COPY[key] = COPY[key] ? `${COPY[key]} ${line.trim()}` : line.trim();
  }
}

function t(key, vars = {}) {
  const text = COPY[key];
  if (text === undefined) {
    console.error(`copy is missing ${key}`);
    return key;
  }
  return text.replace(/\{(\w+)\}/g, (match, name) => (name in vars ? vars[name] : match));
}

function gigabytes(bytes) {
  const value = Math.floor((bytes / 1e9) * 100) / 100;
  return String(value);
}

function size(bytes) {
  if (bytes >= 1e9) {
    const value = gigabytes(bytes);
    return `${value} ${value === "1" ? "gigabyte" : "gigabytes"}`;
  }
  if (bytes >= 1e6) return `${Math.round(bytes / 1e6)} megabytes`;
  return `${Math.max(0, Math.round(bytes / 1e3))} kilobytes`;
}

function capText() {
  return size(app.ledger ? app.ledger.cap_bytes : 5e9);
}

// dates in the interfaces are calendar days in universal time; show that same day everywhere.
function day(iso, withYear = false) {
  const stamp = new Date(iso);
  const local = new Date(stamp.getUTCFullYear(), stamp.getUTCMonth(), stamp.getUTCDate());
  const options = { month: "long", day: "numeric" };
  if (withYear) options.year = "numeric";
  return local.toLocaleDateString("en-US", options);
}

async function api(path, body) {
  const response = await fetch(path, body === undefined ? { cache: "no-store" } : {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return { ok: response.ok, body: await response.json().catch(() => ({})) };
}

let toastTimer;
function toast(text) {
  const node = $(".toast");
  node.textContent = text;
  node.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => node.classList.remove("show"), 3200);
}

// a text swap fades out, changes, and fades back in, so nothing snaps.
function swapText(node, text) {
  if (node.textContent === text) return;
  if (!node.textContent) {
    node.textContent = text;
    return;
  }
  node.classList.add("swap");
  setTimeout(() => {
    node.textContent = text;
    node.classList.remove("swap");
  }, 150);
}

/* navigation */

function showView(view) {
  app.view = view;
  const tabs = $$(".tabs button");
  tabs.forEach((tab, index) => {
    const on = tab.dataset.view === view;
    tab.setAttribute("aria-selected", String(on));
    if (on) $(".tabs-indicator").style.transform = `translateX(${index * 100}%)`;
  });
  $$(".view").forEach((section) => {
    section.hidden = section.dataset.view !== view;
  });
  if (view === "meter") renderMeter();
  if (view === "dial" && app.state) renderDial();
}

/* tier dial */

function renderDial() {
  const current = app.state.tier;
  const preview = app.preview;
  const index = TIERS.indexOf(preview);
  const stops = $(".dial-stops");
  if (!stops.children.length) {
    TIERS.forEach((tier) => {
      const stop = el("button", "dial-stop");
      stop.setAttribute("role", "radio");
      stop.dataset.tier = tier;
      stop.append(el("span", "stop-name", t(`dial.${tier}.name`)), el("span", "stop-note"));
      stop.addEventListener("click", () => {
        app.preview = tier;
        renderDial();
      });
      stops.append(stop);
    });
  }
  $$(".dial-stop").forEach((stop) => {
    const tier = stop.dataset.tier;
    stop.setAttribute("aria-checked", String(tier === preview));
    $(".stop-note", stop).textContent = tier === current ? t("dial.current") : OPEN_TIERS.has(tier) ? "" : t("dial.notyet");
  });

  const track = $(".dial-track");
  const fraction = index / (TIERS.length - 1);
  $(".dial-knob").style.transform = `translateX(${track.clientWidth * fraction}px)`;
  $(".dial-fill").style.transform = `scaleX(${fraction})`;

  swapText($(".tier-summary"), t(`dial.${preview}.summary`));
  for (const axis of ["lend", "autonomy"]) {
    const row = $(`.linked-row[data-axis="${axis}"]`);
    $(".bar-fill", row).style.transform = `scaleX(${LEVELS[preview][axis]})`;
    swapText($(".linked-text", row), t(`dial.${preview}.${axis}`, { cap: capText() }));
  }

  const action = $(".dial-action");
  const key = `${preview}:${current}`;
  if (action.dataset.key === key) return;
  action.dataset.key = key;
  action.replaceChildren();
  if (preview === current) return;
  const button = el("button", "pill pill-enter");
  if (!OPEN_TIERS.has(preview)) {
    button.classList.add("quiet");
    button.disabled = true;
    button.textContent = t("dial.notyet");
  } else {
    button.classList.add(preview === "solo" ? "quiet" : "primary");
    button.textContent = t("dial.choose", { tier: t(`dial.${preview}.name`) });
    button.addEventListener("click", () => (preview === "solo" ? moveToSolo() : openConsent("dial")));
  }
  action.append(button);
}

// leaving Neighborly is one step: less sharing never needs a consent moment.
async function moveToSolo() {
  const result = await api("/api/tier", { tier: "solo" });
  if (!result.ok) return;
  app.state = result.body;
  app.preview = "solo";
  renderAll();
  toast(t("dial.moved.solo"));
}

/* usage meter */

let shownUsed = null;
function tweenFigure(node, to) {
  if (shownUsed === to && node.textContent) return;
  const from = shownUsed === null ? to : shownUsed;
  shownUsed = to;
  const cap = capText();
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const start = performance.now();
  const step = (now) => {
    const progress = reduce ? 1 : Math.min(1, (now - start) / 500);
    const eased = 1 - Math.pow(1 - progress, 3);
    node.textContent = t("meter.used", { used: gigabytes(from + (to - from) * eased), cap });
    if (progress < 1) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
}

function renderMeter() {
  const ledger = app.ledger;
  const section = $('.view[data-view="meter"]');
  if (!ledger || section.hidden) return;
  const cap = ledger.cap_bytes;
  const used = Math.min(ledger.used_bytes, cap);
  const quiet = app.state.tier === "solo" && used === 0;
  section.classList.toggle("solo-quiet", quiet);
  tweenFigure($(".meter-figure"), used);

  const carried = Math.min(ledger.carried_bytes, cap) / cap;
  const sent = Math.min(ledger.sent_bytes, cap - Math.min(ledger.carried_bytes, cap)) / cap;
  $(".meter-seg.carried").style.transform = `scaleX(${carried})`;
  $(".meter-seg.sent").style.transform = `translateX(${carried * 100}%) scaleX(${sent})`;
  const over = used >= cap;
  $(".meter-bar").classList.toggle("over", over);
  $(".n-carried").textContent = size(ledger.carried_bytes);
  $(".n-sent").textContent = size(ledger.sent_bytes);

  const note = $(".meter-note");
  const resets = day(ledger.period.end);
  let text = t("meter.resets", { date: resets });
  if (quiet) text = t("meter.solo");
  else if (over) text = t("meter.over", { cap: capText(), date: resets });
  else if (used / cap >= NEAR_CAP) text = `${t("meter.near", { cap: capText() })} ${text}`;
  note.textContent = text;
  note.classList.toggle("alert", over || used / cap >= NEAR_CAP);

  const list = $(".sessions");
  if (!ledger.sessions.length) {
    if (!$(".empty", list)) list.replaceChildren(el("li", "empty", t("meter.sessions.none")));
    return;
  }
  // rows are keyed by session, so a live session grows in place instead of re-entering.
  const seen = new Set();
  ledger.sessions.forEach((session, index) => {
    seen.add(session.id);
    let row = $(`li[data-id="${CSS.escape(session.id)}"]`, list);
    if (!row) {
      row = el("li");
      row.dataset.id = session.id;
      row.style.animationDelay = `${index * 40}ms`;
      row.append(el("span", "domain"), el("span", "size"), el("span", "what"), el("span", "when"));
      list.append(row);
    }
    $(".domain", row).textContent = session.domain;
    $(".size", row).textContent = size(session.bytes);
    $(".what", row).textContent = t(`meter.session.${session.direction}`);
    const when = $(".when", row);
    if (session.ended_at === null) {
      when.replaceChildren(el("span", "live-dot"), document.createTextNode(t("meter.session.live")));
    } else {
      when.textContent = day(session.ended_at);
    }
  });
  $$("li", list).forEach((row) => {
    if (!seen.has(row.dataset.id)) row.remove();
  });
}

/* site list */

function renderList() {
  const registry = app.registry;
  const meta = $(".list-meta");
  meta.replaceChildren();
  if (registry.published_at) {
    meta.append(el("span", "", t("list.version", { version: registry.registry_version, date: day(registry.published_at, true) })));
  }
  if (registry.test_data) meta.append(el("span", "badge", t("list.testdata")));

  const list = $(".sites");
  list.replaceChildren();
  const approved = registry.entries.filter((entry) => entry.status === "approved");
  if (!approved.length) {
    list.append(el("li", "empty", t("list.empty")));
    return;
  }
  approved.forEach((entry, index) => {
    const item = el("li", "site");
    item.style.animationDelay = `${index * 40}ms`;
    const head = el("button", "site-head");
    head.setAttribute("aria-expanded", "false");
    head.append(el("span", "domain", entry.domain), el("span", "scope", t(`list.scope.${entry.scope}`)));
    const inner = el("div", "site-inner");
    inner.append(el("p", "label", t("list.why")), el("p", "why", entry.rationale));
    const dates = el("p", "dates");
    dates.append(el("span", "", t("list.reviewed", { date: day(entry.last_reviewed_at, true) })),
      el("span", "", t("list.next", { date: day(entry.next_review_by, true) })));
    inner.append(dates);
    const sources = (entry.public_positions || []).filter((source) => /^https:\/\//.test(source.url));
    if (sources.length) {
      inner.append(el("p", "label", t("list.sources")));
      const links = el("p");
      sources.forEach((source) => {
        const link = el("a", "", source.label);
        link.href = source.url;
        link.target = "_blank";
        link.rel = "noopener noreferrer";
        links.append(link);
      });
      inner.append(links);
    }
    const body = el("div", "site-body");
    body.append(inner);
    item.append(head, body);
    head.addEventListener("click", () => toggleSite(item, head));
    list.append(item);
  });
}

function toggleSite(item, head) {
  if (item.classList.contains("open")) {
    item.classList.add("closing");
    head.setAttribute("aria-expanded", "false");
    setTimeout(() => item.classList.remove("open", "closing"), 150);
  } else {
    item.classList.add("open");
    head.setAttribute("aria-expanded", "true");
  }
}

/* consent moment */

const consent = { steps: [], at: 0, origin: null, lastFocus: null };

function stepContent(name) {
  const cap = capText();
  const node = el("div", "step");
  const title = (key, vars) => {
    const heading = el("h2", "", t(key, vars));
    heading.id = "consent-title";
    return heading;
  };
  const points = (rows, className = "points") => {
    const list = el("ul", className);
    rows.forEach(([label, text, mark]) => {
      const item = el("li");
      item.append(el("span", `k${mark ? ` ${mark}` : ""}`, label), el("span", "v", text));
      list.append(item);
    });
    return list;
  };
  if (name === "block") {
    const host = (app.state.last_block && app.state.last_block.host) || "";
    const heading = title("consent.block.title", { host: "\u0000" });
    const [before, after] = heading.textContent.split("\u0000");
    heading.replaceChildren(document.createTextNode(before), el("span", "host", host), document.createTextNode(after || ""));
    node.append(el("p", "eyebrow", t("consent.block.eyebrow")), heading, el("p", "", t("consent.block.body")));
  } else if (name === "means") {
    node.append(title("consent.means.title"), points([
      [t("consent.means.lend.label"), t("consent.means.lend.body", { cap })],
      [t("consent.means.get.label"), t("consent.means.get.body")],
      [t("consent.means.agent.label"), t("consent.means.agent.body")],
    ]), el("p", "note", t("consent.means.linked")));
  } else if (name === "list") {
    const approved = app.registry.entries.filter((entry) => entry.status === "approved");
    const count = approved.length;
    const countKey = count === 0 ? "consent.list.count.none" : count === 1 ? "consent.list.count.one" : "consent.list.count.many";
    node.append(title("consent.list.title"), el("p", "", t("consent.list.body")), el("p", "note", t(countKey, { count })));
    if (count) {
      node.append(points(approved.slice(0, 4).map((entry) => ["", entry.domain]), "points marks"));
    }
  } else if (name === "carry") {
    node.append(title("consent.carry.title"), points([
      ["", t("consent.carry.yes"), ""],
      ["", t("consent.carry.no", { cap }), "no"],
      ["", t("consent.carry.who"), ""],
      ["", t("consent.carry.private"), ""],
    ], "points marks"));
  } else if (name === "proof") {
    node.append(title("consent.proof.title"), points([
      ["", t("consent.proof.cap", { cap })],
      ["", t("consent.proof.both")],
      ["", t("consent.proof.signed")],
      ["", t("consent.proof.meter")],
    ], "points marks"));
  } else if (name === "choose") {
    if (app.state.peer_routing_available) {
      node.append(title("consent.choose.title"), el("p", "", t("consent.choose.body")));
    } else {
      node.append(title("consent.closed.title"), el("p", "", t("consent.closed.body")));
    }
  }
  return node;
}

function pill(text, style, onClick) {
  const button = el("button", `pill ${style}`, text);
  button.addEventListener("click", onClick);
  return button;
}

function renderStep(direction = "forward") {
  const name = consent.steps[consent.at];
  const content = stepContent(name);
  if (direction === "back") content.classList.add("back");
  $(".consent-steps").replaceChildren(content);
  $(".consent-dots").replaceChildren(...consent.steps.map((_, index) => el("span", index === consent.at ? "on" : "")));

  const actions = $(".consent-actions");
  const first = consent.at === 0;
  // a choice is always two buttons of equal weight; nothing is preselected or emphasized.
  if (name === "block") {
    actions.replaceChildren(
      pill(t("consent.block.stay"), "quiet", () => decide("solo")),
      pill(t("consent.block.learn"), "quiet", () => go(1)));
  } else if (name === "choose" && app.state.peer_routing_available) {
    actions.replaceChildren(
      pill(t("consent.choose.stay"), "quiet", () => decide("solo")),
      pill(t("consent.choose.join"), "quiet", () => decide("neighborly")));
  } else if (name === "choose") {
    const done = pill(t("consent.closed.ack"), "quiet", () => decide("not_open"));
    done.style.gridColumn = "1 / -1";
    actions.replaceChildren(done);
  } else {
    actions.replaceChildren(
      first ? pill(t("consent.block.stay"), "quiet", () => decide("solo")) : pill(t("consent.back"), "quiet", () => go(-1)),
      pill(t("consent.next"), "primary", () => go(1)));
  }
  $("button", actions).focus({ preventScroll: true });
}

function go(delta) {
  consent.at = Math.max(0, Math.min(consent.steps.length - 1, consent.at + delta));
  renderStep(delta < 0 ? "back" : "forward");
}

function openConsent(origin) {
  const root = $(".consent");
  if (!root.hidden) return;
  app.asked = true;
  consent.origin = origin;
  consent.steps = origin === "block" ? ["block", "means", "list", "carry", "proof", "choose"] : ["means", "list", "carry", "proof", "choose"];
  consent.at = 0;
  consent.lastFocus = document.activeElement;
  root.hidden = false;
  renderStep();
  requestAnimationFrame(() => requestAnimationFrame(() => root.classList.add("open")));
}

function closeConsent() {
  const root = $(".consent");
  root.classList.add("closing");
  root.classList.remove("open");
  setTimeout(() => {
    root.hidden = true;
    root.classList.remove("closing");
    if (consent.lastFocus) consent.lastFocus.focus({ preventScroll: true });
  }, 150);
}

async function decide(decision) {
  if (decision === "neighborly") {
    const moved = await api("/api/tier", { tier: "neighborly" });
    if (!moved.ok) {
      // the runtime said no, most likely because peer routing is not open: show that screen.
      app.state.peer_routing_available = false;
      renderStep();
      return;
    }
    app.state = moved.body;
  }
  const recorded = await api("/api/consent", { decision });
  if (recorded.ok) app.state = recorded.body;
  app.preview = app.state.tier;
  closeConsent();
  renderAll();
  if (decision === "neighborly") toast(t("consent.done.neighborly"));
  if (decision === "solo") toast(t("consent.done.solo"));
}

function maybeAskOnBlock() {
  const state = app.state;
  if (app.asked || state.tier !== "solo" || !state.last_block || state.consent.prompted) return;
  openConsent("block");
}

/* wiring */

function renderAll() {
  renderDial();
  renderMeter();
}

async function refreshState() {
  const result = await api("/api/state");
  if (!result.ok) return;
  const changed = !app.state || result.body.tier !== app.state.tier;
  app.state = result.body;
  if (changed) app.preview = app.state.tier;
  renderDial();
  maybeAskOnBlock();
}

async function refreshLedger() {
  const result = await api("/api/ledger");
  if (!result.ok) return;
  app.ledger = result.body;
  renderMeter();
}

async function boot() {
  const [consentCopy, surfaceCopy, state, ledger, registry] = await Promise.all([
    fetch("/copy/consent-moment.md").then((response) => response.text()),
    fetch("/copy/surfaces.md").then((response) => response.text()),
    api("/api/state"),
    api("/api/ledger"),
    api("/api/registry"),
  ]);
  parseCopy(consentCopy);
  parseCopy(surfaceCopy);
  app.state = state.body;
  app.ledger = ledger.body;
  app.registry = registry.body;
  app.preview = app.state.tier;

  $$("[data-copy]").forEach((node) => {
    node.textContent = t(node.dataset.copy);
  });
  $$("[data-copy-label]").forEach((node) => node.setAttribute("aria-label", t(node.dataset.copyLabel)));
  $$(".tabs button").forEach((tab) => tab.addEventListener("click", () => showView(tab.dataset.view)));
  $(".consent-close").addEventListener("click", () => decide("dismissed"));
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !$(".consent").hidden) decide("dismissed");
  });
  window.addEventListener("resize", renderDial);

  const initial = new URLSearchParams(location.search).get("view");
  showView(["dial", "meter", "list"].includes(initial) ? initial : "dial");
  renderList();
  renderAll();
  $(".shell").setAttribute("aria-busy", "false");
  maybeAskOnBlock();

  setInterval(refreshState, 3000);
  setInterval(refreshLedger, 2000);
}

boot();
