// Bank providers: Plaid, Teller and SimpleFIN. The key forms here are shared by the Connect-a-bank drawer
// (Accounts) and Settings → Bank providers, and the Link flows run only in this dashboard.
import { fill, h, api, store, heavy, cached, forget, afterWrite, toast, callout, button, busy, armed, tag, plural, reportError, secretAttrs } from "./core.js";

const PLAID_JS = "https://cdn.plaid.com/link/v2/stable/link-initialize.js";
const TELLER_JS = "https://cdn.teller.io/connect/connect.js";

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
  if (!body) return { plaid: { label: "Checking", tone: "", ready: false }, teller: { label: "Checking", tone: "", ready: false }, simplefin: sealing ? { label: "Ready", tone: "ok", ready: true } : noKey };
  const p = body.providers.plaid, t = body.providers.teller;
  const plaid = !sealing ? noKey : p.origin === "none" ? { label: "Needs keys", tone: "", ready: false }
    : { label: p.environment === "production" ? "Ready" : "Ready · sandbox", tone: "ok", ready: true };
  const teller = !sealing ? noKey : t.origin === "none" || !t.applicationID ? { label: "Needs keys", tone: "", ready: false }
    : t.environment !== "sandbox" && !t.hasCertificate ? { label: "Needs certificate", tone: "watch", ready: false }
    : { label: t.environment === "sandbox" ? "Ready · sandbox" : "Ready", tone: "ok", ready: true };
  return { plaid, teller, simplefin: sealing ? { label: "Ready", tone: "ok", ready: true } : noKey };
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

const field = (label, input, help, wide) => h("label", { class: `field${wide ? " wide" : ""}` }, h("span", { class: "field-head" }, label), input, help ? h("span", { class: "help" }, help) : null);

/// Plaid's keys. `onChange` is told whenever a value changes (Settings counts unsaved changes with it).
export function plaidForm({ onChange } = {}) {
  const body = cached("providers"), p = body.providers.plaid;
  const client = h("input", { class: "input", ...secretAttrs, placeholder: "24 characters, 0–9 and a–f", value: p.clientID || "", "aria-describedby": "plaid-client-help" });
  const env = h("select", { class: "input" }, h("option", { value: "sandbox" }, "Sandbox (test data)"), h("option", { value: "production" }, "Production (your real banks)"));
  env.value = p.environment || "sandbox";
  const secret = h("input", { class: "input", type: "password", ...secretAttrs, placeholder: p.origin === "dashboard" ? "Saved — leave empty to keep it" : "" });
  const redirect = h("input", { class: "input", spellcheck: "false", autocomplete: "off", value: p.redirectURI || body.suggestedRedirectURI || "" });
  const initial = { client: client.value, env: env.value, redirect: redirect.value };
  for (const el of [client, env, secret, redirect]) el.addEventListener("input", () => onChange && onChange());
  const el = h("div", { class: "stack" },
    h("div", { class: "form" },
      field("Client ID", client, "Plaid → Developers → Keys. It names this app; it isn't a password."),
      field("Environment", env),
      field("Secret for that environment", secret, null, true),
      field("Return address for banks that sign in on their own site", redirect,
        "Add this exact address under Allowed redirect URIs in Plaid. Chase, Schwab and other OAuth banks come back here to finish.", true)),
    h("p", { class: "help" }, "Keys: ", h("a", { href: "https://dashboard.plaid.com/developers/keys", target: "_blank", rel: "noopener" }, "https://dashboard.plaid.com/developers/keys"),
      " · Redirect addresses: ", h("a", { href: "https://dashboard.plaid.com/developers/api", target: "_blank", rel: "noopener" }, "https://dashboard.plaid.com/developers/api")),
    originNote(p.origin) ? h("p", { class: "help" }, originNote(p.origin)) : null);
  return {
    el,
    changes: () => [client.value.trim() !== initial.client, env.value !== initial.env, !!secret.value.trim(), redirect.value.trim() !== initial.redirect].filter(Boolean).length,
    /// A sentence saying what's wrong, or null.
    validate() {
      const id = client.value.trim(), s = secret.value.trim();
      if (!/^[0-9a-f]{24}$/i.test(id)) return `That isn't a Plaid client ID: it's 24 characters of 0–9 and a–f, and ${id.length} are entered. A password manager may have filled it.`;
      if (s && !/^[0-9a-f]{20,64}$/i.test(s)) return `That isn't a Plaid secret: it's about 30 characters of 0–9 and a–f, and ${s.length} are entered.`;
      if (p.origin === "none" && !s) return "Add the secret for that environment too.";
      return null;
    },
    /// Saves, then asks Plaid for a Link token to prove the keys work. Resolves to { ok, message }.
    async save() {
      await api("/dash/providers/plaid", { method: "PUT", body: { clientID: client.value.trim(), secret: secret.value.trim() || null,
        environment: env.value, redirectURI: redirect.value.trim() || null } });
      secret.value = "";
      forget("providers");
      try { await api("/v1/links/plaid/token", { method: "POST", body: {} }); return { ok: true, message: "Saved, and Plaid accepted the keys." }; }
      catch (error) { return { ok: false, message: "Saved, but Plaid turned the keys down.", detail: error.detail || error.message }; }
    },
  };
}

/// Teller's application and client certificate.
export function tellerForm({ onChange } = {}) {
  const t = cached("providers").providers.teller;
  const app = h("input", { class: "input", placeholder: "app_…", autocomplete: "off", spellcheck: "false", value: t.applicationID || "" });
  const env = h("select", { class: "input" }, h("option", { value: "sandbox" }, "Sandbox (test data)"), h("option", { value: "development" }, "Development (real banks, free)"),
    h("option", { value: "production" }, "Production"));
  env.value = t.environment || "sandbox";
  const cert = h("input", { class: "input", type: "file", accept: ".pem,.crt" }), key = h("input", { class: "input", type: "file", accept: ".pem,.key" });
  const initial = { app: app.value, env: env.value };
  for (const el of [app, env, cert, key]) { el.addEventListener("input", () => onChange && onChange()); el.addEventListener("change", () => onChange && onChange()); }
  const el = h("div", { class: "stack" },
    h("div", { class: "form" },
      field("Application ID", app), field("Environment", env),
      field("Certificate (certificate.pem)", cert, t.hasCertificate ? "One is saved. Choose a file only to replace it." : null),
      field("Private key (private_key.pem)", key, "Sealed on the server as soon as it's saved.")),
    h("p", { class: "help" }, "From ", h("a", { href: "https://teller.io/dashboard", target: "_blank", rel: "noopener" }, "https://teller.io/dashboard"),
      ": the application ID and the two files in teller.zip. Sandbox needs no certificate; real banks do."),
    originNote(t.origin) ? h("p", { class: "help" }, originNote(t.origin)) : null);
  return {
    el,
    changes: () => [app.value.trim() !== initial.app, env.value !== initial.env, !!cert.files.length, !!key.files.length].filter(Boolean).length,
    validate: () => (!app.value.trim() ? "Add Teller's application ID." : !!cert.files.length !== !!key.files.length ? "Choose both the certificate and the private key." : null),
    async save() {
      const summary = await api("/dash/providers/teller", { method: "PUT", body: { applicationID: app.value.trim(), environment: env.value,
        certificatePEM: cert.files[0] ? await cert.files[0].text() : null, keyPEM: key.files[0] ? await key.files[0].text() : null } });
      cert.value = ""; key.value = "";
      forget("providers");
      return { ok: true, message: summary.teller.hasCertificate ? "Saved, with the certificate." : "Saved. Sandbox works without a certificate." };
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
      toast(provider === "plaid" ? "Plaid keys removed" : "Teller setup removed");
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

/// Plaid Link. A new link trades Link's public token for an Item. `update` (a link waiting for a sign-in) opens
/// Link in update mode for that Item instead: the person signs in again, and finishing just syncs the link, so its
/// accounts and history carry on (there's nothing to exchange). Banks that sign in on their own site (OAuth) leave
/// the page and come back with `?oauth_state_id=…`; `resume` picks the same session up again (the Link token and
/// the link being repaired are kept in sessionStorage). Resolves once Link closes and its outcome is shown.
/// `grant` (with `update`) is the same update mode asking the person to add card-bill access (Plaid Liabilities) to
/// that Item: same Item, same access, nothing exchanged. Only a click on "Grant card-bill access" starts it.
export async function linkPlaid({ resume = false, update = null, grant = false, where } = {}) {
  let token, linkID;
  store.pending++;
  try {
    await loadScript(PLAID_JS);
    linkID = resume ? sessionStorage.getItem("plaidUpdateLink") : update ? update.id : null;
    if (resume) grant = sessionStorage.getItem("plaidGrant") === "1";
    token = resume ? sessionStorage.getItem("plaidLinkToken")
      : (await api("/v1/links/plaid/token", { method: "POST", body: linkID ? (grant ? { linkID, grantCardBills: true } : { linkID }) : {} })).linkToken;
  } catch (error) { reportError(error, where); return; }
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
  await new Promise((finish) => {
    window.Plaid.create({
      token, receivedRedirectUri: resume ? location.href : undefined,
      onSuccess: async (publicToken, metadata) => {
        clean();
        toast(grant ? "Card-bill access granted. Checking…" : linkID ? "Signed in. Syncing…" : "Linking and syncing…");
        try {
          const result = linkID
            ? await api(`/v1/links/${encodeURIComponent(linkID)}/sync`, { method: "POST" })
            : await api("/v1/links/plaid/exchange", { method: "POST", body: { publicToken, institution: (metadata.institution && metadata.institution.name) || "Plaid" } });
          announce(grant ? granted(result) : linkID ? reconnected(result) : linked(result), where);
        } catch (error) { reportError(error, where); }
        await afterWrite();
        finish();
      },
      onExit: (err) => {
        clean();
        if (err) reportError({ message: err.display_message || "The bank sign-in closed before it finished.", detail: [err.error_code, err.error_message].filter(Boolean).join(": ") }, where);
        finish();
      },
    }).open();
  });
}

/// Teller's reconnect: Connect reopens the same enrollment, and the access token it hands back replaces the stored
/// one (PUT /v1/links/:id/token), which syncs the link. Resolves once Connect closes and its outcome is shown.
export async function relinkTeller(link, { where } = {}) {
  store.pending++;
  try { await Promise.all([loadScript(TELLER_JS), heavy("providers")]); }
  catch (error) { reportError(error, where); return; }
  finally { store.pending--; }
  const t = cached("providers").providers.teller;
  if (!t.applicationID) { reportError({ message: "Teller isn't set up on this server anymore. Add its application ID in Settings, under Bank providers." }, where); return; }
  if (!link.externalID) { reportError({ message: `This server doesn't know which Teller connection ${link.institution} is, so it can't reopen it. Remove the connection and connect ${link.institution} again; its history stays.` }, where); return; }
  await new Promise((finish) => {
    window.TellerConnect.setup({
      applicationId: t.applicationID, environment: t.environment || "sandbox", products: ["transactions", "balance"], enrollmentId: link.externalID,
      onSuccess: async (enrollment) => {
        toast("Signed in. Syncing…");
        try {
          const e = enrollment.enrollment || {};
          const result = await api(`/v1/links/${encodeURIComponent(link.id)}/token`, { method: "PUT", body: { accessToken: enrollment.accessToken, enrollmentID: e.id || link.externalID } });
          announce(reconnected(result), where);
        } catch (error) { reportError(error, where); }
        await afterWrite();
        finish();
      },
      onExit: () => finish(),
      onFailure: (failure) => { reportError({ message: "Teller couldn't finish signing in.", detail: failure && failure.message }, where); finish(); },
    }).open();
  });
}

export async function linkTeller({ where } = {}) {
  store.pending++;
  try {
    await loadScript(TELLER_JS);
    const t = cached("providers").providers.teller;
    window.TellerConnect.setup({
      applicationId: t.applicationID, environment: t.environment || "sandbox", products: ["transactions", "balance"],
      onSuccess: async (enrollment) => {
        toast("Linking and syncing…");
        try {
          const e = enrollment.enrollment || {};
          const result = await api("/v1/links/teller", { method: "POST", body: { accessToken: enrollment.accessToken, enrollmentID: e.id,
            institution: (e.institution && e.institution.name) || "Teller" } });
          announce(linked(result), where);
        } catch (error) { reportError(error, where); }
        await afterWrite();
      },
      onFailure: (failure) => reportError({ message: "Teller couldn't finish linking.", detail: failure && failure.message }, where),
    }).open();
  } catch (error) { reportError(error, where); }
  finally { store.pending--; }
}

// MARK: The Connect panes (drawer)

const PANES = [
  ["plaid", "Plaid", "Most US and Canadian banks, cards and brokerages."],
  ["teller", "Teller", "Chase and other large US banks, with no approval wait."],
  ["simplefin", "SimpleFIN", "Any bank SimpleFIN Bridge supports, for a small yearly fee paid to them."],
];

/// Tabs for the three providers, each with its status, a Link button and (for Plaid and Teller) its keys.
export function connectPanes({ where, selected } = {}) {
  const states = providerStates();
  const first = selected || (states.plaid.ready ? "plaid" : states.teller.ready ? "teller" : "plaid");
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
  root.append(tabs);
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

function renderPane(panel, id, name, blurb, where, rerender) {
  const state = providerStates()[id];
  panel.append(h("p", { class: "t-callout muted" }, blurb));
  if (id === "simplefin") {
    const input = h("input", { class: "input", placeholder: "Setup token", ...secretAttrs, "aria-label": "SimpleFIN setup token" });
    panel.append(
      h("p", { class: "help" }, "Get a setup token from ", h("a", { href: "https://beta-bridge.simplefin.org", target: "_blank", rel: "noopener" }, "https://beta-bridge.simplefin.org"),
        ". It works once: the server trades it for an access address and seals it."),
      h("div", { class: "secret-row" }, input, button("Link", { kind: "primary", disabled: !state.ready, onclick: (e) => busy(e.currentTarget, "Linking…", async () => {
        const token = input.value.trim();
        if (!token) throw new Error("Paste the setup token first.");
        const result = await api("/v1/links/simplefin", { method: "POST", body: { setupToken: token } });
        input.value = "";
        announce(linked(result), where);
        await afterWrite();
      }, { errorTarget: where }) })));
    return;
  }
  const link = button("Link an account", { kind: "primary", disabled: !state.ready,
    onclick: () => (id === "plaid" ? linkPlaid({ where }) : linkTeller({ where })) });
  panel.append(h("div", { class: "actions" }, link));
  if (!cached("providers")) return;
  const form = id === "plaid" ? plaidForm() : tellerForm();
  const result = h("div");
  const keys = h("details", { class: "fold", open: !state.ready && state.label !== "Needs encryption key" },
    h("summary", {}, h("span", { class: "grow" }, id === "plaid" ? "Keys" : "Application and certificate")),
    h("div", { class: "fold-body" }, form.el,
      h("div", { class: "actions" },
        button(id === "plaid" ? "Save and test" : "Save", { kind: "secondary", disabled: !cached("providers").providers.sealingAvailable, onclick: (e) => busy(e.currentTarget, "Saving…", async () => {
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

