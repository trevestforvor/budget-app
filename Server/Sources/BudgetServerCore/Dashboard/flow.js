// The month's cash flow as a Sankey (GET /v1/flow): income sources → Bills / Subscriptions / Everyday / Saved → each
// bucket's top categories. The ledger works out every figure and balances every node; this only draws it, in SVG
// built in the DOM (classes for colour, nothing inline for the CSP to refuse).
import { h, fill, api, money, skeleton, callout, button } from "./core.js";

const NS = "http://www.w3.org/2000/svg";
const BAR = 8, GAP = 10, LABEL_H = 34;

function svg(tag, attrs, ...kids) {
  const el = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs || {})) if (v != null && v !== false) el.setAttribute(k, String(v));
  for (const kid of kids.flat()) if (kid != null && kid !== false) el.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
  return el;
}

const amount = (m) => m.minor / 100;
const toneClass = (node) => (node && node.color ? `tone-${node.color}` : "neutral");

/// Where everything goes, the phone's way (DSSankeyLayout): one scale for every column, each column centred with its
/// spare room spread between bars, bands stacked in the order of their other ends, labels nudged a label apart.
export function layout(flow, width) {
  const columns = [...new Set(flow.nodes.map((n) => n.column))].sort((a, b) => a - b);
  const busiest = Math.max(1, ...columns.map((c) => flow.nodes.filter((n) => n.column === c).length));
  const height = Math.max(300, busiest * LABEL_H + GAP);
  const trailing = Math.min(150, width * 0.36);
  const right = Math.max(BAR * 3, width - trailing);
  const last = columns[columns.length - 1] || 0;
  const x = (c) => (last ? ((right - BAR) * c) / last : 0);
  const scales = columns.map((c) => {
    const list = flow.nodes.filter((n) => n.column === c);
    const total = list.reduce((s, n) => s + amount(n.value), 0);
    return total > 0 ? Math.max(0, height - GAP * Math.max(list.length - 1, 0)) / total : Infinity;
  });
  const scale = Math.min(...scales) === Infinity ? 0 : Math.min(...scales);
  const bars = new Map();
  const labels = [];
  columns.forEach((c, index) => {
    const list = flow.nodes.filter((n) => n.column === c);
    const heights = list.map((n) => Math.max(2, amount(n.value) * scale));
    const used = heights.reduce((a, b) => a + b, 0);
    const spare = Math.max(0, height - used - GAP * Math.max(list.length - 1, 0));
    const between = GAP + (list.length > 1 ? Math.min(spare / (list.length - 1), GAP * 3) : 0);
    let y = Math.max(0, (height - (used + between * Math.max(list.length - 1, 0))) / 2);
    const centres = [];
    list.forEach((n, i) => {
      bars.set(n.id, { node: n, x: x(c), y, h: heights[i] });
      centres.push(y + heights[i] / 2);
      y += heights[i] + between;
    });
    for (let i = 1; i < centres.length; i++) centres[i] = Math.max(centres[i], centres[i - 1] + LABEL_H);
    if (centres.length && centres[centres.length - 1] > height - LABEL_H / 2) {
      centres[centres.length - 1] = height - LABEL_H / 2;
      for (let i = centres.length - 2; i >= 0; i--) centres[i] = Math.min(centres[i], centres[i + 1] - LABEL_H);
    }
    const lx = x(c) + BAR + 6;
    const room = (index + 1 < columns.length ? x(columns[index + 1]) - 4 : width) - lx;
    list.forEach((n, i) => labels.push({ node: n, x: lx, y: centres[i], room, last: c === last }));
  });
  const links = flow.links.filter((l) => bars.has(l.source) && bars.has(l.target) && l.value.minor > 0);
  const out = new Map(), into = new Map(), tops = new Map();
  const key = (l) => `${l.source}>${l.target}`;
  [...links].sort((a, b) => bars.get(a.source).y - bars.get(b.source).y || bars.get(a.target).y - bars.get(b.target).y).forEach((l) => {
    const top = out.has(l.source) ? out.get(l.source) : bars.get(l.source).y;
    tops.set(key(l), top);
    out.set(l.source, top + amount(l.value) * scale);
  });
  const bands = [...links].sort((a, b) => bars.get(a.target).y - bars.get(b.target).y || bars.get(a.source).y - bars.get(b.source).y).map((l) => {
    const top = into.has(l.target) ? into.get(l.target) : bars.get(l.target).y;
    into.set(l.target, top + amount(l.value) * scale);
    const s = bars.get(l.source), t = bars.get(l.target);
    return { link: l, from: tops.get(key(l)), to: top, thick: amount(l.value) * scale, sx: s.x + BAR, tx: t.x, tone: t.node };
  });
  return { width, height, bars: [...bars.values()], bands, labels };
}

function bandPath(b) {
  const mid = (b.sx + b.tx) / 2;
  return `M${b.sx},${b.from} C${mid},${b.from} ${mid},${b.to} ${b.tx},${b.to} L${b.tx},${b.to + b.thick} `
    + `C${mid},${b.to + b.thick} ${mid},${b.from + b.thick} ${b.sx},${b.from + b.thick} Z`;
}

/// What a screen reader hears: every node, column by column.
export function summary(flow) {
  const col = (c) => flow.nodes.filter((n) => n.column === c).map((n) => `${n.label} ${money(n.value, { cents: false })}`).join(", ");
  return `In: ${col(0)}. Out: ${col(1)}. By category: ${col(2)}.`;
}

export function sankey(flow, width) {
  const L = layout(flow, width);
  return svg("svg", { class: "sankey", viewBox: `0 0 ${L.width} ${L.height}`, width: L.width, height: L.height, role: "img", "aria-label": summary(flow) },
    svg("title", {}, "Where the month's money went"),
    L.bands.map((b) => svg("path", { class: `band ${toneClass(b.tone)}`, d: bandPath(b) })),
    L.bars.map((b) => svg("rect", { class: `bar ${toneClass(b.node)}`, x: b.x, y: b.y, width: BAR, height: b.h, rx: 2 })),
    L.labels.map((l) => svg("g", { class: "lbl", "aria-hidden": "true" },
      l.last ? svg("circle", { class: `key ${toneClass(l.node)}`, cx: l.x + 3, cy: l.y - 6, r: 3 }) : null,
      svg("text", { class: "name", x: l.x + (l.last ? 11 : 0), y: l.y - 2 }, fit(l.node.label, l.room - (l.last ? 11 : 0))),
      svg("text", { class: "amt", x: l.x, y: l.y + 13 }, money(l.node.value, { cents: false })))));
}

/// A label shortened with an ellipsis to the room it has (about 7px a character at 13px).
function fit(text, room) {
  const max = Math.max(4, Math.floor(room / 7));
  return text.length > max ? text.slice(0, max - 1) + "…" : text;
}

/// This month and the five before it, as "2026-09" keys with names.
function recentMonths() {
  const now = new Date();
  return Array.from({ length: 6 }, (_, i) => {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
    return { key, name: i === 0 ? "This month" : d.toLocaleDateString("en-US", { month: "long", year: "numeric" }) };
  });
}

/// The card: a month picker, the Sankey and the month's three figures.
export function flowCard() {
  const months = recentMonths();
  const body = h("div", { class: "flow-body" }, skeleton(4));
  const select = h("select", { class: "input compact", "aria-label": "Month", onchange: () => load() },
    months.map((m) => h("option", { value: m.key }, m.name)));
  let flow = null, drawnAt = 0;
  const draw = () => {
    if (!flow) return;
    if (!flow.nodes.length) { fill(body, h("p", { class: "empty-line" }, "Nothing came in or went out yet.")); return; }
    drawnAt = Math.max(320, body.clientWidth || 720);
    fill(body, sankey(flow, drawnAt),
      h("dl", { class: "kv" },
        h("dt", {}, "Came in"), h("dd", {}, money(flow.income)),
        h("dt", {}, "Went out"), h("dd", {}, money({ ...flow.spending, minor: -flow.spending.minor })),
        flow.drawnFromCash.minor > 0
          ? [h("dt", {}, "From cash"), h("dd", {}, money({ ...flow.drawnFromCash, minor: -flow.drawnFromCash.minor }))]
          : [h("dt", {}, "Saved"), h("dd", {}, money(flow.saved))]),
      h("p", { class: "t-caption faint" }, "Spending as the budget counts it: each category net of refunds, a yearly charge a twelfth a month. Saved is income left after spending."));
  };
  async function load() {
    const key = select.value;
    fill(body, skeleton(4));
    try {
      flow = await api(key === months[0].key ? "/v1/flow" : `/v1/flow?month=${encodeURIComponent(key)}`);
      draw();
    } catch (error) {
      fill(body, callout({ tone: "watch", title: "The month's flow didn't load.", detail: error.detail || error.message,
        actions: [button("Try again", { compact: true, onclick: () => load() })] }));
    }
  }
  // Redrawn when the card's width changes enough to matter, so labels keep their size.
  if (typeof ResizeObserver !== "undefined") {
    new ResizeObserver(() => { if (flow && Math.abs((body.clientWidth || 0) - drawnAt) > 40) draw(); }).observe(body);
  }
  queueMicrotask(load);
  return h("section", { class: "card flow", "aria-labelledby": "flow-title" },
    h("div", { class: "card-head" }, h("h2", { class: "t-eyebrow card-title", id: "flow-title" }, "Where the money went"), select),
    body);
}
