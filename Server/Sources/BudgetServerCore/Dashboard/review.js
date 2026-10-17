// Review: what's waiting for a category, duplicates between statements and syncs, and a second look at what the model
// filed. Rules live with the categories they file under (Categories & rules); "Make a rule" on a group opens there.
// The light refresh never redraws an open tab; only the tab counts update.
import { fill, h, api, store, heavy, cached, pageHead, button, busy, armed, callout, tag, afterWrite, reportError, toast, money, count, plural,
  dateShort, SOURCE, accountName, categoryTag, emptyState, skeleton, closeDrawer, rowMoney } from "./core.js";
import { arrowKeys } from "./providers.js";
import { renderGroups } from "./groups.js";

/// The tabs, in order.
const TABS = [
  // Decisions (groups), as the phone's badge counts them; the tab itself says how many transactions they file.
  { id: "categories", label: "Needs a category", count: () => store.overview.reviewDecisions ?? store.overview.reviewCount, render: renderGroups },
  { id: "duplicates", label: "Duplicates", count: () => (cached("dupes") ? cached("dupes").pairs.length : 0) + (lookAlike ? lookAlike.length : 0), tone: "watch", render: renderDuplicates },
  { id: "recurring", label: "Recurring", count: () => recurringCount(), tone: "watch", render: renderRecurring },
  { id: "recheck", label: "Re-check filings", count: () => 0, render: renderRecheck },
];

// MARK: Duplicates

/// The last /v1/duplicates answer (server 0.6.0): rows added that might be the same charge as one already here. An
/// older server has no such route, so it reads as none.
let lookAlike = null;
const loadLookAlike = async () => (lookAlike = await api("/v1/duplicates").catch((error) => (error.status === 404 ? [] : Promise.reject(error))));

function renderDuplicates(panel, { force = false } = {}) {
  fill(panel, skeleton(4));
  Promise.all([heavy("dupes", { force }), loadLookAlike()]).then(([r]) => {
    if (view) view.updateCounts();
    drawDuplicates(panel, r);
  }, (error) => fill(panel, callout({ tone: "watch", title: error.message, detail: error.detail,
    actions: [button("Try again", { compact: true, onclick: () => renderDuplicates(panel, { force: true }) })] })));
}

/// One answer on a possible duplicate: `sameAs` a candidate's id (Same charge) or null (Keep both).
async function answerLookAlike(panel, item, sameAs, e) {
  await busy(e.currentTarget, "Saving…", async () => {
    const r = await api(`/v1/duplicates/${encodeURIComponent(item.id)}`, { method: "POST", body: { sameAs } });
    toast(r.merged ? "Merged into one transaction. If that was wrong, Bring back is in Imports, under the import or sync it came in with." : "Kept both. File it as usual.");
    await afterWrite();
    renderDuplicates(panel, { force: true });
  });
}

/// "Look alike": rows a statement or a sync added because the wording couldn't tell which row already here they are.
function lookAlikeSection(panel) {
  if (!lookAlike || !lookAlike.length) return null;
  const line = (t) => `${SOURCE[t.source] || t.source} · ${dateShort(t.postedAt)} · ${t.rawDescription}`;
  return h("section", { class: "card stack", "aria-labelledby": "dupes-alike" },
    h("h2", { class: "t-headline", id: "dupes-alike" }, "Look alike"),
    h("p", { class: "t-callout muted" }, `${plural(lookAlike.length, "transaction")} came in for the same amount as one already here, and the wording didn't say which. Same charge keeps one copy (the bank's own, which stays current); Keep both leaves them as two.`),
    h("div", { class: "rows" }, lookAlike.map((item) => h("div", { class: "row" },
      h("div", { class: "grow" },
        h("div", { class: "title wrap" }, item.row.merchant, " ", tag("Look alike", "watch")),
        h("div", { class: "sub wrap" }, `${accountName(item.row.accountID) || "—"} · ${line(item.row)}`),
        item.candidates.map((c) => h("div", { class: "sub wrap" }, "Might be: ", line(c), " ",
          button("Same charge", { kind: "tinted", compact: true, "aria-label": `Same charge as ${c.rawDescription} on ${dateShort(c.postedAt)}`,
            onclick: (e) => answerLookAlike(panel, item, c.id, e) })))),
      rowMoney(item.row.amount),
      h("div", { class: "actions" }, button("Keep both", { compact: true, onclick: (e) => answerLookAlike(panel, item, null, e) }))))));
}

function drawDuplicates(panel, r) {
  const look = button("Look again", { compact: true, onclick: (e) => busy(e.currentTarget, "Looking…", async () => { await heavy("dupes", { force: true }); drawDuplicates(panel, cached("dupes")); }) });
  const alike = lookAlikeSection(panel);
  const unclear = r.ambiguous ? h("p", { class: "help" }, `${plural(r.ambiguous, "more imported row")} look${r.ambiguous === 1 ? "s" : ""} like more than one synced row, so ${r.ambiguous === 1 ? "it's" : "they're"} left as ${r.ambiguous === 1 ? "it is" : "they are"}.`) : null;
  if (!r.pairs.length) {
    fill(panel, alike, h("section", { class: "card" }, emptyState({ title: alike ? "Nothing else is in the ledger twice" : "Nothing is in the ledger twice",
      body: "When a statement you imported overlaps a bank you later linked, the copies show up here.", actions: [look] }), unclear));
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
  fill(panel, alike, h("section", { class: "card stack" },
    h("p", { class: "t-callout muted" }, `${plural(n, "transaction")} came in from an imported statement and again from a sync. Removing keeps the synced copy, which stays current; Imports lists each one under its statement, to bring back.`),
    unclear,
    h("table", { class: "table stack-phone dupes-table" },
      h("thead", {}, h("tr", {}, h("th", {}, "Account"), h("th", {}, "From the statement"), h("th", {}, "From the sync"), h("th", { class: "numcol" }, "Amount"))),
      h("tbody", {}, r.pairs.map((p) => h("tr", {},
        h("td", { "data-label": "" }, h("div", { class: "cell-title" }, accountName(p.accountID) || "—")),
        h("td", { "data-label": "Statement:" }, h("div", { class: "cell-title" }, p.fileDescription), h("div", { class: "cell-sub" }, dateShort(p.fileDate))),
        h("td", { "data-label": "Sync:" }, h("div", { class: "cell-title" }, p.syncedDescription), h("div", { class: "cell-sub" }, `${SOURCE[p.syncedSource] || p.syncedSource} · ${dateShort(p.syncedDate)}`)),
        h("td", { class: "numcol t-amount-row", "data-label": "" }, money(p.amount)))))),
    h("div", { class: "card-foot" }, remove, look)));
}

// MARK: Recurring

/// The last /v1/recurring/review answer (server 0.5.0): "Did this stop?" and "Is this recurring?", as the phone asks them.
let recurring = null;
/// The mounted view, so a fresh answer can update the tab counts.
let view = null;
const recurringCount = () => (recurring ? recurring.candidates.length + recurring.maybeStopped.length : 0);
const loadRecurring = async () => (recurring = await api("/v1/recurring/review"));
const CADENCE = { weekly: "Weekly", monthly: "Monthly", quarterly: "Every 3 months", yearly: "Yearly" };

function renderRecurring(panel) {
  fill(panel, skeleton(4));
  // Another tab may have opened while this loaded; it keeps the panel.
  const stillOpen = () => panel.getAttribute("aria-labelledby") === "rtab-recurring";
  loadRecurring().then(() => {
    if (view) view.updateCounts();
    if (stillOpen()) drawRecurring(panel);
  }, (error) => { if (stillOpen()) fill(panel, callout({ tone: "watch", title: error.message, detail: error.detail,
    actions: [button("Try again", { compact: true, onclick: () => renderRecurring(panel) })] })); });
}

/// One answer through /v1/actions, then the queue again. The phone's toast offers Undo; here the answer's undo is a button.
async function answerRecurring(panel, body, e) {
  await busy(e.currentTarget, "Saving…", async () => {
    const r = await api("/v1/actions", { method: "POST", body });
    toast(r.message || "Saved", r.undo ? { action: { label: "Undo", run: async () => {
      await api("/v1/actions", { method: "POST", body: r.undo });
      await afterWrite();
      renderRecurring(panel);
    } } } : {});
    await afterWrite();
    renderRecurring(panel);
  });
}

function recurringRow(s, labels, detail, actions) {
  return h("div", { class: "row" },
    h("div", { class: "grow" },
      h("div", { class: "title wrap" }, s.merchant, ...labels.flatMap((label) => [" ", tag(label, label === "Review" ? "watch" : "info")])),
      h("div", { class: "sub wrap" }, detail)),
    rowMoney(s.amount),
    h("div", { class: "actions" }, actions));
}

function drawRecurring(panel) {
  const r = recurring;
  const stopped = r.maybeStopped, candidates = r.candidates, ended = r.ended || [];
  if (!stopped.length && !candidates.length && !ended.length) {
    fill(panel, h("section", { class: "card" }, emptyState({ title: "Nothing to check on recurring",
      body: "When a recurring charge goes quiet, or new charges start to repeat, Budget asks about them here and on the phone." })));
    return;
  }
  fill(panel,
    stopped.length ? h("section", { class: "card stack", "aria-labelledby": "rec-stopped" },
      h("h2", { class: "t-headline", id: "rec-stopped" }, "Did this stop?"),
      h("p", { class: "t-callout muted" }, "No charge for about a cycle and a half. If you canceled it, it comes off the list and out of the usual month of bills and subscriptions now. If it's still active, Budget asks again a cycle later."),
      h("div", { class: "rows" }, stopped.map((s) => recurringRow(s, ["Recurring"], `${CADENCE[s.cadence] || s.cadence} · no charge since ${dateShort(s.lastCharged)}`, [
        button("Yes, I canceled it", { kind: "tinted", compact: true, onclick: (e) => answerRecurring(panel, { type: "reviewRecurring", merchant: s.merchant, answer: "stopped" }, e) }),
        button("No, still active", { compact: true, onclick: (e) => answerRecurring(panel, { type: "reviewRecurring", merchant: s.merchant, answer: "stillActive" }, e) }),
      ])))) : null,
    candidates.length ? h("section", { class: "card stack", "aria-labelledby": "rec-new" },
      h("h2", { class: "t-headline", id: "rec-new" }, "Is this recurring?"),
      h("p", { class: "t-callout muted" }, "These repeat on a schedule but don't have enough history for the recurring list yet. Yes puts them on it, so the budget plans for them."),
      h("div", { class: "rows" }, candidates.map((s) => recurringRow(s, ["Recurring", "Review"], `Charged ${plural(s.charges, "time")} · ${(CADENCE[s.cadence] || s.cadence).toLowerCase()} · next around ${dateShort(s.nextExpected)}`, [
        button("Yes, it repeats", { kind: "tinted", compact: true, onclick: (e) => answerRecurring(panel, { type: "setRecurring", merchant: s.merchant, isRecurring: true, cadence: s.cadence, amount: (s.amount.minor / 100).toFixed(2) }, e) }),
        button("Not recurring", { compact: true, onclick: (e) => answerRecurring(panel, { type: "setRecurring", merchant: s.merchant, isRecurring: false }, e) }),
      ])))) : null,
    ended.length ? h("section", { class: "card stack", "aria-labelledby": "rec-ended" },
      h("h2", { class: "t-headline", id: "rec-ended" }, "You said these stopped"),
      h("div", { class: "rows" }, ended.map((m) => h("div", { class: "row" }, h("div", { class: "grow" }, h("div", { class: "title" }, m)),
        button("Put back", { kind: "quiet", compact: true, onclick: (e) => answerRecurring(panel, { type: "reviewRecurring", merchant: m, restores: true }, e) }))))) : null);
}

// MARK: Re-check filings

function renderRecheck(panel) {
  const p = store.status.decisionPolicy, off = p.provider === "off";
  const waiting = store.overview.reviewCount;
  const preview = h("div", { class: "recheck-result" });
  fill(panel, 
    off ? h("div", { class: "banners" }, callout({ tone: "info", title: "The decision model is off", body: "Turn one on in Settings to file transactions for you and to re-check them here.",
      actions: [h("a", { class: "btn secondary compact", href: "#/settings/categorizing" }, "Open Settings")] })) : null,
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
    view = this;
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
    // The recurring and look-alike counts, before their tabs are opened.
    loadRecurring().then(() => this.updateCounts(), () => {});
    loadLookAlike().then(() => this.updateCounts(), () => {});
  },
  navigate({ sub }) { this.show(sub); },
  unmount() { closeDrawer(); view = null; },
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
