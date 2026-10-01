// Categories & rules: the categories transactions are filed under (spending by budget type, then money in, then
// Transfer), with "Add a category"; and the rules that file new transactions under them (rules.js). Renaming,
// recoloring and merging stay on the phone. Review's "Make a rule" lands here with its drawer open.
import { fill, h, store, pageHead, sectionHead, button, busy, toast, plural, isMoneyIn, BUDGET_TYPES, newCategoryFields, createCategory,
  closeDrawer } from "./core.js";
import { renderRules, refreshRules, openRule, takePendingRule } from "./rules.js";

const active = () => ((store.summary && store.summary.categories) || []).filter((c) => !c.isArchived);

/// Spending by budget type, then money in, then neither (Transfer): the phone's Settings → Categories sections.
function sections(list) {
  return [
    ...BUDGET_TYPES.map(([group, label, line]) => ({ id: group, label, line, rows: list.filter((c) => c.countsAsSpending && c.group === group) })),
    { id: "moneyIn", label: "Money in", line: "Counts as money coming in, like income: never spending, never budgeted.", rows: list.filter(isMoneyIn) },
    { id: "neither", label: "Not spending", line: "Moves between your own accounts count as neither spending nor money in.",
      rows: list.filter((c) => !c.countsAsSpending && !isMoneyIn(c)) },
  ].filter((s) => s.rows.length);
}

function categoryRow(c) {
  return h("li", { class: "cat-row" }, h("span", { class: `sw tone-${c.color || "amber"}`, "aria-hidden": "true" }),
    h("span", { class: "cat-name" }, c.name));
}

/// The list, redrawn after every write; the add form beside it keeps whatever is being typed.
function drawCategories(el) {
  const list = active(), spending = list.filter((c) => c.countsAsSpending).length, moneyIn = list.filter(isMoneyIn).length;
  fill(el,
    h("p", { class: "t-caption faint cat-count" }, [plural(list.length, "category", "categories"), `${spending} spending`, `${moneyIn} money in`].join(" · ")),
    h("div", { class: "cat-groups" }, sections(list).map((s) => h("section", { class: "cat-group", "aria-labelledby": `catg-${s.id}` },
      h("h3", { class: "t-eyebrow cat-group-title", id: `catg-${s.id}` }, s.label, h("span", { class: "cat-group-count" }, String(s.rows.length))),
      h("p", { class: "help" }, s.line),
      h("ul", { class: "cat-list" }, s.rows.map(categoryRow))))));
}

function categoriesCard(view) {
  const fields = newCategoryFields();
  const flash = h("div", { class: "flash" });
  const listEl = h("div", { class: "cat-body" });
  const add = button("Add a category", { compact: true, id: "add-category", "aria-expanded": "false", "aria-controls": "new-category",
    onclick: () => toggle(true) });
  const save = button("Add category", { kind: "primary", onclick: (e) => busy(e.currentTarget, "Adding…", async () => {
    const { action, problem } = fields.read();
    if (problem) throw new Error(problem);
    const { result } = await createCategory(action);
    toast(result.message || `Added ${action.name}`);
    fields.reset();
    toggle(false);
    drawCategories(listEl);
  }, { errorTarget: flash }) });
  const form = h("div", { class: "newcat-panel", id: "new-category", hidden: true },
    h("h3", { class: "t-eyebrow card-title" }, "New category"), fields.el,
    h("div", { class: "actions" }, save, button("Cancel", { kind: "quiet", onclick: () => toggle(false) })));
  function toggle(open) {
    form.hidden = !open;
    add.hidden = open;
    add.setAttribute("aria-expanded", String(open));
    fill(flash);
    if (open) fields.focus(); else add.focus();
  }
  form.addEventListener("keydown", (e) => { if (e.key === "Escape") { e.preventDefault(); toggle(false); } });
  view.categoryList = listEl;
  drawCategories(listEl);
  return h("section", { class: "card cats", "aria-labelledby": "cats-title" },
    h("div", { class: "rules-head" }, h("div", { class: "grow" },
      h("p", { class: "t-callout muted" }, "Every transaction is filed under one of these. Spending counts against your budget by its budget type; money in counts like income."),
      h("p", { class: "t-caption faint" }, "Rename, recolor or merge on your phone in Settings → Categories.")), add),
    flash, form, listEl);
}

export default {
  title: "Categories & rules",
  mount(root, { sub }) {
    this.root = root;
    this.rules = h("div", { class: "rules-panel" });
    fill(root,
      pageHead({ eyebrow: "How things get filed", title: "Categories & rules",
        sub: "What transactions are filed under, and the rules that file new ones for you. It's the same ledger your phone shows." }),
      sectionHead("Categories", null, "cats-title"), categoriesCard(this),
      sectionHead("Rules", null, "rules-title"), this.rules);
    renderRules(this.rules);
    const prefill = takePendingRule();
    if (prefill) openRule({ prefill, onSaved: () => renderRules(this.rules, { focus: "add" }) });
    this.show(sub, { first: true });
  },
  navigate({ sub }) { this.show(sub); },
  /// #/categories/rules scrolls to the rules (Settings links there).
  show(sub, { first = false } = {}) {
    if (sub !== "rules") return;
    const head = this.root.querySelector("#rules-title");
    if (head) setTimeout(() => head.scrollIntoView({ block: "start", behavior: first ? "auto" : "smooth" }), 0);
  },
  unmount() { closeDrawer(); },
  refresh({ after = false } = {}) {
    if (this.categoryList && this.categoryList.isConnected) drawCategories(this.categoryList);
    if (after) refreshRules(this.rules);
  },
};
