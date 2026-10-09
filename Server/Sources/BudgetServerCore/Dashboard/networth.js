// Net worth on the Accounts page: today's figure and its change over a range, the history as a line (the stretch where
// an investment holds a stand-in value dashed), what you own and owe, and the assets and debts kept by hand — added,
// edited and removed here through POST /v1/actions (saveManualAsset, removeManualAsset), with Undo.
import { h, fill, api, money, bigMoney, rowMoney, sectionHead, button, busy, armed, toast, reportError, afterWrite, dateShort, tag,
  skeleton } from "./core.js";

const RANGES = ["1M", "3M", "YTD", "1Y", "ALL"];
const CATEGORIES = { asset: [["realEstate", "Real estate"], ["vehicle", "Vehicle"], ["other", "Other"]], liability: [["loan", "Loan"], ["other", "Other"]] };
const GROUP_TONE = { cash: "azure", investments: "teal", realEstate: "amber", vehicles: "coral", otherAssets: "lime", cards: "rose", loans: "violet", otherDebts: "irisDeep" };

const view = { range: "3M", data: null, error: null, el: null, editing: null, loading: null, missing: false };

/// The section, built once and kept, so a form being filled in survives the page's light refreshes.
export function netWorthSection() {
  if (!view.el) {
    view.el = h("section", { class: "networth", "aria-labelledby": "networth-title" });
    document.addEventListener("budget:write", () => load());
    load();
  }
  return view.el;
}

async function load() {
  const range = view.range;
  if (!view.data) render();
  const request = api(`/v1/networth?range=${encodeURIComponent(range)}`).then((data) => {
    if (range === view.range) { view.data = data; view.error = null; view.missing = false; }
  }, (error) => {
    if (error && error.status === 404) view.missing = true; else view.error = error;
  });
  view.loading = request;
  await request;
  if (view.loading === request) render();
}

const formKey = () => (view.editing ? view.editing.id : "new");

/// A form being typed in isn't redrawn under the person; the numbers above it are.
function render() {
  const el = view.el;
  if (!el) return;
  const kept = el.querySelector(".nw-form");
  const form = kept && kept.dataset.key === formKey() ? kept : null;
  if (view.missing) {
    fill(el, sectionHead("Net worth", null, "networth-title"),
      h("div", { class: "card" }, h("p", { class: "t-callout muted" }, "This server doesn't keep net worth history yet. Update it to see it here.")));
    return;
  }
  const d = view.data;
  const segs = h("div", { class: "seg", role: "tablist", "aria-label": "Range" }, RANGES.map((r) =>
    h("button", { type: "button", role: "tab", "aria-selected": String(r === view.range), onclick: () => { view.range = r; load(); } }, r)));
  if (!d) {
    fill(el, sectionHead("Net worth", segs, "networth-title"), view.error ? h("div", { class: "card" }, h("p", { class: "t-callout muted" }, view.error.message))
      : h("div", { class: "card" }, skeleton(4)));
    return;
  }
  const since = dateShort(d.start);
  const percent = d.changePercent == null ? "" : ` (${d.changePercent >= 0 ? "+" : "−"}${Math.abs(d.changePercent).toFixed(1)}%)`;
  const summary = h("div", { class: "card nw-summary" },
    h("span", { class: "t-eyebrow" }, "Net worth"),
    bigMoney(d.netWorth, { cls: "t-amount-xl" }),
    h("p", { class: `t-callout nw-change ${d.change.minor < 0 ? "down" : "up"}` }, `${money(d.change, { cents: false, sign: true })}${percent} since ${since}`),
    chart(d),
    d.note ? h("p", { class: "help nw-note" }, tag("Estimated", "tone-iris"), " ", d.note) : null);
  const lists = h("div", { class: "nw-lists" },
    breakdown("What you own", d.assets, d.assetLines, since),
    breakdown("What you owe", d.liabilities, d.liabilityLines, since));
  fill(el, sectionHead("Net worth", segs, "networth-title"), summary, lists, form || editor());
}

function breakdown(title, total, lines, since) {
  return h("div", { class: "card" },
    h("div", { class: "nw-list-head" }, h("h3", { class: "t-headline" }, title), rowMoney(total)),
    lines.length ? h("div", { class: "rows" }, lines.map((l) => line(l, since))) : h("p", { class: "empty-line" }, "Nothing here."));
}

function line(l, since) {
  const change = l.change && l.change.minor ? `${money(l.change, { cents: false, sign: true })} since ${since}` : null;
  const sub = [l.detail, l.isManual ? "added by you" : null, l.isEstimated ? "partly estimated" : null, change].filter(Boolean).join(" · ");
  const item = l.isManual ? (view.data.manualAssets || []).find((a) => a.id === l.id) : null;
  return h("div", { class: "row" },
    h("span", { class: `glyph tone-${GROUP_TONE[l.group] || "amber"}`, "aria-hidden": "true" }, l.name.slice(0, 2).toUpperCase()),
    h("div", { class: "grow" }, h("div", { class: "title" }, l.name), sub ? h("div", { class: "sub" }, sub) : null),
    rowMoney(l.value),
    item ? button("Edit", { kind: "quiet", "aria-label": `Edit ${l.name}`, onclick: () => {
      view.editing = item;
      render();
      const first = view.el.querySelector(".nw-form input");
      if (first) { first.scrollIntoView({ block: "center", behavior: "smooth" }); first.focus({ preventScroll: true }); }
    } }) : null,
    item ? button("Remove", { kind: "caution", compact: true, "aria-label": `Remove ${l.name}`,
      onclick: (e) => armed(e.currentTarget, "Click again to remove", () => send({ type: "removeManualAsset", id: item.id }, e.currentTarget)) }) : null);
}

// MARK: Chart

const SVG = "http://www.w3.org/2000/svg";
function svg(tag, attrs, ...kids) {
  const el = document.createElementNS(SVG, tag);
  for (const [k, v] of Object.entries(attrs || {})) if (v != null) el.setAttribute(k, String(v));
  for (const kid of kids) if (kid) el.append(kid);
  return el;
}

/// The history as a line: solid from records, dashed where an investment holds a stand-in value.
function chart(d) {
  const pts = d.points || [];
  if (pts.length < 2) return null;
  const W = 640, H = 180, pad = 8;
  const t0 = Date.parse(pts[0].date), t1 = Date.parse(pts[pts.length - 1].date);
  const values = pts.map((p) => p.netWorth.minor);
  let lo = Math.min(...values), hi = Math.max(...values);
  const span = Math.max(hi - lo, 100);
  lo -= span * 0.1; hi += span * 0.1;
  const x = (p) => pad + (W - 2 * pad) * ((Date.parse(p.date) - t0) / Math.max(t1 - t0, 1));
  const y = (p) => H - pad - (H - 2 * pad) * ((p.netWorth.minor - lo) / (hi - lo));
  const path = (list) => list.map((p, i) => `${i ? "L" : "M"}${x(p).toFixed(1)},${y(p).toFixed(1)}`).join(" ");
  const estimated = pts.filter((p) => p.isEstimated), measured = pts.filter((p) => !p.isEstimated);
  const area = measured.length > 1 ? `${path(measured)} L${x(measured[measured.length - 1]).toFixed(1)},${H} L${x(measured[0]).toFixed(1)},${H} Z` : null;
  const label = `Net worth from ${money(pts[0].netWorth, { cents: false })} on ${dateShort(pts[0].date)} to ${money(d.netWorth, { cents: false })} today`;
  return svg("svg", { class: "nw-chart", viewBox: `0 0 ${W} ${H}`, preserveAspectRatio: "none", role: "img", "aria-label": label },
    svg("defs", {}, svg("linearGradient", { id: "nw-fill", x1: 0, y1: 0, x2: 0, y2: 1 },
      svg("stop", { offset: "0", class: "nw-stop-top" }), svg("stop", { offset: "0.55", class: "nw-stop-mid" }), svg("stop", { offset: "1", class: "nw-stop-end" }))),
    area ? svg("path", { d: area, class: "nw-area", fill: "url(#nw-fill)" }) : null,
    estimated.length ? svg("path", { d: path(measured.length ? [...estimated, measured[0]] : estimated), class: "nw-line estimated" }) : null,
    measured.length > 1 ? svg("path", { d: path(measured), class: "nw-line" }) : null);
}

// MARK: Adding and editing

function editor() {
  const item = view.editing;
  const id = "nw-" + (item ? item.id : "new");
  const kind = h("select", { class: "input", id: `${id}-kind` }, h("option", { value: "asset" }, "I own it"), h("option", { value: "liability" }, "I owe it"));
  kind.value = item ? item.kind : "asset";
  const category = h("select", { class: "input", id: `${id}-category` });
  const fillCategories = () => {
    const keep = category.value || (item && item.category);
    fill(category, CATEGORIES[kind.value].map(([value, label]) => h("option", { value }, label)));
    if (CATEGORIES[kind.value].some(([v]) => v === keep)) category.value = keep;
  };
  fillCategories();
  if (item) category.value = item.category;
  kind.addEventListener("change", fillCategories);
  const name = h("input", { class: "input", id: `${id}-name`, maxlength: "60", autocomplete: "off", placeholder: "Home, car, car loan…", value: item ? item.name : "" });
  const value = h("input", { class: "input num", id: `${id}-value`, inputmode: "decimal", autocomplete: "off", placeholder: "0.00",
    value: item ? (item.value.minor / 100).toFixed(2) : "" });
  const msg = h("p", { class: "field-msg" }, item ? "A new value counts from today; the history keeps the old one before it." : "It counts in net worth from today.");
  const field = (label, input) => h("div", { class: "field" }, h("label", { class: "field-head", for: input.id }, label), input);
  const save = button(item ? "Save" : "Add", { kind: "primary", type: "submit" });
  const cancel = item ? button("Cancel", { kind: "quiet", onclick: () => { view.editing = null; render(); } }) : null;
  const form = h("form", { class: "card nw-form", dataset: { key: formKey() }, onsubmit: (e) => {
    e.preventDefault();
    const n = name.value.trim(), raw = value.value.replace(/[$,\s]/g, "");
    if (!n) { msg.textContent = "Give it a name."; msg.classList.add("error"); name.setAttribute("aria-invalid", "true"); return; }
    if (!/^[0-9]{1,9}(\.[0-9]{1,2})?$/.test(raw)) { msg.textContent = "Enter what it's worth, or what's owed, like 12500 or 12500.50."; msg.classList.add("error"); value.setAttribute("aria-invalid", "true"); return; }
    const action = { type: "saveManualAsset", value: raw };
    if (item) {
      action.id = item.id;
      if (n !== item.name) action.name = n;
      if (kind.value !== item.kind) action.kind = kind.value;
      if (category.value !== item.category) action.category = category.value;
      if (Math.round(parseFloat(raw) * 100) === item.value.minor) delete action.value;
      if (Object.keys(action).length === 2) { view.editing = null; render(); return; }
    } else {
      Object.assign(action, { name: n, kind: kind.value, category: category.value });
    }
    send(action, save, () => { view.editing = null; form.remove(); });
  } },
    h("h3", { class: "t-headline" }, item ? `Edit ${item.name}` : "Add an asset or debt"),
    h("p", { class: "help" }, "A home, a car, a loan: anything no bank reports."),
    h("div", { class: "form" }, field("Asset or debt", kind), field("Type", category), h("div", { class: "field wide" },
      h("label", { class: "field-head", for: name.id }, "Name"), name), field(item ? "Value now" : "Value", value)),
    msg, h("div", { class: "actions" }, save, cancel));
  return form;
}

/// Sends a change, says what the ledger did with Undo, and reloads.
async function send(action, buttonEl, done) {
  await busy(buttonEl, "Saving…", async () => {
    const result = await api("/v1/actions", { method: "POST", body: action });
    if (done) done();
    toast(result.message, result.undo ? { action: { label: "Undo", run: () => undo(result.undo) } } : {});
    await afterWrite();
  });
}

async function undo(action) {
  try {
    const result = await api("/v1/actions", { method: "POST", body: action });
    toast(result.message);
    await afterWrite();
  } catch (error) { reportError(error); }
}
