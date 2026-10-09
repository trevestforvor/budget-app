import BudgetKit
import DesignSystem
import SwiftUI

/// Assistant memory: the facts Ask keeps in mind across conversations — the person's plans, people, preferences.
/// Reached from Settings → Assistant and from the Ask hub. Separate from "What Budget has learned" (merchant memory).
struct AssistantMemoryView: View {
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<[AssistantMemory]> = .loading
    @State private var unavailable = false
    @State private var editing: Editing?
    @State private var toast: DSToastMessage?
    @State private var problem: String?

    enum Editing: Identifiable {
        case new
        case existing(AssistantMemory)
        var id: String {
            switch self {
            case .new: "new"
            case let .existing(memory): memory.id
            }
        }
    }

    var body: some View {
        Group {
            if unavailable {
                DSStateView(systemImage: "sparkles", title: "Not on this server yet",
                            message: "Update the Budget server on your Olares to give Ask a memory.")
                    .frame(maxHeight: .infinity)
            } else {
                switch state {
                case .loading:
                    LoadingPlaceholder(text: "Reading what Ask keeps in mind…")
                case let .failed(message):
                    DSStateView(systemImage: "wifi.slash", title: "Can't load this", message: message, actionTitle: "Try again") {
                        Task { await load() }
                    }
                case let .loaded(memories):
                    list(memories)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dsScreenBackground()
        .navigationTitle("Assistant memory")
        .navigationBarTitleDisplayMode(.inline)
        .announcesProblem(problem)
        .toolbar {
            if !unavailable, let memories = state.value, memories.count < AssistantMemory.maxCount {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add", systemImage: "plus") { editing = .new }
                        .accessibilityIdentifier("addAssistantMemory")
                }
            }
        }
        .task(id: app.revision) { await load() }
        .dsToast($toast)
        .sheet(item: $editing) { editing in
            switch editing {
            case .new:
                AssistantMemorySheet(title: "Remember", initial: "") { await add($0) }
            case let .existing(memory):
                AssistantMemorySheet(title: "Edit memory", initial: memory.text, onDelete: { await delete(memory) }) { await update(memory, to: $0) }
            }
        }
    }

    private func list(_ memories: [AssistantMemory]) -> some View {
        List {
            Section {
                SettingsCaption("Things you've asked Ask to keep in mind: plans, people, how you like answers. They help it understand you. It never quotes figures from them — every number still comes from your ledger.")
                if let problem {
                    SettingsNote(text: problem, tint: Color.ds.caution, systemImage: "exclamationmark.triangle.fill").settingsCardRow()
                }
            }
            if memories.isEmpty {
                Section {
                    DSStateView(systemImage: "sparkles", title: "Nothing yet",
                                message: "Tap + to add one, or tell Ask “remember that…” and apply its card.")
                        .settingsCardRow()
                }
            } else {
                DSListSection("\(memories.count) of \(AssistantMemory.maxCount)",
                              footer: memories.count >= AssistantMemory.maxCount ? "That's the most Ask keeps. Forget one to add another." : nil) {
                    ForEach(memories) { memory in
                        Button { editing = .existing(memory) } label: { row(memory) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("Forget", role: .destructive) { Task { await delete(memory) } }
                            }
                            .accessibilityHint("Edit or forget")
                            .accessibilityIdentifier("assistantMemoryRow")
                    }
                }
            }
        }
        .dsGroupedList()
    }

    private func row(_ memory: AssistantMemory) -> some View {
        let when = (memory.updatedAt ?? memory.createdAt).formatted(.dateTime.month(.abbreviated).day())
        let detail = memory.source == .assistant ? "From Ask · \(when)" : "Added \(when)"
        return DSListRow(memory.text, detail: detail, systemImage: memory.source == .assistant ? "sparkles" : "person", tone: .iris) {
            EmptyView()
        }
    }

    // MARK: Actions

    private func load() async {
        guard let assistant = app.assistant else {
            unavailable = true
            return
        }
        do {
            state = .loaded(try await assistant.assistantMemories())
            unavailable = false
        } catch BudgetAPIError.notFound {
            unavailable = true
        } catch {
            if !Task.isCancelled, state.value == nil { state = .failed(error.localizedDescription) }
        }
    }

    private func add(_ text: String) async -> Bool {
        await change("Ask will keep that in mind.") { _ = try await $0.addAssistantMemory(text) }
    }

    private func update(_ memory: AssistantMemory, to text: String) async -> Bool {
        await change("Saved.") { _ = try await $0.updateAssistantMemory(id: memory.id, text: text) }
    }

    private func delete(_ memory: AssistantMemory) async -> Bool {
        await change("Ask stopped keeping that in mind.") { try await $0.deleteAssistantMemory(id: memory.id) }
    }

    /// Runs a write, then reloads every screen (the prompt Settings shows changes with it).
    private func change(_ message: String, _ write: (any AssistantAPI) async throws -> Void) async -> Bool {
        problem = nil
        guard let assistant = app.assistant else { return false }
        do {
            try await write(assistant)
            await app.didWrite()
            toast = DSToastMessage(message)
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }
}

/// One memory, new or being edited: a sentence, at most `AssistantMemory.maxLength` characters.
struct AssistantMemorySheet: View {
    let title: String
    let initial: String
    var onDelete: (() async -> Bool)?
    let onSave: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isSaving = false
    @FocusState private var focused: Bool

    private var trimmed: String { AssistantMemory.normalized(text) }
    private var tooLong: Bool { trimmed.count > AssistantMemory.maxLength }

    var body: some View {
        NavigationStack {
            List {
                DSListSection(footer: "One fact, in your words. Ask reads it as background; figures still come from your ledger.") {
                    DSField(nil, style: .inline, error: tooLong ? "Keep it to \(AssistantMemory.maxLength) characters." : nil,
                            counter: "\(trimmed.count) / \(AssistantMemory.maxLength)", isFocused: focused) {
                        TextField("Saving for a trip in March", text: $text, axis: .vertical)
                            .lineLimit(2...6)
                            .focused($focused)
                            .padding(.vertical, DSSpace.xxs)
                            .accessibilityIdentifier("assistantMemoryField")
                    }
                }
                if let onDelete {
                    DSListSection {
                        SettingsDestructiveRow(title: "Forget") {
                            Task {
                                isSaving = true
                                if await onDelete() { dismiss() }
                                isSaving = false
                            }
                        }
                        .disabled(isSaving)
                    }
                }
            }
            .dsGroupedList()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled(trimmed.isEmpty || tooLong || trimmed == initial || isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.ds.canvas)
        .onAppear {
            text = initial
            focused = true
        }
    }

    private func save() {
        Task {
            isSaving = true
            if await onSave(trimmed) { dismiss() }
            isSaving = false
        }
    }
}
