// Amazon orders, on the Imports page: Amazon's order history file matched to the card charges it paid for, so each
// charge says what it bought. Preview first; nothing is re-filed (a charge whose items read as another category waits in
// Review with that suggestion), and importing the same file again changes nothing.
import { fill, h, api, sectionHead, button, busy, details, tag, toast, money, count, plural, dateShort, reportError, afterWrite, categoryName } from "./core.js";

const MAX_BYTES = 30 * 1024 * 1024;
/// The file chosen and what it would do (or did). Module-level, so leaving the page and coming back keeps it.
let chosen = null;

/// The section: a heading and its card, for the Imports page to place.
export function ordersRegion() {
  const card = h("section", { class: "card orders", "aria-labelledby": "orders-title" });
  render(card);
  return [sectionHead("Amazon orders", null, "orders-title"), card];
}

function render(card) {
  const flash = h("div", { class: "flash", id: "orders-flash" });
  if (!chosen) {
    const input = h("input", { type: "file", accept: ".csv,text/csv", hidden: true, onchange: (e) => choose(card, flash, e.target.files[0]) });
    fill(card, flash,
      h("p", { class: "t-callout" }, "See what each Amazon charge bought. Ask Amazon for your data (Your Orders), then choose Retail.OrderHistory.1.csv from the download."),
      h("div", { class: "actions" }, button("Choose order history", { kind: "secondary", onclick: () => input.click() })), input,
      h("p", { class: "help" }, "Orders are matched to Amazon charges of the same amount within a week. Nothing is re-filed: a charge whose items read as another category waits in Review with that suggestion. Importing the same file again changes nothing."));
    return;
  }
  const r = chosen.report;
  const actions = h("div", { class: "actions" });
  if (chosen.done) {
    fill(actions, button("Match another file", { kind: "secondary", onclick: () => { chosen = null; render(card); } }),
      r.suggested ? h("a", { class: "btn quiet", href: "#/review/categories" }, `Review ${plural(r.suggested, "suggestion")}`) : null);
  } else {
    fill(actions,
      button(r.matched ? `Match ${plural(r.matched, "charge")}` : "Nothing to match", { kind: "primary", disabled: !r.matched,
        onclick: (e) => busy(e.currentTarget, "Matching…", () => apply(card), { errorTarget: flash }) }),
      button("Cancel", { kind: "quiet", onclick: () => { chosen = null; render(card); } }));
  }
  fill(card, flash,
    h("div", { class: "file-name" }, chosen.name, " ", tag(chosen.done ? "Matched" : "Preview", chosen.done ? "ok" : "info")),
    h("p", { class: "totals" }, summary(r, chosen.done)),
    r.matches.length ? matchTable(r) : null,
    r.unmatchedOrders.length ? details(`Orders with no charge found (${count(r.unmatched)})`, unmatchedTable(r)) : null,
    actions);
}

/// "Would match 12 charges from 40 orders · 3 to review · 2 orders found no charge · 25 are from before your ledger."
function summary(r, done) {
  const parts = [`${done ? "Matched" : "Would match"} ${plural(r.matched, "charge")} from ${plural(r.orders, "order")}`];
  if (r.suggested) parts.push(`${count(r.suggested)} ${done ? "wait" : "would wait"} in Review with a category from their items`);
  if (r.alreadyMatched) parts.push(`${plural(r.alreadyMatched, "order")} matched before`);
  if (r.unmatched) parts.push(`${plural(r.unmatched, "order")} found no charge`);
  if (r.beforeLedger) parts.push(`${plural(r.beforeLedger, "order")} from before your first transaction`);
  if (r.skippedLines) parts.push(`${plural(r.skippedLines, "line")} cancelled or unreadable`);
  return parts.join(" · ") + ".";
}

function matchTable(r) {
  return h("div", { class: "table-wrap" }, h("table", { class: "table stack-phone" },
    h("thead", {}, h("tr", {}, h("th", {}, "Charge"), h("th", { class: "numcol" }, "Amount"), h("th", {}, "Bought"), h("th", {}, "Suggested"))),
    h("tbody", {}, r.matches.map((m) => h("tr", {},
      h("td", { "data-label": "Charge" }, dateShort(m.postedAt)),
      h("td", { class: "numcol num", "data-label": "Amount" }, money(m.amount)),
      h("td", { "data-label": "Bought" }, m.items.join(", ")),
      h("td", { "data-label": "Suggested" }, m.suggestedCategoryID ? categoryName(m.suggestedCategoryID) : "—"))))));
}

function unmatchedTable(r) {
  return h("table", { class: "table stack-phone" },
    h("thead", {}, h("tr", {}, h("th", {}, "Ordered"), h("th", {}, "Order"), h("th", { class: "numcol" }, "Total"), h("th", {}, "Items"))),
    h("tbody", {}, r.unmatchedOrders.map((o) => h("tr", {},
      h("td", { "data-label": "Ordered" }, dateShort(o.orderedAt)), h("td", { "data-label": "Order" }, o.orderID),
      h("td", { class: "numcol num", "data-label": "Total" }, money(o.total)), h("td", { "data-label": "Items" }, o.items.join(", "))))));
}

async function choose(card, flash, file) {
  if (!file) return;
  if (file.size > MAX_BYTES) { reportError({ message: `${file.name} is over 30 MB.` }, flash); return; }
  try {
    const text = await file.text();
    const report = await api("/v1/imports/amazon", { method: "POST", body: { content: text, preview: true } });
    chosen = { name: file.name, text, report, done: false };
    render(card);
  } catch (error) { reportError(error, flash); }
}

async function apply(card) {
  const report = await api("/v1/imports/amazon", { method: "POST", body: { content: chosen.text, preview: false } });
  chosen = { ...chosen, report, done: true };
  render(card);
  toast(`Matched ${plural(report.matched, "Amazon charge")}${report.suggested ? ` · ${count(report.suggested)} waiting in Review` : ""}`,
    report.suggested ? { action: { label: "Review", run: () => { location.hash = "#/review/categories"; } } } : {});
  await afterWrite();
}
