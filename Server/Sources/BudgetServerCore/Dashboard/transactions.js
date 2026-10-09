// Transactions: the ledger's rows, narrowed by search, period, category and tag, each with its tags; "Download CSV" saves
// exactly what's showing (GET /v1/transactions/export.csv, the same filter; RFC 4180). Tags in use sit on top as chips:
// one click narrows to that tag and shows what it adds up to (GET /v1/tags/{tag}). Tagging happens on the phone.
import { fill, h, api, pageHead, button, callout, tag, money, count, plural, dateShort, accountName, categoryTag, categoryOptions, fileable,
  emptyState, skeleton } from "./core.js";

const PAGE = 100;
const PERIODS = [["", "All time"], ["this_month", "This month"], ["last_month", "Last month"], ["last_90_days", "Last 90 days"],
  ["year_to_date", "This year"], ["last_year", "Last year"]];

/// The view while it's on screen: the filter, how many rows to ask for, and the regions it redraws.
let view = null;

/// The filter as `TransactionFilter.queryItems` names it (the export ignores paging).
function query(f, { limit } = {}) {
  const p = new URLSearchParams();
  if (limit) p.set("limit", String(limit));
  if (f.q.trim()) p.set("q", f.q.trim());
  if (f.period) p.set("period", f.period);
  if (f.category) p.append("category", f.category);
  if (f.tag) p.append("tag", f.tag);
  return p.toString();
}

function filterFromParams(params) {
  return { q: params.get("q") || "", period: params.get("period") || "", category: params.get("category") || "", tag: params.get("tag") || "" };
}

/// The hash keeps the filter, so a reload or a shared link opens the same rows.
function remember(f) {
  const q = query(f);
  history.replaceState(null, "", `#/transactions${q ? "?" + q : ""}`);
}

function draw(v) {
  const f = v.filter;
  const search = h("input", { class: "input", type: "search", placeholder: "Merchant, note, tag or amount", "aria-label": "Search transactions", value: f.q,
    oninput: (e) => { f.q = e.target.value; clearTimeout(v.typing); v.typing = setTimeout(() => reload(v), 250); } });
  const period = h("select", { class: "input", "aria-label": "Period", onchange: (e) => { f.period = e.target.value; reload(v); } },
    PERIODS.map(([value, label]) => h("option", { value, selected: value === f.period }, label)));
  const cat = h("select", { class: "input", "aria-label": "Category", onchange: (e) => { f.category = e.target.value; reload(v); } },
    h("option", { value: "" }, "All categories"), categoryOptions(fileable()));
  cat.value = f.category;
  v.download = h("a", { class: "btn secondary", download: "", href: `/v1/transactions/export.csv?${query(f)}` }, "Download CSV");
  v.tagsEl = h("div", { class: "chips txn-tags", role: "group", "aria-label": "Tags" });
  v.tagCard = h("div", { class: "txn-tag-card" });
  v.listEl = h("div", {});
  fill(v.root,
    pageHead({ eyebrow: "Ledger", title: "Transactions", sub: "Every row the phone shows, with its tags. Download what's showing as a CSV for a spreadsheet.",
      action: v.download }),
    h("section", { class: "card stack", "aria-label": "Filter" },
      h("div", { class: "txn-filters" }, search, period, cat),
      v.tagsEl),
    v.tagCard,
    h("section", { class: "card", "aria-label": "Transactions" }, v.listEl));
}

async function loadTags(v) {
  try {
    const tags = await api(`/v1/tags${v.filter.period ? `?period=${encodeURIComponent(v.filter.period)}` : ""}`);
    if (view !== v) return;
    v.tags = tags;
    drawTags(v);
  } catch (error) {
    if (view !== v) return;
    // A server before tags has no /v1/tags; the list still works without the chips.
    fill(v.tagsEl, error.status === 404 ? null : h("p", { class: "help" }, `Tags didn't load: ${error.message}`));
  }
}

function drawTags(v) {
  const f = v.filter;
  if (!v.tags.length) {
    fill(v.tagsEl, h("p", { class: "help" }, "No tags yet. Tag transactions on the phone (a trip, a project, what work pays back) and they show up here."));
    return;
  }
  fill(v.tagsEl, h("span", { class: "t-eyebrow txn-tags-label" }, "Tags"), v.tags.map((t) => h("button", {
    type: "button", class: "chip", "aria-pressed": String(f.tag.toLowerCase() === t.tag.toLowerCase()),
    onclick: () => { f.tag = f.tag.toLowerCase() === t.tag.toLowerCase() ? "" : t.tag; reload(v); },
  }, t.tag, h("span", { class: "tag" }, count(t.count)))));
}

/// What the chosen tag adds up to, by the Spending tab's rules.
async function loadTagCard(v) {
  const f = v.filter;
  if (!f.tag) { fill(v.tagCard); return; }
  try {
    const s = await api(`/v1/tags/${encodeURIComponent(f.tag)}${f.period ? `?period=${encodeURIComponent(f.period)}` : ""}`);
    if (view !== v || f.tag.toLowerCase() !== s.tag.toLowerCase()) return;
    fill(v.tagCard, h("section", { class: "card stack", "aria-labelledby": "txn-tag-title" },
      h("div", { class: "section-head" }, h("h2", { class: "t-headline", id: "txn-tag-title" }, s.tag),
        button("Show every tag", { kind: "quiet", onclick: () => { f.tag = ""; reload(v); } })),
      h("div", { class: "stats" },
        h("div", { class: "stat" }, h("span", { class: "t-eyebrow" }, "Spent"), h("span", { class: "t-amount num" }, money(s.spent)),
          h("span", { class: "sub" }, "Net of refunds; hidden rows and transfers left out")),
        s.income && s.income.minor ? h("div", { class: "stat" }, h("span", { class: "t-eyebrow" }, "Money in"), h("span", { class: "t-amount num inflow" }, money(s.income))) : null,
        h("div", { class: "stat" }, h("span", { class: "t-eyebrow" }, "Transactions"), h("span", { class: "t-amount num" }, count(s.count)),
          h("span", { class: "sub" }, s.earliest ? `${dateShort(s.earliest)} – ${dateShort(s.latest)}` : ""))),
      (s.byCategory || []).length ? h("div", { class: "rows" }, s.byCategory.map((c) => h("div", { class: "row" },
        h("div", { class: "grow" }, categoryTag(c.categoryID)), h("span", { class: "t-amount-row amount num" }, money(c.spent))))) : null));
  } catch (error) {
    if (view !== v) return;
    fill(v.tagCard, error.status === 404 ? callout({ tone: "info", role: "note", title: `Nothing in this period is tagged “${f.tag}”.` })
      : callout({ tone: "watch", title: error.message, detail: error.detail }));
  }
}

async function loadRows(v) {
  const f = v.filter, asked = query(f, { limit: v.limit });
  if (!v.rows) fill(v.listEl, skeleton(6));
  try {
    const rows = await api(`/v1/transactions?${asked}`);
    if (view !== v || asked !== query(v.filter, { limit: v.limit })) return;
    v.rows = rows;
    drawRows(v);
  } catch (error) {
    if (view !== v) return;
    fill(v.listEl, callout({ tone: "watch", title: error.message, detail: error.detail,
      actions: [button("Try again", { compact: true, onclick: () => loadRows(v) })] }));
  }
}

function row(r) {
  const out = r.amount.minor < 0, dim = r.isHidden || (r.categorization && r.categorization.categoryID === "transfer");
  return h("div", { class: `row${dim ? " dim" : ""}` },
    h("div", { class: "grow" },
      h("div", { class: "title" }, r.merchant),
      h("div", { class: "sub" }, [dateShort(r.postedAt), accountName(r.accountID), r.isPending ? "pending" : null, r.isHidden ? "hidden" : null].filter(Boolean).join(" · ")),
      r.tags && r.tags.length ? h("div", { class: "tags" }, r.tags.map((t) => tag(t, "info"))) : null,
      r.note ? h("div", { class: "sub note" }, r.note) : null),
    r.categorization ? categoryTag(r.categorization.categoryID) : h("span", { class: "cat" }, "Uncategorized"),
    h("span", { class: `t-amount-row amount num${out ? "" : " inflow"}` }, money(r.amount, { sign: !out })));
}

function drawRows(v) {
  const rows = v.rows, f = v.filter;
  const narrowed = f.q.trim() || f.period || f.category || f.tag;
  if (!rows.length) {
    fill(v.listEl, emptyState({ title: narrowed ? "Nothing matches" : "No transactions yet",
      body: narrowed ? "Try another search, or fewer filters." : "Link a bank or import a statement, and they'll show up here.",
      actions: narrowed ? [button("Clear filters", { compact: true, onclick: () => { Object.assign(f, { q: "", period: "", category: "", tag: "" }); draw(v); reload(v); } })] : [] }));
    return;
  }
  const more = rows.length === v.limit;
  fill(v.listEl,
    h("div", { class: "rows" }, rows.map(row)),
    h("div", { class: "card-foot" },
      more ? button(`Show ${PAGE} more`, { compact: true, onclick: () => { v.limit += PAGE; loadRows(v); } }) : null,
      h("span", { class: "t-caption faint" }, more ? `The newest ${count(rows.length)}` : plural(rows.length, "transaction"))));
}

/// After any change to the filter: the hash, the download link, the rows, and the tag chips and card.
function reload(v) {
  v.limit = PAGE;
  v.rows = null;
  remember(v.filter);
  v.download.setAttribute("href", `/v1/transactions/export.csv?${query(v.filter)}`);
  loadRows(v);
  loadTags(v);
  loadTagCard(v);
}

export default {
  title: "Transactions",
  mount(root, { params }) {
    view = { root, filter: filterFromParams(params), limit: PAGE, rows: null, tags: [] };
    draw(view);
    reload(view);
  },
  navigate({ params }) {
    // The hash this view writes for itself lands here too; only a different filter redraws.
    const next = filterFromParams(params), f = view.filter;
    if (["q", "period", "category", "tag"].every((k) => next[k] === f[k])) return;
    view.filter = next;
    draw(view);
    reload(view);
  },
  refresh() { if (view) { loadRows(view); loadTags(view); loadTagCard(view); } },
  unmount() { view = null; },
};
