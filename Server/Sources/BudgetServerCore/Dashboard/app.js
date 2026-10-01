// The shell: boots the data, routes #/overview · #/accounts · #/imports · #/review · #/categories · #/settings, keeps the rail
// current, and refreshes lightly every 30 s without ever redrawing something the person is working in.
import { fill, $, h, store, loadCore, heavy, cached, callout, button, busy, dot, tag, ago, duration, nextSyncIn, institutionGroups, plural, ApiError } from "./core.js";
import { attentionItems } from "./overview.js";
import { linkPlaid } from "./providers.js";
import overview from "./overview.js";
import accounts from "./accounts.js";
import imports from "./imports.js";
import review from "./review.js";
import categories from "./categories.js";
import settings from "./settings.js";
import { needsLook } from "./rules.js";

const VIEWS = { overview, accounts, imports, review, categories, settings };
let current = null, currentName = null, booted = false, firstRoute = true;

function parseHash() {
  const raw = location.hash.replace(/^#\/?/, "");
  const [path, query] = raw.split("?");
  const [name, sub] = (path || "").split("/");
  return { name: VIEWS[name] ? name : "overview", sub: sub || "", params: new URLSearchParams(query || "") };
}

/// The hash the current view was opened on, to go back to when leaving it is cancelled.
let currentHash = "";

/// Unsaved changes on the view (Settings' save bar): leaving asks first.
const unsaved = () => (current && current.dirty ? current.dirty() : 0);

function route() {
  if (!booted) return;
  const { name, sub, params } = parseHash();
  if (current && currentName === name && current.navigate) { current.navigate({ sub, params }); currentHash = location.hash; renderShell(); return; }
  const n = unsaved();
  if (n && !window.confirm(`Leave ${current.title}? ${n === 1 ? "1 unsaved change is" : `${n} unsaved changes are`} lost if you do.`)) {
    history.replaceState(null, "", currentHash || "#/overview");
    return;
  }
  currentHash = location.hash;
  if (current && current.unmount) current.unmount();
  current = VIEWS[name]; currentName = name;
  const root = $("view");
  const body = h("div", { class: "view-body" });
  fill(root, h("div", { class: "flash", id: "flash" }), body);
  document.title = `${current.title} · Budget`;
  current.mount(body, { sub, params });
  renderShell();
  if (!firstRoute) {
    window.scrollTo(0, 0);
    const title = root.querySelector(".page-title");
    if (title) title.focus({ preventScroll: true });
  }
  firstRoute = false;
}

// MARK: Rail

function setCount(id, value, tone) {
  const el = $(id);
  el.textContent = value ? String(value) : "";
  el.className = "count" + (tone ? " " + tone : "");
  const label = el.parentElement.firstChild.textContent;
  el.parentElement.setAttribute("aria-label", value ? `${label}, ${value} ${tone === "act" ? "need you" : "to look at"}` : label);
}

function renderShell() {
  for (const a of $("nav").querySelectorAll("a")) {
    const on = a.dataset.view === currentName;
    if (on) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current");
    if (on && window.matchMedia("(max-width: 1023px)").matches) a.scrollIntoView({ block: "nearest", inline: "nearest" });
  }
  if (!store.summary) return;
  const problems = institutionGroups().filter((g) => g.state.tone === "act").length;
  setCount("count-accounts", problems, "act");
  const dupes = cached("dupes"), pairs = dupes ? dupes.pairs.length : 0;
  // Decisions, as the phone's badge counts them (one answer files a group); duplicates are their own number.
  const o = store.overview, waiting = (o.reviewDecisions ?? o.reviewCount) || 0;
  setCount("count-review", waiting, "");
  setCount("count-review-dupes", pairs, "watch");
  $("count-review").parentElement.setAttribute("aria-label", ["Review", waiting ? `${plural(waiting, "decision")} waiting` : null,
    pairs ? `${plural(pairs, "transaction")} in the ledger twice` : null].filter(Boolean).join(", "));
  // Rules whose category is gone or that disagree with another: worth a look, on the page that has them.
  const rules = cached("rules"), look = rules ? rules.filter(needsLook).length : 0;
  setCount("count-categories", look, "watch");
  if (look) $("count-categories").parentElement.setAttribute("aria-label", `Categories & rules, ${plural(look, "rule")} to look at`);
  setCount("count-settings", store.summary.settings.inMemory ? 1 : 0, "act");

  const s = store.summary, offline = store.lastError;
  const hasLinks = s.links.length > 0;
  const lastSync = s.links.map((l) => l.lastSync).filter(Boolean).sort().pop();
  const foot = [
    h("span", { class: `t-eyebrow status-eyebrow${offline ? " act" : ""}` }, dot(offline ? "act" : "ok"), offline ? (offline.network ? "Can't reach the server" : "Server problem") : "Server running"),
    offline ? h("span", { class: "t-caption faint" }, `Showing what loaded ${ago(store.loadedAt)}.`) : null,
    offline ? button("Try again", { kind: "quiet", onclick: () => refresh() }) : null,
    h("span", { class: `t-caption ${s.settings.inMemory ? "act-text" : "faint"}` }, s.settings.inMemory ? "In memory: not kept after a restart" : "Saved in the database"),
    hasLinks ? h("span", { class: "t-caption faint" }, `Synced ${ago(lastSync)} · next in about ${duration(nextSyncIn())}`) : null,
    h("span", { class: "t-caption faint" }, `Version ${s.version} · up ${duration((Date.now() - new Date(s.startedAt)) / 1000)}`),
  ];
  fill($("railFoot"), ...foot.filter(Boolean));
  // The compact tag counts what the overview's headline counts: everything that needs you.
  const items = offline ? [] : attentionItems(), needs = items.length;
  fill($("railStatusCompact"), offline ? tag("Offline", "act")
    : needs ? tag(`${needs} need${needs === 1 ? "s" : ""} you`, items.some((i) => i.tone === "act") ? "act" : "watch") : "");
  // Below 1024 px the rail foot is hidden; the offline note and Try again show as a banner instead.
  const banner = $("offlineBanner");
  banner.hidden = !offline;
  if (offline) fill(banner, dot("act"), h("span", { class: "grow" }, offline.network ? "Can't reach the server." : "The server had a problem.",
    ` Showing what loaded ${ago(store.loadedAt)}.`), button("Try again", { compact: true, onclick: () => refresh() }));
}

// MARK: Data

async function refresh({ after = false } = {}) {
  const wasOffline = !!store.lastError;
  let changed;
  try { changed = await loadCore(); }
  catch (error) { store.lastError = error; renderShell(); return; }
  renderShell();
  // Redraw a view only when its data moved (or after a write): an idle redraw would drop keyboard focus.
  if (current && current.refresh && (changed || after || wasOffline)) current.refresh({ after });
  if (after || cached("dupes") === undefined) heavy("dupes", { force: after }).then(renderShell).catch(() => {});
  if (cached("rules") === undefined) heavy("rules").then(renderShell).catch(() => {});
}

/// Every 30 s while the tab is visible and nothing is in flight: summary, overview and status only. The
/// checkup, duplicate sweep and settings reload only after something changes them.
function tick() {
  if (document.visibilityState !== "visible" || store.pending > 0 || !booted) return;
  refresh();
}

function bootError(error) {
  const network = error instanceof ApiError && error.network;
  fill($("view"), h("div", { class: "view-body" },
    h("header", { class: "page-head" }, h("div", { class: "page-head-text" },
      h("span", { class: "t-eyebrow page-eyebrow" }, "Budget dashboard"),
      h("h1", { class: "t-display page-title" }, network ? "Can't reach the server." : "The server couldn't load."))),
    callout({ tone: "act", title: error.message,
      body: network ? "Check that the Budget app is running on your Olares, then try again."
        : "Try again in a moment. If it keeps happening, restart the Budget app on your Olares.",
      detail: error.detail && error.detail !== error.message ? error.detail : null,
      actions: [button("Try again", { kind: "secondary", onclick: (e) => busy(e.currentTarget, "Connecting…", start, { errorTarget: document.createElement("div") }) })] })));
  fill($("railFoot"), h("span", { class: "t-eyebrow status-eyebrow act" }, dot("act"), network ? "Can't reach the server" : "Server problem"));
  fill($("railStatusCompact"), tag("Offline", "act"));
}

async function start() {
  try { await loadCore(); }
  catch (error) { bootError(error); return; }
  const firstBoot = !booted;
  booted = true;
  route();
  if (!firstBoot) return;
  heavy("dupes").then(renderShell).catch(() => {});
  heavy("rules").then(renderShell).catch(() => {});
  // A bank that signs in on its own site returns here with ?oauth_state_id; finish Plaid Link on Accounts.
  if (new URLSearchParams(location.search).has("oauth_state_id")) heavy("providers").then(() => linkPlaid({ resume: true })).catch(() => linkPlaid({ resume: true }));
  setInterval(tick, 30000);
  setInterval(renderShell, 60000);  // "synced 2 hours ago" keeps up without a request
}

if (new URLSearchParams(location.search).has("oauth_state_id") && !location.hash.startsWith("#/accounts")) {
  history.replaceState(null, "", location.pathname + location.search + "#/accounts");
}
window.addEventListener("hashchange", route);
// ⋯ menus close on a click elsewhere or Escape (they're <details>, which only close on their own summary).
document.addEventListener("click", (e) => {
  for (const menu of document.querySelectorAll(".menu[open]")) if (!menu.contains(e.target)) menu.open = false;
});
document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return;
  for (const menu of document.querySelectorAll(".menu[open]")) { menu.open = false; menu.querySelector("summary").focus(); }
});
document.addEventListener("budget:write", () => refresh({ after: true }));
// Closing or reloading the tab with unsaved changes asks too (the browser words it).
window.addEventListener("beforeunload", (e) => { if (unsaved()) { e.preventDefault(); e.returnValue = ""; } });
document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible" && booted && Date.now() - store.loadedAt > 30000) tick(); });
start();
