// Imports: one table for one file or a year of them (preview, then import), and the history of every
// import and sync with its warnings and an Undo that says what it removes.
import { fill, h, api, store, heavy, cached, pageHead, sectionHead, button, busy, armed, isArmed, callout, details, tag, icon, afterWrite,
  reportError, toast, money, count, plural, dateShort, span, KIND, SOURCE, emptyState, loadInto } from "./core.js";

const NEW = "__new__";
const MAX_BYTES = 30 * 1024 * 1024;
/// Files chosen but not imported yet. Module-level, so leaving the page and coming back keeps them.
let batch = null;
/// The view while it's mounted, for work that finishes after a request (an undo redraws the file table).
let viewRef = null;

const isOFX = (name, text) => /\.(ofx|qfx)$/i.test(name) || /<OFX>|OFXHEADER/i.test(text.slice(0, 4000));

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
  if (item.ofx) return true;
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

/// The request body for one file, preview or not. A new account (CSV) carries its name, kind and balance.
function importBody(item, preview) {
  const account = store.overview.accounts.find((a) => a.id === item.accountID);
  const options = { format: item.ofx ? "ofx" : "csv", sign: item.ofx ? "auto" : item.sign,
    institution: account ? account.institution : (item.newAccount.institution.trim() || "Import") };
  const body = { content: item.text, label: item.name, preview, options };
  if (account) body.accountID = account.id;
  else if (!item.ofx) {
    options.accountName = item.newAccount.name.trim();
    options.accountKind = item.newAccount.kind;
    const balance = parseBalance(item.newAccount.balance);
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
    h("option", { value: "" }, item.ofx ? "A new account from the file" : "Choose an account…"),
    accounts.map((a) => h("option", { value: a.id }, `${a.institution} · ${a.name}${a.mask ? ` ••${a.mask}` : ""}`)),
    item.ofx ? null : h("option", { value: NEW }, "New account…"));
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
    input("balance", "Balance today (optional)", { inputmode: "decimal", placeholder: "2450.18" }))));
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
    r.rowsUpdated ? `${count(r.rowsUpdated)} updated` : null, r.needsReview ? `${count(r.needsReview)} to review` : null, span(r.addedFrom, r.addedThrough) || null].filter(Boolean).join(" · ");
  const filed = [[r.byRule, "by your rules"], [r.byTransferMatch, "as transfers between your accounts"], [r.byStatement, "settled by the statement"],
    [r.byMemory, "by remembered merchants"], [r.byModel, "by the decision model"]].filter(([n]) => n > 0).map(([n, how]) => `${count(n)} ${how}`);
  const how = [filed.length ? `Filed on their own: ${filed.join(", ")}.` : "Nothing was filed on its own.",
    r.modelCalls ? `${plural(r.modelCalls, "question")} to the decision model${r.modelMilliseconds != null ? `, ${(r.modelMilliseconds / 1000).toFixed(1)} s` : ""}.` : null].filter(Boolean).join(" ");
  const undo = record.rolledBack ? tag("Undone") : button("Undo", { compact: true, "aria-label": `Undo ${record.label}`,
    onclick: (e) => armed(e.currentTarget, r.rowsAdded ? `Click again to remove ${plural(r.rowsAdded, "row")}` : "Click again to undo", () => undoImport(record)) });
  return h("div", { class: `row${record.rolledBack ? " dim" : ""}` },
    h("span", { class: `glyph ${sync ? "cyan" : "neutral"}` }, icon(sync ? "sync" : "file"), h("span", { class: "sr-only" }, sync ? "Sync" : "File import")),
    h("div", { class: "grow" }, h("div", { class: "title wrap" }, record.label), h("div", { class: "sub wrap" }, summary),
      (r.warnings || []).map((w) => h("div", { class: "warn-line" }, h("span", { class: "dot watch", "aria-hidden": "true" }), h("span", {}, "Warning: ", w))),
      details("Details", how)),
    h("div", { class: "row-actions" }, undo));
}

async function undoImport(record) {
  try {
    const r = await api(`/v1/imports/${encodeURIComponent(record.batchID)}`, { method: "DELETE" });
    toast(`Removed ${plural(r.removed, "transaction")} from ${record.label}`);
    // The file table above says so too, when the undone file is one of this batch.
    if (batch) for (const item of batch) if (item.batchID === record.batchID) item.undone = true;
    await afterWrite();
    if (batch && viewRef) viewRef.renderTable();
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
        h("div", { class: "title" }, a.name, a.mask ? h("span", { class: "mask" }, ` ••${a.mask}`) : null),
        h("div", { class: "sub" }, `${a.institution} · ${statements ? "statements" : `via ${SOURCE[a.source] || a.source}`}`,
          gaps ? h("span", { class: "watch-text" }, ` · ${gaps === 1 ? "1 empty month" : `${gaps} empty months`}`) : null)),
      h("div", { class: "cov-strip", role: "img", "aria-label": `${a.name}: ${described}.` }, cells),
      h("div", { class: "cov-act" }, statements ? h("a", { class: "btn quiet", href: `#/imports?account=${encodeURIComponent(a.id)}`, "aria-label": `Import a statement into ${a.name}` }, "Import") : null));
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
      this.coverageRegion(),
      sectionHead("History", null, "history-title"),
      this.history);
    this.renderFlow();
    this.renderHistory();
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
      const accountID = guess || (!ofx && this.preselect) || "";
      return { name: f.name, text, ofx, accountID, guessed: !!guess, sign: "auto", preview: null, done: null, error: null,
        newAccount: { name: "", institution: "", kind: "checking", balance: "" } };
    }));
    batch = items;
    this.render();
  },

  renderTable() {
    if (!batch) return this.renderFlow();
    const wrap = this.flow.querySelector(".table-wrap");
    const rows = batch.flatMap((item) => [fileRow(item, this), !item.ofx && item.accountID === NEW && !item.done ? newAccountRow(item, this) : null, samplesRow(item)].filter(Boolean));
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
