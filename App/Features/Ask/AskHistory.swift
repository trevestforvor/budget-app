import BudgetKit
import DesignSystem
import SwiftUI

/// Pages the Ask hub pushes.
enum AskRoute: Hashable {
    /// Every kept conversation (`ChatHistoryView`).
    case conversations
    /// What Ask keeps in mind (`AssistantMemoryView`).
    case memory
}

extension AppModel {
    /// Assistant memory and chat history, when this connection has them (the demo, or a server from 0.5.0).
    var assistant: (any AssistantAPI)? { api as? any AssistantAPI }
}

/// Conversations split the way Recents shows them: today's, then everything before.
struct ConversationGroups {
    var today: [ChatSessionSummary] = []
    var older: [ChatSessionSummary] = []

    init(_ sessions: [ChatSessionSummary], now: Date = AppClock.now, calendar: Calendar = .current) {
        for session in sessions.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            if calendar.isDate(session.updatedAt, inSameDayAs: now) { today.append(session) } else { older.append(session) }
        }
    }

    var sections: [(title: String, sessions: [ChatSessionSummary])] {
        [("Today", today), ("Older", older)].filter { !$0.1.isEmpty }
    }
}

extension ChatSessionSummary {
    /// "3 questions · 2:14 PM", or "· Sep 18" before today.
    func detail(now: Date = AppClock.now) -> String {
        let count = "\(turnCount) question\(turnCount == 1 ? "" : "s")"
        let when = Calendar.current.isDate(updatedAt, inSameDayAs: now)
            ? updatedAt.formatted(date: .omitted, time: .shortened)
            : updatedAt.formatted(.dateTime.month(.abbreviated).day())
        return "\(count) · \(when)"
    }
}

/// The conversation row, with rename and delete on a long press.
struct ConversationRow: View {
    let session: ChatSessionSummary
    var showsChevron = false

    var body: some View {
        DSListRow(session.title, detail: session.detail(), systemImage: "bubble.left.and.text.bubble.right", tone: .iris) {
            if showsChevron { DSListValue(nil, showsChevron: true) }
        }
    }
}

/// Recents on the Ask hub: the latest few conversations, grouped Today and Older, and a way to all of them.
struct AskRecentsCard: View {
    let sessions: [ChatSessionSummary]
    let onOpen: (ChatSessionSummary) -> Void
    let onRename: (ChatSessionSummary) -> Void
    let onDelete: (ChatSessionSummary) -> Void

    static let shown = 5

    var body: some View {
        let groups = ConversationGroups(Array(sessions.prefix(Self.shown)))
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            DSSectionHeader("Recents")
            ForEach(groups.sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    DSEyebrow(section.title)
                    DSCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(section.sessions.enumerated()), id: \.element.id) { index, session in
                                Button { onOpen(session) } label: { ConversationRow(session: session, showsChevron: true) }
                                    .buttonStyle(DSPressStyle(radius: 0))
                                    .contextMenu {
                                        Button("Rename", systemImage: "pencil") { onRename(session) }
                                        Button("Delete", systemImage: "trash", role: .destructive) { onDelete(session) }
                                    }
                                    .accessibilityHint("Opens the conversation. Touch and hold to rename or delete it.")
                                    .accessibilityIdentifier("askRecent")
                                if index < section.sessions.count - 1 { DSDivider() }
                            }
                        }
                        .padding(.horizontal, DSSpace.md)
                    }
                }
            }
            if sessions.count > Self.shown {
                NavigationLink(value: AskRoute.conversations) {
                    Text("All \(sessions.count) conversations").dsFont(.callout)
                }
                .buttonStyle(.ds(.quiet))
                .accessibilityIdentifier("askAllConversations")
            }
        }
    }
}

/// Every conversation Ask has kept, Today then Older. Open one to carry on; swipe or hold to rename or delete.
struct ChatHistoryView: View {
    let onOpen: (ChatSessionSummary) -> Void

    @Environment(AppModel.self) private var app
    @State private var state: LoadState<[ChatSessionSummary]> = .loading
    @State private var query = ""
    @State private var renaming: ChatSessionSummary?
    @State private var deleting: ChatSessionSummary?
    @State private var problem: String?

    var body: some View {
        Group {
            switch state {
            case .loading:
                LoadingPlaceholder(text: "Reading your conversations…")
            case let .failed(message):
                DSStateView(systemImage: "wifi.slash", title: "Can't load conversations", message: message, actionTitle: "Try again") {
                    Task { await load() }
                }
            case let .loaded(sessions) where sessions.isEmpty:
                DSStateView(systemImage: "bubble.left.and.text.bubble.right", title: "No conversations yet",
                            message: "Questions you ask are kept here, so you can come back to them.")
                    .frame(maxHeight: .infinity)
            case let .loaded(sessions):
                list(sessions)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dsScreenBackground()
        .navigationTitle("Conversations")
        .navigationBarTitleDisplayMode(.inline)
        .announcesProblem(problem)
        .task(id: app.revision) { await load() }
        .sheet(item: $renaming) { session in
            RenameConversationSheet(initial: session.title) { title in await rename(session, to: title) }
        }
        .confirmationDialog(deleting.map { "Delete “\($0.title)”?" } ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { session in
            Button("Delete", role: .destructive) { Task { await delete(session) } }
        } message: { _ in
            Text("The conversation is removed from this server. Changes you applied from it stay.")
        }
    }

    private func list(_ sessions: [ChatSessionSummary]) -> some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = q.isEmpty ? sessions : sessions.filter {
            $0.title.localizedCaseInsensitiveContains(q) || ($0.lastQuestion?.localizedCaseInsensitiveContains(q) ?? false)
        }
        let groups = ConversationGroups(shown)
        return List {
            if let problem {
                SettingsNote(text: problem, tint: Color.ds.caution, systemImage: "exclamationmark.triangle.fill").settingsCardRow()
            }
            if shown.isEmpty {
                SettingsCaption("Nothing matches “\(q)”.")
            }
            ForEach(groups.sections, id: \.title) { section in
                DSListSection(section.title) {
                    ForEach(section.sessions) { session in
                        Button { onOpen(session) } label: { ConversationRow(session: session) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("Delete", role: .destructive) { deleting = session }
                                Button("Rename") { renaming = session }.tint(Color.ds.iris)
                            }
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") { renaming = session }
                                Button("Delete", systemImage: "trash", role: .destructive) { deleting = session }
                            }
                    }
                }
            }
        }
        .dsGroupedList()
        .searchable(text: $query, prompt: "Conversations")
    }

    private func load() async {
        guard let assistant = app.assistant else {
            state = .failed("This connection doesn't keep conversations.")
            return
        }
        state = await state.refreshed { try await assistant.chatSessions() }
    }

    private func rename(_ session: ChatSessionSummary, to title: String) async -> Bool {
        problem = nil
        do {
            _ = try await app.assistant?.renameChatSession(id: session.id, title: title)
            await load()
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    private func delete(_ session: ChatSessionSummary) async {
        problem = nil
        do {
            try await app.assistant?.deleteChatSession(id: session.id)
            await load()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// A new name for a conversation.
struct RenameConversationSheet: View {
    let initial: String
    let onSave: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var isSaving = false
    @FocusState private var focused: Bool

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var tooLong: Bool { trimmed.count > ChatSession.maxTitleLength }

    var body: some View {
        NavigationStack {
            List {
                DSListSection {
                    DSField("Name", style: .inline, error: tooLong ? "Keep it to \(ChatSession.maxTitleLength) characters." : nil,
                            counter: "\(trimmed.count) / \(ChatSession.maxTitleLength)", isFocused: focused) {
                        TextField("Conversation name", text: $title)
                            .focused($focused)
                            .submitLabel(.done)
                            .onSubmit(save)
                            .accessibilityIdentifier("conversationNameField")
                    }
                }
            }
            .dsGroupedList()
            .navigationTitle("Rename conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save", action: save)
                        .disabled(trimmed.isEmpty || tooLong || trimmed == initial || isSaving)
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(Color.ds.canvas)
        .onAppear {
            title = initial
            focused = true
        }
    }

    private func save() {
        guard !trimmed.isEmpty, !tooLong, !isSaving else { return }
        Task {
            isSaving = true
            if await onSave(trimmed) { dismiss() }
            isSaving = false
        }
    }
}
