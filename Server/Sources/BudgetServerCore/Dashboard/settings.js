// Settings: what each job runs on (Models), how categorizing files, then the server's own settings, two short sections
// to a row where the page is wide enough. One sticky save bar holds everything editable here except the list of models
// itself: adding, changing and removing one saves right away, in a drawer (as rules do), while which one each job uses is
// a pick that waits for Save. A value's source shows only when it isn't the default. Removing data is its own guarded
// action at the bottom and never rides the save bar.
import { fill, h, api, store, heavy, cached, loadCore, pageHead, sectionHead, button, busy, armed, callout, details, tag, afterWrite,
  reportError, toast, plural, ago, duration, dateTime, nextSyncIn, skeleton, loadInto, dot, money, drawer, closeDrawer, secretAttrs } from "./core.js";
import { plaidForm, tellerForm, removeKeysButton, providerStates } from "./providers.js";

/// Plain names for the server's settings (the server's own label and help are the fallback).
const LABELS = {
  openRouterKey: ["OpenRouter key", "Jev runs in the cloud through OpenRouter, on your own account. The key stays on this server. A chat model on OpenRouter can use it too."],
  openRouterZeroRetention: ["Only providers that keep nothing", "Asks OpenRouter to route only to providers with zero data retention: for Jev, and for a chat model on OpenRouter."],
  syncIntervalHours: ["Sync linked banks", "How often the server pulls new transactions from every linked bank."],
  timeZone: ["Time zone", "Where months begin and end."],
  publicURL: ["Server URL", "What the phone connects to. The Olares app fills this in; change it only if you reach the server another way."],
  dashboardURL: ["Dashboard address for the phone", "Where Open dashboard in the phone's Settings goes. Usually this page's own address."],
  apnsKey: ["APNs key", "The .p8 file's text, from developer.apple.com → Certificates, IDs & Profiles → Keys, with Apple Push Notifications service on. Pasting it all on one line is fine. It's saved encrypted."],
  apnsKeyID: ["Key ID", "The 10-character ID shown beside that key."],
  apnsTeamID: ["Team ID", "Your Apple Developer team."],
  apnsTopic: ["App bundle ID", "The app the notifications are for."],
};
/// Where each server setting lives on this page; a setting the server adds later lands in its group's section.
const GROUP_SECTION = { Models: "models", Jev: "models", Sync: "sync", Phone: "phone", Notifications: "notifications" };
/// Jev's settings live in its drawer (Models → Jev): the page takes them without showing them, and they never ride the save bar.
const JEV_KEYS = ["openRouterKey", "openRouterZeroRetention"];
const INTERVALS = [["0.25", "Every 15 minutes"], ["1", "Every hour"], ["3", "Every 3 hours"], ["6", "Every 6 hours"], ["12", "Every 12 hours"], ["24", "Once a day"]];
const ORIGIN_TAG = { environment: ["From the Olares app", ""], dashboard: ["Set here", "info"] };

let uid = 0;
const nextID = (key) => `set-${key}-${++uid}`;

/// One server setting: its input, where its value comes from, Reset (to the Olares app or default) and
/// Turn off, all held until Save. `locked` replaces Reset and Turn off with a line saying why they can't be used now;
/// `disabled` keeps the input itself off (a key with no encryption key to save it), whatever is held or kept.
function settingControl(f, onChange, { locked = null, disabled = false } = {}) {
  const [label, help] = LABELS[f.key] || [f.label, f.help];
  const id = nextID(f.key);
  let pending;  // undefined: nothing pending; null: reset; "": turn off
  let input;
  if (f.kind === "bool") input = h("input", { type: "checkbox", class: "switch", id, checked: f.value === "true" });
  else if (f.kind === "secret") input = h("input", { class: "input", type: "password", id, ...secretAttrs, autocomplete: "new-password",
    placeholder: f.isSet ? "Saved — type a new one to replace it" : "Not set" });
  else if (f.key === "syncIntervalHours") {
    const current = String(Number(f.value || f.defaultValue || 6));
    const options = INTERVALS.some(([v]) => v === current) ? INTERVALS : [...INTERVALS, [current, `Every ${current} hours`]];
    input = h("select", { class: "input", id, value: current }, options.map(([v, l]) => h("option", { value: v }, l + (v === String(Number(f.defaultValue)) ? " (default)" : ""))));
  } else input = h("input", { class: "input", id, value: f.value || "", spellcheck: "false", autocomplete: "off", list: f.kind === "timeZone" ? "tz-list" : null,
    inputmode: f.kind === "number" ? "decimal" : f.kind === "url" ? "url" : null,
    placeholder: f.kind === "url" ? (f.key === "publicURL" ? "https://…" : f.key === "dashboardURL" ? "Not set" : "Off") : (f.defaultValue || "") });
  input.disabled = disabled;
  const value = () => (f.kind === "bool" ? (input.checked ? "true" : "false") : input.value.trim());
  const initial = f.kind === "secret" ? "" : f.kind === "bool" ? (f.value === "true" ? "true" : "false") : value();
  const note = h("span", { class: "help pending-note" });
  // Keep it puts the keyboard back on the button that held the change (Keep it itself goes).
  const hold = (next, text, from) => {
    pending = next; input.disabled = true;
    fill(note, text, " ", button("Keep it", { kind: "quiet", onclick: () => { pending = undefined; input.disabled = disabled; fill(note); from.focus(); onChange(); } }));
    onChange();
  };
  const [originLabel, originTone] = ORIGIN_TAG[f.origin] || [];
  const head = h("div", { class: "field-head" }, f.kind === "bool" ? null : h("label", { for: id }, label), h("span", { class: "grow" }),
    originLabel ? tag(originLabel, originTone) : null,
    !locked && f.origin === "dashboard" ? button("Reset", { kind: "quiet", "aria-label": `Reset ${label}`, onclick: (e) => hold(null, "Goes back to the Olares app's setting or the default when you save.", e.currentTarget) }) : null,
    !locked && (f.kind === "secret" || f.kind === "url") && f.isSet ? button("Turn off", { kind: "quiet", "aria-label": `Turn off ${label}`, onclick: (e) => hold("", "Turns off when you save.", e.currentTarget) }) : null,
    f.key === "dashboardURL" && !f.isSet && !f.value ? button("Use this page's address", { kind: "quiet", onclick: () => { input.value = location.origin + "/"; onChange(); } }) : null);
  input.addEventListener(f.kind === "bool" || input.tagName === "SELECT" ? "change" : "input", onChange);
  const body = f.kind === "bool"
    ? h("label", { class: "check", for: id }, input, h("span", {}, label, h("span", { class: "help" }, help)))
    : [input, h("span", { class: "help" }, help)];
  return {
    key: f.key, group: f.group, field: f, input,
    el: h("div", { class: "field" }, head, body, locked ? h("span", { class: "help" }, locked) : null, note),
    /// What the field holds now, saved or not: "" for a secret nobody typed (the saved one stands), "" for Turn off.
    current: () => (pending === "" ? "" : value()),
    /// Puts a value in, as if typed.
    set: (next) => { pending = undefined; input.disabled = disabled; fill(note); input.value = next; onChange(); },
    changes: () => (pending !== undefined ? 1 : f.kind === "secret" ? (value() ? 1 : 0) : value() !== initial ? 1 : 0),
    change: () => (pending !== undefined ? { [f.key]: pending } : (f.kind === "secret" ? value() : value() !== initial) ? { [f.key]: value() } : {}),
  };
}

// MARK: Picks

/// Categorizing's picks that are a policy provider of their own. Every other pick is a server (the chat model's, the Olares
/// app's, or one added here), which categorizing uses as Qwen Decide.
const PROVIDER_PICKS = ["off", "jev", "laya"];
const providerFor = (pick) => (PROVIDER_PICKS.includes(pick) ? pick : "localDecide");
const isServerPick = (pick) => !PROVIDER_PICKS.includes(pick);
/// The categorizing pick the server runs now: the policy's provider, or for Qwen Decide the server it decides on.
const savedCategorizing = (policy, list) => (policy.provider === "localDecide" ? list.decisionInUse : policy.provider);
/// A categorizing pick in words, for "Runs on …" and "Ask Jev when … is unsure".
function pickName(pick) {
  if (pick === "chat") return "the chat model's server";
  if (pick === "jev") return "Jev";
  if (pick === "laya") return "Laya";
  const e = ((cached("models") || {}).decision || []).find((x) => x.id === pick);
  return e ? e.name : "the local model";
}
/// "switchboard.example" (with its port, if it has one) for an address.
function hostOf(address) {
  try { return new URL(address).host; } catch { return null; }
}
function originOf(address) {
  try { return new URL(address).origin; } catch { return null; }
}
/// The host without its port: what the server names a categorizing server after.
function hostnameOf(address) {
  try { return new URL(address).hostname; } catch { return null; }
}
const OPENROUTER = "https://openrouter.ai/api/v1";
/// openrouter.ai over https: the one place a chat model can take Jev's OpenRouter key (the server checks this too).
function isOpenRouter(address) {
  try { const u = new URL(address); return u.protocol === "https:" && (u.hostname === "openrouter.ai" || u.hostname.endsWith(".openrouter.ai")); } catch { return false; }
}

/// The categorization policy: how sure the model must be, Ask Jev when unsure, and what comes to you anyway. Where it runs
/// is a row in Models (`picks.categorizing`), read from there and counted here once, whether the pick moves the provider,
/// the server, or both. "Ask Jev when unsure" (`jevLabel`) shows in Models, under the picks it goes with.
/// - hasJevKey: whether an OpenRouter key is saved.
function policyControl(onChange, { picks, hasJevKey }) {
  const p = store.status.decisionPolicy;
  const pct = h("input", { type: "range", id: "pol-pct", min: "50", max: "99", step: "1", value: String(p.autoAcceptPercent), "aria-describedby": "pol-pct-help" });
  const out = h("output", { for: "pol-pct" }, `${p.autoAcceptPercent}%`);
  const savedJev = !!p.escalateToJev && (store.status.availableDecisionProviders || []).includes("jev");
  const jev = h("input", { type: "checkbox", class: "switch", id: "pol-jev", checked: savedJev });
  const rerun = h("input", { type: "checkbox", id: "pol-rerun" });
  // What comes to you even when something could file it: new merchants, big amounts, pending charges.
  const newMerchants = h("input", { type: "checkbox", class: "switch", id: "pol-new", checked: !!p.reviewNewMerchants });
  const big = h("input", { type: "checkbox", class: "switch", id: "pol-big", checked: p.reviewAbove != null });
  const savedAbove = p.reviewAbove != null ? String(Number(p.reviewAbove)) : "";
  const above = h("input", { class: "input above", id: "pol-above", inputmode: "decimal", value: savedAbove || "500", "aria-label": "Amount", "aria-describedby": "pol-big-help" });
  const pending = h("input", { type: "checkbox", class: "switch", id: "pol-pending", checked: !!p.holdPending });
  const newLabel = h("label", { class: "check", for: "pol-new" }, newMerchants, h("span", {}, "Check new merchants before they're filed", h("span", { class: "help new-help" })));
  const aboveAmount = () => { const v = above.value.replace(/[$,\s]/g, ""); return /^\d{1,9}(\.\d{1,2})?$/.test(v) && Number(v) > 0 ? v : null; };
  const jevName = h("span");
  const jevHelp = h("span", { class: "help" });
  const jevLabel = h("label", { class: "check", for: "pol-jev" }, jev, h("span", {}, jevName, jevHelp));
  // Where it runs, in a line that goes to the picks (and wraps: it can hold a 60-character server name). With the address
  // already there, the click alone wouldn't move the page, so it scrolls itself.
  const runsOn = h("a", { class: "btn quiet runs-on", href: "#/settings/categorizing", onclick: (e) => {
    if (location.hash !== "#/settings/categorizing") return;
    e.preventDefault();
    const target = document.getElementById("section-categorizing");
    if (target) target.scrollIntoView({ block: "start" });
  } });
  const sync = () => {
    const pick = picks.categorizing, off = pick === "off", local = !off && pick !== "jev";
    newMerchants.disabled = off;
    newLabel.classList.toggle("disabled", newMerchants.disabled);
    newLabel.querySelector(".new-help").textContent = newMerchants.disabled
      ? "Only with a decision model: without one, everything new comes to you anyway."
      : "The model's first answer for a merchant waits for you, however sure it is. After you file one, the rest follow.";
    above.disabled = !big.checked;
    // Only for a model on the Olares (or a server like it): Jev can't ask itself.
    jev.disabled = !local;
    jevLabel.hidden = !local;
    jevLabel.classList.toggle("disabled", jev.disabled);
    jevName.textContent = `Ask Jev when ${local ? pickName(pick) : "the local model"} is unsure`;
    jevHelp.textContent = !hasJevKey() ? "Needs an OpenRouter key: Jev → Add a key, above."
      : "Only merchant names leave the Olares, and only for what it's unsure about.";
    runsOn.textContent = off ? "Off: everything waits for you. Turn it on in Models, above." : `Runs on ${pickName(pick)}. Change it in Models, above.`;
    pct.disabled = off;
    out.textContent = `${pct.value}%`;
    onChange();
  };
  for (const el of [jev, rerun, newMerchants, big, pending]) el.addEventListener("change", sync);
  for (const el of [pct, above]) el.addEventListener("input", sync);
  sync();
  const changed = () => ({ pick: picks.categorizing !== picks.saved.categorizing, provider: providerFor(picks.categorizing) !== p.provider,
    pct: Number(pct.value) !== p.autoAcceptPercent, jev: !jev.disabled && jev.checked !== savedJev,
    newMerchants: !newMerchants.disabled && newMerchants.checked !== !!p.reviewNewMerchants,
    // Something unreadable counts as a change, so Save can say what's wrong with it.
    above: big.checked ? aboveAmount() === null || Number(aboveAmount()) !== Number(savedAbove || NaN) : savedAbove !== "",
    pending: pending.checked !== !!p.holdPending });
  return {
    /// "Ask Jev when unsure", for Models.
    jevLabel,
    sync,
    el: h("div", { class: "stack" },
      runsOn,
      h("div", { class: "field" }, h("div", { class: "field-head" }, h("label", { for: "pol-pct" }, "Files on its own when at least this sure")),
        h("div", { class: "range-row" }, pct, out), h("span", { class: "help", id: "pol-pct-help" }, "Anything below waits for you in Needs a category, here or on your phone. Between 50% and 99%.")),
      h("label", { class: "check", for: "pol-rerun" }, rerun, h("span", {}, "Also re-check what's waiting when I save",
        h("span", { class: "help" }, `${plural(store.overview.reviewCount, "transaction")} waiting now.`))),
      h("a", { class: "btn quiet", href: "#/review/recheck" }, "Re-check what the model already filed"),
      h("div", { class: "subsection" },
        h("h3", { class: "t-eyebrow card-title" }, "What comes to you anyway"),
        newLabel,
        h("div", { class: "check-with" },
          h("label", { class: "check", for: "pol-big" }, big, h("span", {}, "Check big amounts before they're filed")),
          h("div", { class: "above-row" }, h("span", { class: "help" }, "Anything over $"), above),
          h("span", { class: "help", id: "pol-big-help" }, "Each one comes to you on its own. Your rules, matched transfers and your own answers still file on their own.")),
        h("label", { class: "check", for: "pol-pending" }, pending, h("span", {}, "Wait for pending charges to post",
          h("span", { class: "help" }, "Pending charges stay out of Needs a category until the bank settles them, when the amount is final."))),
        h("a", { class: "btn quiet", href: "#/categories/rules" }, "Rules that file transactions for you"))),
    /// The categorizing pick is one change, whatever it moves.
    changes: () => { const c = changed(); return [c.pick, c.pct, c.jev, rerun.checked, c.newMerchants, c.above, c.pending].filter(Boolean).length; },
    /// Whether the policy itself changes: a pick from one server to another is Models' alone (`/dash/models/use`).
    needsAction: () => { const c = changed(); return [c.provider, c.pct, c.jev, rerun.checked, c.newMerchants, c.above, c.pending].some(Boolean); },
    /// A problem with what's typed, or null.
    validate: () => (big.checked && aboveAmount() === null ? "The amount to check above is in dollars, like 500." : null),
    body: () => {
      const c = changed(), body = { type: "updateDecisionPolicy", rerunPending: rerun.checked };
      if (c.provider) body.provider = providerFor(picks.categorizing);
      if (c.pct) body.autoAcceptPercent = Number(pct.value);
      // Only when it can be chosen: a disabled box must never rewrite the saved setting.
      if (c.jev) body.escalateToJev = jev.checked;
      if (c.newMerchants) body.reviewNewMerchants = newMerchants.checked;
      if (c.above) body.reviewAbove = big.checked ? aboveAmount() : "0";
      if (c.pending) body.holdPending = pending.checked;
      return body;
    },
  };
}

// MARK: Models

const TEST_LINE = "Each gets a one-word question or a made-up coffee charge, nothing from your ledger.";
const NO_ADDRESS = "No address now: the Olares app stopped setting one";
/// What the last test found, by what was tested: the job, the entry, its address and model, and whether it had a key. It
/// outlasts a redraw and a refresh, and an entry that has changed since shows no answer rather than an old one.
const results = new Map();
const resultKey = (job, id, address, model, hasKey) => [job, id, address || "", model || "", hasKey ? "key" : ""].join(":");
const statusTag = (o) => (!o ? null : o.testing ? tag("Testing…") : o.off ? tag("Off")
  : o.ok ? tag(o.milliseconds != null ? `Working · ${(o.milliseconds / 1000).toFixed(1)} s` : "Working", "ok") : tag("Not working", "act"));
const showOutcome = (el, o) => fill(el, statusTag(o), o && o.detail ? h("span", { class: "help" }, o.detail) : null);
const sealingHelp = () => [h("span", { class: "help" }, "Add an encryption key in the Budget app's settings on the Olares, then restart it."),
  details("Details", "Set BUDGET_TOKEN_KEY to the output of: openssl rand -base64 32")];

/// Models: a block per job, each a list of what it can run on with a radio for the one it uses (`picks`). A pick waits
/// for Save: a radio's arrow keys pick as they move, so saving each one would switch the live model at every step. Add,
/// Edit and Remove act at once, in a drawer, and the rows are redrawn around the same picks. Categorizing's list also holds
/// the policy's own choices (the chat model's server, Jev, Off), so its pick is the provider and the server in one; the
/// policy counts and saves that part.
/// - otherChanges: how many changes the page holds, for a drawer's toast.
/// - rerender: draws the whole page again, when the list can't be loaded.
/// - current: the page's Models card now. A Save or Discard draws a new one, so a drawer or a test that outlives this
///   card (opened or started before) shows what it did on that one.
function modelsCard({ picks, policy, onChange, otherChanges, rerender, current }) {
  // The list the rows were last drawn from stands in while a new one loads, so a pick, Test or Add meanwhile has one.
  let drawn = null;
  const list = () => cached("models") || drawn;
  const entry = (kind, id) => (kind === "chat" ? list().chat : list().decision).find((e) => e.id === id) || null;
  /// Where a chat pick sends, or null: Off, or an entry whose address came from the Olares app and is gone.
  const chatAddress = (id) => (id === "off" ? null : (entry("chat", id) || {}).address || null);
  /// What "The chat model's server" points at: the server's word for the saved chat pick, or the picked one's while it waits.
  const followed = () => {
    if (picks.chat === picks.saved.chat) return list().chatServer;
    const e = entry("chat", picks.chat);
    return { address: e ? e.address : null, local: e ? e.local : true };
  };
  /// The key a test's answer is kept under (see `results`). "chat" (categorizing on the chat model's server) is whatever the
  /// saved chat pick is.
  const keyFor = (kind, id) => {
    const l = list();
    if (kind === "jev") return resultKey("jev", "jev", "openrouter", l.jev.zeroRetention ? "zero retention" : "", l.jev.hasKey);
    if (kind === "decision" && id === "chat") return resultKey("decision", "chat", l.chatServer.address, l.chatInUse, true);
    const e = entry(kind, id);
    return e ? resultKey(kind, id, e.address, e.model, e.hasKey) : null;
  };

  const chatTitle = "models-chat-title", catTitle = "models-categorizing-title";
  const chatGroup = h("div", { class: "rows model-list", role: "radiogroup", "aria-labelledby": chatTitle });
  const catGroup = h("div", { class: "rows model-list", role: "radiogroup", "aria-labelledby": catTitle });
  const chatEmpty = h("p", { class: "help job-line" }, "Any OpenAI-compatible server: your switchboard, llama.cpp on the Olares, or a cloud API like OpenRouter.");
  const caption = h("span", { class: "t-caption muted grow", role: "status" }, TEST_LINE);
  const problem = h("div", { class: "model-problem" });
  const testButton = button("Test", { compact: true, onclick: () => test() });
  const addChat = button("Add a chat model", { compact: true, "data-model": "add-chat", onclick: () => openModel("chat") });
  const addDecision = button("Add a categorizing server", { compact: true, "data-model": "add-decision", onclick: () => openModel("decision") });
  let rows = [];

  /// One choice: a radio with its name, where it sends (mono), what the last test said, and its tags; Edit beside it, never
  /// inside the label. `sub` gives { text, mono }; it, `cloud` and `testKey` are read again on every update, since the chat
  /// model's server follows the chat pick.
  const choice = (job, id, { title, sub, cloud = () => false, olares = false, unreadable = false, flags = [], testKey = () => null, disabled = false, action = null }) => {
    const n = ++uid, ids = { title: `pick-${n}-title`, sub: `pick-${n}-sub`, pending: `pick-${n}-pending`, tags: `pick-${n}-tags` };
    const input = h("input", { type: "radio", name: `pick-${job}`, id: `pick-${n}`, value: id, checked: picks[job] === id, disabled,
      "aria-labelledby": ids.title, "aria-describedby": `${ids.sub} ${ids.pending} ${ids.tags}` });
    input.addEventListener("change", () => { if (input.checked) choose(job, id); });
    const subEl = h("span", { class: "sub", id: ids.sub }), pendingEl = h("span", { class: "sub note", id: ids.pending });
    // A failed test's answer can list a dozen model names: two lines here, all of it in the title and the drawer's Test.
    const detailEl = h("span", { class: "sub note clamp-2" }), tagsEl = h("span", { class: "tags", id: ids.tags });
    const el = h("div", { class: "row choice-row" },
      h("label", { class: `check grow${disabled ? " disabled" : ""}`, for: input.id }, input,
        h("span", { class: "grow" }, h("span", { class: "title", id: ids.title }, title), subEl, pendingEl, detailEl, tagsEl)),
      h("div", { class: "row-actions" }, action));
    const update = () => {
      input.checked = picks[job] === id;
      const s = typeof sub === "function" ? sub() : sub;
      subEl.textContent = s.text;
      subEl.classList.toggle("plain", !s.mono);
      pendingEl.textContent = picks[job] === id && picks.saved[job] !== id ? "Used after you save" : "";
      const o = results.get(testKey()) || null;
      detailEl.textContent = o && !o.testing && !o.ok && !o.off ? o.detail || "" : "";
      if (detailEl.textContent) detailEl.title = detailEl.textContent; else detailEl.removeAttribute("title");
      fill(tagsEl, picks.saved[job] === id ? tag("In use") : null, flags.map(([label, tone]) => tag(label, tone)), cloud() ? tag("In the cloud", "watch") : null,
        olares ? tag("From the Olares app") : null, statusTag(o), unreadable ? tag("Key unreadable", "act") : null);
    };
    return { job, id, el, update };
  };
  const at = (address, tail) => (address ? { text: `${hostOf(address) || address} · ${tail}`, mono: true } : { text: NO_ADDRESS, mono: false });
  const plain = (text) => ({ text, mono: false });
  const editButton = (kind, e) => (e.origin === "dashboard"
    ? button("Edit", { compact: true, "aria-label": `Edit ${e.name}`, "data-model": e.id, onclick: () => openModel(kind, e) }) : null);
  const fromOlares = (e) => e.origin === "environment" || (e.inherits || []).length > 0;
  const chatRows = (l) => [
    ...l.chat.map((e) => choice("chat", e.id, { title: e.name, sub: at(e.address, e.model || ""), cloud: () => !!e.address && !e.local,
      olares: fromOlares(e), unreadable: e.keyUnreadable, testKey: () => keyFor("chat", e.id), action: editButton("chat", e) })),
    choice("chat", "off", { title: "Off", sub: plain("Ask gives simple built-in answers") }),
  ];
  const categorizingRows = (l) => [
    ...l.decision.map((e) => choice("categorizing", e.id, { title: e.name, sub: at(e.address, "/v1/systemone"), cloud: () => !!e.address && !e.local,
      olares: fromOlares(e), unreadable: e.keyUnreadable, testKey: () => keyFor("decision", e.id), action: editButton("decision", e) })),
    choice("categorizing", "chat", { title: "The chat model's server",
      sub: () => { const s = followed(); return s.address ? at(s.address, "/v1/systemone") : plain("No chat model in use"); },
      cloud: () => { const s = followed(); return !!s.address && !s.local; },
      // A test of it is a test of the saved chat pick's server: nothing to show while another one waits for Save.
      testKey: () => (picks.chat === picks.saved.chat ? keyFor("decision", "chat") : null) }),
    choice("categorizing", "jev", { title: "Jev, in the cloud",
      sub: plain(!l.jev.hasKey ? "Needs an OpenRouter key" : l.jev.zeroRetention ? "OpenRouter · providers that keep nothing" : "OpenRouter"),
      olares: l.jev.keyOrigin === "environment", unreadable: l.jev.keyUnreadable, disabled: !l.jev.hasKey, testKey: () => keyFor("jev", "jev"),
      action: l.jev.hasKey ? button("Edit", { compact: true, "aria-label": "Edit Jev", "data-model": "jev", onclick: () => openJev() })
        : button("Add a key", { compact: true, "aria-label": "Add a key for Jev (OpenRouter)", "data-model": "jev", onclick: () => openJev() }) }),
    // Laya only while the policy already names it (the phone can pick it); the server can't run it.
    picks.saved.categorizing === "laya" ? choice("categorizing", "laya", { title: "Laya, on your Olares",
      sub: plain("Not set up on this server: new transactions wait for you"), flags: [["Not set up", "watch"]] }) : null,
    choice("categorizing", "off", { title: "Off", sub: plain("Everything waits for you") }),
  ].filter(Boolean);

  const update = () => { for (const r of rows) r.update(); showProblems(); };
  const build = () => {
    const l = list(), chat = chatRows(l), categorizing = categorizingRows(l);
    drawn = l;
    rows = [...chat, ...categorizing];
    fill(chatGroup, chat.map((r) => r.el));
    fill(catGroup, categorizing.map((r) => r.el));
    chatEmpty.hidden = l.chat.length > 0;
    update();
  };
  const choose = (job, id) => {
    picks[job] = id;
    update();
    policy.sync();  // follows the categorizing pick, and counts the change
  };

  /// What's wrong with the saved setup, said beside Test without holding up any Save.
  const savedProblems = () => {
    const l = list(), out = [];
    const chat = entry("chat", picks.saved.chat), cat = picks.saved.categorizing, decision = isServerPick(cat) && cat !== "chat" ? entry("decision", cat) : null;
    if (chat && !chat.address) out.push(`${chat.name} has no address now: the Olares app stopped setting it, so Ask gives simple built-in answers. Pick another, or type one in its Edit.`);
    if (cat === "chat" && !l.chatServer.address) out.push("Categorizing uses the chat model's server, and no chat model is in use, so new transactions wait for you. Pick a chat model, or another place for categorizing.");
    if (decision && !decision.address) out.push(`${decision.name} has no address now: the Olares app stopped setting it, so new transactions wait for you.`);
    if (cat === "jev" && !l.jev.hasKey) out.push("Jev is categorizing but has no OpenRouter key, so new transactions wait for you. Add a key on Jev, or pick another.");
    for (const e of [chat, decision]) {
      if (e && e.keyUnreadable) out.push(`${e.name}'s saved API key can't be read: the server's encryption key changed. Type the key again in its Edit.`);
    }
    if (cat === "jev" && l.jev.keyUnreadable) out.push("Jev's saved OpenRouter key can't be read: the server's encryption key changed. Type it again on Jev.");
    return out;
  };
  /// A callout when what a job uses now isn't working (from the last test), and one for each saved-setup problem.
  const showProblems = () => {
    const cat = picks.saved.categorizing, failing = [];
    const chatO = picks.saved.chat !== "off" ? results.get(keyFor("chat", picks.saved.chat)) : null;
    const catO = cat === "jev" ? results.get(keyFor("jev", "jev")) : isServerPick(cat) ? results.get(keyFor("decision", cat)) : null;
    for (const [job, o] of [["Ask", chatO], ["Categorizing", catO]]) if (o && !o.testing && !o.ok && !o.off) failing.push([job, o]);
    fill(problem,
      failing.length ? callout({ tone: "watch", title: failing.map(([job]) => job).join(" and ") + (failing.length > 1 ? " aren't" : " isn't") + " working",
        body: failing.map(([job, o]) => `${job}: ${o.detail}`).join(" ") }) : null,
      savedProblems().map((text) => callout({ tone: "watch", role: "note", title: text })));
  };

  /// Tests what `body` names ({chat: [id], decision: [id], jev}; {} for everything listed): "Testing…" on each row until
  /// its answer is in, then the answers, a count beside Test, and a callout if what a job uses now isn't working. The
  /// answers land on the page's card as it is when they come (`tested`), which a Save or Discard meanwhile drew again.
  const test = (body = {}) => busy(testButton, "Testing…", async () => {
    const l = list(), all = !body.chat && !body.decision && !body.jev;
    const chatIDs = all ? l.chat.map((e) => e.id) : body.chat || [];
    const decisionIDs = all ? [...l.decision.map((e) => e.id), ...(l.chatServer.address ? ["chat"] : [])] : body.decision || [];
    const keys = [...chatIDs.map((id) => keyFor("chat", id)), ...decisionIDs.map((id) => keyFor("decision", id)),
      ...((all ? l.jev.hasKey : body.jev) ? [keyFor("jev", "jev")] : [])].filter(Boolean);
    const before = new Map(keys.map((k) => [k, results.get(k)]));
    keys.forEach((k) => results.set(k, { testing: true }));
    update();
    let summary = null, failure = null;
    try {
      const r = await api("/dash/models/test", { method: "POST", body });
      const answers = [];
      const keep = (key, o) => { answers.push(o); if (key) results.set(key, o); };
      for (const [id, o] of Object.entries(r.chat || {})) keep(keyFor("chat", id), o);
      for (const [id, o] of Object.entries(r.decision || {})) keep(keyFor("decision", id), o);
      if (r.jev) keep(keyFor("jev", "jev"), r.jev);
      const ok = answers.filter((o) => o.ok).length, off = answers.filter((o) => !o.ok && o.off).length, bad = answers.length - ok - off;
      summary = answers.length
        ? `Tested ${answers.length}: ${[ok ? `${ok} working` : null, bad ? `${bad} not working` : null, off ? `${off} off` : null].filter(Boolean).join(", ")}. ${TEST_LINE}`
        : `Nothing to test yet. ${TEST_LINE}`;
    } catch (error) { failure = error; }
    // Whatever didn't answer goes back to what it showed before.
    for (const [k, o] of before) if ((results.get(k) || {}).testing) { if (o) results.set(k, o); else results.delete(k); }
    card().tested(summary, failure);
  }, { errorTarget: problem });
  /// A test's answers on this card: the count beside Test, the rows and callouts again, and why it couldn't run.
  const tested = (summary, failure) => {
    if (summary) caption.textContent = summary;
    update();
    if (failure) reportError(failure, problem);
  };

  /// After a drawer saved or removed something: the list again (the one before stays until it's in), the rows redrawn
  /// around the same picks, the keyboard back on the entry's Edit (or the job's Add), then the toast and a test of what
  /// changed. All on the page's card now: a Save or Discard while the drawer was open drew a new one.
  const afterDrawer = async ({ message, focus, fields = false, testBody = null }) => {
    try { await Promise.all([heavy("models", { force: true }), fields ? heavy("fields", { force: true }) : null]); }
    catch (error) { reportError(error); }
    if (!cached("models")) { rerender(); return; }
    const now = card();
    now.refresh({ focus });
    toast(message + (otherChanges() ? " Your other changes still need Save." : ""));
    afterWrite();
    const next = typeof testBody === "function" ? testBody() : testBody;
    if (next) now.test(next);
  };

  /// The rows again from the list as it is now, keeping the picks: one whose entry is gone goes back to the saved pick, and
  /// with nothing waiting for Save the chat pick follows the server's (which picks the first chat model added to a server
  /// with none). `focus`: the data-model of the button to put the keyboard on, else the job's Add.
  const refresh = ({ focus = null } = {}) => {
    const l = list();
    const has = {
      chat: (id) => id === "off" || l.chat.some((e) => e.id === id),
      categorizing: (id) => id === "off" || id === "chat" || (id === "jev" && l.jev.hasKey) || (id === "laya" && picks.saved.categorizing === "laya")
        || l.decision.some((e) => e.id === id),
    };
    const waiting = { chat: picks.chat !== picks.saved.chat, categorizing: picks.categorizing !== picks.saved.categorizing };
    picks.saved = { chat: l.chatInUse, categorizing: savedCategorizing(store.status.decisionPolicy, l) };
    for (const job of ["chat", "categorizing"]) if (!waiting[job] || !has[job](picks[job])) picks[job] = picks.saved[job];
    build();
    policy.sync();
    if (!focus) return;
    const target = root.querySelector(`[data-model="${CSS.escape(focus)}"]`)
      || root.querySelector(entry("chat", focus) || focus === "add-chat" ? '[data-model="add-chat"]' : '[data-model="add-decision"]');
    if (target) target.focus();
  };

  // MARK: Drawers

  /// Add or change a chat model (kind "chat") or a categorizing server ("decision"). Saving and Remove act at once; which
  /// one a job uses stays with the picks and Save.
  const openModel = (kind, e = null) => {
    const l = list(), chat = kind === "chat", job = chat ? "chat" : "categorizing", sealing = l.sealingAvailable;
    const inherits = (field) => !!e && (e.inherits || []).includes(field);
    // A names list still waiting to load goes with the drawer.
    const { body, foot, close } = drawer(e ? `Edit ${e.name}` : chat ? "Add a chat model" : "Add a categorizing server", { onClose: () => clearTimeout(timer) });
    const n = ++uid, fid = (what) => `model-${n}-${what}`;
    const flash = h("div", { class: "flash" });
    const outcome = h("div", { class: "model-outcome", role: "status" });
    // The name the server gives an entry with none typed (the model's, or the server's host), shown as the placeholder. A
    // name that is still the default starts blank, so it keeps following the model or the address.
    const defaultName = (modelName, addressText) => (chat ? modelName || "" : hostnameOf(addressText) || (e ? "Categorizing server" : ""));
    const named = !!e && e.name !== defaultName(e.model, e.address);
    const name = h("input", { class: "input", id: fid("name"), value: named ? e.name : "", maxlength: "60", autocomplete: "off", spellcheck: "false" });
    // A value that follows the Olares app shows as a placeholder (never a key); typing one replaces it.
    const address = h("input", { class: "input", id: fid("address"), inputmode: "url", autocomplete: "off", spellcheck: "false",
      value: e && !inherits("address") ? e.address || "" : "", placeholder: inherits("address") ? `From the Olares app: ${e.address || "not set now"}` : "https://…" });
    const key = h("input", { class: "input", type: "password", id: fid("key"), ...secretAttrs, autocomplete: "new-password", disabled: !sealing });
    const model = chat ? h("input", { class: "input", id: fid("model"), autocomplete: "off", spellcheck: "false",
      value: e && !inherits("model") ? e.model || "" : "", placeholder: inherits("model") ? `From the Olares app: ${e.model || ""}` : "" }) : null;

    // "Remove the key" holds until Save (sent as removeKey), like a setting's Turn off.
    let removeKey = false;
    const savedKey = !!e && (e.hasKey || e.keyUnreadable);
    const keyNote = h("span", { class: "help pending-note" });
    // Why the saved key can't come along to a new address, in the field's help (a placeholder that long is cut off).
    const keyMoved = h("span", { class: "help pending-note", id: fid("key-moved") });
    const keyUnreadable = sealing && e && e.keyUnreadable
      ? h("span", { class: "help", id: fid("key-unreadable") }, "The saved key can't be read: the server's encryption key changed. Type the key again.") : null;
    key.setAttribute("aria-describedby", [keyMoved.id, keyUnreadable && keyUnreadable.id].filter(Boolean).join(" "));
    const removeKeyButton = savedKey ? button("Remove the key", { kind: "quiet", onclick: () => holdRemove(true) }) : null;
    // On OpenRouter a chat model can save a copy of Jev's key instead of a typed one: on by default unless it has its own.
    const where = () => address.value.trim() || (e && e.address) || "";
    const useJev = chat && l.jev.hasKey ? h("input", { type: "checkbox", class: "switch", id: fid("use-jev"), checked: !savedKey, disabled: !sealing }) : null;
    const useJevRow = useJev ? h("label", { class: "check", for: useJev.id }, useJev,
      h("span", {}, "Use Jev's OpenRouter key", h("span", { class: "help" }, "Saves a copy for this model. Changing Jev's key later leaves this one as it is."))) : null;
    const usingJev = () => !!useJev && useJev.checked && !removeKey && isOpenRouter(where());
    const toOpenRouter = chat ? button("OpenRouter", { kind: "quiet", "aria-label": "Use OpenRouter's address", onclick: () => {
      address.value = OPENROUTER;
      if (useJev && !removeKey) useJev.checked = true;
      sync();
      loadNames();
      model.focus();
    } }) : null;
    // What leaves for OpenRouter follows Jev's "Only providers that keep nothing".
    const routing = h("span", { class: "help" });
    const holdRemove = (on) => {
      removeKey = on;
      if (on && useJev) useJev.checked = false;
      if (on) key.value = "";
      removeKeyButton.hidden = on;
      const keep = on ? button("Keep it", { kind: "quiet", onclick: () => holdRemove(false) }) : null;
      fill(keyNote, on ? ["Removed when you save. ", keep] : null);
      (on ? keep : removeKeyButton).focus();
      sync();
    };
    // The saved key only ever goes to its own server: a new one on another server needs its own key, or none.
    const moved = () => !!e && !!e.address && !!address.value.trim() && !!originOf(address.value.trim()) && originOf(address.value.trim()) !== originOf(e.address);
    const sync = () => {
      const openRouter = isOpenRouter(where());
      if (toOpenRouter) toOpenRouter.hidden = openRouter;
      if (useJevRow) useJevRow.hidden = !openRouter;
      key.disabled = removeKey || !sealing || usingJev();
      if (removeKeyButton) removeKeyButton.hidden = removeKey || usingJev();
      const routingNote = !chat || !openRouter ? ""
        : l.jev.zeroRetention ? "OpenRouter sends it only to providers that keep nothing, as Jev's requests are."
        : "OpenRouter may send it to providers that keep what they're sent. Jev → “Only providers that keep nothing” changes that for both.";
      if (routing.textContent !== routingNote) routing.textContent = routingNote;
      const movedNote = !removeKey && !usingJev() && moved() && savedKey ? `The saved key is for ${hostOf(e.address)}: type this server's key, or remove it.` : "";
      if (keyMoved.textContent !== movedNote) keyMoved.textContent = movedNote;
      key.placeholder = removeKey ? "None"
        : usingJev() ? "Jev's OpenRouter key"
        : movedNote ? "Type this server's key"
        : inherits("key") ? "From the Olares app"
        : e && e.hasKey ? "Saved — type a new one to replace it"
        : e && e.keyUnreadable ? "Saved, but unreadable: type it again"
        : "None";
      name.placeholder = defaultName(model ? model.value.trim() || (e && e.model) : null, address.value.trim() || (e && e.address));
    };

    const field = (label, input, { help = null, extra = null, more = null } = {}) => h("div", { class: "field wide" },
      h("div", { class: "field-head" }, h("label", { for: input.id }, label), extra ? [h("span", { class: "grow" }), extra] : null),
      input, more, help ? h("span", { class: "help" }, help) : null);
    fill(body, flash,
      h("div", { class: "form" },
        field("Name", name, { help: chat ? "Leave it blank to use the model's name." : "Leave it blank to use the server's host name." }),
        field("Address", address, { extra: toOpenRouter, help: chat ? "Just the address: Budget adds /v1/… itself." : "The server with /v1/systemone, like Clef on your Olares." }),
        field("API key", key, { extra: removeKeyButton, more: [useJevRow, keyNote, keyMoved, !sealing ? sealingHelp() : keyUnreadable] }),
        chat ? field("Model", model) : null),
      chat ? h("p", { class: "help" }, "Ask and the morning summary send this server what they read from your ledger. ", routing) : null,
      outcome);
    // Model: type a name, or pick one the server lists (loaded now, and again a moment after the address or key changes).
    const names = chat ? combobox(model, "model names") : null;
    let asked = 0, timer = null;
    const loadNames = async () => {
      if (!names) return;
      const ticket = ++asked, typed = address.value.trim(), ask = {};
      if (e) ask.id = e.id;
      if (typed) {
        if (!/^https?:\/\/[^\s/]+/i.test(typed)) { names.setOptions(null); return; }
        ask.address = typed;
      } else if (!e) { names.setOptions(null); return; }
      if (usingJev()) ask.useOpenRouterKey = true;
      else if (key.value.trim() && !removeKey) ask.apiKey = key.value.trim();
      try {
        const r = await api("/dash/models/names", { method: "POST", timeout: 20000, body: ask });
        if (ticket === asked) names.setOptions(r && r.models);
      } catch { if (ticket === asked) names.setOptions(null); }
    };
    for (const el of [address, key]) el.addEventListener("input", () => { sync(); clearTimeout(timer); timer = setTimeout(loadNames, 700); });
    if (useJev) useJev.addEventListener("change", () => { if (useJev.checked) key.value = ""; sync(); loadNames(); });
    if (model) model.addEventListener("input", sync);
    sync();
    loadNames();

    /// What's typed, as the server takes it: blank fields keep what's saved (or keep following the Olares app), except the
    /// name, where blank on an edit is the default name again ("" tells the server so).
    const draft = (forTest) => {
      const d = { kind };
      if (e) d.id = e.id;
      if (!forTest && (name.value.trim() || e)) d.name = name.value.trim();
      if (address.value.trim()) d.address = address.value.trim();
      if (removeKey) d.removeKey = true;
      else if (usingJev()) d.useOpenRouterKey = true;
      else if (key.value.trim()) d.apiKey = key.value.trim();
      if (chat && model.value.trim()) d.model = model.value.trim();
      return d;
    };
    const check = () => {
      const typed = address.value.trim();
      if (typed ? !/^https?:\/\//i.test(typed) : !inherits("address")) return "The address must start with http:// or https://.";
      if (chat && !model.value.trim() && !inherits("model")) return "Add the model's name. Test lists the names the server offers.";
      return null;
    };
    const save = (el) => busy(el, "Saving…", async () => {
      fill(flash);
      // The server refuses this too; saying it here first saves the round trip.
      const problem = check() || (moved() && savedKey && !removeKey && !usingJev() && !key.value.trim()
        ? "The address is on another server now: type its API key, or remove the key." : null);
      if (problem) throw new Error(problem);
      const r = await api("/dash/models/save", { method: "POST", body: draft(false) });
      const saved = ((r.list && r.list[kind]) || []).find((x) => x.id === r.id);
      const shown = saved ? saved.name : name.value.trim() || (e && e.name) || "it";
      close();
      await afterDrawer({ message: e ? "Saved." : `Added ${shown}.${r.autoSelected ? " Ask uses it now." : " Pick it and save to use it."}`,
        focus: r.id, testBody: () => {
          // The chat model in use is also "The chat model's server" under Categorizing: a new key or address there changes
          // both, so both are tested (else that row keeps the answer from before).
          const l = list(), next = { [kind]: [r.id] };
          if (chat && l.chatInUse === r.id && l.chatServer.address) next.decision = ["chat"];
          return next;
        } });
    }, { errorTarget: flash });
    const tryIt = (el) => busy(el, "Testing…", async () => {
      fill(flash);
      fill(outcome);
      const problem = check();
      if (problem) throw new Error(problem);
      fill(outcome, tag("Testing…"));
      try {
        const r = await api("/dash/models/test", { method: "POST", body: { draft: draft(true) } });
        showOutcome(outcome, r.draft);
        if (names && r.models) names.setOptions(r.models);
      } catch (error) { fill(outcome); throw error; }
    }, { errorTarget: flash });
    const removeIt = (el) => busy(el, "Removing…", async () => {
      await api("/dash/models/remove", { method: "POST", body: { id: e.id } });
      close();
      await afterDrawer({ message: `Removed ${e.name}.`, focus: chat ? "add-chat" : "add-decision" });
    }, { errorTarget: flash });
    // What a job uses now can't go: pick another one and save first. (A categorizing server counts only while categorizing
    // runs on it, which is what its saved pick says.)
    const inUse = !!e && picks.saved[job] === e.id;
    fill(foot,
      button(e ? "Save" : chat ? "Add the model" : "Add the server", { kind: "primary", onclick: (ev) => save(ev.currentTarget) }),
      button("Test", { kind: "secondary", onclick: (ev) => tryIt(ev.currentTarget) }),
      button("Cancel", { kind: "quiet", onclick: close }),
      h("span", { class: "grow" }),
      e && !inUse ? button("Remove", { kind: "caution", onclick: (ev) => { const b = ev.currentTarget; armed(b, "Click again to remove it", () => removeIt(b)); } }) : null,
      inUse ? h("span", { class: "help" }, "In use. Pick another one and save first.") : null);
    (e ? name : address).focus();
  };

  /// Jev: its OpenRouter key and "only providers that keep nothing", as fresh controls from the server's settings as they
  /// are now, saved on their own: never part of the page's controls or its save bar.
  const openJev = async () => {
    const { el: dialog, body, foot, close } = drawer("Jev");
    fill(body, skeleton(3));
    let fields;
    try { fields = await heavy("fields", { force: true }); }
    catch (error) {
      fill(body, callout({ tone: "watch", title: error.message, detail: error.detail, actions: [button("Try again", { compact: true, onclick: () => openJev() })] }));
      return;
    }
    if (!dialog.open || !dialog.contains(body)) return;  // closed, or another drawer took its place
    const p = store.status.decisionPolicy;
    // While Jev files, or is asked, its key can't go: the server refuses that too.
    const locked = p.provider === "jev" ? "Jev is categorizing now. Pick another one and save first."
      : p.escalateToJev && (p.provider === "localDecide" || p.provider === "laya") ? "Jev is asked when the local model is unsure. Turn that off and save first." : null;
    const sealing = list().sealingAvailable;
    const controls = fields.filter((f) => JEV_KEYS.includes(f.key)).map((f) => settingControl(f, () => {},
      f.key === "openRouterKey" ? { locked, disabled: !sealing } : {}));
    const keyControl = controls.find((c) => c.key === "openRouterKey"), zdr = controls.find((c) => c.key === "openRouterZeroRetention");
    const flash = h("div", { class: "flash" }), outcome = h("div", { class: "model-outcome", role: "status" });
    fill(body, flash,
      keyControl ? keyControl.el : null,
      keyControl && !sealing ? h("div", { class: "field" }, sealingHelp()) : null,
      zdr ? zdr.el : null,
      h("p", { class: "t-callout muted" }, "Jev sees only merchant names and your category list, never amounts, balances or accounts."),
      store.status.decisionSample ? details("Exactly what a model receives for one transaction", store.status.decisionSample) : null,
      outcome);
    const save = button("Save", { kind: "primary", onclick: (ev) => busy(ev.currentTarget, "Saving…", async () => {
      fill(flash);
      const changes = Object.assign({}, ...controls.map((c) => c.change()));
      if (!Object.keys(changes).length) { close(); return; }
      await api("/dash/settings", { method: "PATCH", body: { changes } });
      close();
      await afterDrawer({ message: "Saved.", focus: "jev", fields: true, testBody: () => (list().jev.hasKey ? { jev: true } : null) });
    }, { errorTarget: flash }) });
    const tryIt = button("Test", { kind: "secondary", onclick: (ev) => busy(ev.currentTarget, "Testing…", async () => {
      fill(flash);
      fill(outcome, tag("Testing…"));
      const typed = keyControl ? keyControl.change().openRouterKey : undefined;
      const d = { kind: "jev", zeroRetention: zdr ? zdr.input.checked : list().jev.zeroRetention };
      if (typed === "") d.removeKey = true;
      else if (typed) d.apiKey = typed;
      try { showOutcome(outcome, (await api("/dash/models/test", { method: "POST", body: { draft: d } })).draft); }
      catch (error) { fill(outcome); throw error; }
    }, { errorTarget: flash }) });
    fill(foot, save, tryIt, button("Cancel", { kind: "quiet", onclick: close }));
    (keyControl && !keyControl.input.disabled ? keyControl.input : save).focus();
  };

  const foot = h("div", { class: "card-foot models-foot" }, testButton, caption, problem);
  const root = h("div", { class: "model-jobs" },
    h("p", { class: "t-callout muted" }, "Each job uses the one picked here. A new pick waits for Save at the bottom of the page; Add, Edit and Remove save right away."),
    h("div", { class: "model-job" },
      h("div", { class: "job-head" }, h("h3", { class: "t-eyebrow card-title", id: chatTitle }, "Ask and planning"), addChat),
      chatEmpty, chatGroup),
    h("div", { class: "model-job", id: "section-categorizing" },
      h("div", { class: "job-head" }, h("h3", { class: "t-eyebrow card-title", id: catTitle }, "Categorizing"), addDecision),
      catGroup, policy.jevLabel));
  build();

  const changedJobs = () => ({ chat: picks.chat !== picks.saved.chat, categorizing: picks.categorizing !== picks.saved.categorizing });
  const self = {
    el: root, foot, refresh, test, tested,
    /// The chat pick is one change; the categorizing pick is the policy's to count.
    changes: () => (changedJobs().chat ? 1 : 0),
    /// A problem with the picks that would leave a job with nothing to run on, or null. Only picks that changed are
    /// checked: a problem already saved shows beside Test instead, and never holds up another Save.
    validate: () => {
      const c = changedJobs();
      if (!c.chat && !c.categorizing) return null;
      if (picks.categorizing === "chat" && !chatAddress(picks.chat)) return "Choose a chat model, or another place for categorizing.";
      if (c.categorizing && picks.categorizing === "jev" && !list().jev.hasKey) return "Jev needs an OpenRouter key.";
      return null;
    },
    /// When Ask moves while categorizing follows it, what Save says before it goes ahead; else null.
    follows: () => {
      if (!changedJobs().chat || picks.categorizing !== "chat") return null;
      const address = chatAddress(picks.chat);
      return address ? `Categorizing follows Ask to ${hostOf(address) || address} too. Click again to save, or pick a categorizing server.` : null;
    },
    /// `POST /dash/models/use` for the jobs whose pick changed, or null. Off, Jev and Laya are the policy's provider: they
    /// leave the categorizing server as it is.
    useBody: () => {
      const c = changedJobs(), body = {};
      if (c.chat) body.chat = picks.chat;
      if (c.categorizing && isServerPick(picks.categorizing) && picks.categorizing !== list().decisionInUse) body.decision = picks.categorizing;
      return Object.keys(body).length ? body : null;
    },
    /// What to test once the picks are saved: each one that changed, and the chat model's server for categorizing when it
    /// moved with Ask.
    autoTests: () => {
      const c = changedJobs(), body = {}, decision = [];
      if (c.chat && picks.chat !== "off") body.chat = [picks.chat];
      if (c.categorizing && isServerPick(picks.categorizing)) decision.push(picks.categorizing);
      if (c.chat && picks.categorizing === "chat" && !decision.includes("chat")) decision.push("chat");
      if (decision.length) body.decision = decision;
      if (c.categorizing && picks.categorizing === "jev") body.jev = true;
      return Object.keys(body).length ? body : null;
    },
  };
  /// The page's card now (see `current`): this one until a Save or Discard draws another.
  const card = () => (current && current()) || self;
  return self;
}

/// A text field with a list to pick from: type anything, or open the list with the chevron or ↓; typing filters it to
/// the names containing what's typed. ↑↓ move, Enter picks, Escape closes. `setOptions(null)` says the server didn't list
/// any. The field keeps its own input, so what's typed is what's saved. (A chat model's Model, in its drawer.)
function combobox(input, what) {
  let options = null, open = false, active = -1;
  const listID = `${input.id}-list`;
  const list = h("div", { class: "combo-list", role: "listbox", id: listID, "aria-label": what, hidden: true });
  const toggle = h("button", { type: "button", class: "combo-toggle", tabindex: "-1", "aria-label": `Show ${what}`,
    onmousedown: (e) => e.preventDefault(), onclick: () => (open ? close() : (input.focus(), show(true))) });
  Object.entries({ role: "combobox", "aria-autocomplete": "list", "aria-controls": listID, "aria-expanded": "false" }).forEach(([k, v]) => input.setAttribute(k, v));
  const wrap = h("div", { class: "combo" });
  input.replaceWith(wrap);
  wrap.append(input, toggle, list);
  const items = () => [...list.querySelectorAll("[role=option]")];
  const render = (all) => {
    const typed = input.value.trim().toLowerCase();
    const shown = (options || []).filter((o) => all || !typed || o.toLowerCase().includes(typed));
    fill(list, shown.length ? shown.map((o, i) => h("div", { role: "option", id: `${listID}-${i}`, class: "combo-option", "aria-selected": String(o === input.value.trim()),
        onmousedown: (e) => { e.preventDefault(); pick(o); } }, o))
      : h("div", { class: "combo-empty" }, options === null ? "The server didn't list its models. Check the address and key, or type the name."
        : options.length ? "No listed model by that name. It's sent as typed." : "The server lists no models."));
    active = -1;
    input.removeAttribute("aria-activedescendant");
  };
  const show = (all) => { render(all); list.hidden = false; open = true; input.setAttribute("aria-expanded", "true"); };
  const close = () => { list.hidden = true; open = false; input.setAttribute("aria-expanded", "false"); input.removeAttribute("aria-activedescendant"); };
  const pick = (o) => { input.value = o; close(); input.dispatchEvent(new Event("input")); close(); };
  const move = (step) => {
    const all = items();
    if (!all.length) return;
    active = (active + step + all.length) % all.length;
    all.forEach((el, i) => el.classList.toggle("active", i === active));
    input.setAttribute("aria-activedescendant", all[active].id);
    all[active].scrollIntoView({ block: "nearest" });
  };
  input.addEventListener("input", () => { if (document.activeElement === input) show(false); });
  input.addEventListener("blur", () => close());
  input.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown") { e.preventDefault(); if (open) move(1); else show(true); }
    else if (e.key === "ArrowUp" && open) { e.preventDefault(); move(-1); }
    else if (e.key === "Enter" && open && active >= 0) { e.preventDefault(); pick(items()[active].textContent); }
    else if (e.key === "Escape" && open) { e.preventDefault(); close(); }
  });
  return { setOptions(next) { options = next ? [...next] : null; if (open) render(false); } };
}

function providerControl(id, onChange) {
  const form = id === "plaid" ? plaidForm({ onChange }) : tellerForm({ onChange });
  return { id, form, el: form.el, changes: () => form.changes(), validate: () => form.validate(), save: () => form.save() };
}

function section(id, title, ...children) {
  return [sectionHead(title, null, `sec-${id}`), h("section", { class: "card", id: `section-${id}`, "aria-labelledby": `sec-${id}` }, children)];
}

/// Pace alerts as the phone would get them now (`GET /v1/alerts/pace`): read-only; each phone picks its own kinds.
function paceAlerts() {
  const region = h("div", { class: "rows" });
  loadInto(region, () => api("/v1/alerts/pace"), (report) => {
    const rows = [];
    if (report.everyday) {
      const e = report.everyday;
      const pace = e.projected ? `on pace for ${money(e.projected, { cents: false })}` : "too early to project";
      rows.push(h("div", { class: "row" }, dot(report.alerts.some((a) => a.kind === "everyday") ? "act" : "ok"),
        h("div", { class: "grow" }, h("div", { class: "title" }, "Everyday budget"),
          h("div", { class: "sub wrap" }, `${money(e.spent, { cents: false })} of ${money(e.limit, { cents: false })} spent, ${pace}.`))));
    }
    for (const a of report.alerts) {
      rows.push(h("div", { class: "row" }, dot(a.threshold === "used80" ? "watch" : "act"),
        h("div", { class: "grow" }, h("div", { class: "title" }, a.title), h("div", { class: "sub wrap" }, a.body))));
    }
    if (!report.alerts.length) rows.push(h("p", { class: "t-callout muted" }, "Nothing is running ahead this month."));
    return rows;
  });
  return [h("p", { class: "t-callout muted" }, "A heads-up when the everyday budget is on pace to finish the month over, or a category target or merchant cap passes 80% or is on pace to go over. Each phone picks which it gets in its Settings; each goes once a month, between 9 am and 9 pm where the phone is."),
    region];
}

function copyButton(getText, label = "Copy") {
  const b = button(label, { compact: true, onclick: async () => {
    const value = getText();
    if (!value) return;
    try { await navigator.clipboard.writeText(value); toast("Copied"); }
    catch {
      const code = b.parentElement.querySelector("code, input");
      if (code && code.select) code.select();
      else if (code) { const r = document.createRange(); r.selectNodeContents(code); const sel = getSelection(); sel.removeAllRanges(); sel.addRange(r); }
      toast("Selected. Press ⌘C to copy.");
    }
  } });
  return b;
}

// MARK: Sections

/// The address (the server setting, editable, with Copy) and the token (shown on request) the phone needs.
function phoneSection(addressControl, more) {
  let token = null;
  const s = store.summary.settings;
  const tokenCode = h("code", {}, "••••••••••••••••••••••••");
  const copyToken = copyButton(() => token);
  copyToken.disabled = true;
  const reveal = button("Show", { compact: true, onclick: () => {
    if (token) { token = null; tokenCode.textContent = "••••••••••••••••••••••••"; reveal.textContent = "Show"; copyToken.disabled = true; return; }
    busy(reveal, "Loading…", async () => {
      const c = await api("/dash/connect");
      token = c.token || null;
      tokenCode.textContent = token || "No token is set, so the phone connects without one.";
      copyToken.disabled = !token;
    }).then(() => { if (token) reveal.textContent = "Hide"; });
  } });
  const address = addressControl
    ? [addressControl.el, h("div", { class: "actions" }, copyButton(() => s.apiURL || "", "Copy the address"))]
    : h("div", { class: "field" }, h("span", { class: "field-head" }, "Server URL"), h("div", { class: "secret-row" }, h("code", {}, s.apiURL || "Not set yet"), copyButton(() => s.apiURL || "")));
  // The phone's own words: its first screen and Settings → Advanced → Your server ask for a "server URL" and an "API token".
  return section("phone", "Connect your phone",
    h("p", { class: "t-callout muted" }, "In the Budget app on your phone, paste this server URL and API token: on its first screen, or later in Settings → Advanced → Your server."),
    address,
    h("div", { class: "field" }, h("span", { class: "field-head" }, "API token"), h("div", { class: "secret-row" }, tokenCode, reveal, copyToken),
      h("span", { class: "help" }, "Anyone with this token and the address can read your ledger. It stays on this server.")),
    more);
}

function aboutCard() {
  const s = store.summary, c = s.settings;
  const lastSync = s.links.map((l) => l.lastSync).filter(Boolean).sort().pop();
  return [
    c.inMemory ? callout({ tone: "act", title: "Nothing here survives a restart",
      body: "The server is keeping your ledger in memory. Give it a database in the Budget app's settings on the Olares so your accounts, imports and settings are kept.",
      detail: "No POSTGRES_HOST is set, so the server runs on its in-memory store." }) : null,
    h("dl", { class: "kv" },
      h("dt", {}, "Version"), h("dd", {}, s.version),
      h("dt", {}, "Running for"), h("dd", {}, duration((Date.now() - new Date(s.startedAt)) / 1000)),
      h("dt", {}, "Storage"), h("dd", {}, c.inMemory ? tag("In memory", "act") : "Postgres database"),
      h("dt", {}, "Transactions"), h("dd", {}, s.stats.rows.toLocaleString()),
      s.links.length ? [h("dt", {}, "Last sync"), h("dd", {}, lastSync ? `${ago(lastSync)} (${dateTime(lastSync)})` : "Not yet"),
        h("dt", {}, "Next sync"), h("dd", {}, `in about ${duration(nextSyncIn())}`)] : null,
      h("dt", {}, "Time zone"), h("dd", {}, c.timeZone)),
  ];
}

function removeDataSection() {
  const phrase = "erase my ledger";
  const boxes = [
    ["ledger", "All transactions and accounts", "The ledger starts empty. Categories, rules and targets go with it."],
    ["links", "Linked banks", "Each is signed out at the bank, so syncing stops."],
    ["imports", "Import and sync history", "Undo stops working for past imports."],
    ["keys", "Saved Plaid and Teller keys", "Keys from the Olares app's settings stay."],
  ].map(([id, label, help]) => ({ id, input: h("input", { type: "checkbox", id: `rm-${id}` }), label, help }));
  const confirm = h("input", { class: "input", id: "rm-confirm", autocomplete: "off", spellcheck: "false", placeholder: phrase, "aria-describedby": "rm-help" });
  const result = h("div");
  const allowDemo = store.summary.settings.demoAllowed;
  const erase = button("Remove selected", { kind: "caution", disabled: true, onclick: (e) => busy(e.currentTarget, "Removing…", () => reset(false), { errorTarget: result }) });
  const demo = allowDemo ? button("Replace with the demo ledger", { kind: "secondary", disabled: true, onclick: (e) => busy(e.currentTarget, "Replacing…", () => reset(true), { errorTarget: result }) }) : null;
  const update = () => {
    const typed = confirm.value.trim().toLowerCase() === phrase, any = boxes.some((b) => b.input.checked);
    erase.disabled = !typed || !any;
    if (demo) demo.disabled = !typed;
  };
  confirm.addEventListener("input", update);
  boxes.forEach((b) => b.input.addEventListener("change", update));
  async function reset(seedDemo) {
    const on = (id) => boxes.find((b) => b.id === id).input.checked;
    const r = await api("/v1/admin/reset", { method: "POST", body: { confirm: phrase, seedDemo, keepLedger: !seedDemo && !on("ledger"),
      removeLinks: on("links"), clearImports: on("imports"), removeProviderKeys: on("keys") } });
    confirm.value = ""; boxes.forEach((b) => { b.input.checked = false; }); update();
    fill(result, callout({ tone: "ok", role: "status", title: `Removed ${r.removed || "nothing"}.` }));
    await afterWrite("providers", "fields");
  }
  return [sectionHead("Remove data", null, "sec-remove"),
    h("section", { class: "card danger-zone", "aria-labelledby": "sec-remove" },
      h("p", { class: "t-callout muted" }, "Choose what to remove. Nothing is selected until you pick it, and none of it can be undone."),
      h("div", {}, boxes.map((b) => h("label", { class: "check", for: b.input.id }, b.input, h("span", {}, b.label, h("span", { class: "help" }, b.help))))),
      h("div", { class: "field" }, h("label", { class: "field-head", for: "rm-confirm" }, "Type “erase my ledger” to confirm"), confirm,
        h("span", { class: "help", id: "rm-help" }, allowDemo ? "The demo ledger is available because this is a test server." : null)),
      h("div", { class: "actions" }, erase, demo), result)];
}

// MARK: View

export default {
  title: "Settings",
  async mount(root, { sub }) {
    this.root = root;
    this.sub = sub;
    fill(root, pageHead({ eyebrow: "This server", title: "Settings" }), skeleton(6));
    try {
      await Promise.all([heavy("fields", { force: true }), heavy("providers"), heavy("models", { force: true })]);
    } catch (error) {
      fill(root, pageHead({ eyebrow: "This server", title: "Settings" }), callout({ tone: "watch", title: error.message, detail: error.detail,
        actions: [button("Try again", { compact: true, onclick: () => this.mount(root, { sub }) })] }));
      return;
    }
    if (this.root === root) this.render();
  },
  navigate({ sub }) { this.sub = sub; this.scrollToSub(); },
  scrollToSub() {
    const target = this.sub && this.root.querySelector(`#section-${this.sub}`);
    if (target) target.scrollIntoView({ block: "start" });
  },
  unmount() { closeDrawer(); },
  /// Light refresh: only "About this server" (never the form someone may be editing).
  refresh() { if (this.about) fill(this.about, ...aboutCard().filter(Boolean)); },
  dirty() { return this.controls ? this.controls.reduce((t, c) => t + c.changes(), 0) : 0; },
  changed() {
    if (!this.bar) return;
    const n = this.dirty();
    this.bar.hidden = n === 0;
    this.barText.textContent = `${plural(n, "unsaved change")}`;
    fill(this.barError);
  },
  /// Leaving with unsaved changes was turned back (app.js): the save bar is where they are.
  showUnsaved() { if (this.bar && !this.bar.hidden) this.bar.scrollIntoView({ block: "nearest", behavior: "smooth" }); },
  render() {
    if (!cached("fields") || !cached("providers") || !cached("models")) { this.mount(this.root, { sub: this.sub }); return; }
    const onChange = () => this.changed();
    const list = cached("models");
    // Jev's two settings are its drawer's (Models → Jev): taken here, never shown inline or counted by the save bar.
    const fields = (cached("fields") || []).filter((f) => !JEV_KEYS.includes(f.key));
    const settingControls = fields.map((f) => settingControl(f, onChange));
    const byKey = Object.fromEntries(settingControls.map((c) => [c.key, c]));
    const placed = new Set(JEV_KEYS);
    const take = (...keys) => keys.map((k) => { placed.add(k); return byKey[k] ? byKey[k].el : null; });
    const rest = (sectionID) => settingControls.filter((c) => !placed.has(c.key) && (GROUP_SECTION[c.group] || "other") === sectionID).map((c) => { placed.add(c.key); return c.el; });
    // Which model each job uses: what the server runs now (`saved`), and what's picked here (the same until a pick changes).
    const saved = { chat: list.chatInUse, categorizing: savedCategorizing(store.status.decisionPolicy, list) };
    const picks = { ...saved, saved };
    const policy = policyControl(onChange, { picks, hasJevKey: () => !!(cached("models") && cached("models").jev.hasKey) });
    const models = modelsCard({ picks, policy, onChange, otherChanges: () => this.dirty(), rerender: () => this.render(), current: () => this.models });
    const plaid = providerControl("plaid", onChange), teller = providerControl("teller", onChange);
    this.providerControls = [plaid, teller];
    this.policy = policy;
    this.models = models;
    this.settingControls = settingControls;
    this.controls = [models, policy, plaid, teller, ...settingControls];
    const states = providerStates();
    const sealing = cached("providers") ? cached("providers").providers.sealingAvailable : true;

    const fold = (id, name, state, ...body) => h("details", { class: "fold", id: `fold-${id}` },
      h("summary", {}, h("span", { class: "grow" }, name), tag(state.label, state.tone)), h("div", { class: "fold-body" }, body));

    this.bar = h("div", { class: "savebar", role: "region", "aria-label": "Unsaved changes", hidden: true });
    this.barText = h("span", { class: "grow t-callout" });
    this.barError = h("div", { class: "savebar-error" });
    this.bar.append(this.barText, button("Discard", { kind: "secondary", compact: true, onclick: () => this.render() }),
      button("Save", { kind: "primary", compact: true, onclick: (e) => this.save(e.currentTarget) }), this.barError);

    this.about = h("section", { class: "card", id: "section-about", "aria-labelledby": "sec-about" }, aboutCard().filter(Boolean));
    const tz = h("datalist", { id: "tz-list" }, ((Intl.supportedValuesOf && Intl.supportedValuesOf("timeZone")) || []).map((z) => h("option", { value: z })));
    // Two short sections side by side where the page is wide enough (each column is its heads and cards, top to bottom).
    const columns = (...cols) => h("div", { class: "grid-2" }, cols.map((c) => h("div", {}, c)));

    fill(this.root,
      pageHead({ eyebrow: "This server", title: "Settings", sub: "What you set here wins over the Budget app's settings on the Olares. The phone edits the same categorization settings." }),
      h("div", { class: "settings" },
        section("models", "Models", models.el, ...rest("models"), models.foot),
        columns(section("categorization", "Categorization", policy.el),
          [section("sync", "Sync and time", ...take("syncIntervalHours", "timeZone"), ...rest("sync"), tz),
            sectionHead("About this server", null, "sec-about"), this.about]),
        section("banks", "Bank providers",
          !sealing ? callout({ tone: "watch", title: "The server can't protect saved keys yet", body: "Add an encryption key in the Budget app's settings on the Olares, then restart it.",
            detail: "Set BUDGET_TOKEN_KEY to the output of: openssl rand -base64 32" }) : null,
          h("div", {},
            fold("plaid", "Plaid", states.plaid, plaid.el, removeKeysButton("plaid", () => this.render())),
            fold("teller", "Teller", states.teller, teller.el, removeKeysButton("teller", () => this.render())),
            fold("simplefin", "SimpleFIN", states.simplefin, h("p", { class: "t-callout muted" }, "SimpleFIN needs no keys here: paste a setup token when you connect a bank."),
              h("a", { class: "btn secondary compact", href: "#/accounts?connect=1" }, "Connect a bank")))),
        columns(phoneSection(byKey.publicURL ? (placed.add("publicURL"), byKey.publicURL) : null, rest("phone")),
          section("notifications", "Notifications",
            h("p", { class: "t-callout muted" }, "The morning summary (yesterday's spending at 9:30 wherever the phone is) and pace alerts. Turn them on in the phone's Settings; they need an APNs key here to send."),
            ...take("apnsKey", "apnsKeyID", "apnsTeamID", "apnsTopic"), ...rest("notifications"))),
        section("pace", "Pace alerts right now", ...paceAlerts()),
        settingControls.some((c) => !placed.has(c.key)) ? section("other", "More", ...settingControls.filter((c) => !placed.has(c.key)).map((c) => c.el)) : null,
        removeDataSection(),
        this.bar));
    this.scrollToSub();
  },

  async save(buttonEl) {
    const problems = [this.models.validate(), this.policy.changes() ? this.policy.validate() : null,
      ...this.providerControls.filter((p) => p.changes()).map((p) => p.validate())].filter(Boolean);
    if (problems.length) { fill(this.barError, callout({ tone: "watch", title: problems[0] })); return; }
    // Ask moving while categorizing follows it to the same server: one more click, so categorizing never moves unseen.
    // (A click on Save while it's asking goes ahead, whatever changed since.)
    const follows = this.models.follows();
    if (follows || buttonEl.dataset.armed === "1") { armed(buttonEl, follows, () => this.commit(buttonEl)); return; }
    await this.commit(buttonEl);
  },

  /// Saves in the order the server needs: the picks (so the policy's check sees the server they name), the settings, the
  /// policy, the bank providers; then everything again from the server, and a test of each pick that changed.
  async commit(buttonEl) {
    const failures = [];
    const use = this.models.useBody(), tests = this.models.autoTests();
    const changes = Object.assign({}, ...this.settingControls.map((c) => c.change()));
    const action = this.policy.needsAction() ? this.policy.body() : null;
    const ok = await busy(buttonEl, "Saving…", async () => {
      if (use) await api("/dash/models/use", { method: "POST", body: use });
      if (Object.keys(changes).length) await api("/dash/settings", { method: "PATCH", body: { changes } });
      let message = null;
      if (action) message = (await api("/v1/actions", { method: "POST", body: action })).message;
      for (const p of this.providerControls.filter((c) => c.changes())) {
        const outcome = await p.save();
        if (!outcome.ok) failures.push(outcome);
      }
      // Each one stays as it was until the new one is in: the page can still be used meanwhile.
      const fresh = { force: true };
      await Promise.all([heavy("fields", fresh), heavy("providers", fresh), heavy("models", fresh), loadCore()]);
      toast(message || "Saved");
    }, { errorTarget: this.barError });
    if (!ok) {
      // Part of it may have saved (the picks, say): the list and status again, keeping every pick and value still waiting,
      // and the error that says why the rest didn't (counting the changes again would clear it).
      await Promise.all([heavy("models", { force: true }), loadCore()]).catch(() => {});
      const why = [...this.barError.childNodes];
      if (cached("models")) this.models.refresh();
      fill(this.barError, ...why);
      return;
    }
    await afterWrite("fields", "providers");
    await Promise.all([heavy("fields"), heavy("providers"), heavy("models")]).catch(() => {});
    this.render();
    if (failures.length) reportError({ message: failures[0].message, detail: failures[0].detail });
    if (tests) await this.models.test(tests);
  },
};
