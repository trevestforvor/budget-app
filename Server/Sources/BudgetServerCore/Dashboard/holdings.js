// [lane A] Investments by holding, under Net worth on the Accounts page: each investment account's positions as the
// broker last reported them (GET /v1/holdings, server 0.6.0), with what the balance holds beyond them, and a status line
// for each Plaid bank whose last holdings check didn't come back. Read-only: holdings are checked once a day per bank.
import { h, fill, api, money, rowMoney, dateShort, details, statusLine, accountName, store } from "./core.js";

const view = { el: null, data: null, missing: false, fetchedAt: 0 };
/// Holdings change once a day; the page's light refreshes ask again after this long.
const FRESH_MS = 60000;

/// What each check that didn't come back says, beside the bank's name. Others (ok, no investment accounts, not offered)
/// need nothing from the person and aren't shown.
const ACCESS = {
  notReady: () => ({ tone: "watch", label: "Holdings not ready yet", detail: ["Plaid is still gathering them; the next check asks again"] }),
  needsConsent: () => ({ tone: "watch", label: "Holdings need investment access", detail: ["this bank was linked without it"] }),
  failed: (c) => ({ tone: "act", label: "Holdings check failed", detail: [`checked ${dateShort(c.checkedAt)}`] }),
};

/// The section, built once and kept; it fetches again when it's older than `FRESH_MS`. Empty on a server before 0.6.0
/// and when there's nothing to show.
export function holdingsSection() {
  if (!view.el) {
    view.el = h("div", { class: "stack nw-holdings" });
    load();
  } else if (Date.now() - view.fetchedAt > FRESH_MS) {
    load();
  }
  return view.el;
}

async function load() {
  view.fetchedAt = Date.now();
  try {
    view.data = await api("/v1/holdings");
    view.missing = false;
  } catch (error) {
    // A server before 0.6.0 has no holdings; any other failure keeps what's on screen.
    if (error && error.status === 404) view.missing = true;
  }
  render();
}

function render() {
  if (!view.el) return;
  const accounts = view.missing || !view.data ? [] : view.data.accounts || [];
  const problems = ((store.summary && store.summary.links) || [])
    .filter((l) => l.provider === "plaid" && l.holdings && ACCESS[l.holdings.access]);
  if (!accounts.length && !problems.length) { fill(view.el); return; }
  fill(view.el,
    h("div", { class: "nw-list-head" }, h("h3", { class: "t-headline", id: "holdings-title" }, "Investments by holding")),
    problems.length ? h("div", { class: "card" }, problems.map((l) => h("div", {},
      h("div", { class: "title" }, l.institution), statusLine(ACCESS[l.holdings.access](l.holdings)),
      l.holdings.access === "failed" && l.holdings.message ? details("Details", l.holdings.message) : null))) : null,
    accounts.map(card));
}

/// One account: its name, bank and when the broker last reported, the total, and a table of positions.
function card(a) {
  const account = ((store.overview && store.overview.accounts) || []).find((x) => x.id === a.id);
  const name = accountName(a.id) || "Investment account";
  const sub = [account && account.institution, `as of ${dateShort(a.fetchedAt)}`].filter(Boolean).join(" · ");
  const rows = a.holdings.map(row);
  if (a.unitemized) {
    rows.push(h("tr", {},
      h("td", { "data-label": "Holding" }, h("div", { class: "cell-title" }, "Not itemized by the broker"), h("div", { class: "cell-sub" }, "Cash or positions it didn't list")),
      h("td", { class: "numcol", "data-label": "Quantity" }, ""), h("td", { class: "numcol", "data-label": "Price" }, ""),
      h("td", { class: "numcol num", "data-label": "Value" }, money(a.unitemized)),
      h("td", { class: "numcol", "data-label": "Cost basis" }, ""), h("td", { class: "numcol", "data-label": "Gain" }, "")));
  }
  return h("section", { class: "card", "aria-label": `${name} holdings` },
    h("div", { class: "nw-list-head" }, h("div", {}, h("h3", { class: "t-headline" }, name), h("p", { class: "help" }, sub)), rowMoney(a.total)),
    rows.length ? h("div", { class: "table-wrap" }, h("table", { class: "table stack-phone" },
      h("thead", {}, h("tr", {}, h("th", {}, "Holding"), h("th", { class: "numcol" }, "Quantity"), h("th", { class: "numcol" }, "Price (as of)"),
        h("th", { class: "numcol" }, "Value"), h("th", { class: "numcol" }, "Cost basis"), h("th", { class: "numcol" }, "Gain"))),
      h("tbody", {}, rows)))
      : h("p", { class: "empty-line" }, "The broker listed no positions."));
}

/// One position. The gain is in neutral ink: no red or green verdict on investments.
function row(p) {
  const gain = p.costBasis ? { minor: p.value.minor - p.costBasis.minor, currency: p.value.currency } : null;
  const sub = p.isCash ? "Cash" : p.ticker || null;
  return h("tr", {},
    h("td", { "data-label": "Holding" }, h("div", { class: "cell-title" }, p.name), sub ? h("div", { class: "cell-sub" }, sub) : null),
    h("td", { class: "numcol num", "data-label": "Quantity" }, p.isCash || p.quantity == null ? "—" : shares(p.quantity)),
    h("td", { class: "numcol num", "data-label": "Price" }, p.isCash || !p.price ? "—"
      : [money(p.price), p.priceAsOf ? h("div", { class: "cell-sub" }, dateShort(p.priceAsOf)) : null]),
    h("td", { class: "numcol num", "data-label": "Value" }, money(p.value)),
    h("td", { class: "numcol num", "data-label": "Cost basis" }, p.costBasis ? money(p.costBasis) : "—"),
    h("td", { class: "numcol num muted", "data-label": "Gain" }, gain && gain.minor ? money(gain, { sign: true }) : "—"));
}

const shares = (q) => Number(q).toLocaleString("en-US", { maximumFractionDigits: 4 });
