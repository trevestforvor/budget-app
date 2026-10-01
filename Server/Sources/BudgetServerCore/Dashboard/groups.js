// Review → Needs a category: the review queue in groups (same account, same direction, same bank descriptor once
// numbers are stripped), biggest first, from GET /dash/review/groups. Picking a category files exactly the group's
// transactions (editTransactions with their ids, never confirm's fan-out), with 5 s to undo. "Make a rule" opens the
// rule drawer on Categories & rules, filled in from the group. Keyboard: j/k move between groups, 1–3 pick a
// suggestion, o opens the other categories, / searches, u undoes.
import { fill, h, api, store, heavy, forget, button, callout, tag, afterWrite, reportError, toast, runToastAction, money, count, plural,
  dateShort, accountName, categoryName, categoryTag, fileable, categoryOptions, emptyState, skeleton } from "./core.js";
import { makeRuleFrom } from "./rules.js";

const PAGE = 40;
/// The tab while it's on screen: its panel, the groups as loaded, how many are shown, which one has focus.
let view = null;

export function renderGroups(panel) {
  view = { panel, groups: null, shown: PAGE, focus: 0, query: "" };
  fill(panel, skeleton(5));
  load(view);
}

async function load(v, { force = false, focus = false } = {}) {
  try {
    const data = await heavy("groups", { force });
    if (view !== v) return;
    v.groups = data.groups;
    draw(v, { keepFocus: focus });
  } catch (error) {
    if (view !== v) return;
    fill(v.panel, callout({ tone: "watch", title: error.message, detail: error.detail,
      actions: [button("Try again", { compact: true, onclick: () => { fill(v.panel, skeleton(5)); load(v, { force: true }); } })] }));
  }
}

const matches = (g, q) => !q || [g.merchant, g.descriptor, accountName(g.accountID)].some((t) => (t || "").toLowerCase().includes(q));

function draw(v, { keepFocus = false } = {}) {
  const active = document.activeElement;
  const searching = active && active.classList && active.classList.contains("group-search");
  const q = v.query.trim().toLowerCase();
  const list = v.groups.filter((g) => matches(g, q));
  const rows = v.groups.reduce((t, g) => t + g.transactionIDs.length, 0);
  if (!v.groups.length) {
    fill(v.panel, h("section", { class: "card" }, emptyState({ title: "Nothing is waiting for a category",
      body: "When a new transaction comes in that your rules, remembered merchants and the decision model can't place, it shows up here, grouped with others like it." })));
    return;
  }
  const off = store.status.decisionPolicy.provider === "off", suggested = v.groups.some((g) => g.suggestions.length);
  const search = h("input", { class: "input group-search", type: "search", placeholder: "Find a merchant or account", "aria-label": "Find a merchant or account",
    value: v.query, oninput: (e) => { v.query = e.target.value; v.shown = PAGE; v.focus = 0; draw(v); } });
  const shown = list.slice(0, v.shown);
  v.focus = Math.min(v.focus, Math.max(0, shown.length - 1));
  fill(v.panel,
    h("div", { class: "flash", id: "groups-flash" }),
    // Suggestions stay on rows that waited from before the model was turned off, so the note says which it is.
    off ? callout({ tone: "info", role: "note", title: suggested ? "The decision model is off; these suggestions are from before" : "No suggestions while the decision model is off",
      body: suggested ? "Pick one, or another category, for each group. Turn a model on in Settings to have most of them filed for you."
        : "Pick a category for each group yourself, or turn a model on in Settings to have most of them filed for you.",
      actions: [h("a", { class: "btn secondary compact", href: "#/settings/categorization" }, "Open Settings")] }) : null,
    h("div", { class: "group-bar" }, search,
      h("p", { class: "t-caption muted" }, `${plural(v.groups.length, "group")} · ${plural(rows, "transaction")} waiting`,
        h("span", { class: "keys hide-phone" }, " · ", kbd("j"), " ", kbd("k"), " move · ", kbd("1"), "–", kbd("3"), " file · ", kbd("u"), " undo"))),
    shown.length
      ? h("section", { class: "card groups", "aria-label": "Groups waiting for a category" }, shown.map((g, i) => groupRow(g, i, v)))
      : h("section", { class: "card" }, h("p", { class: "empty-line" }, `Nothing waiting matches “${v.query.trim()}”.`)),
    list.length > shown.length ? h("div", { class: "card-foot" },
      button(`Show ${Math.min(PAGE, list.length - shown.length)} more`, { compact: true, onclick: () => { v.shown += PAGE; draw(v, { keepFocus: true }); } }),
      h("span", { class: "t-caption faint" }, `${count(shown.length)} of ${plural(list.length, "group")}`)) : null);
  if (searching) { const s = v.panel.querySelector(".group-search"); s.focus(); s.setSelectionRange(s.value.length, s.value.length); }
  else if (keepFocus) focusGroup(v, v.focus);
}

const kbd = (key) => h("kbd", {}, key);

function groupRow(g, i, v) {
  const n = g.transactionIDs.length, out = g.direction === "out";
  const id = `grp-${i}`;
  const range = dateShort(g.earliest) === dateShort(g.latest) ? dateShort(g.latest) : `${dateShort(g.earliest)} – ${dateShort(g.latest)}`;
  const picks = g.suggestions.map((s, k) => h("button", { type: "button", class: "pick", "aria-label": `File under ${categoryName(s.categoryID)}, ${Math.round(s.confidence * 100)}% sure`,
    onclick: (e) => file(v, g, s.categoryID, e.currentTarget) },
    categoryTag(s.categoryID), h("span", { class: "pct" }, `${Math.round(s.confidence * 100)}%`), h("kbd", { class: "hide-phone" }, String(k + 1))));
  const other = h("select", { class: "input pick-other", "aria-label": `File ${g.merchant} under another category`,
    onchange: (e) => { if (e.target.value) file(v, g, e.target.value, e.target); } },
    h("option", { value: "" }, g.suggestions.length ? "Other category…" : "Choose a category…"),
    categoryOptions(fileable({ direction: g.direction }).filter((c) => !g.suggestions.some((s) => s.categoryID === c.id))));
  const rule = button("Make a rule", { kind: "quiet", "aria-label": `Make a rule for ${g.merchant}`, onclick: () => makeRuleFrom(rulePrefill(g)) });
  const more = n - g.rows.length;
  return h("article", { class: "group", tabindex: "-1", "aria-labelledby": id, dataset: { index: String(i) }, onfocusin: () => { v.focus = i; mark(v); } },
    h("div", { class: "group-head" },
      h("div", { class: "grow" },
        h("h3", { class: "group-title", id }, g.merchant),
        h("div", { class: "sub" }, [accountName(g.accountID) || "An account", plural(n, "transaction"), range].join(" · "))),
      h("span", { class: `t-amount-row num${out ? "" : " inflow"}` }, money(g.total, { sign: !out }))),
    g.reason ? h("p", { class: "group-reason" }, g.reason) : null,
    g.isLarge || g.isGeneric ? h("div", { class: "tags" },
      g.isLarge ? tag("Big amount, on its own", "info") : null,
      g.isGeneric ? tag("No merchant name", "") : null) : null,
    h("div", { class: "group-picks" }, picks, other, rule),
    h("details", { class: "disclosure group-rows" }, h("summary", {}, n === 1 ? "See the transaction" : `See the ${plural(n, "transaction")}`),
      h("div", { class: "rows" }, g.rows.map((r) => h("div", { class: "row" },
        h("div", { class: "grow" }, h("div", { class: "title" }, r.rawDescription), h("div", { class: "sub" }, dateShort(r.postedAt), r.isPending ? " · pending" : "")),
        h("span", { class: `t-amount-row num${r.amount.minor > 0 ? " inflow" : ""}` }, money(r.amount, { sign: r.amount.minor > 0 }))))),
      more > 0 ? h("p", { class: "help" }, `And ${plural(more, "earlier one")}.`) : null));
}

/// The rule that would file this group from now on — the phone's "always file these this way", sent by the server
/// (`ReviewGroup.scopedRule`): the bank description as memory reads it and the direction, and — when the description
/// names no merchant ("Withdrawal", "PAYPAL *XJ29QK") — its exact text and the account. Never an empty condition.
function rulePrefill(g) {
  const r = g.rule || {};
  return { merchantContains: r.merchantContains || "", descriptorContains: r.descriptorContains || "", direction: r.direction || g.direction,
    accountID: r.accountID || "", categoryID: g.suggestions.length ? g.suggestions[0].categoryID : "" };
}

async function file(v, g, categoryID, control) {
  const row = control.closest(".group");
  if (!row || row.classList.contains("filing")) return;
  row.classList.add("filing");
  row.querySelectorAll("button, select").forEach((el) => { el.disabled = true; });
  const flash = v.panel.querySelector("#groups-flash");
  store.pending++;
  try {
    const result = await api("/v1/actions", { method: "POST", body: { type: "editTransactions", transactionIDs: g.transactionIDs, categoryID } });
    const n = g.transactionIDs.length;
    v.groups = v.groups.filter((x) => x !== g);
    if (view === v) draw(v, { keepFocus: true });
    toast(n === 1 ? `Filed ${g.merchant} under ${categoryName(categoryID)}` : `Filed ${count(n)} ${g.merchant} transactions under ${categoryName(categoryID)}`,
      { action: result.undo ? { label: "Undo", run: () => undo(v, result.undo) } : null });
    afterWrite();
  } catch (error) {
    row.classList.remove("filing");
    row.querySelectorAll("button, select").forEach((el) => { el.disabled = false; });
    if (control.tagName === "SELECT") control.value = "";
    if (error.status === 404) {
      reportError({ message: "Some of these transactions changed since the list loaded, so nothing was filed. The list is up to date now." }, flash);
      reload(v);
    } else reportError(error, flash);
  } finally { store.pending--; }
}

async function undo(v, action) {
  try {
    await api("/v1/actions", { method: "POST", body: action });
    toast("Put back as it was");
    await afterWrite();
    if (view === v) reload(v);
  } catch (error) { reportError(error, view === v ? v.panel.querySelector("#groups-flash") : null); }
}

function reload(v) { forget("groups"); load(v, { force: true }); }

// MARK: Keyboard

function mark(v) {
  v.panel.querySelectorAll(".group.current").forEach((el) => el.classList.remove("current"));
  const el = v.panel.querySelector(`.group[data-index="${v.focus}"]`);
  if (el) el.classList.add("current");
}
function focusGroup(v, i) {
  const all = v.panel.querySelectorAll(".group");
  if (!all.length) return;
  v.focus = Math.max(0, Math.min(i, all.length - 1));
  const el = all[v.focus];
  el.focus({ preventScroll: true });
  el.scrollIntoView({ block: "nearest", behavior: "smooth" });
  mark(v);
}

document.addEventListener("keydown", (e) => {
  const v = view;
  if (!v || !v.groups || !v.panel.isConnected || e.metaKey || e.ctrlKey || e.altKey) return;
  const t = e.target, typing = t && (t.tagName === "INPUT" || t.tagName === "SELECT" || t.tagName === "TEXTAREA" || t.isContentEditable);
  if (document.querySelector("dialog[open]")) return;
  if (typing) {
    if (e.key === "Escape" && t.classList.contains("group-search")) { t.blur(); focusGroup(v, v.focus); }
    return;
  }
  const current = () => v.panel.querySelector(`.group[data-index="${v.focus}"]`);
  // The first j (or k) lands on the group already marked, or the first one; after that they move.
  if (e.key === "j" || e.key === "k") { e.preventDefault(); focusGroup(v, current() && current().classList.contains("current") ? v.focus + (e.key === "j" ? 1 : -1) : v.focus); }
  else if (e.key === "/") { e.preventDefault(); const s = v.panel.querySelector(".group-search"); if (s) s.focus(); }
  else if (e.key === "u") { if (runToastAction()) e.preventDefault(); }
  else if (e.key === "o") { const el = current(); if (el) { e.preventDefault(); el.querySelector(".pick-other").focus(); } }
  else if (/^[1-3]$/.test(e.key)) {
    const el = current(), pick = el && el.querySelectorAll(".pick")[Number(e.key) - 1];
    if (pick && !pick.disabled) { e.preventDefault(); pick.click(); }
  }
});
