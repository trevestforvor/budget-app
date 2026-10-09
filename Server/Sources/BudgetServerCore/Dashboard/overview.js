// Overview: what needs you, how fresh each connection is, and a glance at the month. Reading the budget
// itself is the phone's job, so the full checkup and subscriptions live there.
import { fill, h, store, cached, heavy, pageHead, sectionHead, button, busy, callout, details, dot, srOnly, tag, glyph, statusLine,
  institutionGroups, syncProblem, syncNow, describeSync, reportError, toast, bigMoney, money, plural, spell, count, dateShort, ago, skeleton,
  providerName, TIERS, tierName, emptyState } from "./core.js";
import { reconnect, reconnectLabel } from "./accounts.js";
import { flowCard } from "./flow.js";

const TONE_RANK = { act: 0, watch: 1, info: 2 };
const TONE_WORD = { act: "Needs you:", watch: "Worth a look:", info: "For you:" };

/// Everything on the dashboard that wants a person, most urgent first. Sources are the data already loaded;
/// nothing here makes its own request except the duplicate sweep (cached).
export function attentionItems() {
  const s = store.summary, o = store.overview, items = [];
  const hours = s.settings.syncIntervalHours;
  for (const g of institutionGroups()) {
    const st = g.state;
    if (st.tone === "act") {
      items.push({ tone: "act", title: `${g.name} needs you to sign in again`,
        sub: [g.accounts.length ? plural(g.accounts.length, "account") : null, st.lastSync ? `nothing new since ${dateShort(st.lastSync)}` : null].filter(Boolean).join(" · "),
        action: { label: reconnectLabel(st.problem), run: (el) => reconnect(st.problem, el) } });
    } else if (st.tone === "watch" && st.problem) {
      items.push({ tone: "watch", title: `${g.name} didn't sync last time`, sub: syncProblem(st.problem),
        action: { label: "Details", href: `#/accounts?bank=${encodeURIComponent(g.key)}` } });
    } else if (st.tone === "watch" && st.stale) {
      items.push({ tone: "watch", title: `${g.name} hasn't updated since ${dateShort(st.lastSync)}`,
        sub: `It should sync every ${hours === 1 ? "hour" : `${hours} hours`}.`, action: { label: "Sync now", sync: true } });
    }
  }
  const dupes = cached("dupes");
  if (dupes && dupes.pairs.length) {
    const n = dupes.pairs.length;
    items.push({ tone: "watch", title: `${plural(n, "transaction")} ${n === 1 ? "is" : "are"} in the ledger twice`,
      sub: "Once from a statement, once from a sync.", action: { label: "Review", href: "#/review/duplicates" } });
  }
  const week = Date.now() - 7 * 86400 * 1000;
  const warned = s.imports.filter((r) => !r.rolledBack && r.report.warnings && r.report.warnings.length && new Date(r.createdAt) > week);
  if (warned.length) {
    items.push({ tone: "watch", title: warned.length === 1 ? `${warned[0].label} came in with a warning` : `${warned.length} recent imports came in with warnings`,
      sub: warned[0].report.warnings[0], action: { label: "See imports", href: "#/imports" } });
  }
  if (s.settings.inMemory) {
    items.push({ tone: "act", title: "Nothing here survives a restart",
      sub: "The server is keeping your ledger in memory. Give it a database in the Budget app's settings on the Olares so it's kept.",
      action: { label: "Details", href: "#/settings/about" } });
  }
  if (!s.settings.linkingEnabled) {
    items.push({ tone: "watch", title: "Bank linking is off",
      sub: "The server has no key to protect bank sign-ins, so it can't link or sync banks. Add one in the Budget app's settings on the Olares.",
      technical: "Set BUDGET_TOKEN_KEY to the output of: openssl rand -base64 32 — then restart the Budget app." });
  }
  if (o.reviewCount) {
    // The phone's words and count: decisions, each of which may file several transactions.
    items.push({ tone: "info", title: o.reviewHeadline || `${plural(o.reviewCount, "transaction")} ${o.reviewCount === 1 ? "is" : "are"} waiting for a category`,
      sub: "Ones that look alike are grouped, so one answer files a whole group.", action: { label: "File them", href: "#/review/categories" } });
  }
  items.push(...coverageItems());
  return items.sort((a, b) => TONE_RANK[a.tone] - TONE_RANK[b.tone]);
}

/// Statement accounts whose latest month is missing, from the coverage grid: "No Keystone statement for August yet".
/// A month counts once it has been over for a week, which is about when a statement shows up at the bank.
function coverageItems() {
  const coverage = cached("coverage");
  if (!coverage) return [];
  const last = coverage.months[coverage.months.length - 2];
  if (!last || new Date().getDate() <= 7) return [];
  return coverage.accounts.filter((a) => a.source === "fileImport" && a.gaps.includes(last)).map((a) => {
    const older = a.gaps.length - 1;
    return { tone: "watch", title: `No ${a.name} statement for ${monthName(last)} yet`,
      sub: `Download it from ${a.institution}'s website and drop it in Imports.${older ? ` ${plural(older, "earlier month")} ${older === 1 ? "has" : "have"} no transactions either.` : ""}`,
      action: { label: "Import", href: `#/imports?account=${encodeURIComponent(a.id)}` } };
  });
}
const monthName = (key) => new Date(`${key}-15T12:00:00`).toLocaleDateString("en-US", { month: "long" });

function attentionRow(item) {
  let action = null;
  // Each action names what it acts on for screen readers ("Details: Northwind Brokerage didn't sync last time").
  const named = item.action ? `${item.action.label}: ${item.title}` : null;
  if (item.action && item.action.href) action = h("a", { class: "btn secondary compact", href: item.action.href, "aria-label": named }, item.action.label);
  else if (item.action && item.action.run) action = button(item.action.label, { compact: true, "aria-label": named, onclick: (e) => item.action.run(e.currentTarget) });
  else if (item.action && item.action.sync) action = button(item.action.label, { compact: true, "aria-label": named, onclick: (e) => runSync(e.currentTarget) });
  return h("div", { class: "row" }, dot(item.tone),
    h("div", { class: "grow" }, h("div", { class: "title" }, srOnly(TONE_WORD[item.tone] + " "), item.title),
      item.sub ? h("div", { class: "sub wrap" }, item.sub) : null,
      item.technical ? details("Details", item.technical) : null),
    action);
}

async function runSync(buttonEl) {
  await busy(buttonEl, "Syncing…", async () => {
    const outcome = describeSync(await syncNow(), store.summary.links.length > 0);
    if (outcome.ok) toast(outcome.message); else reportError({ message: outcome.message, detail: outcome.detail });
  });
}

function tileStatus(g) {
  const recent = store.syncResults && Date.now() - store.syncResults.at < 120000 ? store.syncResults.byLink : null;
  const result = recent && g.links.map((l) => recent[l.id]).find(Boolean);
  if (result && !result.ok) return statusLine({ tone: "watch", label: "Didn't sync", detail: [] }); // as its attention row says
  if (result) return statusLine({ tone: "ok", label: "Synced just now", detail: [plural(result.report.rowsAdded, "new transaction")] });
  const st = g.state;
  if (st.tone === "ok") return statusLine({ tone: "ok", label: ago(st.lastSync), detail: [plural(g.accounts.length, "account")] });
  if (st.tone === "watch") return statusLine({ tone: "watch", label: st.problem ? "Sync failed, retrying" : ago(st.lastSync), detail: [] });
  if (st.tone === "act") return statusLine({ tone: "act", label: "Needs sign-in", detail: [] });
  return statusLine({ tone: "neutral", label: g.kind === "statements" ? "Statements" : st.label, detail: [plural(g.accounts.length, "account")] });
}

function connectionsCard() {
  const groups = institutionGroups(), links = store.summary.links;
  if (!groups.length) {
    return h("section", { class: "card", "aria-labelledby": "conn-title" }, emptyState({ title: "Nothing connected yet",
      body: "Link a bank to keep accounts current on their own, or import statements you've downloaded.",
      actions: [h("a", { class: "btn secondary compact", href: "#/accounts?connect=1" }, "Connect a bank"), h("a", { class: "btn quiet", href: "#/imports" }, "Import statements")] }));
  }
  const hours = store.summary.settings.syncIntervalHours;
  return h("section", { class: "card", "aria-labelledby": "conn-title" },
    h("div", { class: "tiles" }, groups.map((g) => h("a", { class: "tile", href: `#/accounts?bank=${encodeURIComponent(g.key)}` },
      glyph(g.name), h("div", { class: "grow" }, h("div", { class: "name" }, g.name), tileStatus(g))))),
    h("div", { class: "card-foot" },
      links.length ? button("Sync everything now", { kind: "tinted", compact: true, onclick: (e) => runSync(e.currentTarget) }) : h("a", { class: "btn secondary compact", href: "#/accounts?connect=1" }, "Connect a bank"),
      h("span", { class: "t-caption faint" }, links.length ? `Syncs every ${hours === 1 ? "hour" : `${hours} hours`} on its own.` : "Linked banks stay current on their own.")));
}

function glanceCard() {
  const o = store.overview, change = o.cashChange30Days.minor;
  const month = new Date().toLocaleDateString("en-US", { month: "long" });
  const findings = h("div", { class: "findings" });
  const checkup = cached("checkup");
  if (checkup) renderFindings(findings, checkup);
  else {
    findings.append(skeleton(3));
    heavy("checkup", { maxAge: 10 * 60 * 1000 }).then((c) => renderFindings(findings, c))
      .catch((error) => fill(findings, callout({ tone: "watch", title: "The checkup didn't run.", detail: error.detail || error.message,
        actions: [button("Try again", { compact: true, onclick: () => { fill(findings, skeleton(3)); heavy("checkup", { force: true }).then((c) => renderFindings(findings, c)).catch(() => {}); } })] })));
  }
  return h("section", { class: "card", "aria-labelledby": "glance-title" },
    h("h2", { class: "t-eyebrow card-title", id: "glance-title" }, "This month, at a glance"),
    h("div", { class: "stats" },
      h("div", { class: "stat" }, h("span", { class: "t-eyebrow muted" }, "Cash on hand"), bigMoney(o.cashOnHand),
        h("div", { class: "sub" }, h("span", { class: change > 0 ? "inflow num" : "num" }, money(o.cashChange30Days, { cents: false, sign: true })), " in the last 30 days")),
      h("div", { class: "stat" }, h("span", { class: "t-eyebrow muted" }, "Safe to spend"), bigMoney(o.flex.safeToSpend, { cents: false }),
        h("div", { class: "sub" }, o.flex.daysLeft === 0 ? `Last day of ${month}` : `${plural(o.flex.daysLeft + 1, "day")} left in ${month}`))),
    findings);
}

function renderFindings(el, checkup) {
  const all = checkup.sections.flatMap((s) => s.findings);
  const rank = { act: 0, watch: 1, good: 2 };
  const top = all.filter((f) => f.status !== "good").sort((a, b) => rank[a.status] - rank[b.status]).slice(0, 4);
  const n = (k) => all.filter((f) => f.status === k).length;
  const tone = { act: "act", watch: "watch" };
  fill(el, 
    ...top.map((f) => h("div", { class: "finding" }, dot(tone[f.status]), h("span", {}, srOnly(f.status === "act" ? "Act on: " : "Watch: "), f.title))),
    h("p", { class: "t-caption faint" }, top.length
      ? `From the checkup · ${n("act")} to act on, ${n("watch")} to watch, ${n("good")} fine. The rest is in Checkup on your phone.`
      : "The checkup found nothing to act on this month."));
}

function categoriesCard() {
  const st = store.summary.stats, p = store.status.decisionPolicy;
  const total = Object.values(st.byTier).reduce((a, b) => a + b, 0);
  const tiers = TIERS.filter(([k]) => st.byTier[k]);
  return h("section", { class: "card", "aria-labelledby": "cat-title" },
    h("h2", { class: "t-eyebrow card-title", id: "cat-title" }, "How transactions got their category"),
    total ? [
      h("div", { class: "bar", role: "img", "aria-label": tiers.map(([k, label]) => `${tierName(k, label)} ${count(st.byTier[k])}`).join(", ") },
        tiers.map(([k, , c]) => h("span", { class: `tone-${c}`, css: { "--w": `${(100 * st.byTier[k]) / total}%` } }))),
      h("div", { class: "legend" }, tiers.map(([k, label, c]) => h("div", {}, h("span", { class: `sw tone-${c}` }), tierName(k, label), h("b", {}, count(st.byTier[k]))))),
    ] : h("p", { class: "empty-line" }, "No transactions yet."),
    h("dl", { class: "kv" },
      h("dt", {}, "Decision model"), h("dd", {}, p.provider === "off" ? tag("Off") : tag(providerName(p.provider), "info")),
      p.provider !== "off" ? [h("dt", {}, "Files on its own at"), h("dd", {}, `${p.autoAcceptPercent}% sure or more${p.escalateToJev ? " · asks Jev when unsure" : ""}`)] : null),
    h("div", { class: "card-foot" }, h("a", { class: "btn quiet", href: "#/settings" }, "Change in Settings")));
}

export default {
  title: "Overview",
  mount(root) { this.root = root; this.render(); },
  refresh() { if (this.root) this.render(); },
  render() {
    // Statement gaps join the list once coverage has loaded; it's kept until something changes the ledger.
    const root = this.root;
    if (cached("coverage") === undefined) heavy("coverage").then(() => { if (this.root === root && root.isConnected) this.render(); }).catch(() => {});
    const items = attentionItems();
    const today = new Date().toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric" });
    const n = items.length;
    fill(this.root, 
      pageHead({ eyebrow: today, bloom: "data", title: n ? `${spell(n)} thing${n === 1 ? " needs" : "s need"} you.` : "Everything's up to date.",
        sub: n ? "The budget itself lives on your phone." : "Syncs, imports and categories are current. The budget itself lives on your phone." }),
      h("section", { class: "card attention", "aria-labelledby": "att-title" },
        h("h2", { class: "t-eyebrow card-title", id: "att-title" }, "Needs attention"),
        n ? h("div", { class: "rows" }, items.map(attentionRow)) : h("p", { class: "empty-line" }, "You're all caught up.")),
      sectionHead("Connections", h("a", { class: "btn quiet", href: "#/accounts" }, "All accounts"), "conn-title"),
      connectionsCard(),
      h("div", { class: "grid-2" }, glanceCard(), categoriesCard()),
      flowCard());
  },
};
