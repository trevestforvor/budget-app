// Review: what's waiting for a category, duplicates between statements and syncs, and a second look at what the model
// filed. Rules live with the categories they file under (Categories & rules); "Make a rule" on a group opens there.
// The light refresh never redraws an open tab; only the tab counts update.
import { fill, h, api, store, heavy, cached, pageHead, button, busy, armed, callout, tag, afterWrite, reportError, toast, money, count, plural,
  dateShort, SOURCE, accountName, categoryTag, emptyState, skeleton, closeDrawer } from "./core.js";
import { arrowKeys } from "./providers.js";
import { renderGroups } from "./groups.js";

/// The tabs, in order.
const TABS = [
  // Decisions (groups), as the phone's badge counts them; the tab itself says how many transactions they file.
  { id: "categories", label: "Needs a category", count: () => store.overview.reviewDecisions ?? store.overview.reviewCount, render: renderGroups },
  { id: "duplicates", label: "Duplicates", count: () => (cached("dupes") ? cached("dupes").pairs.length : 0), tone: "watch", render: renderDuplicates },
  { id: "recheck", label: "Re-check filings", count: () => 0, render: renderRecheck },
];

// MARK: Duplicates

function renderDuplicates(panel, { force = false } = {}) {
  fill(panel, skeleton(4));
  heavy("dupes", { force }).then((r) => drawDuplicates(panel, r), (error) => fill(panel, callout({ tone: "watch", title: error.message, detail: error.detail,
    actions: [button("Try again", { compact: true, onclick: () => renderDuplicates(panel, { force: true }) })] })));
}

function drawDuplicates(panel, r) {
  const look = button("Look again", { compact: true, onclick: (e) => busy(e.currentTarget, "Looking…", async () => { await heavy("dupes", { force: true }); drawDuplicates(panel, cached("dupes")); }) });
  if (!r.pairs.length) {
    fill(panel, h("section", { class: "card" }, emptyState({ title: "Nothing is in the ledger twice",
      body: "When a statement you imported overlaps a bank you later linked, the copies show up here.", actions: [look] })));
    return;
  }
  const n = r.pairs.length;
  const remove = button(`Remove ${n} imported ${n === 1 ? "copy" : "copies"}`, { kind: "caution", onclick: (e) => armed(e.currentTarget, "Click again to remove them", async () => {
    try {
      const done = await api("/v1/imports/duplicates", { method: "POST", body: { apply: true } });
      toast(`Removed ${plural(done.removed, "duplicate")}`);
      await afterWrite();
      renderDuplicates(panel, { force: true });
    } catch (error) { reportError(error); }
  }) });
  fill(panel, h("section", { class: "card stack" },
    h("p", { class: "t-callout muted" }, `${plural(n, "transaction")} came in from an imported statement and again from a sync. Removing keeps the synced copy, which stays current.`),
    h("table", { class: "table stack-phone dupes-table" },
      h("thead", {}, h("tr", {}, h("th", {}, "Account"), h("th", {}, "From the statement"), h("th", {}, "From the sync"), h("th", { class: "numcol" }, "Amount"))),
      h("tbody", {}, r.pairs.map((p) => h("tr", {},
        h("td", { "data-label": "" }, h("div", { class: "cell-title" }, accountName(p.accountID) || "—")),
        h("td", { "data-label": "Statement:" }, h("div", { class: "cell-title" }, p.fileDescription), h("div", { class: "cell-sub" }, dateShort(p.fileDate))),
        h("td", { "data-label": "Sync:" }, h("div", { class: "cell-title" }, p.syncedDescription), h("div", { class: "cell-sub" }, `${SOURCE[p.syncedSource] || p.syncedSource} · ${dateShort(p.syncedDate)}`)),
        h("td", { class: "numcol t-amount-row", "data-label": "" }, money(p.amount)))))),
    h("div", { class: "card-foot" }, remove, look)));
}

// MARK: Re-check filings

function renderRecheck(panel) {
  const p = store.status.decisionPolicy, off = p.provider === "off";
  const waiting = store.overview.reviewCount;
  const preview = h("div", { class: "recheck-result" });
  fill(panel, 
    off ? h("div", { class: "banners" }, callout({ tone: "info", title: "The decision model is off", body: "Turn one on in Settings to file transactions for you and to re-check them here.",
      actions: [h("a", { class: "btn secondary compact", href: "#/settings" }, "Open Settings")] })) : null,
    h("section", { class: "card stack", "aria-labelledby": "recheck-filed" },
      h("h2", { class: "t-headline", id: "recheck-filed" }, "What the model already filed"),
      h("p", { class: "t-callout muted" }, "The decision model looks again at the merchants it filed, against your current categories, and shows what it would move. Your own confirmations and rules are never touched."),
      h("div", { class: "actions" }, button("Preview changes", { compact: true, disabled: off, onclick: (e) => busy(e.currentTarget, "Checking…", () => previewMoves(preview), { errorTarget: preview }) })),
      preview),
    h("section", { class: "card stack", "aria-labelledby": "recheck-waiting" },
      h("h2", { class: "t-headline", id: "recheck-waiting" }, "What's waiting for a category"),
      h("p", { class: "t-callout muted" }, waiting
        ? `Runs the current settings over the ${plural(waiting, "transaction")} waiting, one question per merchant. Anything it's sure about is filed; the rest keeps waiting for you.`
        : "Nothing is waiting for a category right now."),
      h("div", { class: "actions" }, button("Re-check now", { kind: "ai", compact: true, disabled: off || !waiting, onclick: (e) => busy(e.currentTarget, "Re-checking…", async () => {
        const r = await api("/v1/actions", { method: "POST", body: { type: "updateDecisionPolicy", rerunPending: true } });
        toast(r.message || "Re-checked");
        await afterWrite();
        renderRecheck(panel);
      }) }))));
}

async function previewMoves(target) {
  const r = await api("/dash/recheck-filed", { method: "POST", body: { apply: false } });
  if (!r.moves.length) { fill(target, callout({ tone: "ok", role: "status", title: r.message || "Nothing would move." })); return; }
  fill(target, 
    h("p", { class: "t-callout" }, r.message),
    h("div", { class: "rows" }, r.moves.map((m) => h("div", { class: "row" },
      h("div", { class: "grow" }, h("div", { class: "title" }, m.merchant),
        h("div", { class: "sub" }, categoryTag(m.from), " → ", categoryTag(m.to), ` · ${plural(m.transactions, "transaction")}`)),
      m.confidence != null ? tag(`${Math.round(m.confidence * 100)}% sure`, "info") : null))),
    h("div", { class: "card-foot" }, button(`Move ${plural(r.movedMerchants, "merchant")}`, { kind: "tinted", onclick: (e) => armed(e.currentTarget, "Click again to move them", async () => {
      try {
        const done = await api("/dash/recheck-filed", { method: "POST", body: { apply: true } });
        toast(done.message || "Moved");
        fill(target);
        await afterWrite();
      } catch (error) { reportError(error, target); }
    }) })));
}

// MARK: View

export default {
  title: "Review",
  mount(root, { sub }) {
    this.root = root;
    this.tabs = TABS;
    const tablist = h("div", { class: "tabs", role: "tablist", "aria-label": "Review" });
    this.panel = h("div", { class: "tab-panel", role: "tabpanel", tabindex: "0" });
    for (const t of this.tabs) {
      tablist.append(h("button", { class: "chip", type: "button", role: "tab", id: `rtab-${t.id}`, "aria-controls": "review-panel", dataset: { id: t.id },
        onclick: () => { location.hash = `#/review/${t.id}`; }, onkeydown: (e) => arrowKeys(e, tablist, (id, focus) => { location.hash = `#/review/${id}`; if (focus) setTimeout(() => this.root.querySelector(`#rtab-${id}`).focus(), 0); }) }, t.label, h("span", { class: "tab-count" })));
    }
    this.panel.id = "review-panel";
    this.tablist = tablist;
    fill(root, 
      pageHead({ eyebrow: "Keeping it tidy", title: "Review",
        sub: "File what's waiting a group at a time, clear out duplicates, and have the model look again. It's the same ledger your phone shows." }),
      tablist, this.panel);
    this.show(sub);
  },
  navigate({ sub }) { this.show(sub); },
  unmount() { closeDrawer(); },
  show(id) {
    const tab = this.tabs.find((t) => t.id === id) || this.tabs[0];
    this.current = tab.id;
    for (const b of this.tablist.children) { const on = b.dataset.id === tab.id; b.setAttribute("aria-selected", String(on)); b.tabIndex = on ? 0 : -1; }
    this.panel.setAttribute("aria-labelledby", `rtab-${tab.id}`);
    tab.render(this.panel);
    this.updateCounts();
  },
  /// Light refresh: counts only. The open tab keeps whatever the person has previewed.
  refresh() { this.updateCounts(); },
  updateCounts() {
    for (const b of this.tablist.children) {
      const t = this.tabs.find((x) => x.id === b.dataset.id), n = t.count();
      fill(b.querySelector(".tab-count"), n ? tag(count(n), t.tone || "") : "");
    }
  },
};
