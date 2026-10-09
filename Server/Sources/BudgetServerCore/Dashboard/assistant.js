// Assistant: what Ask keeps in mind (assistant memory: add, edit, forget) and the conversations it has kept (rename,
// delete). Reading a conversation stays on the phone, in Ask. Not merchant memory, which is how Budget files merchants.
import { fill, h, api, pageHead, sectionHead, button, busy, armed, toast, plural, dateShort, dateTime, tag, loadInto, reportError,
  emptyState } from "./core.js";

const MAX_MEMORIES = 30, MAX_MEMORY = 200, MAX_TITLE = 60;

/// One text field with its label and a counter, and Save / Cancel under it.
function editor({ label, value = "", max, saveLabel, onSave, onCancel }) {
  const id = `ed-${Math.random().toString(36).slice(2, 8)}`;
  const input = h("input", { class: "input", id, value, maxlength: String(max), autocomplete: "off" });
  const counter = h("span", { class: "faint" }, `${value.length} / ${max}`);
  const flash = h("div", { class: "flash" });
  input.addEventListener("input", () => { counter.textContent = `${input.value.trim().length} / ${max}`; });
  const save = button(saveLabel, { kind: "primary", compact: true, onclick: (e) => busy(e.currentTarget, "Saving…", async () => {
    const text = input.value.trim();
    if (!text) throw new Error("Write something first.");
    await onSave(text);
  }, { errorTarget: flash }) });
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); save.click(); }
    if (e.key === "Escape" && onCancel) { e.preventDefault(); onCancel(); }
  });
  const el = h("div", { class: "stack" },
    h("div", { class: "field" }, h("div", { class: "field-head" }, h("label", { for: id }, label), h("span", { class: "grow" }), counter), input),
    flash,
    h("div", { class: "actions" }, save, onCancel ? button("Cancel", { kind: "quiet", compact: true, onclick: onCancel }) : null));
  return { el, focus: () => input.focus() };
}

// MARK: Memory

function memoryRow(m, redraw) {
  const row = h("div", { class: "row" });
  const show = () => fill(row,
    h("div", { class: "grow" },
      h("div", { class: "title wrap" }, m.text),
      h("div", { class: "sub" }, m.source === "assistant" ? `From Ask · ${dateShort(m.updatedAt || m.createdAt)}` : `Added ${dateShort(m.updatedAt || m.createdAt)}`)),
    m.source === "assistant" ? tag("Ask", "tone-iris") : null,
    h("div", { class: "row-actions" },
      button("Edit", { kind: "quiet", compact: true, "aria-label": `Edit “${m.text}”`, onclick: edit }),
      button("Forget", { kind: "caution", compact: true, "aria-label": `Forget “${m.text}”`, onclick: (e) => armed(e.currentTarget, "Forget it?", async () => {
        try {
          await api(`/v1/assistant/memories/${encodeURIComponent(m.id)}`, { method: "DELETE" });
          toast("Ask stopped keeping that in mind.");
          redraw();
        } catch (error) { reportError(error); }
      }) })));
  function edit() {
    const ed = editor({ label: "Memory", value: m.text, max: MAX_MEMORY, saveLabel: "Save",
      onSave: async (text) => {
        await api(`/v1/assistant/memories/${encodeURIComponent(m.id)}`, { method: "PATCH", body: { text } });
        toast("Saved.");
        redraw();
      },
      onCancel: show });
    fill(row, h("div", { class: "grow" }, ed.el));
    ed.focus();
  }
  show();
  return row;
}

function memoryCard() {
  const body = h("div", { class: "rows" });
  const addSlot = h("div", {});
  const redraw = () => loadInto(body, () => api("/v1/assistant/memories"), (memories) => {
    const add = memories.length < MAX_MEMORIES
      ? editor({ label: "Something for Ask to keep in mind", max: MAX_MEMORY, saveLabel: "Remember",
        onSave: async (text) => {
          await api("/v1/assistant/memories", { method: "POST", body: { text } });
          toast("Ask will keep that in mind.");
          redraw();
        } }).el
      : h("p", { class: "help" }, `That's the most Ask keeps (${MAX_MEMORIES}). Forget one to add another.`);
    fill(addSlot, add);
    if (!memories.length) return h("p", { class: "empty-line" }, "Nothing yet. Add one here, or tell Ask “remember that…” on your phone and apply its card.");
    return [h("p", { class: "t-caption faint" }, `${plural(memories.length, "memory", "memories")} of ${MAX_MEMORIES}`), ...memories.map((m) => memoryRow(m, redraw))];
  });
  redraw();
  return h("section", { class: "card", "aria-labelledby": "memory-title" },
    h("p", { class: "t-callout muted" }, "Plans, people and preferences Ask reads as background in every conversation. It never quotes figures from them: every number still comes from the ledger."),
    body, addSlot);
}

// MARK: Conversations

function conversationRow(s, redraw) {
  const row = h("div", { class: "row" });
  const show = () => fill(row,
    h("div", { class: "grow" },
      h("div", { class: "title wrap" }, s.title),
      h("div", { class: "sub" }, `${plural(s.turnCount, "question")} · ${dateTime(s.updatedAt)}`)),
    h("div", { class: "row-actions" },
      button("Rename", { kind: "quiet", compact: true, "aria-label": `Rename “${s.title}”`, onclick: rename }),
      button("Delete", { kind: "caution", compact: true, "aria-label": `Delete “${s.title}”`, onclick: (e) => armed(e.currentTarget, "Delete it?", async () => {
        try {
          await api(`/v1/assistant/sessions/${encodeURIComponent(s.id)}`, { method: "DELETE" });
          toast("Deleted the conversation.");
          redraw();
        } catch (error) { reportError(error); }
      }) })));
  function rename() {
    const ed = editor({ label: "Name", value: s.title, max: MAX_TITLE, saveLabel: "Save",
      onSave: async (title) => {
        await api(`/v1/assistant/sessions/${encodeURIComponent(s.id)}`, { method: "PATCH", body: { title } });
        toast("Renamed.");
        redraw();
      },
      onCancel: show });
    fill(row, h("div", { class: "grow" }, ed.el));
    ed.focus();
  }
  show();
  return row;
}

function conversationsCard() {
  const body = h("div", { class: "rows" });
  const redraw = () => loadInto(body, () => api("/v1/assistant/sessions"), (sessions) => sessions.length
    ? sessions.map((s) => conversationRow(s, redraw))
    : emptyState({ title: "No conversations yet", body: "Questions asked in Ask are kept here, newest first." }));
  redraw();
  return h("section", { class: "card", "aria-labelledby": "chats-title" },
    h("p", { class: "t-callout muted" }, "Open one in Ask on your phone to read it or carry on. The oldest go once there are more than 50."),
    body);
}

export default {
  title: "Assistant",
  mount(root) {
    fill(root,
      pageHead({ eyebrow: "Ask", title: "Assistant", bloom: "ai",
        sub: "What Ask keeps in mind about you, and the conversations it has kept." }),
      sectionHead("Assistant memory", null, "memory-title"), memoryCard(),
      sectionHead("Conversations", null, "chats-title"), conversationsCard());
  },
};
