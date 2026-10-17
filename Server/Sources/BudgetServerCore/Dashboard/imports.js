// Imports: one table for one file or a year of them (preview, then import), and the history of every
// import and sync with its warnings and an Undo that says what it removes.
import { fill, h, api, store, heavy, cached, pageHead, sectionHead, button, busy, armed, isArmed, callout, details, tag, icon, afterWrite,
  reportError, toast, money, count, plural, dateShort, span, KIND, SOURCE, emptyState, loadInto, accountName } from "./core.js";
import { ordersRegion } from "./orders.js";

const NEW = "__new__";
const MAX_BYTES = 30 * 1024 * 1024;
/// Files chosen but not imported yet. Module-level, so leaving the page and coming back keeps them.
let batch = null;
/// The view while it's mounted, for work that finishes after a request (an undo redraws the file table).
let viewRef = null;

const isOFX = (name, text) => /\.(ofx|qfx)$/i.test(name) || /<OFX>|OFXHEADER/i.test(text.slice(0, 4000));

/// A new account for an OFX file, named from the file the way the server would ("Card ••1234"). The number stays in
/// the browser: only the name and kind are sent.
function ofxNewAccount(text) {
  const acct = ((text || "").match(/<ACCTID>\s*([^<\s]+)/i) || [])[1] || "";
  const digits = acct.replace(/\D/g, "").slice(-4), card = /<CCSTMTRS>/i.test(text || "");
  const org = ((text || "").match(/<ORG>\s*([^<\r\n]+)/i) || [])[1] || "";
  return { name: `${card ? "Card" : "Account"}${digits.length >= 2 ? ` ••${digits}` : ""}`, institution: org.trim(), kind: card ? "credit" : "checking", balance: "" };
}

/// Which account a statement belongs to: the last digits in its name or its OFX account number
/// (Chase1234_Activity….CSV, "Amex Gold 22222.csv"), else a distinctive word of an account's name.
function guessAccount(name, text) {
  const accounts = store.overview.accounts, lower = name.toLowerCase();
  const acct = ((text || "").match(/<ACCTID>\s*([^<\s]+)/i) || [])[1];
  const digits = [...(name.match(/(?<!\d)\d{4,5}(?!\d)/g) || []), ...(acct ? [acct.slice(-4), acct.slice(-5)] : [])];
  const byMask = accounts.filter((a) => a.mask && digits.some((d) => d.endsWith(a.mask) || a.mask.endsWith(d)));
  if (byMask.length === 1) return byMask[0].id;
  const byName = accounts.filter((a) => (a.name || "").split(/[^A-Za-z]+/).some((w) => w.length > 3 && !/^(card|account|credit|checking|savings)$/i.test(w) && lower.includes(w.toLowerCase())));
  return byName.length === 1 ? byName[0].id : "";
}

function ready(item) {
  if (item.done) return true;
  // An OFX file needs an account too: its account number never becomes one.
  if (!item.accountID) return false;
  return item.accountID !== NEW || !!item.newAccount.name.trim();
}

function parseBalance(raw) {
  const cleaned = (raw || "").replace(/[$,\s]/g, "").replace("−", "-");
  if (!cleaned) return null;
  const n = Number(cleaned);
  if (!Number.isFinite(n)) throw new Error("A balance should be a number, like 2450.18.");
  return { minor: Math.round(n * 100), currency: "USD" };
}

/// The request body for one file, preview or not. A new account carries its name and kind, and a CSV's its balance
/// (an OFX file states its own).
function importBody(item, preview) {
  const account = store.overview.accounts.find((a) => a.id === item.accountID);
  const options = { format: item.ofx ? "ofx" : "csv", sign: item.ofx ? "auto" : item.sign,
    institution: account ? account.institution : (item.newAccount.institution.trim() || "Import") };
  const body = { content: item.text, label: item.name, preview, options };
  if (account) body.accountID = account.id;
  else {
    options.accountName = item.newAccount.name.trim();
    options.accountKind = item.newAccount.kind;
    const balance = item.ofx ? null : parseBalance(item.newAccount.balance);
    if (balance) options.balance = balance;
  }
  return body;
}

// MARK: The file table

function accountSelect(item, view) {
  // Once imported into a new account, the row names the account it made rather than "New account…".
  if (item.done && item.accountID === NEW) return h("div", { class: "cell-title" }, item.newAccount.name || "The new account");
  const accounts = store.overview.accounts;
  const select = h("select", { class: "input", "aria-label": `Account for ${item.name}`, disabled: !!item.done,
    onchange: (e) => { item.accountID = e.target.value; item.guessed = false; item.preview = null; item.error = null; view.renderTable(); } },
    h("option", { value: "" }, "Choose an account…"),
    accounts.map((a) => h("option", { value: a.id }, `${a.institution} · ${accountName(a)}`)),
    h("option", { value: NEW }, "New account…"));
  select.value = item.accountID;
  return select;
}

function statusCell(item) {
  if (item.undone) return tag("Undone");
  if (item.error) return tag("Didn't work", "act");
  if (item.done) return tag("Imported", "ok");
  if (!ready(item)) return tag(item.accountID === NEW ? "Name the account" : "Choose an account", "watch");
  if (item.preview) return tag("Ready", "info");
  return tag("Not previewed");
}

function newAccountRow(item, view) {
  const a = item.newAccount;
  const input = (key, label, attrs) => h("label", { class: "field" }, h("span", { class: "help" }, label),
    h("input", { class: "input", value: a[key], ...attrs, oninput: (e) => { a[key] = e.target.value; item.preview = null; view.updateButtons(); view.updateStatus(item); } }));
  const kind = h("select", { class: "input", onchange: (e) => { a.kind = e.target.value; item.preview = null; view.updateButtons(); } },
    Object.entries(KIND).map(([k, label]) => h("option", { value: k }, label)));
  kind.value = a.kind;
  return h("tr", { class: "expand" }, h("td", { colspan: "6" }, h("div", { class: "new-account" },
    input("name", "New account's name", { placeholder: "Chase Checking", "aria-required": "true" }),
    input("institution", "Bank", { placeholder: "Chase" }),
    h("label", { class: "field" }, h("span", { class: "help" }, "Kind"), kind),
    item.ofx ? null : input("balance", "Balance today (optional)", { inputmode: "decimal", placeholder: "2450.18" }))));
}

function samplesRow(item) {
  const samples = (item.preview && !item.done && item.preview.duplicateSamples) || [];
  if (!samples.length) return null;
  return h("tr", { class: "expand" }, h("td", { colspan: "6" }, details(`What counts as already here (${samples.length} example${samples.length === 1 ? "" : "s"})`,
    h("table", { class: "table stack-phone" },
      h("thead", {}, h("tr", {}, h("th", {}, "Date"), h("th", { class: "numcol" }, "Amount"), h("th", {}, "In this file"), h("th", {}, "Already in the ledger as"))),
      h("tbody", {}, samples.map((s) => h("tr", {},
        h("td", { "data-label": "Date" }, dateShort(s.date)), h("td", { class: "numcol", "data-label": "Amount" }, money(s.amount)),
        h("td", { "data-label": "In this file" }, s.description),
        h("td", { "data-label": "Already here as" }, `${s.matchedDescription} · ${SOURCE[s.matchedSource] || s.matchedSource}, ${dateShort(s.matchedDate)}`))))))));
}

function fileRow(item, view) {
  const r = item.done || item.preview;
  const warnings = (r && r.warnings) || [];
  const signSelect = item.ofx ? null : h("div", { class: "row-options" }, h("span", { class: "help" }, "Amounts"),
    h("select", { class: "input", "aria-label": `How ${item.name} shows money going out`, disabled: !!item.done, value: item.sign,
      onchange: (e) => { item.sign = e.target.value; item.preview = null; view.renderTable(); } },
    h("option", { value: "auto" }, "Work it out"), h("option", { value: "negativeIsOut" }, "Money out is negative"),
    h("option", { value: "positiveIsOut" }, "Charges are positive (Amex)")));
  const matched = item.guessed && item.accountID ? store.overview.accounts.find((a) => a.id === item.accountID) : null;
  // A file that hasn't gone in can be dropped from the batch, so one unreadable file never holds up the rest.
  const remove = item.done ? null : button("Remove", { kind: "quiet", compact: true, "aria-label": `Remove ${item.name} from this import`,
    onclick: () => { batch = batch.filter((i) => i !== item); if (!batch.length) batch = null; view.renderTable(); } });
  return h("tr", { dataset: { file: item.name } },
    h("td", { "data-label": "" }, h("div", { class: "file-name" }, item.name, " ", tag(item.ofx ? "OFX" : "CSV"), remove), signSelect,
      item.error ? h("div", { class: "warn-line act-text" }, item.error, item.done ? null : " Remove it to import the others.") : null,
      warnings.map((w) => h("div", { class: "warn-line" }, h("span", { class: "dot watch", "aria-hidden": "true" }), h("span", {}, "Warning: ", w)))),
    h("td", { "data-label": "" }, accountSelect(item, view), matched ? h("div", { class: "cell-sub" }, tag(matched.mask ? `Matched ••${matched.mask}` : "Matched by name", "ok")) : null),
    h("td", { class: "inline-phone", "data-label": "Dates" }, r ? span(r.addedFrom, r.addedThrough) || "—" : "—"),
    h("td", { class: "numcol inline-phone", "data-label": "New" }, r ? count(r.rowsAdded) : "—"),
    h("td", { class: "numcol inline-phone", "data-label": "Already here" }, r ? count(r.duplicatesSkipped) + (r.rowsUpdated ? ` · ${count(r.rowsUpdated)} updated` : "") : "—"),
    h("td", { class: "status-cell inline-phone", "data-label": "" }, statusCell(item)));
}

// MARK: History

function historyRow(record) {
  const r = record.report, sync = record.kind === "sync";
  const summary = [dateShort(record.createdAt), plural(r.rowsAdded, "new transaction"), r.duplicatesSkipped ? `${count(r.duplicatesSkipped)} already here` : null,
    r.rowsUpdated ? `${count(r.rowsUpdated)} updated` : null,
    r.pendingSettled ? `${count(r.pendingSettled)} pending settled` : null, r.pendingDropped ? `${count(r.pendingDropped)} pending dropped` : null,
    r.needsReview ? `${count(r.needsReview)} to review` : null, span(r.addedFrom, r.addedThrough) || null].filter(Boolean).join(" · ");
  const filed = [[r.byRule, "by your rules"], [r.byTransferMatch, "as transfers between your accounts"], [r.byStatement, "settled by the statement"],
    [r.byMemory, "by remembered merchants"], [r.byModel, "by the decision model"]].filter(([n]) => n > 0).map(([n, how]) => `${count(n)} ${how}`);
  const how = [filed.length ? `Filed on their own: ${filed.join(", ")}.` : "Nothing was filed on its own.",
    r.modelCalls ? `${plural(r.modelCalls, "question")} to the decision model${r.modelMilliseconds != null ? `, ${(r.modelMilliseconds / 1000).toFixed(1)} s` : ""}.` : null].filter(Boolean).join(" ");
  const failed = record.outcome === "failed", policy = record.undo || { mode: "allowed" };
  // A Plaid sync can't be undone (Plaid won't send its rows again), so it offers Hide; a SimpleFIN sync asks first
  // how many rows its next sync brings back; a failed sync has nothing to undo.
  const hideNote = !record.rolledBack && !failed && !record.hiddenAt && sync && policy.mode === "refused" && r.rowsAdded
    ? `${policy.message || "Undo is off for this sync."} Hidden rows stay out of every total, and you can show them again from Activity.` : null;
  const actions = record.rolledBack ? tag("Undone") : failed ? null : record.hiddenAt ? tag("Hidden")
    : policy.mode === "refused" ? (sync && r.rowsAdded ? hideButton(record) : null)
    : policy.mode === "warn" ? [undoButton(record, true), r.rowsAdded ? hideButton(record) : null]
    : undoButton(record, false);
  return h("div", { class: `row${record.rolledBack || failed ? " dim" : ""}` },
    h("span", { class: `glyph ${sync ? "tone-cyan" : "neutral"}` }, icon(sync ? "sync" : "file"), h("span", { class: "sr-only" }, sync ? "Sync" : "File import")),
    h("div", { class: "grow" }, h("div", { class: "title wrap" }, record.label), h("div", { class: "sub wrap" }, summary),
      failed ? h("div", { class: "warn-line act-text" }, `Didn't sync: ${record.error || "the provider didn't answer."}`) : null,
      (r.warnings || []).map((w) => h("div", { class: "warn-line" }, h("span", { class: "dot watch", "aria-hidden": "true" }), h("span", {}, "Warning: ", w))),
      hideNote ? h("div", { class: "help" }, hideNote) : null,
      details("Details", how),
      !record.rolledBack && !failed && (r.duplicatesSkipped || mergeCounts[record.batchID]) ? alreadyHere(record) : null),
    h("div", { class: "row-actions" }, actions));
}

/// Open merge-log entries per batch (GET /v1/merges/by-batch, server 0.6.0), so an import whose rows were swept or
/// merged later lists them even when it skipped nothing. Reloaded with the history; an older server has none.
let mergeCounts = {};
async function loadMergeCounts() {
  try { mergeCounts = (await api("/v1/merges/by-batch")) || {}; } catch { mergeCounts = {}; }
}

/// What Bring back did, in a toast: filed now, waiting in Review, or left for the decision model (`MergeUndoResult`).
function broughtBack(r) {
  if (r.restored === 1) {
    return r.waiting ? "Brought back. The decision model files it when the server next syncs or imports."
      : r.toReview ? "Brought back. It's waiting in Review for a category." : "Brought back and filed.";
  }
  const parts = [r.filed ? `${count(r.filed)} filed` : null, r.toReview ? `${count(r.toReview)} waiting in Review` : null,
    r.waiting ? `${count(r.waiting)} for the decision model to file when the server next syncs or imports, a few hundred at a time` : null].filter(Boolean);
  return `Brought back ${plural(r.restored, "transaction")}${parts.length ? `: ${parts.join(", ")}` : ""}.`;
}

/// "N already here" (or, for an import that skipped nothing, "N merged"), opened: each row the batch skipped and any
/// statement copy swept or merged since, with what it matched and Bring back. Read from the merge log (server 0.6.0)
/// when opened; an older server has none to show.
function alreadyHere(record) {
  const r = record.report;
  const list = h("div", { class: "rows" });
  const line = (t) => `${dateShort(t.postedAt)} · ${t.rawDescription} · ${money(t.amount)}`;
  const KIND_LABEL = { skippedIncoming: "Already here", sweptFileCopy: "Removed as a copy", duplicateResolved: "You said same charge",
    pendingSettled: "Pending, posted under a new id", pendingDropped: "Pending, the bank dropped it" };
  // What the logged row went into, or why it went.
  const why = (m) => m.kind === "pendingSettled" ? `Posted as: ${m.keptBefore ? line(m.keptBefore) : "a new row"}`
    : m.kind === "pendingDropped" ? `${SOURCE[m.dropped.source] || "The bank"} stopped sending it, on two syncs at least half a day apart.`
    : m.keptID ? `Matched ${SOURCE[(m.keptBefore || {}).source] || "a row already in the ledger"}${m.keptBefore ? `: ${line(m.keptBefore)}` : ""}` : null;
  // Rows an earlier import skipped (or merged) first are listed under that import, not this one.
  const before = r.duplicatesSkippedBefore || 0;
  const beforeNote = before ? h("div", { class: "help" }, `${plural(before, "row")} ${before === 1 ? "was" : "were"} skipped or merged by an earlier import first; ${before === 1 ? "it's" : "they're"} listed under that import, with Bring back.`) : null;
  const load = async () => {
    fill(list, h("div", { class: "help" }, "Loading…"));
    try {
      const merges = await api(`/v1/merges?batch=${encodeURIComponent(record.batchID)}`);
      const open = merges.filter((m) => !m.undoneAt);
      if (!open.length) {
        fill(list, beforeNote && !merges.length ? beforeNote
          : h("div", { class: "help" }, merges.length ? "All of them were brought back." : "Rows skipped before this server kept a log can't be listed."));
        return;
      }
      const skipped = open.filter((m) => m.kind === "skippedIncoming").length;
      fill(list,
        open.map((m) => h("div", { class: "row" },
          h("div", { class: "grow" }, h("div", { class: "title wrap" }, line(m.dropped), " ", tag(KIND_LABEL[m.kind] || m.kind)),
            why(m) ? h("div", { class: "sub wrap" }, why(m)) : null),
          button("Bring back", { kind: "quiet", compact: true, "aria-label": `Bring back ${m.dropped.rawDescription} on ${dateShort(m.dropped.postedAt)}`,
            onclick: (e) => busy(e.currentTarget, "Bringing back…", async () => {
              toast(broughtBack(await api(`/v1/merges/${encodeURIComponent(m.id)}/undo`, { method: "POST" })));
              await afterWrite();
              await load();
            }) }))),
        beforeNote,
        skipped > 1 ? h("div", { class: "card-foot" }, button(`Bring back all ${skipped}`, { compact: true, onclick: (e) => armed(e.currentTarget, `Click again to add ${plural(skipped, "row")} anyway`, async () => {
          try {
            toast(broughtBack(await api(`/v1/imports/${encodeURIComponent(record.batchID)}/merges/undo`, { method: "POST" })));
            await afterWrite();
            await load();
          } catch (error) { reportError(error); }
        }) })) : null);
    } catch (error) {
      fill(list, h("div", { class: "help" }, error.status === 404 ? "This server doesn't keep a list of skipped rows yet." : error.message));
    }
  };
  let loaded = false;
  // What the import itself did (skipped rows, pending charges swept), from its report; otherwise every open entry for
  // it, which counts rows merged or swept as copies since.
  const merged = mergeCounts[record.batchID] || 0, pending = (r.pendingSettled || 0) + (r.pendingDropped || 0);
  const said = [r.duplicatesSkipped ? `${count(r.duplicatesSkipped)} already here` : null,
    pending ? `${plural(pending, "pending charge")} settled or dropped` : null].filter(Boolean).join(" · ");
  return h("details", { class: "disclosure", ontoggle: (e) => { if (e.currentTarget.open && !loaded) { loaded = true; load(); } } },
    h("summary", {}, said || `${count(merged)} merged or removed as copies`), list);
}

/// Undo, armed by a second click. With `ask` (a SimpleFIN sync) the first click asks the server what Undo would do, and
/// the armed button says how many rows come back; the second sends that yes along. Clicks while the plan is loading
/// are ignored, so a double-click can't send the yes before the count was on screen.
function undoButton(record, ask) {
  const r = record.report;
  return button("Undo", { compact: true, "aria-label": `Undo ${record.label}`, onclick: async (e) => {
    const b = e.currentTarget;
    if (b.dataset.pending === "1") return;
    if (!ask || b.dataset.armed === "1") {
      armed(b, r.rowsAdded ? `Click again to remove ${plural(r.rowsAdded, "row")}` : "Click again to undo", () => undoImport(record, b._acknowledge === true));
      return;
    }
    b.dataset.pending = "1";
    try {
      const plan = await api(`/v1/imports/${encodeURIComponent(record.batchID)}/undo`);
      if (plan.verdict === "refuse") { toast(plan.message); return; }
      b._acknowledge = plan.verdict === "undoReturns";
      const back = plan.returning ? `${count(plan.returning)} come back at the next sync` : "linking it again brings them back";
      armed(b, `Click again to remove ${plural(plan.rows, "row")}${b._acknowledge ? `; ${back}` : ""}`, () => undoImport(record, b._acknowledge));
    } catch (error) { reportError(error); } finally { b.dataset.pending = ""; }
  } });
}

/// Hide rows: what a sync batch gets instead of Undo. Hidden rows keep balances and stay hidden when the bank sends them again.
function hideButton(record) {
  return button("Hide rows", { compact: true, kind: "quiet", "aria-label": `Hide the rows from ${record.label}`,
    onclick: (e) => armed(e.currentTarget, `Click again to hide ${plural(record.report.rowsAdded, "row")}`, () => hideImport(record)) });
}

async function undoImport(record, acknowledge) {
  try {
    const r = await api(`/v1/imports/${encodeURIComponent(record.batchID)}${acknowledge ? "?acknowledge=returning" : ""}`, { method: "DELETE" });
    toast(`Removed ${plural(r.removed, "transaction")} from ${record.label}`);
    // The file table above says so too, when the undone file is one of this batch.
    if (batch) for (const item of batch) if (item.batchID === record.batchID) item.undone = true;
    await afterWrite();
    if (batch && viewRef) viewRef.renderTable();
  } catch (error) { reportError(error); }
}

async function hideImport(record) {
  try {
    const result = await api(`/v1/imports/${encodeURIComponent(record.batchID)}/hide`, { method: "POST" });
    // History works "hidden" out from the rows on every read, so this undo also brings Hide rows back.
    toast(`${result.message} You can show them again from Activity.`, result.undo ? { action: { label: "Undo", run: async () => {
      try {
        await api("/v1/actions", { method: "POST", body: result.undo });
        await afterWrite();
      } catch (error) { reportError(error); }
    } } } : {});
    await afterWrite();
  } catch (error) { reportError(error); }
}

// MARK: Coverage

const monthLabel = (key, style) => new Date(`${key}-15T12:00:00`).toLocaleDateString("en-US", style);

/// One row per account: its months as a strip of cells. Filled means transactions came in; an amber outline means
/// none did in a month after its first transaction (a missing statement, or a card nobody used); faint is before
/// its first. This month is still under way.
function renderCoverage(data) {
  if (!data.accounts.length) return h("p", { class: "empty-line" }, "Once transactions come in, each account's months show here.");
  const months = data.months, now = months.length - 1;
  // Month labels over the strips: the first month and each January with its year; on wider screens also April,
  // July and October. Each sits over its own column and may run over the next few; a label that would run into
  // the first one is left out.
  const firstJanuary = months.findIndex((m) => m.endsWith("-01"));
  const showFirst = firstJanuary < 0 || firstJanuary >= 4;
  const marks = months.map((m, i) => {
    const year = (i === 0 && showFirst) || m.endsWith("-01"), quarter = /-(04|07|10)$/.test(m) && (!showFirst || i >= 3);
    if (!year && !quarter) return null;
    return h("span", { class: `cov-mark${year ? "" : " minor"}`, css: { "grid-column": String(i + 1) } },
      monthLabel(m, year ? { month: "short", year: "numeric" } : { month: "short" }));
  });
  const rows = data.accounts.map((a) => {
    const first = a.firstMonth;
    const nonzero = a.counts.filter((n) => n > 0).sort((x, y) => x - y);
    const median = nonzero.length ? nonzero[Math.floor(nonzero.length / 2)] : 0;
    const cells = months.map((m, i) => {
      const n = a.counts[i], gap = a.gaps.includes(m), before = !first || m < first;
      const cls = n > 0 ? (n < median / 3 ? "has low" : "has") : gap ? "gap" : i === now ? "now" : before ? "before" : "none";
      const says = n > 0 ? plural(n, "transaction") : gap ? "no transactions" : i === now ? "nothing yet this month" : "before its first transaction";
      return h("span", { class: `cov-cell ${cls}`, title: `${monthLabel(m, { month: "long", year: "numeric" })}: ${says}` });
    });
    const gaps = a.gaps.length;
    const described = gaps ? `no transactions in ${a.gaps.map((m) => monthLabel(m, { month: "short", year: "numeric" })).join(", ")}`
      : first ? `transactions every month since ${monthLabel(first, { month: "short", year: "numeric" })}` : "no transactions yet";
    const statements = a.source === "fileImport";
    return h("div", { class: "cov-row" },
      h("div", { class: "cov-name" },
        h("div", { class: "title" }, a.nickname || a.name, a.mask ? h("span", { class: "mask" }, ` ••${a.mask}`) : null),
        h("div", { class: "sub" }, `${a.institution} · ${statements ? "statements" : `via ${SOURCE[a.source] || a.source}`}`,
          gaps ? h("span", { class: "watch-text" }, ` · ${gaps === 1 ? "1 empty month" : `${gaps} empty months`}`) : null)),
      h("div", { class: "cov-strip", role: "img", "aria-label": `${a.nickname || a.name}: ${described}.` }, cells),
      h("div", { class: "cov-act" }, statements ? h("a", { class: "btn quiet", href: `#/imports?account=${encodeURIComponent(a.id)}`, "aria-label": `Import a statement into ${accountName(a)}` }, "Import") : null));
  });
  return [
    h("div", { class: "cov-grid" }, h("div", { class: "cov-row cov-head", "aria-hidden": "true" }, h("div", { class: "cov-name" }), h("div", { class: "cov-strip" }, marks), h("div", { class: "cov-act" })), rows),
    h("div", { class: "cov-legend", "aria-hidden": "true" },
      h("span", {}, h("span", { class: "cov-cell has" }), "Transactions"), h("span", {}, h("span", { class: "cov-cell has low" }), "Fewer than usual"),
      h("span", {}, h("span", { class: "cov-cell gap" }), "Nothing that month"), h("span", {}, h("span", { class: "cov-cell before" }), "Before its first")),
    h("p", { class: "help" }, "Calendar months in the server's time zone, including this one so far. A card nobody used that month shows as nothing too."),
  ];
}

// MARK: View

export default {
  title: "Imports",
  limit: 50,
  mount(root, { params }) {
    this.root = root;
    this.preselect = params.get("account") || "";
    this.render();
  },
  navigate({ params }) { this.preselect = params.get("account") || ""; this.render(); },
  refresh({ after } = {}) {
    if (after && this.coverage && cached("coverage") === undefined) loadInto(this.coverage, () => heavy("coverage"), renderCoverage);
    if (after) loadMergeCounts().then(() => this.refresh());
    if (!this.history || isArmed(this.history) || this.history.querySelector(".busy")) return;
    if (after) this.limit = Math.max(50, this.limit);
    this.renderHistory();
  },
  render() {
    viewRef = this;
    this.flow = h("section", { class: "card", "aria-label": "Import statements" });
    this.history = h("section", { class: "card history", "aria-labelledby": "history-title" });
    const pre = this.preselect && store.overview.accounts.find((a) => a.id === this.preselect);
    fill(this.root, 
      pageHead({ eyebrow: "Statements", title: "Imports",
        sub: "Download CSV, OFX or QFX files from your bank's website and drop them here. Rows already in the ledger, from a sync or an earlier import, are skipped." }),
      pre && !batch ? h("div", { class: "banners" }, callout({ tone: "info", role: "note", title: `Files go into ${pre.name}${pre.mask ? ` ••${pre.mask}` : ""} unless they name another account.` })) : null,
      this.flow,
      ordersRegion(),
      this.coverageRegion(),
      sectionHead("History", null, "history-title"),
      this.history);
    this.renderFlow();
    this.renderHistory();
    loadMergeCounts().then(() => this.refresh());
  },

  /// Accounts × the last 24 months (GET /dash/coverage): which months have transactions, and which don't.
  coverageRegion() {
    this.coverage = h("section", { class: "card coverage", "aria-labelledby": "coverage-title" });
    loadInto(this.coverage, () => heavy("coverage"), renderCoverage);
    return [sectionHead("What's covered", null, "coverage-title"), this.coverage];
  },

  renderFlow() {
    if (!batch) {
      const input = h("input", { type: "file", accept: ".csv,.ofx,.qfx,text/csv", multiple: true, hidden: true, onchange: (e) => this.choose(e.target.files) });
      const drop = h("div", { class: "drop", tabindex: "0", role: "button", "aria-label": "Choose statement files to import",
        onclick: () => input.click(), onkeydown: (e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); input.click(); } },
        ondragover: (e) => { e.preventDefault(); drop.classList.add("over"); }, ondragleave: () => drop.classList.remove("over"),
        ondrop: (e) => { e.preventDefault(); drop.classList.remove("over"); this.choose(e.dataTransfer.files); } },
        h("strong", {}, "Drop statements here"),
        h("span", { class: "t-callout" }, "One file or a whole year of them. Each is matched to its account by the digits in its name."),
        h("span", { class: "btn secondary compact", "aria-hidden": "true" }, "Choose files"));
      fill(this.flow, h("div", { class: "flash", id: "import-flash" }), drop, input,
        h("p", { class: "help flow-note" }, "New rows are filed by your rules, then remembered merchants, then the decision model once per merchant. Anything it isn't sure about waits for you. Every import can be undone below."));
      return;
    }
    fill(this.flow, h("div", { class: "flash", id: "import-flash" }), h("div", { class: "table-wrap" }), h("p", { class: "totals" }), h("div", { class: "actions flow-actions" }));
    this.renderTable();
  },

  async choose(fileList) {
    const files = [...(fileList || [])];
    if (!files.length) return;
    const big = files.find((f) => f.size > MAX_BYTES);
    if (big) { reportError({ message: `${big.name} is over 30 MB. Split it into smaller date ranges at the bank.` }, this.root.querySelector("#import-flash")); return; }
    const items = await Promise.all(files.sort((a, b) => a.name.localeCompare(b.name)).map(async (f) => {
      const text = await f.text(), ofx = isOFX(f.name, text);
      const guess = guessAccount(f.name, text);
      const accountID = guess || this.preselect || "";
      return { name: f.name, text, ofx, accountID, guessed: !!guess, sign: "auto", preview: null, done: null, error: null,
        newAccount: ofx ? ofxNewAccount(text) : { name: "", institution: "", kind: "checking", balance: "" } };
    }));
    batch = items;
    this.render();
  },

  renderTable() {
    if (!batch) return this.renderFlow();
    const wrap = this.flow.querySelector(".table-wrap");
    const rows = batch.flatMap((item) => [fileRow(item, this), item.accountID === NEW && !item.done ? newAccountRow(item, this) : null, samplesRow(item)].filter(Boolean));
    fill(wrap, h("table", { class: "table stack-phone file-table" },
      h("thead", {}, h("tr", {}, h("th", {}, "File"), h("th", {}, "Into account"), h("th", {}, "Dates"), h("th", { class: "numcol" }, "New"),
        h("th", { class: "numcol" }, "Already here"), h("th", {}, "Status"))),
      h("tbody", {}, rows)));
    this.updateButtons();
  },
  updateStatus(item) {
    const row = [...this.flow.querySelectorAll("tr[data-file]")].find((tr) => tr.dataset.file === item.name);
    if (row) fill(row.querySelector(".status-cell"), statusCell(item));
  },

  updateButtons() {
    if (!batch) return;
    const pending = batch.filter((i) => !i.done);
    const allReady = batch.every(ready), previewed = pending.every((i) => i.preview);
    const totals = batch.filter((i) => !i.undone).reduce((t, i) => { const r = i.done || i.preview; if (r) { t.added += r.rowsAdded; t.dupes += r.duplicatesSkipped; t.n++; } return t; }, { added: 0, dupes: 0, n: 0 });
    const allDone = !pending.length;
    this.flow.querySelector(".totals").textContent = !totals.n ? (allReady ? "Preview to see what each file adds before anything is saved." : "Choose an account for each file, then preview.")
      : `${allDone ? "Imported" : "Would add"} ${plural(totals.added, "new transaction")} from ${plural(totals.n, "file")}` +
        (totals.dupes ? `; ${count(totals.dupes)} ${totals.dupes === 1 ? "is" : "are"} already in the ledger and ${allDone ? "were" : "will be"} skipped.` : ".");
    const actions = this.flow.querySelector(".flow-actions");
    if (allDone) {
      fill(actions, button("Import more", { kind: "secondary", onclick: () => { batch = null; this.render(); } }));
      return;
    }
    fill(actions, 
      button("Preview", { kind: "secondary", disabled: !allReady, onclick: (e) => busy(e.currentTarget, "Previewing…", () => this.preview(), { errorTarget: this.flow.querySelector("#import-flash") }) }),
      button(`Import ${plural(pending.length, "file")}`, { kind: "primary", disabled: !allReady || !previewed || batch.some((i) => i.error),
        onclick: (e) => this.importAll(e.currentTarget) }),
      button("Cancel", { kind: "quiet", onclick: () => { batch = null; this.render(); } }));
  },

  /// One request for every file, so rows two exports share are counted once. If it fails, each file is
  /// previewed alone to say which one is the problem.
  async preview() {
    const items = batch.filter((i) => !i.done);
    items.forEach((i) => { i.error = null; });
    try {
      const bodies = items.map((i) => importBody(i, true));
      const reports = await api("/v1/imports/preview", { method: "POST", body: { files: bodies } });
      items.forEach((item, index) => { item.preview = reports[index]; });
    } catch (error) {
      if (error.network) throw error;
      for (const item of items) {
        try { item.preview = await api("/v1/imports", { method: "POST", body: importBody(item, true) }); }
        catch (e) { item.preview = null; item.error = e.message; }
      }
      if (!items.some((i) => i.error)) throw error;
    }
    this.renderTable();
  },

  async importAll(buttonEl) {
    const items = batch.filter((i) => !i.done);
    const label = buttonEl.textContent;
    let n = 0;
    await busy(buttonEl, `Importing 1 of ${items.length}…`, async () => {
      for (const item of items) {
        buttonEl.textContent = `Importing ${++n} of ${items.length}…`;
        try {
          const record = await api("/v1/imports", { method: "POST", body: importBody(item, false) });
          item.done = record.report; item.batchID = record.batchID; item.error = null;
        }
        catch (error) { item.error = error.message; break; }
      }
    }, { errorTarget: this.flow.querySelector("#import-flash") });
    buttonEl.textContent = label;
    const done = items.filter((i) => i.done), review = done.reduce((t, i) => t + i.done.needsReview, 0);
    if (done.length) toast(`Imported ${plural(done.length, "file")}${review ? ` · ${count(review)} waiting for a category` : ""}`,
      review ? { action: { label: "File them", run: () => { location.hash = "#/review/categories"; } } } : {});
    this.renderTable();
    await afterWrite();
  },

  renderHistory() {
    const all = cached("history");
    const records = (all ? [...all].sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt)) : store.summary.imports);
    const shown = records.slice(0, this.limit);
    const more = records.length > this.limit || (!all && store.summary.imports.length >= 50);
    fill(this.history, 
      shown.length ? h("div", { class: "rows" }, shown.map(historyRow))
        : emptyState({ title: "Nothing imported yet", body: "Imports and syncs that add transactions show up here, each with an Undo." }),
      more ? h("div", { class: "card-foot" }, button("Show older", { compact: true, onclick: (e) => busy(e.currentTarget, "Loading…", async () => {
        await heavy("history");
        this.limit += 50;
        this.renderHistory();
      }) }), h("span", { class: "t-caption faint" }, `Showing the latest ${count(shown.length)}.`)) : null);
  },
};
