// Settings: one column, one sticky save bar for everything editable. A value's source shows only when it
// isn't the default. Removing data is its own guarded action at the bottom and never rides the save bar.
import { fill, h, api, store, heavy, cached, forget, loadCore, pageHead, sectionHead, button, busy, callout, details, tag, afterWrite, reportError, toast,
  plural, ago, duration, dateTime, nextSyncIn, ROLE, skeleton } from "./core.js";
import { plaidForm, tellerForm, removeKeysButton, providerStates } from "./providers.js";

/// Plain names for the server's settings (the server's own label and help are the fallback).
const LABELS = {
  modelBaseURL: ["Address", "The OpenAI-compatible server Ask and planning use, like your switchboard or llama.cpp on the Olares. Just the address: Budget adds /v1/… itself. Empty gives simple built-in answers."],
  modelAPIKey: ["API key", "Sent as a bearer token, for a server that asks for one. It stays on this server."],
  modelName: ["Model", "The name that server knows the model by. Test lists the names it offers."],
  decisionBaseURL: ["Address", "The server with /v1/systemone, like the Clef decision server on your Olares."],
  decisionAPIKey: ["API key", "For that server, if it asks for one."],
  openRouterKey: ["OpenRouter key", "Jev runs in the cloud through OpenRouter. It sees only merchant names and your category list, never amounts, balances or accounts."],
  openRouterZeroRetention: ["Only providers that keep nothing", "Asks OpenRouter to route only to providers with zero data retention."],
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
const INTERVALS = [["0.25", "Every 15 minutes"], ["1", "Every hour"], ["3", "Every 3 hours"], ["6", "Every 6 hours"], ["12", "Every 12 hours"], ["24", "Once a day"]];
const ORIGIN_TAG = { environment: ["From the Olares app", ""], dashboard: ["Set here", "info"] };

let uid = 0;
const nextID = (key) => `set-${key}-${++uid}`;

/// One server setting: its input, where its value comes from, Reset (to the Olares app or default) and
/// Turn off, all held until Save.
function settingControl(f, onChange) {
  const [label, help] = LABELS[f.key] || [f.label, f.help];
  const id = nextID(f.key);
  let pending;  // undefined: nothing pending; null: reset; "": turn off
  let input;
  if (f.kind === "bool") input = h("input", { type: "checkbox", class: "switch", id, checked: f.value === "true" });
  else if (f.kind === "secret") input = h("input", { class: "input", type: "password", id, autocomplete: "off", spellcheck: "false", "data-1p-ignore": "", "data-lpignore": "true",
    placeholder: f.isSet ? "Saved — type a new one to replace it" : "Not set" });
  else if (f.key === "syncIntervalHours") {
    const current = String(Number(f.value || f.defaultValue || 6));
    const options = INTERVALS.some(([v]) => v === current) ? INTERVALS : [...INTERVALS, [current, `Every ${current} hours`]];
    input = h("select", { class: "input", id, value: current }, options.map(([v, l]) => h("option", { value: v }, l + (v === String(Number(f.defaultValue)) ? " (default)" : ""))));
  } else input = h("input", { class: "input", id, value: f.value || "", spellcheck: "false", autocomplete: "off", list: f.kind === "timeZone" ? "tz-list" : null,
    inputmode: f.kind === "number" ? "decimal" : f.kind === "url" ? "url" : null,
    placeholder: f.kind === "url" ? (f.key === "decisionBaseURL" ? "Same as the chat model" : f.key === "publicURL" ? "https://…" : f.key === "dashboardURL" ? "Not set" : "Off") : (f.defaultValue || "") });
  const value = () => (f.kind === "bool" ? (input.checked ? "true" : "false") : input.value.trim());
  const initial = f.kind === "secret" ? "" : f.kind === "bool" ? (f.value === "true" ? "true" : "false") : value();
  const note = h("span", { class: "help pending-note" });
  const hold = (next, text) => { pending = next; input.disabled = true; fill(note, text, " ", button("Keep it", { kind: "quiet", onclick: () => { pending = undefined; input.disabled = false; fill(note); onChange(); } })); onChange(); };
  const [originLabel, originTone] = ORIGIN_TAG[f.origin] || [];
  const head = h("div", { class: "field-head" }, f.kind === "bool" ? null : h("label", { for: id }, label), h("span", { class: "grow" }),
    originLabel ? tag(originLabel, originTone) : null,
    f.origin === "dashboard" ? button("Reset", { kind: "quiet", "aria-label": `Reset ${label}`, onclick: () => hold(null, "Goes back to the Olares app's setting or the default when you save.") }) : null,
    (f.kind === "secret" || f.kind === "url") && f.isSet ? button("Turn off", { kind: "quiet", "aria-label": `Turn off ${label}`, onclick: () => hold("", "Turns off when you save.") }) : null,
    f.key === "dashboardURL" && !f.isSet && !f.value ? button("Use this page's address", { kind: "quiet", onclick: () => { input.value = location.origin + "/"; onChange(); } }) : null);
  input.addEventListener(f.kind === "bool" || input.tagName === "SELECT" ? "change" : "input", onChange);
  const body = f.kind === "bool"
    ? h("label", { class: "check", for: id }, input, h("span", {}, label, h("span", { class: "help" }, help)))
    : [input, h("span", { class: "help" }, help)];
  return {
    key: f.key, group: f.group, field: f, input,
    el: h("div", { class: "field" }, head, body, note),
    /// What the field holds now, saved or not: "" for a secret nobody typed (the saved one stands), "" for Turn off.
    current: () => (pending === "" ? "" : value()),
    /// Puts a value in, as if typed.
    set: (next) => { pending = undefined; input.disabled = false; fill(note); input.value = next; onChange(); },
    changes: () => (pending !== undefined ? 1 : f.kind === "secret" ? (value() ? 1 : 0) : value() !== initial ? 1 : 0),
    change: () => (pending !== undefined ? { [f.key]: pending } : (f.kind === "secret" ? value() : value() !== initial) ? { [f.key]: value() } : {}),
  };
}

/// Where categorizing runs, as Models offers it: the policy's provider, with Qwen Decide split by whether it has a server
/// of its own or uses the chat model's.
const RUNS_ON = [["off", "Off — everything waits for you"], ["chat", "The chat model's server"], ["own", "A server of its own"],
  ["jev", "Jev, in the cloud (OpenRouter)"], ["laya", "Laya, on your Olares"]];
const providerFor = (runsOn) => (runsOn === "chat" || runsOn === "own" ? "localDecide" : runsOn);

/// The categorization policy. Where it runs ("Runs on") and "Ask Jev when unsure" are shown in Models, next to the models
/// they need; the threshold and what comes to you anyway stay in Categorization.
/// - ownServer: whether the decision endpoint has an address of its own (else it's the chat model's).
/// - hasJevKey: whether an OpenRouter key is saved or typed.
function policyControl(onChange, { ownServer, hasJevKey }) {
  const p = store.status.decisionPolicy;
  const initial = p.provider === "localDecide" ? (ownServer ? "own" : "chat") : p.provider;
  const model = h("select", { class: "input", id: "pol-provider" },
    RUNS_ON.filter(([id]) => id !== "laya" || initial === "laya").map(([id, label]) => h("option", { value: id }, label)));
  model.value = initial;
  const pct = h("input", { type: "range", id: "pol-pct", min: "50", max: "99", step: "1", value: String(p.autoAcceptPercent), "aria-describedby": "pol-pct-help" });
  const out = h("output", { for: "pol-pct" }, `${p.autoAcceptPercent}%`);
  const canJev = () => hasJevKey();
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
  const jevLabel = h("label", { class: "check", for: "pol-jev" }, jev, h("span", {}, "Ask Jev when the local model is unsure", h("span", { class: "help jev-help" })));
  const sync = () => {
    newMerchants.disabled = model.value === "off";
    newLabel.classList.toggle("disabled", newMerchants.disabled);
    newLabel.querySelector(".new-help").textContent = newMerchants.disabled
      ? "Only with a decision model: without one, everything new comes to you anyway."
      : "The model's first answer for a merchant waits for you, however sure it is. After you file one, the rest follow.";
    above.disabled = !big.checked;
    const local = model.value !== "off" && model.value !== "jev";
    jev.disabled = !local;
    jevLabel.classList.toggle("disabled", jev.disabled);
    jevLabel.querySelector(".jev-help").textContent = !local ? "Only with a model on your Olares."
      : !canJev() ? "Add an OpenRouter key below. Only merchant names leave the Olares, and only for what it's unsure about."
      : "Only merchant names leave the Olares, and only for what it's unsure about.";
    pct.disabled = model.value === "off";
    out.textContent = `${pct.value}%`;
    onChange();
  };
  for (const el of [model, jev, rerun, newMerchants, big, pending]) el.addEventListener("change", sync);
  for (const el of [pct, above]) el.addEventListener("input", sync);
  sync();
  const changed = () => ({ provider: providerFor(model.value) !== p.provider, pct: Number(pct.value) !== p.autoAcceptPercent, jev: !jev.disabled && jev.checked !== savedJev,
    newMerchants: !newMerchants.disabled && newMerchants.checked !== !!p.reviewNewMerchants,
    // Something unreadable counts as a change, so Save can say what's wrong with it.
    above: big.checked ? aboveAmount() === null || Number(aboveAmount()) !== Number(savedAbove || NaN) : savedAbove !== "",
    pending: pending.checked !== !!p.holdPending });
  return {
    /// "Runs on", for Models.
    runsOnEl: h("div", { class: "field" }, h("div", { class: "field-head" }, h("label", { for: "pol-provider" }, "Runs on")), model,
      h("span", { class: "help" }, "Categorizing files what Budget isn't sure about. It can use the chat model's server, a server of its own, or Jev in the cloud.")),
    runsOnInput: model,
    runsOn: () => model.value,
    providerChanged: () => changed().provider,
    /// "Ask Jev when unsure", for Models.
    jevLabel,
    sync,
    el: h("div", { class: "stack" },
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
    changes: () => { const c = changed(); return [c.provider, c.pct, c.jev, rerun.checked, c.newMerchants, c.above, c.pending].filter(Boolean).length; },
    /// A problem with what's typed, or null.
    validate: () => (big.checked && aboveAmount() === null ? "The amount to check above is in dollars, like 500." : null),
    body: () => {
      const c = changed(), body = { type: "updateDecisionPolicy", rerunPending: rerun.checked };
      if (c.provider) body.provider = providerFor(model.value);
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

/// Models: each job and what it runs on. Chat (Ask and planning): the server, its key, the model name. Categorizing: where
/// it runs — the chat model's server, one of its own, or Jev in the cloud — with only that choice's fields showing, and
/// Ask Jev when unsure. Test tries every job on what's in the fields, saved or not, and fills the model names the chat
/// server offers into Model's suggestions.
/// Returns the section's children and a check for Save.
function modelsSection({ byKey, take, rest, policy, status }) {
  const f = (key) => byKey[key];
  const [chatAddress, chatKey, chatModel, ownAddress, ownKey, jevKey, jevZdr] =
    take("modelBaseURL", "modelAPIKey", "modelName", "decisionBaseURL", "decisionAPIKey", "openRouterKey", "openRouterZeroRetention");
  const own = h("div", { class: "stack" }, ownAddress, ownKey);
  const jevBox = h("div", { class: "stack" }, jevKey, jevZdr,
    status.decisionSample ? details("Exactly what a model receives for one transaction", status.decisionSample) : null);
  const escalate = policy.jevLabel.querySelector("input");
  const current = (key) => (f(key) ? f(key).current() : undefined);
  // Model: type a name, or pick from what the chat server lists — loaded now, and again when the address or key changes.
  const names = f("modelName") ? combobox(f("modelName").input, "model names") : null;
  const loadNames = async () => {
    if (!names) return;
    try {
      const r = await api("/dash/models/names", { method: "POST", timeout: 20000, body: { modelBaseURL: current("modelBaseURL"), modelAPIKey: current("modelAPIKey") } });
      names.setOptions(r.models);
    } catch { names.setOptions(null); }
  };
  let reload;
  for (const key of ["modelBaseURL", "modelAPIKey"]) {
    if (f(key)) f(key).input.addEventListener("input", () => { clearTimeout(reload); reload = setTimeout(loadNames, 700); });
  }
  loadNames();
  const sync = () => {
    const runsOn = policy.runsOn(), local = runsOn === "chat" || runsOn === "own";
    own.hidden = runsOn !== "own";
    policy.jevLabel.hidden = !local;
    jevBox.hidden = !(runsOn === "jev" || (local && escalate.checked));
  };
  policy.runsOnInput.addEventListener("change", () => {
    // On the chat model's server, the decision endpoint's own address goes, so it follows the chat model's.
    if (policy.runsOn() === "chat" && f("decisionBaseURL") && f("decisionBaseURL").current()) f("decisionBaseURL").set("");
    sync();
  });
  escalate.addEventListener("change", sync);
  if (f("openRouterKey")) f("openRouterKey").input.addEventListener("input", () => policy.sync());
  sync();

  // What each job runs on, and what Test found.
  const rows = status.roles.map((r) => {
    const slot = h("span"), note = h("div", { class: "sub" });
    return { role: r.role, slot, note,
      el: h("div", { class: "row" }, h("div", { class: "grow" }, h("div", { class: "title" }, ROLE[r.role] || r.role),
        h("div", { class: "sub" }, r.model || "Not assigned"), note), slot) };
  });
  const show = (report) => {
    for (const r of rows) {
      const o = r.role === "chat" || r.role === "plan" ? report.chat : r.role === "categorize" ? report.categorize : null;
      if (!o) continue;
      fill(r.slot, o.off ? tag("Off") : o.ok ? tag(`Working · ${(o.milliseconds / 1000).toFixed(1)} s`, "ok") : tag("Not working", "act"));
      fill(r.note, o.detail);
    }
    if (names && report.models) names.setOptions(report.models);
  };
  const problem = h("div");
  /// Tests every job on what's in the fields; a job that isn't working is also called out under the button.
  const runTest = () => busy(test, "Testing…", async () => {
    fill(problem);
    const report = await api("/dash/models/test", { method: "POST", timeout: 120000, body: {
      modelBaseURL: current("modelBaseURL"), modelName: current("modelName"), modelAPIKey: current("modelAPIKey"),
      categorizing: policy.runsOn(), decisionBaseURL: current("decisionBaseURL"), decisionAPIKey: current("decisionAPIKey"),
      openRouterKey: current("openRouterKey"), openRouterZeroRetention: current("openRouterZeroRetention") === "true" } });
    show(report);
    const failing = [["Ask", report.chat], ["Categorizing", report.categorize]].filter(([, o]) => !o.ok && !o.off);
    if (failing.length) fill(problem, callout({ tone: "watch", title: failing.map(([job]) => job).join(" and ") + (failing.length > 1 ? " aren't" : " isn't") + " working",
      body: failing.map(([job, o]) => `${job}: ${o.detail}`).join(" ") }));
  }, { errorTarget: problem });
  const test = button("Test", { compact: true, onclick: runTest });

  const children = [
    h("div", { class: "subsection" }, h("h3", { class: "t-eyebrow card-title" }, "Chat · Ask and planning"), chatAddress, chatKey, chatModel),
    h("div", { class: "subsection" }, h("h3", { class: "t-eyebrow card-title" }, "Categorizing"), policy.runsOnEl, own, policy.jevLabel, jevBox),
    ...rest("models"),
    h("div", { class: "field" }, h("div", { class: "field-head" }, h("span", {}, "What each job runs on"), h("span", { class: "grow" }), test),
      h("div", { class: "rows role-list" }, rows.map((r) => r.el)),
      h("span", { class: "help" }, "Test tries each job on what's in the fields above, saved or not: a one-word question and a made-up coffee charge, nothing from your ledger."),
      problem),
  ];
  const validate = () => {
    const runsOn = policy.runsOn();
    if (runsOn === "own" && !current("decisionBaseURL")) return "Add the categorizing server's address, or choose the chat model's server.";
    if (runsOn === "jev" && !(f("openRouterKey") && (f("openRouterKey").field.isSet || current("openRouterKey")))) return "Jev needs an OpenRouter key.";
    return null;
  };
  return { children, validate, test: runTest };
}

/// A text field with a list to pick from: type anything, or open the list with the chevron or ↓; typing filters it to
/// the names containing what's typed. ↑↓ move, Enter picks, Escape closes. `setOptions(nil)` says the server didn't list
/// any. The field keeps its own input, so saving and Reset work as before.
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

/// Settings that decide which model each job uses: a save that changes any of them tests them right away.
const MODEL_KEYS = ["modelBaseURL", "modelAPIKey", "modelName", "decisionBaseURL", "decisionAPIKey", "openRouterKey", "openRouterZeroRetention"];

function providerControl(id, onChange) {
  const form = id === "plaid" ? plaidForm({ onChange }) : tellerForm({ onChange });
  return { id, form, el: form.el, changes: () => form.changes(), validate: () => form.validate(), save: () => form.save() };
}

function section(id, title, ...children) {
  return [sectionHead(title, null, `sec-${id}`), h("section", { class: "card", id: `section-${id}`, "aria-labelledby": `sec-${id}` }, children)];
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
      await Promise.all([heavy("fields", { force: true }), heavy("providers")]);
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
  render() {
    if (!cached("fields") || !cached("providers")) { this.mount(this.root, { sub: this.sub }); return; }
    const onChange = () => this.changed();
    const fields = cached("fields") || [];
    const settingControls = fields.map((f) => settingControl(f, onChange));
    const byKey = Object.fromEntries(settingControls.map((c) => [c.key, c]));
    const placed = new Set();
    const take = (...keys) => keys.map((k) => { placed.add(k); return byKey[k] ? byKey[k].el : null; });
    const rest = (sectionID) => settingControls.filter((c) => !placed.has(c.key) && (GROUP_SECTION[c.group] || "other") === sectionID).map((c) => { placed.add(c.key); return c.el; });
    const hasJevKey = () => !!(byKey.openRouterKey && (byKey.openRouterKey.field.isSet || byKey.openRouterKey.current()));
    const policy = policyControl(onChange, { ownServer: !!(byKey.decisionBaseURL && byKey.decisionBaseURL.field.isSet), hasJevKey });
    const plaid = providerControl("plaid", onChange), teller = providerControl("teller", onChange);
    this.providerControls = [plaid, teller];
    this.policy = policy;
    this.settingControls = settingControls;
    this.controls = [policy, plaid, teller, ...settingControls];
    const states = providerStates();
    const status = store.status;
    const models = modelsSection({ byKey, take, rest, policy, status });
    this.validateModels = models.validate;
    this.testModels = models.test;
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

    fill(this.root, 
      pageHead({ eyebrow: "This server", title: "Settings", sub: "What you set here wins over the Budget app's settings on the Olares. The phone edits the same categorization settings." }),
      h("div", { class: "settings" },
        section("categorization", "Categorization", policy.el),
        section("banks", "Bank providers",
          !sealing ? callout({ tone: "watch", title: "The server can't protect saved keys yet", body: "Add an encryption key in the Budget app's settings on the Olares, then restart it.",
            detail: "Set BUDGET_TOKEN_KEY to the output of: openssl rand -base64 32" }) : null,
          h("div", {},
            fold("plaid", "Plaid", states.plaid, plaid.el, removeKeysButton("plaid", () => this.render())),
            fold("teller", "Teller", states.teller, teller.el, removeKeysButton("teller", () => this.render())),
            fold("simplefin", "SimpleFIN", states.simplefin, h("p", { class: "t-callout muted" }, "SimpleFIN needs no keys here: paste a setup token when you connect a bank."),
              h("a", { class: "btn secondary compact", href: "#/accounts?connect=1" }, "Connect a bank")))),
        section("models", "Models", ...models.children),
        section("sync", "Sync and time", ...take("syncIntervalHours", "timeZone"), ...rest("sync"), tz),
        phoneSection(byKey.publicURL ? (placed.add("publicURL"), byKey.publicURL) : null, rest("phone")),
        section("notifications", "Notifications",
          h("p", { class: "t-callout muted" }, "The morning summary: yesterday's spending at 9:30 wherever the phone is. Turn it on in the phone's Settings; it needs an APNs key here to send."),
          ...take("apnsKey", "apnsKeyID", "apnsTeamID", "apnsTopic"), ...rest("notifications")),
        settingControls.some((c) => !placed.has(c.key)) ? section("other", "More", ...settingControls.filter((c) => !placed.has(c.key)).map((c) => c.el)) : null,
        sectionHead("About this server", null, "sec-about"), this.about,
        removeDataSection(),
        this.bar));
    this.scrollToSub();
  },

  async save(buttonEl) {
    const problems = [this.validateModels ? this.validateModels() : null, this.policy.changes() ? this.policy.validate() : null,
      ...this.providerControls.filter((p) => p.changes()).map((p) => p.validate())].filter(Boolean);
    if (problems.length) { fill(this.barError, callout({ tone: "watch", title: problems[0] })); return; }
    const failures = [];
    // Changed where a job's model lives, or its key: test it as soon as it's saved.
    const modelsChanged = this.settingControls.some((c) => MODEL_KEYS.includes(c.key) && c.changes()) || (this.policy.changes() && this.policy.providerChanged());
    const ok = await busy(buttonEl, "Saving…", async () => {
      const changes = Object.assign({}, ...this.settingControls.map((c) => c.change()));
      if (Object.keys(changes).length) await api("/dash/settings", { method: "PATCH", body: { changes } });
      let message = null;
      if (this.policy.changes()) message = (await api("/v1/actions", { method: "POST", body: this.policy.body() })).message;
      for (const p of this.providerControls.filter((c) => c.changes())) {
        const outcome = await p.save();
        if (!outcome.ok) failures.push(outcome);
      }
      forget("fields", "providers");
      await Promise.all([heavy("fields"), heavy("providers"), loadCore()]);
      toast(message || "Saved");
    }, { errorTarget: this.barError });
    if (!ok) return;
    await afterWrite("fields", "providers");
    await Promise.all([heavy("fields"), heavy("providers")]).catch(() => {});
    this.render();
    if (failures.length) reportError({ message: failures[0].message, detail: failures[0].detail });
    if (modelsChanged && this.testModels) await this.testModels();
  },
};
