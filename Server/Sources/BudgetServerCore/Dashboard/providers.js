// Bank providers: Plaid and SimpleFIN, side by side for the person to choose; neither is the recommended one. Plaid's
// key form is shared by the Connect-a-bank drawer (Accounts) and Settings → Bank providers, and Plaid Link runs only in
// this dashboard. SimpleFIN needs no keys here: a setup token from SimpleFIN Bridge, and its banks are managed there.
import { fill, h, api, store, heavy, cached, forget, afterWrite, toast, callout, button, busy, armed, tag, plural, reportError, secretAttrs,
  dateTime } from "./core.js";

const PLAID_JS = "https://cdn.plaid.com/link/v2/stable/link-initialize.js";
const BRIDGE = "https://beta-bridge.simplefin.org";

/// Loads a provider's script once, only when someone presses Link. A second call while it loads waits for the same
/// load; a failed load can be tried again.
const scripts = {};
export function loadScript(src) {
  scripts[src] ||= new Promise((resolve, reject) => {
    const el = document.createElement("script");
    el.src = src; el.onload = resolve;
    el.onerror = () => {
      delete scripts[src]; el.remove();
      reject(new Error("Couldn't load the bank sign-in window. Check the internet connection and try again."));
    };
    document.head.append(el);
  });
  return scripts[src];
}

/// Where each provider stands, for the tabs and Settings: "Ready", "Needs keys", "Needs encryption key".
export function providerStates() {
  const body = cached("providers");
  const sealing = !!(store.summary && store.summary.settings.linkingEnabled) && (!body || body.providers.sealingAvailable);
  const noKey = { label: "Needs encryption key", tone: "watch", ready: false };
  const simplefin = sealing ? { label: "Ready", tone: "ok", ready: true } : noKey;
  if (!body) return { plaid: { label: "Checking", tone: "", ready: false }, simplefin };
  const p = body.providers.plaid;
  const plaid = !sealing ? noKey : p.origin === "none" ? { label: "Needs keys", tone: "", ready: false }
    : { label: p.environment === "production" ? "Ready" : "Ready · sandbox", tone: "ok", ready: true };
  return { plaid, simplefin };
}

/// Where a provider's keys come from, said only when it isn't the default.
function originNote(origin) {
  if (origin === "dashboard") return "Saved here.";
  if (origin === "environment") return "From the server's install settings. Saving keys here takes over from those.";
  return null;
}
const noSealing = () => callout({ tone: "watch", title: "The server can't protect saved keys yet",
  body: "It needs an encryption key before it can store bank keys or sign-ins. Add BUDGET_TOKEN_KEY to the server's install settings (budget.env on a Mac, the app's settings on an Olares), then restart it.",
  detail: "Set BUDGET_TOKEN_KEY to the output of: openssl rand -base64 32" });

/// Plaid's page for Allowed redirect URIs (Developers, then API).
const PLAID_REDIRECTS = "https://dashboard.plaid.com/developers/api";
/// Whether an address is on this computer's own name (localhost, *.localhost, 127.x, ::1), where no bank can return.
function localName(address) {
  let host;
  try { host = new URL(address).hostname.toLowerCase().replace(/^\[|\]$/g, ""); } catch { return false; }
  return host === "localhost" || host.endsWith(".localhost") || host.startsWith("127.") || host === "::1" || host === "0.0.0.0";
}

const field = (label, input, help, wide) => h("label", { class: `field${wide ? " wide" : ""}` }, h("span", { class: "field-head" }, label), input, help ? h("span", { class: "help" }, help) : null);

/// Plaid's keys. `onChange` is told whenever a value changes (Settings counts unsaved changes with it).
export function plaidForm({ onChange } = {}) {
  const body = cached("providers"), p = body.providers.plaid;
  const client = h("input", { class: "input", ...secretAttrs, placeholder: "24 characters, 0–9 and a–f", value: p.clientID || "", "aria-describedby": "plaid-client-help" });
  const env = h("select", { class: "input" }, h("option", { value: "sandbox" }, "Sandbox (test data)"), h("option", { value: "production" }, "Production (your real banks)"));
  env.value = p.environment || "sandbox";
  const secret = h("input", { class: "input", type: "password", ...secretAttrs, placeholder: p.origin === "dashboard" ? "Saved. Leave empty to keep it" : "" });
  // Only an https dashboard at a real name (Olares, a tunnel) gets a suggestion; a computer install's stays empty, and
  // desktop Link opens banks like Chase in a pop-up without one.
  const httpsDashboard = !!body.suggestedRedirectURI;
  const redirect = h("input", { class: "input", spellcheck: "false", autocomplete: "off", placeholder: httpsDashboard ? "" : "Leave empty on a computer install",
    value: p.redirectURI || body.suggestedRedirectURI || "" });
  const initial = { client: client.value, env: env.value, redirect: redirect.value };
  for (const el of [client, env, secret, redirect]) el.addEventListener("input", () => onChange && onChange());
  const el = h("div", { class: "stack" },
    h("div", { class: "form" },
      field("Client ID", client, "Plaid → Developers → Keys. It names this app; it isn't a password."),
      field("Environment", env),
      field("Secret for that environment", secret, null, true),
      field("Return address for banks that sign in on their own site", redirect, httpsDashboard
        ? "Add this exact address under Allowed redirect URIs in Plaid. Chase, Schwab and other banks that sign in on their own site come back here to finish."
        : "Optional. Leave this empty on a computer install: banks like Chase open their sign-in in a pop-up. Fill it in only if this dashboard has an https address, then add it under Allowed redirect URIs in Plaid.", true)),
    h("p", { class: "help" }, "Keys: ", h("a", { href: "https://dashboard.plaid.com/developers/keys", target: "_blank", rel: "noopener" }, "https://dashboard.plaid.com/developers/keys"),
      " · Allowed redirect URIs: ", h("a", { href: PLAID_REDIRECTS, target: "_blank", rel: "noopener" }, PLAID_REDIRECTS)),
    originNote(p.origin) ? h("p", { class: "help" }, originNote(p.origin)) : null);
  return {
    el,
    changes: () => [client.value.trim() !== initial.client, env.value !== initial.env, !!secret.value.trim(), redirect.value.trim() !== initial.redirect].filter(Boolean).length,
    /// A sentence saying what's wrong, or null.
    validate() {
      const id = client.value.trim(), s = secret.value.trim(), r = redirect.value.trim();
      if (!/^[0-9a-f]{24}$/i.test(id)) return `That isn't a Plaid client ID: it's 24 characters of 0–9 and a–f, and ${id.length} are entered. A password manager may have filled it.`;
      if (s && !/^[0-9a-f]{20,64}$/i.test(s)) return `That isn't a Plaid secret: it's about 30 characters of 0–9 and a–f, and ${s.length} are entered.`;
      if (p.origin === "none" && !s) return "Add the secret for that environment too.";
      if (r && !/^https:\/\//i.test(r)) return "Plaid only takes an https:// return address. Leave it empty unless this dashboard has an https address.";
      if (r && localName(r)) return "That return address is this computer's own, so a bank can't come back to it. Leave the field empty: banks like Chase open their sign-in in a pop-up.";
      return null;
    },
    /// Saves, then asks Plaid for a Link token to prove the keys work. Resolves to { ok, message }.
    async save() {
      await api("/dash/providers/plaid", { method: "PUT", body: { clientID: client.value.trim(), secret: secret.value.trim() || null,
        environment: env.value, redirectURI: redirect.value.trim() || null } });
      secret.value = "";
      forget("providers");
      try { await api("/v1/links/plaid/token", { method: "POST", body: {} }); return { ok: true, message: "Saved, and Plaid accepted the keys." }; }
      catch (error) {
        // The keys are fine when Plaid only refuses the return address: the server says which address and where to add it.
        if (/return address/.test(error.message || "")) return { ok: false, message: error.message };
        return { ok: false, message: "Saved, but Plaid turned the keys down.", detail: error.detail || error.message };
      }
    },
  };
}

/// "Remove saved keys" for keys saved on this dashboard (environment keys stay).
export function removeKeysButton(provider, done) {
  const origin = cached("providers").providers[provider].origin;
  if (origin !== "dashboard") return null;
  return button("Remove saved keys", { kind: "caution", compact: true, onclick: (e) => armed(e.currentTarget, "Click again to remove", async () => {
    try {
      await api(`/dash/providers/${provider}`, { method: "DELETE" });
      forget("providers");
      toast("Plaid keys removed");
      await heavy("providers");
      done && done();
    } catch (error) { reportError(error); }
  }) });
}

// MARK: Linking

/// After signing in again: the sync that follows says whether the bank took it.
export function reconnected(result) {
  if (!result.ok) return { ok: false, message: `${result.institution} is signed in, but the sync after it didn't finish.`, detail: result.error };
  return { ok: true, message: `${result.institution} is connected again · ${plural((result.report && result.report.rowsAdded) || 0, "new transaction")}` };
}
/// After granting card-bill access: the sync that follows asks Plaid again (`CardBillSync`).
function granted(result) {
  if (!result.ok) return { ok: false, message: `${result.institution} granted card-bill access, but the sync after it didn't finish.`, detail: result.error };
  return { ok: true, message: `${result.institution}: card-bill access granted` };
}
function linked(result) {
  if (!result.ok) return { ok: false, message: `${result.institution} is linked, but its first sync didn't finish. It'll try again on its own.`, detail: result.error };
  return { ok: true, message: `Linked ${result.institution} · ${plural(result.report.rowsAdded, "new transaction")}` };
}
export function announce(outcome, where) {
  if (outcome.ok) toast(outcome.message);
  else reportError({ message: outcome.message, detail: outcome.detail }, where);
}

// [lane P] linkPlaid
import { duplicatePlaidLink } from "./linkerrors.js";

/// Plaid Link. A new link trades Link's public token for an Item. `update` (a link waiting for a sign-in) opens
/// Link in update mode for that Item instead: the person signs in again, and finishing just syncs the link, so its
/// accounts and history carry on (there's nothing to exchange). Banks that sign in on their own site (OAuth) leave
/// the page and come back with `?oauth_state_id=…`; `resume` picks the same session up again (the Link token and
/// the link being repaired are kept in sessionStorage). Resolves once Link closes and its outcome is shown.
/// `grant` (with `update`) is the same update mode asking the person to add card-bill access (Plaid Liabilities) to
/// that Item: same Item, same access, nothing exchanged. Only a click on "Grant card-bill access" starts it.
/// A new link never makes a second Item at a bank that already has a working one (each is one of the Plaid Trial
/// plan's ten, and its accounts would all come in twice): picking such a bank closes Link with a note to use Reconnect,
/// and the server refuses the exchange too, by the same rule, before anything is exchanged.
export async function linkPlaid({ resume = false, update = null, grant = false, where } = {}) {
  let token, linkID;
  store.pending++;
  try {
    await loadScript(PLAID_JS);
    linkID = resume ? sessionStorage.getItem("plaidUpdateLink") : update ? update.id : null;
    if (resume) grant = sessionStorage.getItem("plaidGrant") === "1";
    token = resume ? sessionStorage.getItem("plaidLinkToken")
      : (await api("/v1/links/plaid/token", { method: "POST", body: linkID ? (grant ? { linkID, grantCardBills: true } : { linkID }) : {} })).linkToken;
  } catch (error) {
    // A refused grant may have corrected an old consent status to unsupported. Redraw from the saved decision.
    if (grant && linkID) await afterWrite();
    reportError(error, where); return;
  }
  finally { store.pending--; }
  const clean = () => {
    sessionStorage.removeItem("plaidLinkToken");
    sessionStorage.removeItem("plaidUpdateLink");
    sessionStorage.removeItem("plaidGrant");
    if (resume) history.replaceState(history.state, "", location.pathname + "#/accounts");
  };
  if (!token) { clean(); reportError({ message: "The bank sign-in expired before it finished. Start again from Accounts." }, where); return; }
  sessionStorage.setItem("plaidLinkToken", token);
  // Which link a bank's own sign-in page is repairing, for when it comes back (?oauth_state_id); none for a new link.
  if (linkID) sessionStorage.setItem("plaidUpdateLink", linkID); else sessionStorage.removeItem("plaidUpdateLink");
  if (linkID && grant) sessionStorage.setItem("plaidGrant", "1"); else sessionStorage.removeItem("plaidGrant");
  let duplicate = null;
  await new Promise((finish) => {
    const handler = window.Plaid.create({
      token, receivedRedirectUri: resume ? location.href : undefined,
      onEvent: (eventName, metadata) => {
        if (linkID || eventName !== "SELECT_INSTITUTION" || duplicate) return;
        duplicate = duplicatePlaidLink(store.summary && store.summary.links, metadata.institution_id, metadata.institution_name);
        if (duplicate) handler.exit({ force: true });
      },
      onSuccess: async (publicToken, metadata) => {
        clean();
        toast(grant ? "Card-bill access granted. Checking…" : linkID ? "Signed in. Syncing…" : "Linking and syncing…");
        try {
          const result = linkID
            // A sign-in or renewal (not the card-bill grant) tells the server update mode finished: it clears a
            // PENDING_DISCONNECT warning and reads the new consent date at its next look.
            ? await api(`/v1/links/${encodeURIComponent(linkID)}/sync`, { method: "POST", body: grant ? undefined : { afterUpdateMode: true } })
            : await api("/v1/links/plaid/exchange", { method: "POST", body: { publicToken, institution: (metadata.institution && metadata.institution.name) || "Plaid",
              institutionID: (metadata.institution && metadata.institution.institution_id) || undefined } });
          announce(grant ? granted(result) : linkID ? reconnected(result) : linked(result), where);
        } catch (error) { reportError(error, where); }
        await afterWrite();
        finish();
      },
      onExit: (err) => {
        clean();
        if (duplicate) reportError({ message: `${duplicate.institution} is already linked. Use Reconnect on it instead, so you keep its history and don't use up a Plaid Item.` }, where);
        else if (err) reportError({ message: err.display_message || "The bank sign-in closed before it finished.", detail: [err.error_code, err.error_message].filter(Boolean).join(": ") }, where);
        finish();
      },
    });
    handler.open();
  });
}
// [end lane P] linkPlaid

// MARK: The choice (one comparison, the same in docs/INSTALL-SERVER.md §6, docs/SETUP.md and setup.sh)

/// Plaid and SimpleFIN on the points that differ. Neither column is the recommended one: it's the person's choice,
/// and either can be added later.
const COMPARE = [
  ["Cost", "Your own Plaid account. Free Trial: 10 bank logins for the life of the account (removing one doesn't free it). Paid plans bill per bank",
    "$15 a year (or $1.50 a month) to SimpleFIN, up to 25 banks"],
  ["Setup", "Developer sign-up, keys and an identity check. Real banks need the free Trial or a paid plan; approval can take days",
    "Sign up, add your banks on their site, paste one token"],
  ["Card bills (statement, minimum, due date)", "Yes, once Card bills is on (Settings → Sync); Plaid then bills Liabilities", "No"],
  ["Merchant names and bank categories", "Yes", "Raw bank descriptions"],
  ["History", "Up to 2 years at link", "About 90 days per request; Budget walks back further where the bank allows"],
  ["Freshness", "Several times a day", "About once a day"],
  ["Investments", "Holdings by position, once Investment holdings is on (Settings → Sync); Plaid then bills Investments", "Balances only"],
];

/// The comparison as a compact table (rows stack on a phone), in a fold that starts open until a bank is linked.
export function compareTable({ open } = {}) {
  const table = h("table", { class: "table stack-phone compare" },
    h("thead", {}, h("tr", {}, h("th", { scope: "col" }, h("span", { class: "sr-only" }, "What")), h("th", { scope: "col" }, "Plaid"), h("th", { scope: "col" }, "SimpleFIN"))),
    h("tbody", {}, COMPARE.map(([what, plaid, simplefin]) => h("tr", {},
      // Row labels wrap (the table's headers don't by default), so the two answers get the drawer's width.
      h("th", { scope: "row", css: { "white-space": "normal", "vertical-align": "top", width: "28%", padding: "var(--s-sm) var(--s-sm) var(--s-sm) 0", "border-bottom-color": "var(--divider)" } }, what), h("td", { "data-label": "Plaid:" }, plaid), h("td", { "data-label": "SimpleFIN:" }, simplefin)))));
  return h("details", { class: "fold", open: open ?? !((store.summary && store.summary.links) || []).length },
    h("summary", {}, h("span", { class: "grow" }, "Plaid or SimpleFIN? Either works, and you can add the other later")),
    h("div", { class: "fold-body" }, h("div", { class: "table-wrap" }, table)));
}

// MARK: The Connect panes (drawer)

const PANES = [
  ["plaid", "Plaid", "Through your own Plaid developer account: card bills, merchant names and two years of history."],
  ["simplefin", "SimpleFIN", "Through SimpleFIN Bridge, a service you subscribe to: one token covers every bank you add there."],
];

/// The comparison, then a tab per provider with its status, its three steps and a Link button. The tab that opens
/// first is the one already set up; with both or neither, the first by name. No badge on either.
export function connectPanes({ where, selected } = {}) {
  const states = providerStates();
  const first = selected || defaultPane(states);
  const root = h("div", { class: "stack" });
  const tabs = h("div", { class: "tabs", role: "tablist", "aria-label": "Provider" });
  const panels = {};
  const select = (id, focus) => {
    for (const b of tabs.children) { const on = b.dataset.id === id; b.setAttribute("aria-selected", String(on)); b.tabIndex = on ? 0 : -1; if (on && focus) b.focus(); }
    for (const [pid, panel] of Object.entries(panels)) panel.hidden = pid !== id;
  };
  for (const [id, name] of PANES) {
    const s = states[id];
    tabs.append(h("button", { class: "chip", type: "button", role: "tab", id: `tab-${id}`, "aria-controls": `pane-${id}`, dataset: { id },
      onclick: () => select(id), onkeydown: (e) => arrowKeys(e, tabs, select) }, name, tag(s.label, s.tone)));
  }
  root.append(compareTable(), tabs);
  if (!store.summary.settings.linkingEnabled || (cached("providers") && !cached("providers").providers.sealingAvailable)) root.append(noSealing());
  for (const [id, name, blurb] of PANES) {
    const panel = h("div", { class: "pane", role: "tabpanel", id: `pane-${id}`, "aria-labelledby": `tab-${id}` });
    panels[id] = panel;
    renderPane(panel, id, name, blurb, where, () => { const again = connectPanes({ where, selected: id }); root.replaceWith(again); });
    root.append(panel);
  }
  select(first);
  return root;
}

/// "Already set up" means the person did something toward that provider: a bank linked through it, or, for Plaid,
/// keys saved. SimpleFIN is Ready as soon as the server can seal (it needs no keys), so Ready alone would open its
/// tab on every new install and lean the choice its way.
function defaultPane(states) {
  const links = (store.summary && store.summary.links) || [];
  const setUp = PANES.map(([id]) => id).filter((id) => links.some((l) => l.provider === id) || (id === "plaid" && states.plaid.ready));
  return setUp.length === 1 ? setUp[0] : PANES[0][0];
}

const extLink = (href, text) => h("a", { href, target: "_blank", rel: "noopener" }, text || href);
const steps = (...items) => h("ol", { class: "steps" }, items.map((item) => h("li", {}, item)));

function renderPane(panel, id, name, blurb, where, rerender) {
  const state = providerStates()[id];
  panel.append(h("p", { class: "t-callout muted" }, blurb));
  if (id === "simplefin") { renderSimpleFIN(panel, state, where); return; }
  const body = cached("providers");
  const returnAddress = body && (body.providers.plaid.redirectURI || body.suggestedRedirectURI);
  panel.append(steps(
    ["Make a Plaid account at ", extLink("https://dashboard.plaid.com"), ". Sandbox is free with made-up banks. Real banks need the free Trial (",
      extLink("https://dashboard.plaid.com/trial-plan"), ") or a paid plan, with an identity check."],
    returnAddress
      ? ["Enter its client ID and secret under Keys below. Then add ", h("code", {}, returnAddress), " under Allowed redirect URIs at ", extLink(PLAID_REDIRECTS), "."]
      : "Enter its client ID and secret under Keys below. On a computer install there's no return address to add: banks like Chase sign in in a pop-up.",
    "Link a bank: Plaid's window opens here, and you sign in to the bank there."));
  const linkButton = button("Link an account", { kind: "primary", disabled: !state.ready, onclick: () => linkPlaid({ where }) });
  panel.append(h("div", { class: "actions" }, linkButton));
  if (!body) return;
  panel.append(plaidExtras(body));
  const form = plaidForm();
  const result = h("div");
  const keys = h("details", { class: "fold", open: !state.ready && state.label !== "Needs encryption key" },
    h("summary", {}, h("span", { class: "grow" }, "Keys")),
    h("div", { class: "fold-body" }, form.el,
      h("div", { class: "actions" },
        button("Save and test", { kind: "secondary", disabled: !cached("providers").providers.sealingAvailable, onclick: (e) => busy(e.currentTarget, "Saving…", async () => {
          const problem = form.validate();
          if (problem) { fill(result, callout({ tone: "watch", title: problem })); return; }
          const outcome = await form.save();
          await heavy("providers");
          await afterWrite("providers");
          if (outcome.ok) { toast(outcome.message); rerender(); }
          else fill(result, callout({ tone: "act", title: outcome.message, detail: outcome.detail }));
        }, { errorTarget: result }) }),
        removeKeysButton(id, rerender)),
      result));
  panel.append(keys);
}

/// The two Plaid things a fresh install misses: Card bills is off until it's turned on, and what phone reconnect needs.
function plaidExtras(body) {
  const cardBills = !!(store.summary && store.summary.settings.cardBills);
  const phone = body.phoneReturnURI;
  return h("div", { class: "stack" },
    cardBills ? null : h("p", { class: "help" }, "Card bills (statement balance, minimum and due date) are off until you turn them on: ",
      h("a", { href: "#/settings/sync" }, "Settings, Sync, Card bills (Plaid Liabilities)"),
      ". Plaid bills Liabilities per bank login once it's used."),
    h("p", { class: "help" }, ...(phone
      ? ["Signing in to a bank again from the phone uses Plaid's Hosted Link. There's nothing to turn on at Plaid for it. Add ",
        h("code", {}, phone), " under Allowed redirect URIs at ", extLink(PLAID_REDIRECTS), "."]
      : ["Signing in to a bank again from the phone uses Plaid's Hosted Link. There's nothing to turn on at Plaid for it, but this server isn't ready yet: ",
        "it needs a public https address for the phone (Settings, Phone) and, with production keys, BUDGET_IOS_APP_ID in the server's install settings. ",
        "Until then, banks sign in again here."])));
}

// MARK: SimpleFIN

/// The server's hard stop on SimpleFIN requests in a rolling 24 hours (SimpleFIN asks for no more than about 24 a day).
const SIMPLEFIN_DAILY_LIMIT = 20;

/// SimpleFIN's pane: three steps with their links, the token box, then each bank already linked with its state.
function renderSimpleFIN(panel, state, where) {
  const input = h("input", { class: "input", placeholder: "Setup token", ...secretAttrs, "aria-label": "SimpleFIN setup token" });
  panel.append(
    steps(
      ["Sign up at ", extLink(BRIDGE), " ($15 a year, or $1.50 a month, paid to SimpleFIN)."],
      ["Add your banks there. Check that yours are covered first: ", extLink(`${BRIDGE}/search-institutions`), "."],
      "Create a setup token there and paste it here. A setup token works only once, so paste it here and nowhere else: the server trades it for an access address and seals it. If it's refused, make a new one there."),
    h("div", { class: "secret-row" }, input, button("Link", { kind: "primary", disabled: !state.ready, onclick: (e) => busy(e.currentTarget, "Linking…", async () => {
      const token = input.value.trim();
      if (!token) throw new Error("Paste the setup token first.");
      const result = await api("/v1/links/simplefin", { method: "POST", body: { setupToken: token } });
      input.value = "";
      announce(linked(result), where);
      await afterWrite();
    }, { errorTarget: where }) })));
  const links = ((store.summary && store.summary.links) || []).filter((l) => l.provider === "simplefin");
  if (links.length) panel.append(...links.map((l) => simplefinLinkPanel(l, where, { named: links.length > 1 })));
  panel.append(h("p", { class: "help" }, "SimpleFIN gives no warning before a bank wants you to sign in again: the first sync that fails is the signal, and this page and the phone name the bank. ",
    "SimpleFIN refreshes about once a day, so the server asks a few times a day at most."));
}

/// One SimpleFIN link: its banks (or the link itself, until the server reports banks), the day's requests, and for a
/// link SimpleFIN no longer accepts, the box for a new setup token. With several links, each is headed by its name.
function simplefinLinkPanel(l, where, { named = false } = {}) {
  const perBank = !!(l.banks && l.banks.length);
  const banks = perBank ? l.banks
    : [{ id: l.id, name: l.institution, status: l.status, errorKind: l.errorKind, lastGoodAt: l.lastSync }];
  // A failed request with no bank to blame (the Bridge was down, say) covers every bank.
  const linkFailed = !!l.lastError && !(perBank && banks.some((b) => b.errorKind));
  const rows = banks.map((b) => {
    const kind = l.errorKind === "revoked" ? "revoked" : b.errorKind || (linkFailed ? l.errorKind || "transient" : null);
    // Withdrawn access isn't fixed by signing in at the Bridge, only by a new setup token (the box below).
    const signIn = kind !== "revoked" && (b.status === "needsReauth" || kind === "needsSignIn");
    const state = kind === "revoked" ? "Access withdrawn" : signIn ? "Needs you to sign in on SimpleFIN Bridge"
      : kind ? "Last sync failed, retrying" : "Connected";
    return h("div", { class: "row" },
      h("div", { class: "grow" },
        h("div", { class: "title" }, b.name),
        h("div", { class: "sub" }, [state, b.lastGoodAt ? `last good data ${dateTime(b.lastGoodAt)}` : "no data yet"].join(" · "))),
      signIn ? h("a", { class: "btn secondary compact", href: BRIDGE, target: "_blank", rel: "noopener", "aria-label": `Fix ${b.name} on SimpleFIN Bridge` }, "Fix on SimpleFIN Bridge") : null);
  });
  return h("section", { class: "stack", "aria-label": `${l.institution} banks` },
    // Several links usually share the name "SimpleFIN Bridge"; when each was linked tells them apart.
    named ? h("h3", { class: "t-eyebrow" }, l.createdAt ? `${l.institution} · linked ${dateTime(l.createdAt)}` : l.institution) : null,
    h("div", { class: "rows" }, rows),
    l.requestsToday != null ? h("p", { class: "help" }, `Requests today: ${l.requestsToday} of ${SIMPLEFIN_DAILY_LIMIT}`) : null,
    simplefinReconnectAction(l, { where }),
    h("p", { class: "help" }, unlinkNote(l)));
}

/// For a SimpleFIN link whose access SimpleFIN withdrew: "Paste a new setup token", which keeps the link (and its
/// accounts and history) and only replaces the sealed access address (PUT /v1/links/:id/token). Null for any other
/// link. accounts.js shows it on the bank's card in place of the generic Try again, and its Reconnect buttons focus it.
export function simplefinReconnectAction(l, { where } = {}) {
  if (l.provider !== "simplefin" || l.errorKind !== "revoked") return null;
  const input = h("input", { class: "input", placeholder: "New setup token", ...secretAttrs, dataset: { setupToken: l.id },
    "aria-label": `New SimpleFIN setup token for ${l.institution}` });
  return callout({ tone: "act", title: "SimpleFIN no longer accepts this server's access",
    body: ["Create a new setup token at ", extLink(BRIDGE), " and paste it here. The link keeps its accounts and history."],
    actions: [h("div", { class: "secret-row" }, input, button("Paste a new setup token", { kind: "primary", compact: true, onclick: (e) => busy(e.currentTarget, "Replacing…", async () => {
      const token = input.value.trim();
      if (!token) throw new Error("Paste the new setup token first.");
      const result = await api(`/v1/links/${encodeURIComponent(l.id)}/token`, { method: "PUT", body: { setupToken: token } });
      input.value = "";
      announce(reconnected(result), where);
      if (result.note) toast(result.note);
      await afterWrite();
    }, { errorTarget: where }) }))] });
}

/// What removing a link here doesn't do at the provider, or null. SimpleFIN has no call to revoke an access address,
/// so the server forgets it and the person removes the app at the Bridge.
export function unlinkNote(l) {
  if (l.provider !== "simplefin") return null;
  return `Removing this link deletes the server's access. To stop SimpleFIN sharing with this server too, remove it from your apps at ${BRIDGE}.`;
}

/// Left/right arrows move between tabs (the ARIA tabs pattern).
export function arrowKeys(event, list, select) {
  if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
  const items = [...list.querySelectorAll("[role=tab]")].filter((b) => !b.hidden);
  const i = items.indexOf(event.currentTarget);
  const next = event.key === "Home" ? 0 : event.key === "End" ? items.length - 1 : (i + (event.key === "ArrowRight" ? 1 : -1) + items.length) % items.length;
  event.preventDefault();
  select(items[next].dataset.id, true);
}

/// Inside a framed window (the Olares desktop's) the bank's sign-in pages misbehave; say so and offer a real tab.
export function framedNote() {
  if (window.top === window.self) return null;
  return callout({ tone: "watch", role: "note", title: "Open this in its own tab to link a bank",
    body: "Bank sign-in pages don't run well inside an embedded window.",
    actions: [h("a", { class: "btn secondary compact", href: location.href, target: "_blank", rel: "noopener" }, "Open in a new tab")] });
}

