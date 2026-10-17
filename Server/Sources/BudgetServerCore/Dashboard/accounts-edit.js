// [lane L] Editing an account from its row: its kind (a SimpleFIN guess corrected, say), a nickname that names it
// everywhere while the bank's own name keeps updating underneath, and its last digits. PATCH /v1/accounts/:id, with an
// Undo that sends the previous values back.
import { h, fill, api, button, busy, callout, drawer, tag, toast, afterWrite, reportError, plural, KIND } from "./core.js";

const NICKNAME_LIMIT = 60;
/// SimpleFIN doesn't say what kind an account is; Budget guesses from its name until the person says.
const kindGuessed = (a) => a.source === "simplefin" && !a.kindSetByPerson;

/// Sends `change` for account `a`; resolves to the server's AccountChangeResult.
const patch = (a, change) => api(`/v1/accounts/${encodeURIComponent(a.id)}`, { method: "PATCH", body: change });

/// The fields of `change` as they were before, so a second PATCH puts them back. An empty string clears.
function previous(a, change) {
  const out = {};
  if ("kind" in change) out.kind = a.kind;
  if ("nickname" in change) out.nickname = a.nickname || "";
  if ("mask" in change) out.mask = a.mask || "";
  return out;
}

async function undo(a, change) {
  try {
    await patch(a, previous(a, change));
    toast(`Put ${a.nickname || a.name} back`);
    await afterWrite();
  } catch (error) { reportError(error); }
}

/// The drawer: kind, nickname and last digits, with what the bank calls the account.
export function openAccountEdit(a) {
  const { body, foot, close } = drawer(`Edit ${a.nickname || a.name}`);
  const field = (label, input, help) => h("label", { class: "field" }, h("span", { class: "field-head" }, label), input, help ? h("span", { class: "help" }, help) : null);
  const kind = h("select", { class: "input", "aria-label": "Kind" }, Object.entries(KIND).map(([value, label]) => h("option", { value }, label)));
  kind.value = a.kind;
  const nickname = h("input", { class: "input", value: a.nickname || "", placeholder: a.name, maxlength: String(NICKNAME_LIMIT), autocomplete: "off" });
  const mask = h("input", { class: "input", value: a.mask || "", placeholder: "0909", inputmode: "numeric", maxlength: "5", autocomplete: "off", spellcheck: "false" });
  const flash = h("div", { class: "flash" });
  const bankNote = `Your bank calls it “${a.name}”.` + (kindGuessed(a) ? " SimpleFIN doesn't say what kind of account this is, so Budget guessed from its name." : "");

  fill(body, flash,
    h("p", { class: "t-callout muted" }, bankNote),
    h("div", { class: "form" },
      field("Kind", kind, "A card's balance counts as owed, not as cash. Investments count toward net worth only."),
      field("Nickname", nickname, "Names it everywhere in Budget. Leave it empty to use the bank's name."),
      field("Last digits", mask, "2 to 5 numbers, as on the card or statement. Leave it empty to use what the bank sends.")));

  /// Only what changed: a field the person didn't touch isn't sent, so it isn't marked as theirs.
  const change = () => {
    const out = {};
    if (kind.value !== a.kind || kindGuessed(a)) out.kind = kind.value;
    const n = nickname.value.trim(), m = mask.value.trim();
    if (n !== (a.nickname || "")) out.nickname = n;
    if (m !== (a.mask || "")) out.mask = m;
    return out;
  };
  const save = button("Save", { kind: "primary", onclick: (e) => busy(e.currentTarget, "Saving…", async () => {
    const c = change();
    if (!Object.keys(c).length) { close(); return; }
    if (c.mask && !/^\d{2,5}$/.test(c.mask)) throw new Error("Last digits are 2 to 5 numbers, like 0909.");
    const result = await patch(a, c);
    const sent = result.sentToReview ? ` ${plural(result.sentToReview, "money-in row")} went back to review.` : "";
    toast(`Saved ${result.account.nickname || result.account.name}.${sent}`, { action: { label: "Undo", run: () => undo(a, c) } });
    await afterWrite();
    if (!result.warning) { close(); return; }
    // Something to check stays in view until it's read.
    fill(flash, callout({ tone: "watch", title: result.warning }));
    fill(foot, button("Done", { kind: "primary", onclick: close }));
  }, { errorTarget: flash }) });
  fill(foot, save, button("Cancel", { kind: "quiet", onclick: close }));
}

/// Menu items for one account row: a note when its kind is only a guess, and Edit.
export function accountMenuItems(a) {
  return [
    kindGuessed(a) ? tag("Kind guessed from the name", "watch") : null,
    button("Edit", { compact: true, kind: "quiet", "aria-label": `Edit ${a.nickname || a.name}`, onclick: () => openAccountEdit(a) }),
  ].filter(Boolean);
}
