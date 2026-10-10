// Shared by every view: the one request helper, element building, formatting, feedback, and the data store.
// No framework and no build step; views import what they need.

// MARK: Elements

export const $ = (id) => document.getElementById(id);

/// h("div", {class: "row", onclick: fn, css: {"--w": "40%"}}, child, "text", [more]) → element.
/// Never writes a style attribute (the page's CSP-minded rule): `css` goes through the CSSOM.
export function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  const late = {};
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === "class") el.className = v;
    else if (k === "css") for (const [prop, value] of Object.entries(v)) el.style.setProperty(prop, value);
    else if (k === "dataset") Object.assign(el.dataset, v);
    else if (k.startsWith("on") && typeof v === "function") el.addEventListener(k.slice(2), v);
    else if (k === "value" || k === "checked" || k === "selected" || k === "open") late[k] = v;
    else el.setAttribute(k, v === true ? "" : String(v));
  }
  append(el, kids);
  for (const [k, v] of Object.entries(late)) el[k] = v;
  return el;
}
/// Replaces an element's children. Unlike replaceChildren, skips null, false and "" (which it would print
/// as "null": the old dashboard's "nullnull") and flattens arrays.
export function fill(el, ...kids) {
  el.replaceChildren();
  return append(el, kids);
}
export function append(el, kids) {
  for (const kid of kids.flat(Infinity)) {
    if (kid == null || kid === false || kid === "") continue;
    el.append(kid.nodeType ? kid : String(kid));
  }
  return el;
}
export const text = (tag, cls, value) => h(tag, { class: cls }, value);

// MARK: Formatting

const NUMBER = new Intl.NumberFormat("en-US");
export const count = (n) => NUMBER.format(n || 0);
/// "1 account", "3 accounts"; `many` for irregular plurals.
export const plural = (n, one, many) => `${count(n)} ${n === 1 ? one : (many || one + "s")}`;
const WORDS = ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"];
export const spell = (n) => (n < WORDS.length ? WORDS[n] : count(n));

/// Money with a real minus sign (U+2212), never a hyphen. `sign` adds "+" to positive amounts.
export function money(m, { cents = true, sign = false } = {}) {
  const minor = (m && m.minor) || 0;
  const s = new Intl.NumberFormat("en-US", { style: "currency", currency: (m && m.currency) || "USD",
    minimumFractionDigits: cents ? 2 : 0, maximumFractionDigits: cents ? 2 : 0 }).format(Math.abs(minor) / 100);
  return (minor < 0 ? "\u2212" : sign && minor > 0 ? "+" : "") + s;
}
/// A headline amount: dollars in the serif, cents small and quiet (DSAmountText).
export function bigMoney(m, { cls = "t-amount", cents = true } = {}) {
  const s = money(m, { cents }), i = s.lastIndexOf(".");
  return h("span", { class: cls + " num" }, i < 0 ? s : [s.slice(0, i), h("span", { class: "cents" }, s.slice(i))]);
}
export const rowMoney = (m) => h("span", { class: "t-amount-row amount num" }, money(m));

const toDate = (d) => (d instanceof Date ? d : new Date(d));
export const dateShort = (d) => (d ? toDate(d).toLocaleDateString("en-US", { month: "short", day: "numeric" }) : "");
export const dateFull = (d) => (d ? toDate(d).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" }) : "");
export const monthYear = (d) => (d ? toDate(d).toLocaleDateString("en-US", { month: "short", year: "numeric" }) : "");
export const dateTime = (d) => (d ? toDate(d).toLocaleString("en-US", { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : "");
/// "just now", "12 minutes ago", "2 hours ago", "yesterday", "3 days ago", then a date.
export function ago(d) {
  if (!d) return "never";
  const s = Math.max(0, (Date.now() - toDate(d)) / 1000);
  if (s < 90) return "just now";
  if (s < 3600) return `${Math.round(s / 60)} minutes ago`;
  if (s < 5400) return "an hour ago";
  if (s < 86400) return `${Math.round(s / 3600)} hours ago`;
  if (s < 172800) return "yesterday";
  if (s < 14 * 86400) return `${Math.round(s / 86400)} days ago`;
  return "on " + dateShort(d);
}
/// "about 4 hours", for a duration in seconds.
export function duration(seconds) {
  const s = Math.max(0, seconds);
  if (s < 90) return "a minute";
  if (s < 3600) return `${Math.round(s / 60)} minutes`;
  if (s < 5400) return "an hour";
  if (s < 172800) return `${Math.round(s / 3600)} hours`;
  return `${Math.round(s / 86400)} days`;
}
/// "Mar 2025 – May 2026" for an import's rows.
export function span(from, through) {
  if (!from) return "";
  const a = toDate(from), b = toDate(through || from);
  if (monthYear(a) === monthYear(b)) return monthYear(a);
  if (a.getFullYear() === b.getFullYear()) return `${a.toLocaleDateString("en-US", { month: "short" })} – ${monthYear(b)}`;
  return `${monthYear(a)} – ${monthYear(b)}`;
}

// MARK: Plain names

export const KIND = { checking: "Checking", savings: "Savings", credit: "Credit card", investment: "Investment" };
export const SOURCE = { plaid: "Plaid", teller: "Teller", simplefin: "SimpleFIN", fileImport: "Statements", demo: "Demo data" };
/// How a row got its category: the order and chart colors (series, not status). The names come from the server
/// (`tierNames`, the phone's `CategorizationTier.displayName`), so both say the same thing; these are fallbacks.
export const TIERS = [
  ["user", "You", "cyan"], ["rule", "Your rule", "azure"], ["transferMatch", "Matched transfer", "teal"], ["statement", "Your statement", "lime"],
  ["merchantMemory", "Merchant memory", "lilac"], ["decisionModel", "The model", "iris"], ["model", "Model fallback", "violet"],
  ["embedding", "Local classifier", "amber"], ["none", "Waiting for you", "steel"],
];
/// A tier's name as the phone shows it on a row's "Filed by".
export function tierName(id, fallback) {
  const names = (store.summary && store.summary.tierNames) || {};
  return names[id] || fallback || id;
}
export const ROLE = { chat: "Ask (chat)", categorize: "Categorizing", plan: "Planning", vision: "Receipts (vision)" };
/// The phone's name for a decision provider (the server sends them), falling back to the id.
export function providerName(id) {
  const names = (store.summary && store.summary.providerNames) || {};
  return names[id] || id;
}

// MARK: Requests

export class ApiError extends Error {
  constructor(message, { status = 0, network = false, detail = "" } = {}) {
    super(message);
    this.status = status; this.network = network; this.detail = detail;
  }
}

/// Every request the dashboard makes goes through here. It always sends `X-Budget-Dashboard: 1`, which the
/// server requires on dashboard writes (a cross-site page can't send it without a preflight the server never
/// approves), and it only talks to this origin. GETs time out after 15 s; writes wait as long as they take
/// (a year of statements with model calls can take a minute).
export async function api(path, { method = "GET", body, timeout } = {}) {
  const headers = { "Accept": "application/json", "X-Budget-Dashboard": "1" };
  if (body !== undefined) headers["Content-Type"] = "application/json";
  const limit = timeout ?? (method === "GET" ? 15000 : 0);
  const controller = new AbortController();
  const timer = limit ? setTimeout(() => controller.abort(), limit) : null;
  let response;
  try {
    response = await fetch(path, { method, headers, credentials: "same-origin", signal: controller.signal,
      body: body === undefined ? undefined : JSON.stringify(body) });
  } catch (error) {
    throw new ApiError(controller.signal.aborted ? "The server took too long to answer." : "Can't reach the server.",
      { network: true, detail: String((error && error.message) || error) });
  } finally { if (timer) clearTimeout(timer); }
  if (response.status === 204 || response.status === 304) return null;
  const raw = await response.text();
  let data = null;
  try { data = raw ? JSON.parse(raw) : null; } catch { data = raw; }
  if (!response.ok) {
    const message = (data && typeof data === "object" && data.error) || (typeof data === "string" && data) || "";
    throw new ApiError(plainMessage(message, response.status), { status: response.status, detail: message || `HTTP ${response.status}` });
  }
  return data;
}

/// The server's own sentence when it reads like one; otherwise a plain line (the raw text goes under Details).
function plainMessage(message, status) {
  const m = (message || "").trim();
  // A provider's own refusal ("Plaid: invalid client_id") is worth reading; other 5xx text is a proxy's or a stack's.
  const provider = /^(Plaid|Teller|SimpleFIN):/.test(m);
  const technical = !m || m.length > 180 || /[{}\[\]]|Error\(|HTTP \d|^\w+\.\w+/.test(m) || (status >= 500 && !provider);
  if (!technical) return m;
  if (status === 502) return "A service the server relies on didn't answer.";
  if (status === 403) return "The server turned that down.";
  if (status === 404) return "That isn't there anymore.";
  if (status >= 500) return "The server ran into a problem.";
  return "The server couldn't do that.";
}

// MARK: Feedback

let toastTimer, toastAction = null, toastLeft = 0, toastStarted = 0, toastHeld = false;
/// Confirmations only ("Saved", "Removed 412 rows"). Failures stay on screen as a callout (see `flash`).
/// With `action` ({label, run}) the toast carries one button, for 5 s: the Undo after filing a group. The time stops
/// while the pointer is on the toast or its button has focus, so reaching Undo by keyboard or switch never loses it,
/// and a drawer opened over it carries it along (`toastIntoDialog`), so Undo is never under the backdrop.
export function toast(message, { action } = {}) {
  const el = toastElement();
  toastAction = action || null;
  fill(el, h("span", { class: "toast-text" }, message),
    action ? h("button", { type: "button", class: "toast-action", onclick: () => runToastAction() }, action.label) : null);
  el.classList.toggle("has-action", !!action);
  el.classList.add("show");
  const open = document.querySelector("dialog[open]");
  if (open) open.append(el);
  toastHeld = false;
  startToastTimer(action ? 5000 : 3200);
}
function startToastTimer(ms) {
  clearTimeout(toastTimer);
  toastLeft = ms; toastStarted = Date.now();
  if (!toastHeld) toastTimer = setTimeout(hideToast, ms);
}
function holdToast(held) {
  const el = $("toast");
  if (!el || !el.classList.contains("show") || toastHeld === held) return;
  toastHeld = held;
  if (held) { clearTimeout(toastTimer); toastLeft = Math.max(toastLeft - (Date.now() - toastStarted), 1500); }
  else startToastTimer(Math.max(toastLeft, 1500));
}
function toastElement() {
  const el = $("toast");
  if (!el.dataset.wired) {
    el.dataset.wired = "1";
    el.addEventListener("mouseenter", () => holdToast(true));
    el.addEventListener("mouseleave", () => holdToast(false));
    el.addEventListener("focusin", () => holdToast(true));
    el.addEventListener("focusout", () => holdToast(false));
  }
  return el;
}
/// A drawer opening over a showing toast takes it along into the top layer; closing puts it back.
export function toastIntoDialog(dialog) {
  const el = $("toast");
  if (el && el.classList.contains("show")) dialog.append(el);
}
function toastBackToBody() {
  const el = $("toast");
  if (el && el.parentElement !== document.body) document.body.append(el);
}
function hideToast() { toastHeld = false; $("toast").classList.remove("show", "has-action"); toastAction = null; toastBackToBody(); }
/// Runs the toast's action once (its button, or a keyboard shortcut); false when there's none showing.
export function runToastAction() {
  const action = toastAction;
  if (!action) return false;
  clearTimeout(toastTimer);
  hideToast();
  action.run();
  return true;
}

/// A callout that stays until dismissed: `tone` act (orchid) / watch (amber) / info (iris) / ok (cyan).
export function callout({ tone = "act", title, body, detail, actions, role, dismiss }) {
  const box = h("div", { class: `callout ${tone}`, role: role || (tone === "act" ? "alert" : "status") },
    h("span", { class: `dot ${tone}`, "aria-hidden": "true" }),
    h("div", { class: "grow" },
      title ? h("strong", { class: "t-body-em callout-title" }, title) : null,
      body ? h("p", {}, body) : null,
      detail ? details("Details", detail) : null,
      actions && actions.length ? h("div", { class: "actions" }, actions) : null),
    dismiss ? h("button", { class: "icon-btn", type: "button", "aria-label": "Dismiss", onclick: () => box.remove() }, "×") : null);
  return box;
}
/// A Details disclosure for technical text (a provider's message, a raw error), in mono.
export function details(summary, content) {
  return h("details", { class: "disclosure" }, h("summary", {}, summary),
    typeof content === "string" ? h("code", { class: "code" }, content) : content);
}

/// Shows an error where the person is looking: the view's flash area (or `where`), never a vanishing toast.
export function reportError(error, where) {
  const target = where || $("flash");
  if (!target) return;
  const err = error instanceof ApiError ? error : new ApiError(String((error && error.message) || error), {});
  fill(target, callout({ tone: "act", title: err.message, detail: err.detail && err.detail !== err.message ? err.detail : null, dismiss: true }));
  if (!where) target.scrollIntoView({ block: "nearest", behavior: "smooth" });
}

/// Runs `fn` with the button showing it's working: spinner, disabled, at least 400 ms so a fast answer still
/// reads as having happened. The label comes back afterwards; results show in the page, not on the button.
export async function busy(button, working, fn, { errorTarget } = {}) {
  const label = button.dataset.idle || button.textContent;
  button.dataset.idle = label;
  button.disabled = true; button.classList.add("busy"); button.setAttribute("aria-busy", "true");
  button.textContent = working;
  const started = Date.now();
  let ok = true;
  store.pending++;
  try { await fn(); } catch (error) { ok = false; reportError(error, errorTarget); }
  finally { store.pending--; }
  const wait = 400 - (Date.now() - started);
  if (wait > 0) await new Promise((r) => setTimeout(r, wait));
  button.classList.remove("busy"); button.removeAttribute("aria-busy");
  button.disabled = false; button.textContent = label;
  return ok;
}

/// Destructive buttons ask twice in the page itself: the browser's confirm() is blocked inside the Olares
/// desktop window, which made it silently answer "no". The second click within 5 s runs `action`.
export function armed(button, prompt, action) {
  if (button.dataset.armed === "1") {
    disarm(button);
    action();
    return;
  }
  button.dataset.label = button.textContent;
  button.dataset.armed = "1";
  button.classList.add("armed");
  button.textContent = prompt;
  button._disarm = setTimeout(() => disarm(button), 5000);
}
function disarm(button) {
  clearTimeout(button._disarm);
  if (button.dataset.armed !== "1") return;
  button.dataset.armed = "";
  button.classList.remove("armed");
  button.textContent = button.dataset.label;
}
export const isArmed = (root) => !!root.querySelector("[data-armed='1']");

// MARK: Building blocks (each mirrors a DesignSystem view)

export const dot = (tone) => h("span", { class: `dot ${tone || ""}`, "aria-hidden": "true" });
/// DSTag: 6 px radius, its tone's 12% wash, mono uppercase.
export const tag = (label, tone) => h("span", { class: `tag ${tone || ""}` }, label);
export const srOnly = (t) => h("span", { class: "sr-only" }, t);
/// For a field that holds a key or a token: no spelling help, and password managers keep out of it (one filled in the
/// Olares login's password once). An API key field adds `autocomplete: "new-password"`, which stops browsers offering a
/// saved password there.
export const secretAttrs = { autocomplete: "off", spellcheck: "false", "data-1p-ignore": "", "data-lpignore": "true", "data-bwignore": "" };
export function button(label, { kind = "secondary", compact = false, onclick, disabled, type = "button", ...rest } = {}) {
  return h("button", { class: `btn ${kind}${compact ? " compact" : ""}`, type, onclick, disabled, ...rest }, label);
}
/// DSSectionHeader: a serif headline and one quiet trailing action.
export function sectionHead(title, action, id) {
  return h("div", { class: "section-head" }, h("h2", { class: "t-headline", id }, title), action || null);
}
/// The page's title block: eyebrow, display serif, one line under it, and at most one primary action.
/// `bloom` ("data" or "ai") lights the top of the screen in that colour (G5); one screen, one bloom.
export function pageHead({ eyebrow, title, sub, action, bloom }) {
  return h("header", { class: bloom ? `page-head bloom-${bloom}` : "page-head" },
    h("div", { class: "page-head-text" },
      eyebrow ? h("span", { class: "t-eyebrow page-eyebrow" }, eyebrow) : null,
      h("h1", { class: "t-display page-title", tabindex: "-1" }, title),
      sub ? h("p", { class: "t-callout page-sub" }, sub) : null),
    action || null);
}
export function emptyState({ title, body, actions }) {
  return h("div", { class: "empty-state" }, h("h3", { class: "t-headline" }, title), body ? h("p", { class: "t-callout muted" }, body) : null,
    actions && actions.length ? h("div", { class: "actions" }, actions) : null);
}
/// Placeholder lines while something loads.
export const skeleton = (lines = 3) => h("div", { class: "skeleton", "aria-hidden": "true" }, Array.from({ length: lines }, () => h("span")));
/// A card region that loads on its own: skeleton, then content, or an error with Try again.
export async function loadInto(region, load, render) {
  fill(region, skeleton(3));
  try { fill(region, ...[].concat(render(await load()))); }
  catch (error) {
    fill(region, callout({ tone: "watch", title: error.message || "Couldn't load this.", detail: error.detail || null,
      actions: [button("Try again", { compact: true, onclick: () => loadInto(region, load, render) })] }));
  }
}

let drawerEl = null;
/// The side drawer (a modal <dialog>, one at a time): Connect a bank, a rule. Returns the body to fill and a
/// `foot` for the drawer's buttons, which stays in view at the bottom.
export function drawer(title, { onClose } = {}) {
  if (!drawerEl) {
    drawerEl = h("dialog", { class: "drawer", "aria-labelledby": "drawer-title" });
    drawerEl.addEventListener("click", (e) => { if (e.target === drawerEl) drawerEl.close(); });
    drawerEl.addEventListener("close", () => { toastBackToBody(); const done = drawerEl.onDone; drawerEl.onDone = null; if (done) done(); });
    document.body.append(drawerEl);
  }
  // A drawer opened over another replaces it in place: the one before is done now, and no close event follows.
  const before = drawerEl.open ? drawerEl.onDone : null;
  drawerEl.onDone = onClose || null;
  if (before) before();
  const body = h("div", { class: "drawer-body" }), foot = h("div", { class: "drawer-foot" });
  fill(drawerEl, h("div", { class: "drawer-head" }, h("h2", { class: "t-headline grow", id: "drawer-title" }, title),
    h("button", { class: "icon-btn", type: "button", "aria-label": "Close", onclick: () => drawerEl.close() }, "×")), body, foot);
  if (!drawerEl.open) drawerEl.showModal();
  toastIntoDialog(drawerEl);
  return { el: drawerEl, body, foot, close: closeDrawer };
}
export function closeDrawer() { if (drawerEl && drawerEl.open) drawerEl.close(); }

/// Every DSTone, in its order (Palette.swift), so the dashboard draws from the same twelve as the phone.
const GLYPH_TONES = ["iris", "lilac", "orchid", "azure", "cyan", "irisDeep", "amber", "coral", "rose", "teal", "lime", "violet"];
/// DSGlyph for an institution: initials on a tone wash, the tone fixed by the name so it never changes.
export function glyph(name) {
  const words = (name || "?").replace(/[^A-Za-z0-9 ]/g, " ").split(/\s+/).filter(Boolean);
  const initials = (words.length > 1 ? words[0][0] + words[1][0] : (words[0] || "?").slice(0, 2)).toUpperCase();
  let hash = 0;
  for (const c of (name || "").toLowerCase()) hash = (hash * 31 + c.charCodeAt(0)) >>> 0;
  return h("span", { class: `glyph tone-${GLYPH_TONES[hash % GLYPH_TONES.length]}`, "aria-hidden": "true" }, initials);
}

// MARK: Data

/// What the server said last. Views read from here; `refresh` (app.js) keeps the light parts current.
export const store = {
  summary: null, overview: null, status: null,
  loadedAt: 0, lastError: null, pending: 0,
  heavy: {},          // name → { at, value, promise } for the slower reads below
  syncResults: null,  // the last "Sync everything" outcome, per link, for the tiles
};

const stableJSON = (value) => JSON.stringify(value, (_, v) =>
  (v && typeof v === "object" && !Array.isArray(v) ? Object.fromEntries(Object.keys(v).sort().map((k) => [k, v[k]])) : v));

/// Summary, overview and status: cheap, and everything on screen hangs off them. Resolves to whether
/// anything in them changed since the last load.
export async function loadCore() {
  const t = { timeout: 10000 };
  const [summary, overview, status] = await Promise.all([api("/dash/summary", t), api("/v1/overview", t), api("/v1/status", t)]);
  // What changed, ignoring the clocks the server stamps on every answer. Keys are sorted because the
  // server's JSON encoder doesn't keep them in one order.
  const key = stableJSON([{ ...summary, now: 0 }, { ...overview, asOf: 0 }, { ...status, lastSync: 0 }]);
  const changed = key !== store.dataKey;
  Object.assign(store, { summary, overview, status, loadedAt: Date.now(), lastError: null, dataKey: key });
  return changed;
}

/// Slower or optional reads, loaded when a view needs them and kept until something changes the ledger.
const HEAVY = {
  checkup: () => api("/v1/checkup", { timeout: 30000 }),
  dupes: () => api("/v1/imports/duplicates", { method: "POST", body: { apply: false } }),
  providers: () => api("/dash/providers"),
  fields: () => api("/dash/settings"),
  models: () => api("/dash/models"),
  history: () => api("/v1/imports"),
  coverage: () => api("/dash/coverage"),
  groups: () => api("/dash/review/groups"),
  rules: () => api("/v1/rules"),
};
export function heavy(name, { maxAge = Infinity, force = false } = {}) {
  const entry = store.heavy[name];
  if (!force && entry && entry.value !== undefined && Date.now() - entry.at < maxAge) return Promise.resolve(entry.value);
  if (!force && entry && entry.promise) return entry.promise;
  const promise = HEAVY[name]().then((value) => { store.heavy[name] = { at: Date.now(), value }; return value; },
    (error) => { store.heavy[name] = undefined; throw error; });
  store.heavy[name] = { ...(entry || {}), promise };
  return promise;
}
export const cached = (name) => (store.heavy[name] ? store.heavy[name].value : undefined);
export function forget(...names) { for (const n of names) store.heavy[n] = undefined; }

/// After anything that changes the ledger or its links: drop what it affects and redraw from fresh data.
export async function afterWrite(...also) {
  forget("checkup", "dupes", "history", "coverage", "groups", "rules", ...also);
  document.dispatchEvent(new CustomEvent("budget:write"));
}

/// Categories come with the summary, each with the color it wears (`color`, a design-system tone name).
export const category = (id) => ((store.summary && store.summary.categories) || []).find((c) => c.id === id);
export const categoryName = (id) => (category(id) || {}).name || id;
/// Counts as money coming in, like income (a server before kinds only had Income).
export const isMoneyIn = (c) => c.kind === "moneyIn" || (!c.kind && c.id === "income");
/// Categories something can be filed under now: not merged away, and never a money-in category (Income, card rewards)
/// for money going out.
export const fileable = ({ direction } = {}) => ((store.summary && store.summary.categories) || [])
  .filter((c) => !c.isArchived && !(direction === "out" && isMoneyIn(c)));
/// A category select's options, grouped as the phone's picker groups them: Spending, Money in, Not spending (Transfer).
export const categoryOptions = (list) => [
  ["Spending", list.filter((c) => c.countsAsSpending)],
  ["Money in", list.filter(isMoneyIn)],
  ["Not spending", list.filter((c) => !c.countsAsSpending && !isMoneyIn(c))],
].filter(([, group]) => group.length)
  .map(([label, group]) => h("optgroup", { label }, group.map((c) => h("option", { value: c.id }, c.name))));
/// A category's color swatch: its tone as a class (tone-teal, tone-irisDeep…), never a style attribute.
export const swatch = (id) => h("span", { class: `sw tone-${(category(id) || {}).color || "amber"}`, "aria-hidden": "true" });
/// DSTag-like label for a category: its swatch and name.
export const categoryTag = (id) => h("span", { class: "cat" }, swatch(id), categoryName(id));
export const accountName = (id) => {
  const a = ((store.overview && store.overview.accounts) || []).find((x) => x.id === id);
  return a ? a.name + (a.mask ? ` ••${a.mask}` : "") : "";
};

// MARK: New categories (Categories & rules, and a rule's "New category…")

/// The phone's budget types, in its order, with its one line on what each does to safe to spend.
export const BUDGET_TYPES = [
  ["bills", "Bills", "What you owe each month: rent, utilities, insurance. A usual month is set aside before safe to spend."],
  ["subscriptions", "Subscriptions", "What you pay for on a schedule and choose to keep: streaming, apps, memberships. Set aside like bills."],
  ["everyday", "Everyday", "Comes out of safe to spend as you go: groceries, dining, shopping, trips."],
];
const MONEY_IN_LINE = "Counts as money coming in, like income: never spending, never budgeted.";
let newCategoryForms = 0;

/// The fields for a new category, the same wherever the dashboard makes one: a name, Spending or Money in, and for
/// spending its budget type. The ledger picks the color the others use least and a plain icon; the phone changes them.
/// `read()` gives the createCategory action, or a problem in plain words; `onChange` hears every edit.
export function newCategoryFields({ kind = "spending", name = "" } = {}) {
  const id = `newcat-${++newCategoryForms}`;
  const nameInput = h("input", { class: "input", id: `${id}-name`, value: name, maxlength: "32", placeholder: "Pets, Gifts, Card rewards…",
    autocomplete: "off", spellcheck: "false" });
  const type = h("select", { class: "input", id: `${id}-kind` }, h("option", { value: "spending" }, "Spending"), h("option", { value: "moneyIn" }, "Money in"));
  type.value = kind === "moneyIn" ? "moneyIn" : "spending";
  const group = h("select", { class: "input", id: `${id}-group` }, BUDGET_TYPES.map(([value, label]) => h("option", { value }, label)));
  group.value = "everyday";
  const typeHelp = h("span", { class: "help" }), groupHelp = h("span", { class: "help" });
  const field = (label, input, help) => h("div", { class: "field" }, h("label", { class: "field-head", for: input.id }, label), input, help);
  const groupField = field("Budget type", group, groupHelp);
  const listeners = [];
  const sync = () => {
    const spending = type.value === "spending";
    groupField.hidden = !spending;
    typeHelp.textContent = MONEY_IN_LINE;
    typeHelp.hidden = spending;
    groupHelp.textContent = (BUDGET_TYPES.find(([v]) => v === group.value) || [])[2] || "";
  };
  for (const el of [type, group]) el.addEventListener("change", () => { sync(); listeners.forEach((fn) => fn()); });
  nameInput.addEventListener("input", () => listeners.forEach((fn) => fn()));
  sync();
  const read = () => {
    const n = nameInput.value.trim();
    if (!n) return { problem: "Name the new category." };
    if (n.length > 32) return { problem: "Keep the name to 32 characters." };
    const same = fileable().find((c) => c.name.toLowerCase() === n.toLowerCase());
    if (same) return { problem: `There's already a ${same.name} category.`, existing: same };
    const action = { type: "createCategory", name: n, kind: type.value };
    if (type.value === "spending") action.group = group.value;
    return { action };
  };
  return {
    el: h("div", { class: "form newcat" }, h("div", { class: "field wide" }, h("label", { class: "field-head", for: nameInput.id }, "Name"), nameInput),
      field("Type", type, typeHelp), groupField),
    read, kind: () => type.value,
    setKind: (k) => { type.value = k === "moneyIn" ? "moneyIn" : "spending"; sync(); },
    reset: () => { nameInput.value = ""; type.value = kind === "moneyIn" ? "moneyIn" : "spending"; group.value = "everyday"; sync(); },
    onChange: (fn) => listeners.push(fn), focus: () => nameInput.focus(),
  };
}

/// Makes a category (POST /v1/actions createCategory; no preview, a category files nothing on its own) and returns the
/// ledger's answer with the category, found by name once the categories are reloaded: its id is the ledger's to pick,
/// and a merged-away one of the same name comes back instead of a second.
export async function createCategory(action) {
  const result = await api("/v1/actions", { method: "POST", body: action });
  await loadCore().catch(() => {});
  const category = fileable().find((c) => c.name.toLowerCase() === action.name.toLowerCase()) || null;
  afterWrite();
  return { result, category };
}

// MARK: Institutions (Overview tiles and the Accounts view share this)

const norm = (s) => (s || "").trim().toLowerCase();
/// A link's last error in plain words; the provider's own text goes under Details.
export function syncProblem(link) {
  const e = link.lastError || "";
  if (link.status === "needsReauth" || /ITEM_LOGIN_REQUIRED|enrollment\.disconnected/.test(e)) return "The bank ended this connection and needs you to sign in again.";
  if (/\b40[13]\b/.test(e)) return "The bank turned down the saved sign-in.";
  if (/isn't set up|not set up/i.test(e)) return "This provider's keys aren't set up on the server anymore.";
  if (/TOKEN_KEY|can't open stored/i.test(e)) return "The server can't open its saved bank sign-ins.";
  if (/unreachable|timed? ?out|connect|resolve|network/i.test(e)) return "Couldn't reach the bank's service. It'll try again on its own.";
  if (/RATE_LIMIT|429/.test(e)) return "The provider asked us to slow down. It'll try again on its own.";
  return "The last sync didn't finish. It'll try again on its own.";
}
/// The Plaid/Teller wording of an error, cleaned of Swift's wrapper, for a Details disclosure.
export function providerDetail(link) {
  const e = link.lastError || "";
  const m = e.match(/error_message\\?"\s*:\s*\\?"([^"\\]+)/), c = e.match(/error_code\\?"\s*:\s*\\?"([^"\\]+)/);
  const core = m ? `${SOURCE[link.provider] || link.provider}: ${m[1]}${c ? ` (${c[1]})` : ""}` : e;
  return core + (link.lastSync ? ` · last good sync ${dateTime(link.lastSync)}` : "");
}

/// Accounts grouped by institution name (as the app's AccountsView does), each with the links that serve it
/// and one status. Problem banks first, then by name.
export function institutionGroups() {
  const accounts = (store.overview && store.overview.accounts) || [];
  const links = (store.summary && store.summary.links) || [];
  const hours = (store.summary && store.summary.settings.syncIntervalHours) || 6;
  const groups = new Map();
  for (const a of accounts) {
    const k = norm(a.institution) || "other";
    if (!groups.has(k)) groups.set(k, { key: k, name: a.institution || "Other", accounts: [], links: [] });
    groups.get(k).accounts.push(a);
  }
  const loose = [];
  for (const l of links) { const g = groups.get(norm(l.institution)); if (g) g.links.push(l); else loose.push(l); }
  // SimpleFIN Bridge is one link for several banks, whose accounts carry the banks' own names.
  const bridges = loose.filter((l) => l.provider === "simplefin");
  if (bridges.length === 1) {
    const claimed = [...groups.values()].filter((g) => !g.links.length && g.accounts.every((a) => a.source === "simplefin"));
    if (claimed.length) { claimed.forEach((g) => g.links.push(bridges[0])); loose.splice(loose.indexOf(bridges[0]), 1); }
  }
  for (const l of loose) groups.set("link:" + l.id, { key: "link:" + l.id, name: l.institution, accounts: [], links: [l] });

  const RANK = { act: 0, watch: 1, ok: 2, neutral: 3 };
  const list = [...groups.values()].map((g) => {
    const sources = new Set(g.accounts.map((a) => a.source));
    g.kind = g.links.length ? "linked"
      : sources.size === 1 && sources.has("fileImport") ? "statements"
      : sources.size === 1 && sources.has("demo") ? "demo" : "unlinked";
    g.state = groupState(g, hours);
    return g;
  });
  return list.sort((a, b) => RANK[a.state.tone] - RANK[b.state.tone] || a.name.localeCompare(b.name));
}

function groupState(g, hours) {
  const via = [...new Set(g.links.map((l) => SOURCE[l.provider] || l.provider))].join(" and ");
  const lastSync = g.links.map((l) => l.lastSync).filter(Boolean).sort().pop();
  const reauth = g.links.find((l) => l.status === "needsReauth");
  if (reauth) return { tone: "act", label: "Needs sign-in", detail: [lastSync ? `last updated ${dateShort(lastSync)}` : null, via && `via ${via}`], lastSync, problem: reauth };
  const failing = g.links.find((l) => l.lastError);
  if (failing) return { tone: "watch", label: lastSync ? `Updated ${ago(lastSync)}` : "Hasn't synced yet", detail: [via && `via ${via}`, "last sync failed, retrying"], lastSync, problem: failing };
  if (g.kind === "linked") {
    if (!lastSync) return { tone: "neutral", label: "Waiting for the first sync", detail: [via && `via ${via}`] };
    const stale = Date.now() - new Date(lastSync) > (2 * hours + 1) * 3600 * 1000;
    return { tone: stale ? "watch" : "ok", label: `Updated ${ago(lastSync)}`, detail: [via && `via ${via}`], lastSync, stale };
  }
  if (g.kind === "statements") return { tone: "neutral", label: "From statements you import", detail: [] };
  if (g.kind === "demo") return { tone: "neutral", label: "Demo data", detail: ["not a real connection"] };
  return { tone: "neutral", label: "Not linked", detail: [] };
}

/// "Updated 2 hours ago · via Plaid" with the colored part first; never color alone (the words say it).
export function statusLine(state, extra) {
  return h("div", { class: "status-line" }, dot(state.tone), h("span", { class: state.tone }, state.label),
    [...(state.detail || []), ...(extra || [])].filter(Boolean).map((d) => ` · ${d}`));
}

/// Syncs linked banks now and remembers each one's outcome for the tiles: `links` one at a time
/// (POST /v1/links/:id/sync, a retry for one waiting for a sign-in), or everything (POST /v1/sync).
export async function syncNow(links) {
  let results;
  if (links) {
    results = [];
    for (const l of links) results.push(await api(`/v1/links/${encodeURIComponent(l.id)}/sync`, { method: "POST" }));
  } else {
    results = await api("/v1/sync", { method: "POST" });
  }
  store.syncResults = { at: Date.now(), byLink: Object.fromEntries(results.map((r) => [r.linkID, r])) };
  const mine = links ? results.filter((r) => links.some((l) => l.id === r.linkID)) : results;
  await afterWrite();
  return { results, mine };
}
/// "Harbor: 14 new transactions" / "3 banks synced · 20 new transactions", and what failed, in plain words.
export function describeSync({ results, mine }, expected) {
  if (!results.length) {
    // Sync-all leaves out banks waiting for a sign-in, so nothing ran when every bank is.
    const waiting = ((store.summary && store.summary.links) || []).some((l) => l.status === "needsReauth");
    return { ok: true, message: !expected ? "Nothing to sync." : waiting ? "Nothing synced: each bank needs you to sign in again first." : "Nothing new to sync right now." };
  }
  const failed = mine.filter((r) => !r.ok), added = mine.reduce((t, r) => t + ((r.report && r.report.rowsAdded) || 0), 0);
  if (failed.length) {
    // What did sync is news too: "2 banks synced · 3 new transactions. Northwind Brokerage didn't sync."
    const synced = mine.length - failed.length;
    const good = synced ? `${synced === 1 ? `${mine.find((r) => r.ok).institution} synced` : `${plural(synced, "bank")} synced`} · ${plural(added, "new transaction")}. ` : "";
    return { ok: false, message: good + (failed.length === 1 ? `${failed[0].institution} didn't sync.` : `${failed.length} banks didn't sync.`),
      detail: failed.map((r) => `${r.institution}: ${r.error}`).join("\n") };
  }
  return { ok: true, message: mine.length === 1 ? `${mine[0].institution} is up to date · ${plural(added, "new transaction")}` : `${plural(mine.length, "bank")} synced · ${plural(added, "new transaction")}` };
}

/// Small line icons (inline SVG built in the DOM, so no files and nothing inline for the CSP to refuse).
const ICONS = {
  sync: "M4 12a8 8 0 0 1 13.7-5.6L20 8M20 4v4h-4M20 12a8 8 0 0 1-13.7 5.6L4 16M4 20v-4h4",
  file: "M7 3h7l5 5v13H7zM14 3v5h5M10 13h6M10 17h6",
  bank: "M3 10h18L12 4zM5 10v8M9.5 10v8M14.5 10v8M19 10v8M3 20h18",
};
export function icon(name) {
  const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  svg.setAttribute("viewBox", "0 0 24 24"); svg.setAttribute("width", "18"); svg.setAttribute("height", "18"); svg.setAttribute("aria-hidden", "true");
  svg.setAttribute("fill", "none"); svg.setAttribute("stroke", "currentColor"); svg.setAttribute("stroke-width", "1.6");
  svg.setAttribute("stroke-linecap", "round"); svg.setAttribute("stroke-linejoin", "round");
  const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
  path.setAttribute("d", ICONS[name]);
  svg.append(path);
  return svg;
}

/// The sync schedule runs from when the server started, every `syncIntervalHours`.
export function nextSyncIn() {
  const s = store.summary;
  if (!s) return null;
  const period = s.settings.syncIntervalHours * 3600 * 1000, since = Date.now() - new Date(s.startedAt);
  return (period - (since % period)) / 1000;
}
