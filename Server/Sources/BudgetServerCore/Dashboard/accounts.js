// Accounts: one card per institution (problem banks first), statement-only accounts after, and the
// Connect-a-bank drawer. Bank sign-in happens here; the phone only reads.
import { fill, h, api, store, heavy, pageHead, sectionHead, button, busy, armed, isArmed, callout, details, glyph, statusLine,
  institutionGroups, syncProblem, providerDetail, syncNow, describeSync, afterWrite, reportError, toast, rowMoney, plural, dateShort, dateFull,
  dateTime, KIND, SOURCE, emptyState, drawer, closeDrawer } from "./core.js";
import { connectPanes, framedNote, linkPlaid, relinkTeller, reconnected, announce } from "./providers.js";
import { netWorthSection } from "./networth.js";

// MARK: Actions on one institution

/// Sync now for one bank: POST /v1/links/:id/sync for each of its connections, one at a time.
async function syncInstitution(g, buttonEl) {
  await busy(buttonEl, "Syncing…", async () => {
    const outcome = describeSync(await syncNow(g.links), true);
    if (outcome.ok) toast(outcome.message); else reportError({ message: outcome.message, detail: outcome.detail });
  });
}

/// What the button that repairs a connection says: SimpleFIN's sign-in lives on its own site, so here it's a retry.
export const reconnectLabel = (link) => (link.provider === "simplefin" ? "Try again" : "Reconnect");

/// Sign in to a bank again without losing its history. Plaid opens Link in update mode for the same Item and then
/// syncs it; Teller reopens the same enrollment in Connect and stores the new token; SimpleFIN is fixed on
/// SimpleFIN Bridge's site, after which a sync of the link takes it back. Inside the Olares window the bank's
/// sign-in pages misbehave, so there it points to a full tab instead.
export async function reconnect(link, buttonEl, where) {
  const flash = where || document.getElementById("flash");
  if (link.provider !== "simplefin" && window.top !== window.self) {
    fill(flash, framedNote());
    flash.scrollIntoView({ block: "nearest", behavior: "smooth" });
    return;
  }
  await busy(buttonEl, link.provider === "simplefin" ? "Trying…" : "Signing in…", async () => {
    if (link.provider === "plaid") return linkPlaid({ update: link, where: flash });
    if (link.provider === "teller") return relinkTeller(link, { where: flash });
    announce(retriedSimpleFIN(await api(`/v1/links/${encodeURIComponent(link.id)}/sync`, { method: "POST" })), flash);
    await afterWrite();
  }, { errorTarget: flash });
}

/// SimpleFIN's "Try again" signs nobody in here: it syncs, and either the bank is back or it still wants a sign-in on
/// SimpleFIN Bridge. (Plaid and Teller come back through `reconnected`, after a sign-in that did happen.)
function retriedSimpleFIN(result) {
  if (result.ok) return { ok: true, message: `${result.institution} is back · ${plural((result.report && result.report.rowsAdded) || 0, "new transaction")}` };
  return { ok: false, message: `${result.institution} still needs you to sign in on SimpleFIN Bridge, then try again here.`, detail: result.error };
}

/// Why a connection stopped, and what signing in again involves, for the panel on its card.
function reconnectHelp(g) {
  const link = g.state.problem;
  if (link.provider === "simplefin") {
    return ["Sign in to this bank again on SimpleFIN Bridge, at ", h("a", { href: "https://beta-bridge.simplefin.org", target: "_blank", rel: "noopener" }, "https://beta-bridge.simplefin.org"),
      ", then try again here. Your history is safe; nothing new comes in until then."];
  }
  return `${g.name} ended this connection, which banks do every so often for security. Sign in again and it carries on where it stopped: your history is safe, and nothing new comes in until then.`;
}

// MARK: Card bills (Plaid Liabilities)

/// What the last card-bill check said about a Plaid link, as a status line (tone, words, when).
const CARD_BILLS = {
  ok: (c) => ({ tone: "ok", label: "Card bills on", detail: [plural(c.cards || 0, "card"), `checked ${dateTime(c.checkedAt)}`] }),
  needsConsent: () => ({ tone: "watch", label: "Card bills need your OK", detail: ["linked before card bills"] }),
  notSupported: () => ({ tone: "neutral", label: "No card bills from this bank", detail: ["it doesn't offer them through Plaid"] }),
  noCreditAccounts: () => ({ tone: "neutral", label: "No card bills", detail: ["no credit card at this bank"] }),
  notReady: (c) => ({ tone: "neutral", label: "Card bills on the way", detail: ["Plaid is still gathering them", `asked ${dateTime(c.checkedAt)}`] }),
  failed: (c) => ({ tone: "watch", label: "Card bills didn't come through", detail: [`asked ${dateTime(c.checkedAt)}`, "tried again tomorrow"] }),
};

/// Card bills for one Plaid link, while the setting is on: its status, and for a bank linked before card bills, the
/// one sign-in that grants access. That sign-in is Plaid's update mode on the same connection: nothing is relinked
/// or removed, and it starts only from this button.
function cardBillsPanel(link) {
  if (link.provider !== "plaid" || !store.summary.settings.cardBills) return null;
  const check = link.cardBills;
  const state = check ? (CARD_BILLS[check.access] || CARD_BILLS.failed)(check) : { tone: "neutral", label: "Card bills on", detail: ["checked at the next sync"] };
  const line = statusLine(state);
  if (!check || check.access !== "needsConsent") {
    return h("div", { class: "card-bills" }, line, check && check.access === "failed" && check.message ? details("What Plaid said", check.message) : null);
  }
  return h("div", { class: "card-bills" }, line, callout({ tone: "watch", title: `Grant card-bill access for ${link.institution}`,
    body: "This bank was linked before card bills. Sign in once to add access to the same connection: nothing is relinked, your history stays, and Plaid starts billing for card bills on this bank.",
    actions: [button("Grant card-bill access", { compact: true, onclick: (e) => grantCardBills(link, e.currentTarget) })] }));
}

async function grantCardBills(link, buttonEl) {
  const flash = document.getElementById("flash");
  if (window.top !== window.self) { fill(flash, framedNote()); flash.scrollIntoView({ block: "nearest", behavior: "smooth" }); return; }
  await busy(buttonEl, "Signing in…", () => linkPlaid({ update: link, grant: true, where: flash }), { errorTarget: flash });
}

async function removeLink(link) {
  try {
    await api(`/v1/links/${encodeURIComponent(link.id)}`, { method: "DELETE" });
    toast(`Removed ${link.institution}. Its transactions stay.`);
    await afterWrite();
  } catch (error) { reportError(error); }
}

// MARK: Rendering

function accountRow(a, g) {
  const stale = g.state.tone === "act" || g.state.stale;
  const sub = [KIND[a.kind] || a.kind, a.kind === "investment" ? "balance only" : null,
    stale && g.state.lastSync ? `balance as of ${dateShort(g.state.lastSync)}` : null].filter(Boolean).join(" · ");
  return h("div", { class: "row" },
    h("div", { class: "grow" }, h("div", { class: "title" }, a.name, a.mask ? h("span", { class: "mask" }, ` ••${a.mask}`) : null), h("div", { class: "sub" }, sub)),
    rowMoney(a.balance));
}

function detailsPanel(g) {
  return h("div", { class: "inst-details" }, g.links.map((l) => h("dl", { class: "kv" },
    h("dt", {}, "Connected through"), h("dd", {}, SOURCE[l.provider] || l.provider),
    h("dt", {}, "Connected since"), h("dd", {}, dateFull(l.createdAt)),
    h("dt", {}, "Last good sync"), h("dd", {}, l.lastSync ? dateTime(l.lastSync) : "Not yet"),
    l.lastError ? [h("dt", {}, "Last problem"), h("dd", {}, syncProblem(l))] : null)),
    g.links.some((l) => l.lastError) ? details("What the provider said", g.links.filter((l) => l.lastError).map(providerDetail).join("\n")) : null,
    h("p", { class: "help" }, "Removing a connection stops syncing and signs this server out at the bank. Transactions already here stay."));
}

function menu(g, view) {
  const items = [];
  if (g.kind === "linked") {
    if (g.state.tone !== "act") items.push(h("button", { type: "button", "aria-label": `Sync ${g.name} now`, onclick: (e) => {
      close(e);
      const visible = view.syncButton(g);
      if (visible && visible.offsetParent) syncInstitution(g, visible);
      else { toast(`Syncing ${g.name}…`); syncInstitution(g, e.currentTarget); }
    } }, "Sync now"));
    if (g.state.tone === "act") items.push(h("button", { type: "button", onclick: (e) => { close(e); reconnect(g.state.problem, view.reconnectButton(g) || e.currentTarget); } }, reconnectLabel(g.state.problem)));
  }
  items.push(h("button", { type: "button", "aria-label": `${view.open.has(g.key) ? "Hide details for" : "Details for"} ${g.name}`,
    onclick: (e) => { close(e); view.toggleDetails(g.key); } }, view.open.has(g.key) ? "Hide details" : "Details"));
  for (const l of g.links) {
    items.push(h("button", { type: "button", class: "caution", "aria-label": `Remove the ${g.name} ${SOURCE[l.provider] || l.provider} connection`, onclick: (e) => { e.stopPropagation(); const b = e.currentTarget; armed(b, "Click again to remove", () => { const d = b.closest("details"); if (d) d.open = false; removeLink(l); }); } },
      g.links.length > 1 ? `Remove the ${SOURCE[l.provider] || l.provider} connection` : "Remove connection"));
  }
  const close = (e) => { const d = e.currentTarget.closest("details"); if (d) d.open = false; };
  return h("details", { class: "menu" },
    h("summary", { class: "icon-btn", "aria-label": `More for ${g.name}` }, "⋯"),
    h("div", { class: "menu-list" }, items));
}

function institutionCard(g, view) {
  const id = "inst-" + g.key.replace(/[^a-z0-9]+/g, "-");
  const act = g.state.tone === "act";
  const head = h("div", { class: "inst-head" }, glyph(g.name),
    h("div", { class: "grow" }, h("h2", { class: "t-headline", id }, g.name), statusLine(g.state)),
    g.kind === "linked" && !act ? button("Sync now", { compact: true, class: "btn tinted compact hide-phone", dataset: { sync: g.key }, "aria-label": `Sync ${g.name} now`,
      onclick: (e) => syncInstitution(g, e.currentTarget) }) : null,
    g.kind === "statements" ? h("a", { class: "btn secondary compact", href: `#/imports?account=${encodeURIComponent(g.accounts[0].id)}`, "aria-label": `Import a statement for ${g.name}` }, "Import") : null,
    // Accounts whose connection is gone keep their history; they can be linked again or kept current with statements.
    g.kind === "unlinked" ? h("a", { class: "btn secondary compact", href: "#/accounts?connect=1", "aria-label": `Connect ${g.name}` }, "Connect") : null,
    g.kind === "unlinked" && g.accounts.length ? h("a", { class: "btn quiet", href: `#/imports?account=${encodeURIComponent(g.accounts[0].id)}`,
      "aria-label": `Import a statement for ${g.name}` }, "Import a statement") : null,
    g.kind === "linked" ? menu(g, view) : null);
  const body = h("div", { class: "inst-body" },
    g.accounts.length ? h("div", { class: "rows" }, g.accounts.map((a) => accountRow(a, g)))
      : h("p", { class: "empty-line" }, g.state.problem ? "No accounts came in before the connection stopped." : "Its accounts show up after the first sync."));
  if (act) {
    body.append(callout({ tone: "act", title: "Further action needed", body: reconnectHelp(g), detail: providerDetail(g.state.problem) }));
    body.append(button(`↻ ${reconnectLabel(g.state.problem)}${g.state.problem.provider === "simplefin" ? "" : ` ${g.name}`}`,
      { class: "btn secondary block", dataset: { reconnect: g.key }, onclick: (e) => reconnect(g.state.problem, e.currentTarget) }));
  } else if (g.state.problem) {
    body.append(callout({ tone: "watch", title: syncProblem(g.state.problem), body: "Nothing is lost; the next sync picks up where this one stopped.", detail: providerDetail(g.state.problem) }));
  }
  for (const l of g.links) { const panel = cardBillsPanel(l); if (panel) body.append(panel); }
  if (view.open.has(g.key)) body.append(detailsPanel(g));
  return h("section", { class: `card${act ? " problem" : ""}`, "aria-labelledby": id, dataset: { bank: g.key } }, head, body);
}

// MARK: Drawer

async function openDrawer() {
  const { body } = drawer("Connect a bank", { onClose: () => {
    if (/[?&]connect=1/.test(location.hash)) history.replaceState(null, "", location.pathname + location.search + "#/accounts");
  } });
  const flash = h("div", { class: "flash" });
  fill(body, flash, framedNote(), h("div", { class: "skeleton-slot" }, h("div", { class: "skeleton" }, h("span"), h("span"), h("span"))));
  try { await heavy("providers"); } catch (error) { reportError(error, flash); }
  body.querySelector(".skeleton-slot").replaceWith(connectPanes({ where: flash }),
    h("p", { class: "help" }, "Bank sign-in runs in the provider's own window. The server stores only a sealed access key, never your bank password."));
}

// MARK: View

export default {
  title: "Accounts",
  open: new Set(),
  mount(root, ctx) {
    this.root = root;
    this.render();
    heavy("providers").catch(() => {});
    this.navigate(ctx);
  },
  navigate({ params }) {
    if (params.get("connect")) openDrawer();
    const bank = params.get("bank");
    if (bank) {
      const card = this.root.querySelector(`[data-bank="${CSS.escape(bank)}"]`);
      if (card) { card.scrollIntoView({ block: "start", behavior: "smooth" }); card.classList.add("highlight"); setTimeout(() => card.classList.remove("highlight"), 1600); }
    }
  },
  unmount() { closeDrawer(); },
  /// Light refresh: redraw unless a menu is open or a remove is waiting for its second click.
  refresh() {
    if (!this.root || isArmed(this.root) || this.root.querySelector(".menu[open]") || this.root.querySelector(".nw-form :focus")) return;
    this.render();
  },
  toggleDetails(key) { if (this.open.has(key)) this.open.delete(key); else this.open.add(key); this.render(); },
  syncButton(g) { return this.root.querySelector(`[data-sync="${CSS.escape(g.key)}"]`); },
  reconnectButton(g) { return this.root.querySelector(`[data-reconnect="${CSS.escape(g.key)}"]`); },
  render() {
    const groups = institutionGroups();
    const accounts = store.overview.accounts;
    const connect = button("Connect a bank", { kind: "primary", onclick: () => openDrawer() });
    const linked = groups.filter((g) => g.kind !== "statements"), statements = groups.filter((g) => g.kind === "statements");
    const banners = groups.filter((g) => g.state.tone === "act").map((g) => callout({ tone: "act", title: `${g.name} needs you to sign in again`,
      body: g.state.lastSync ? `Nothing new has come in since ${dateShort(g.state.lastSync)}. Your history is safe.` : "Your history is safe.",
      actions: [button(reconnectLabel(g.state.problem), { compact: true, onclick: (e) => reconnect(g.state.problem, e.currentTarget) })] }));
    if (!store.summary.settings.linkingEnabled) banners.push(callout({ tone: "watch", title: "Bank linking is off",
      body: "The server has no key to protect bank sign-ins, so it can't link or sync banks. Add one in the Budget app's settings on the Olares, then restart it.",
      detail: "Set BUDGET_TOKEN_KEY to the output of: openssl rand -base64 32" }));
    const institutions = new Set(groups.map((g) => g.name)).size;
    fill(this.root, 
      pageHead({ eyebrow: "Connections", title: "Accounts",
        sub: accounts.length ? `${plural(accounts.length, "account")} at ${plural(institutions, "institution")}. Bank sign-in happens here; the phone only reads.`
          : "Bank sign-in happens here; the phone only reads.", action: connect }),
      banners.length ? h("div", { class: "stack banners" }, banners) : null,
      groups.length ? null : h("section", { class: "card" }, emptyState({ title: "Nothing connected yet",
        body: "Connect a bank to sync its accounts on their own, or import statements you've downloaded from its website.",
        actions: [button("Connect a bank", { kind: "secondary", onclick: () => openDrawer() }), h("a", { class: "btn quiet", href: "#/imports" }, "Import statements")] })),
      linked.length ? h("div", { class: "stack" }, linked.map((g) => institutionCard(g, this))) : null,
      statements.length ? [sectionHead("From statements", h("a", { class: "btn quiet", href: "#/imports" }, "Import a statement")),
        h("div", { class: "stack" }, statements.map((g) => institutionCard(g, this)))] : null,
      netWorthSection());
  },
};

