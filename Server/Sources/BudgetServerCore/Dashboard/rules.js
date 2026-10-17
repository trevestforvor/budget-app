// Categories & rules → Rules: every categorization rule with how much it has filed, whether it disagrees with another
// rule, and whether it still files anything; plus the drawer to add, change or delete one, which shows what the rule
// would reach as you type (POST /v1/actions/preview, which changes nothing). Saving goes through POST /v1/actions. The
// drawer's "New category…" makes the category first (createCategory), then the rule that files under it.
import { fill, h, api, store, heavy, cached, forget, button, busy, armed, callout, tag, afterWrite, reportError, toast, money, count, plural,
  dateShort, dateFull, accountName, categoryName, categoryTag, fileable, categoryOptions, isMoneyIn, newCategoryFields, createCategory,
  emptyState, skeleton, drawer } from "./core.js";

/// Rules that need a look: one whose category is gone, or one that disagrees with another rule.
export const needsLook = (s) => s.isDead || s.conflicts.length > 0;
const number = (s) => Number((s.rule.id.match(/\d+$/) || [0])[0]);

/// `focus` ("add", or a rule's id) is where the keyboard goes once the list is back, after a drawer saved. `quiet`
/// keeps what's on screen until the fresh list arrives (a redraw after someone else's write), instead of a skeleton.
export function renderRules(panel, { focus = null, quiet = false } = {}) {
  if (!quiet || !panel.firstChild) fill(panel, skeleton(4));
  panel.dataset.loading = "1";
  heavy("rules").then((rules) => { delete panel.dataset.loading; drawRules(panel, rules); focusAfter(panel, focus); }, (error) => {
    delete panel.dataset.loading;
    fill(panel, callout({ tone: "watch", title: error.message, detail: error.detail,
      actions: [button("Try again", { compact: true, onclick: () => { forget("rules"); renderRules(panel); } })] }));
  });
}

/// After a write anywhere: the list again, quietly, keeping the keyboard on the rule it was on. Nothing when the list is
/// already on its way (a drawer that just saved asked for it, and puts the focus on what it saved).
export function refreshRules(panel) {
  if (!panel.isConnected || panel.dataset.loading) return;
  const active = document.activeElement;
  renderRules(panel, { quiet: true, focus: active && panel.contains(active) && active.dataset ? active.dataset.rule || null : null });
}

// Review's "Make a rule": rules live on Categories & rules, so the drawer opens there, filled in from the group.
let pendingRule = null;
export function makeRuleFrom(prefill) { pendingRule = prefill; location.hash = "#/categories/rules"; }
/// The rule Review asked for, once: the Categories & rules view opens its drawer when it mounts.
export function takePendingRule() { const p = pendingRule; pendingRule = null; return p; }

function focusAfter(panel, focus) {
  if (!focus || !panel.isConnected) return;
  const target = panel.querySelector(`[data-rule="${CSS.escape(focus)}"]`) || panel.querySelector('[data-rule="add"]');
  if (target) target.focus();
}

function drawRules(panel, rules) {
  if (!panel.isConnected) return;
  const onSaved = (id) => { forget("rules"); renderRules(panel, { focus: id || "add" }); };
  const add = button("Add a rule", { compact: true, "data-rule": "add", onclick: () => openRule({ onSaved }) });
  const intro = h("p", { class: "t-callout muted" }, "Rules file new transactions before remembered merchants and the decision model do. When two rules match the same transaction, the newer one wins.");
  if (!rules.length) {
    fill(panel, h("section", { class: "card" }, emptyState({ title: "No rules yet",
      body: "A rule files every transaction that matches it, now and as new ones arrive: “Bank description contains PAYROLL, money in → Income”. You can also make one from a group in Needs a category.",
      actions: [add] })));
    return;
  }
  const sorted = [...rules].sort((a, b) => (needsLook(b) - needsLook(a)) || (b.rule.isEnabled - a.rule.isEnabled) || (number(b) - number(a)));
  const look = rules.filter(needsLook).length;
  fill(panel, h("section", { class: "card rules" },
    h("div", { class: "rules-head" }, h("div", { class: "grow" }, intro,
      h("p", { class: "t-caption faint" }, `${plural(rules.length, "rule")}${look ? ` · ${look} to look at` : ""}`)), add),
    h("div", { class: "rows" }, sorted.map((s) => ruleRow(s, rules, onSaved)))));
}

function ruleRow(s, all, onSaved) {
  const r = s.rule;
  const by = r.createdBy === "assistant" ? "added by Ask" : "added by you"; // the phone's words
  const others = s.conflicts.map((id) => all.find((x) => x.rule.id === id)).filter(Boolean);
  return h("div", { class: `row rule-row${r.isEnabled ? "" : " dim"}` },
    h("div", { class: "grow" },
      h("div", { class: "title wrap" }, s.matchDescription),
      h("div", { class: "sub rule-sub" }, h("span", { class: "rule-to" }, "→ ", categoryTag(r.categoryID)),
        [`filed ${count(s.hitCount)}`, `matches ${count(s.matchCount)} now`, by, r.createdAt ? dateShort(r.createdAt) : null].filter(Boolean).join(" · ")),
      !r.isEnabled || s.isDead || others.length ? h("div", { class: "tags" },
        !r.isEnabled ? tag("Off") : null,
        // The phone's colors: a rule that files nothing is worth a look (watch); one that disagrees needs a decision (act).
        s.isDead ? tag("Files nothing", "watch") : null,
        others.length ? tag(others.length === 1 ? "Disagrees with 1 rule" : `Disagrees with ${others.length} rules`, "act") : null) : null,
      s.isDead ? h("p", { class: "help" }, "Its category was merged away. Point it at another category, or delete it.") : null,
      others.length ? h("p", { class: "help" }, "Some transactions match both this and ", others.map((o, i) => [i ? "; " : "",
        h("span", { class: "quote" }, o.matchDescription), " → ", categoryName(o.rule.categoryID)]),
        others.every((o) => number(o) > number(s)) ? ". That one is newer, so it files them." : others.every((o) => number(o) < number(s)) ? ". This one is newer, so it files them." : ". The newest of them files those.") : null),
    h("div", { class: "row-actions" }, button("Edit", { compact: true, "aria-label": `Edit the rule ${s.matchDescription}`, "data-rule": r.id,
      onclick: () => openRule({ summary: s, onSaved: () => onSaved(r.id) }) })));
}

// MARK: The drawer

const AMOUNT = /^\d{1,9}(\.\d{1,2})?$/;
/// The target select's "New category…" (not a category id: ids are slugs of names).
const NEW = "+new";
/// "$1,200.50" → "1200.50"; "" → null; anything else → undefined (not an amount).
function amount(raw) {
  const s = (raw || "").replace(/[$,\s]/g, "");
  if (!s) return null;
  return AMOUNT.test(s) ? s : undefined;
}

/// Add a rule (`prefill` from a group) or change one (`summary`). `onSaved` runs after a save or a delete.
export function openRule({ summary = null, prefill = {}, onSaved } = {}) {
  const rule = summary ? summary.rule : null, m = rule ? rule.match : prefill;
  const { body, foot, close } = drawer(rule ? "Edit rule" : "New rule");
  heavy("rules").catch(() => {});  // names the rules a preview says it disagrees with
  const field = (label, input, help, wide) => h("label", { class: `field${wide ? " wide" : ""}` }, h("span", { class: "field-head" }, label), input, help ? h("span", { class: "help" }, help) : null);
  const text = (value, placeholder) => h("input", { class: "input", value: value || "", placeholder, autocomplete: "off", spellcheck: "false" });
  const merchant = text(m.merchantContains, "Any merchant");
  const descriptor = text(m.descriptorContains, "Any description");
  const direction = h("select", { class: "input" }, h("option", { value: "" }, "Either way"), h("option", { value: "out" }, "Going out"), h("option", { value: "in" }, "Coming in"));
  direction.value = m.direction || "";
  const min = h("input", { class: "input", inputmode: "decimal", placeholder: "At least $", value: m.minAmount || "" });
  const max = h("input", { class: "input", inputmode: "decimal", placeholder: "At most $", value: m.maxAmount || "" });
  const byBank = Object.entries(store.overview.accounts.reduce((all, a) => ((all[a.institution] ||= []).push(a), all), {}));
  const account = h("select", { class: "input" }, h("option", { value: "" }, "Any account"),
    byBank.map(([bank, list]) => h("optgroup", { label: bank }, list.map((a) => h("option", { value: a.id }, `${a.nickname || a.name}${a.mask ? ` ••${a.mask}` : ""}`)))));
  account.value = m.accountID || "";
  const target = h("select", { class: "input", id: "rule-target" });
  // "New category…" opens the fields for one under the list; saving makes it, then the rule that files under it.
  const fresh = newCategoryFields({ kind: direction.value === "in" ? "moneyIn" : "spending" });
  const freshPanel = h("div", { class: "newcat-panel", hidden: true }, h("p", { class: "help" }, "Saving adds it, then the rule. Its color and icon can change on your phone."), fresh.el);
  const makingNew = () => target.value === NEW;
  const fillTargets = (keep = target.value || (rule ? rule.categoryID : prefill.categoryID) || "") => {
    fill(target, h("option", { value: "" }, "Choose a category…"), h("option", { value: NEW }, "New category…"), categoryOptions(fileable({ direction: direction.value })));
    target.value = [...target.options].some((o) => o.value === keep) ? keep : "";
    freshPanel.hidden = !makingNew();
  };
  fillTargets();
  const enabled = h("input", { type: "checkbox", class: "switch", checked: rule ? rule.isEnabled : true });
  const existing = h("input", { type: "checkbox", checked: !rule });
  const preview = h("div", { class: "rule-preview", "aria-live": "polite" });
  const flash = h("div", { class: "flash" });

  fill(body, flash,
    h("p", { class: "t-callout muted" }, "A transaction matches when it meets every condition you fill in. Text ignores capitals, spaces, punctuation and numbers, so “Google Fi” also catches “GOOGLE*FI 4DFLFD”."),
    h("div", { class: "form" },
      field("Merchant name contains", merchant), field("Bank description contains", descriptor, "As the bank writes it, like SQ *CASA TACO."),
      field("At least", min), field("At most", max, "Sizes, whichever way the money goes."),
      field("Money", direction), field("Account", account)),
    h("div", { class: "field" }, h("label", { class: "field-head", for: target.id }, "File under"), target, freshPanel),
    rule ? h("label", { class: "check" }, enabled, h("span", {}, "On", h("span", { class: "help" }, "A rule that's off files nothing, and is kept so you can turn it back on."))) : null,
    h("label", { class: "check" }, existing, h("span", {}, "Also re-file the ones it matches",
      h("span", { class: "help" }, "Otherwise only new transactions are filed by it. Ones you filed yourself, and ones a newer rule files, keep their category."))),
    h("h3", { class: "t-eyebrow card-title" }, "What it would do"), preview);

  const matchBody = () => {
    const out = {};
    const t1 = merchant.value.trim(), t2 = descriptor.value.trim();
    if (t1) out.merchantContains = t1;
    if (t2) out.descriptorContains = t2;
    if (direction.value) out.direction = direction.value;
    const lo = amount(min.value), hi = amount(max.value);
    if (lo === undefined || hi === undefined) return { problem: "Amounts are in dollars, like 25 or 25.50." };
    if (lo) out.minAmount = lo;
    if (hi) out.maxAmount = hi;
    if (account.value) out.accountID = account.value;
    return { match: out };
  };
  /// The category the rule files under, or for a new one what makes it and a stand-in of its kind for the preview (which
  /// only counts what the rule matches; nothing is filed under the stand-in).
  const destination = () => {
    if (!makingNew()) return target.value ? { categoryID: target.value } : { problem: "Choose a category to see what the rule would file." };
    const { action: create, problem, existing: same } = fresh.read();
    if (problem) return { problem: same ? `${problem} Choose it above instead.` : problem };
    if (create.kind === "moneyIn" && direction.value === "out") return { problem: "Money going out never counts as money in. Make it a spending category, or match money coming in." };
    const standIn = fileable().find((c) => (create.kind === "moneyIn" ? isMoneyIn(c) : c.countsAsSpending));
    return standIn ? { categoryID: standIn.id, create } : { problem: "There's no category to preview with yet." };
  };
  const action = () => {
    const { match, problem } = matchBody();
    if (problem) return { problem };
    const { categoryID, create, problem: missing } = destination();
    if (missing) return { problem: missing };
    const on = !rule || enabled.checked;
    return { create, action: rule
      ? { type: "updateBudgetRule", ruleID: rule.id, match, categoryID, isEnabled: enabled.checked, applyToExisting: on && existing.checked }
      : { type: "createBudgetRule", match, categoryID, applyToExisting: existing.checked } };
  };

  // A rule with no text to match reaches everything on an account; re-filing with one asks twice.
  const broad = (a) => a && !a.match.merchantContains && !a.match.descriptorContains && a.applyToExisting;
  const saveRule = (el) => busy(el, "Saving…", async () => {
    const { action: a, create, problem } = action();
    if (problem) throw new Error(problem);
    if (create) {
      // The category first. Once it's made the list points at it, so a rule that then fails is retried without a second.
      const { category } = await createCategory(create);
      if (!category) throw new Error(`${create.name} was added, but the list hasn't caught up. Choose it under File under.`);
      fillTargets(category.id);
      fresh.reset();
      a.categoryID = category.id;
    }
    const result = await api("/v1/actions", { method: "POST", body: a });
    toast(result.message || "Saved");
    close();
    await afterWrite();
    if (onSaved) onSaved();
  }, { errorTarget: flash });
  const save = button(rule ? "Save" : "Add the rule", { kind: "primary", disabled: true, onclick: (e) => {
    const el = e.currentTarget;
    if (broad(action().action)) armed(el, "Click again to re-file them all", () => saveRule(el));
    else saveRule(el);
  } });
  const remove = rule ? button("Delete the rule", { kind: "caution", onclick: (e) => armed(e.currentTarget, "Click again to delete it", async () => {
    try {
      const result = await api("/v1/actions", { method: "POST", body: { type: "deleteBudgetRule", ruleID: rule.id } });
      toast(result.message || "Rule deleted");
      close();
      await afterWrite();
      if (onSaved) onSaved();
    } catch (error) { reportError(error, flash); }
  }) }) : null;
  fill(foot, save, button("Cancel", { kind: "quiet", onclick: close }), h("span", { class: "grow" }), remove);

  // The preview follows the form, a moment after typing stops; an answer that arrives late is dropped.
  let timer = null, asked = 0;
  const update = () => {
    clearTimeout(timer);
    existing.disabled = !!rule && !enabled.checked;
    timer = setTimeout(async () => {
      const ticket = ++asked;
      const { action: a, create, problem } = action();
      if (problem) { save.disabled = true; fill(preview, h("p", { class: "empty-line" }, problem)); return; }
      preview.classList.add("loading");
      try {
        const p = await api("/v1/actions/preview", { method: "POST", body: a });
        if (ticket !== asked) return;
        save.disabled = false;
        drawPreview(preview, p, a, summary, create);
        if (broad(a)) preview.prepend(callout({ tone: "watch", role: "note", title: "No text to match",
          body: `It reaches every transaction on ${accountName(a.match.accountID) || "the account"}${a.match.direction ? ` going ${a.match.direction === "out" ? "out" : "in"}` : ""}. Saving re-files the ${count(p.changeCount || 0)} shown as moving.` }));
      } catch (error) {
        if (ticket !== asked) return;
        save.disabled = true;
        fill(preview, error.status === 422 ? h("p", { class: "empty-line watch-text" }, error.message)
          : callout({ tone: "watch", title: error.message, detail: error.detail }));
      } finally { if (ticket === asked) preview.classList.remove("loading"); }
    }, 300);
  };
  for (const el of [merchant, descriptor, min, max]) el.addEventListener("input", update);
  for (const el of [account, enabled, existing]) el.addEventListener("change", update);
  target.addEventListener("change", () => {
    freshPanel.hidden = !makingNew();
    // A new category starts as the kind the rule's money is: money in for a rule on money coming in.
    if (makingNew()) { fresh.setKind(direction.value === "in" ? "moneyIn" : "spending"); fresh.focus(); }
    update();
  });
  fresh.onChange(update);
  direction.addEventListener("change", () => { fillTargets(); update(); });
  update();
  // A fresh rule starts at its first condition; a prefilled or existing one at what it files under.
  (rule || prefill.descriptorContains || prefill.accountID ? target : merchant).focus();
}

/// With `create` (a new category), the preview ran against a stand-in of the same kind: only what it matches is shown,
/// in words about the new category, not the stand-in's title, moves or disagreements.
function drawPreview(el, p, action, summary, create) {
  const matched = p.matchCount || 0, moving = p.changeCount || 0;
  const refiling = action.applyToExisting;
  const others = create ? [] : (cachedRules() || []).filter((s) => (p.conflicts || []).includes(s.rule.id) && (!summary || s.rule.id !== summary.rule.id));
  const kind = create ? (create.kind === "moneyIn" ? "money in" : `spending, ${create.group ?? "everyday"}`) : "";
  fill(el,
    h("p", { class: "t-body-em" }, create ? `Adds ${create.name} (${kind}), then files what the rule matches under it` : p.title),
    !create && p.detail ? h("p", { class: "t-callout muted" }, p.detail) : null,
    create && refiling ? h("p", { class: "t-callout muted" }, "The ones it matches now move to it too, except ones you filed yourself and ones a newer rule files.") : null,
    h("div", { class: "tags" }, tag(matched ? `${count(matched)} match now` : "Nothing matches yet", matched ? "info" : ""),
      !create && refiling && moving ? tag(`${count(moving)} would be filed`, "ok") : null),
    others.length ? callout({ tone: "watch", role: "note", title: others.length === 1 ? "It disagrees with another rule" : `It disagrees with ${others.length} other rules`,
      body: others.map((o) => `${o.matchDescription} → ${categoryName(o.rule.categoryID)}`).join("; ") + ". The newer rule files the transactions both match." }) : null,
    p.sample && p.sample.length ? h("div", { class: "rows" }, p.sample.map((t) => h("div", { class: "row" },
      h("div", { class: "grow" }, h("div", { class: "title" }, t.merchant),
        h("div", { class: "sub" }, [dateFull(t.postedAt), accountName(t.accountID)].filter(Boolean).join(" · "), " · ",
          t.categorization && !t.categorization.needsReview ? categoryTag(t.categorization.categoryID) : "waiting for a category")),
      h("span", { class: `t-amount-row num${t.amount.minor > 0 ? " inflow" : ""}` }, money(t.amount, { sign: t.amount.minor > 0 }))))) : null,
    matched > (p.sample || []).length ? h("p", { class: "help" }, `The newest ${(p.sample || []).length} of ${count(matched)}.`) : null);
}

const cachedRules = () => cached("rules");
