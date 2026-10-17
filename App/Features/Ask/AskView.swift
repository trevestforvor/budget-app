import BudgetKit
import DesignSystem
import SwiftUI

struct ChatEntry: Identifiable {
    enum Kind {
        case user(String)
        case answer(AskReply)
        case failure(String)
    }

    let id = UUID()
    let kind: Kind
}

/// Natural-language questions through the server's agent loop.
/// Numbers in answers come from ledger tools; the model only explains them.
struct AskView: View {
    @Environment(AppModel.self) private var app
    @State private var entries: [ChatEntry] = []
    @State private var draft = ""
    @State private var isAsking = false
    @State private var conversationID: String?
    @State private var phases: [String: DSActionCard.Phase] = [:]
    /// Proposals refreshed after going stale, by id: what they would do now, and the basis to apply them with.
    @State private var refreshed: [String: ProposedAction] = [:]
    /// A proposal reaching more than a handful of rows, shown with its count and sample before it applies.
    @State private var reviewing: ProposedAction?
    /// Questions asked while one is still being answered, sent in order once it's done — never dropped.
    @State private var queued: [String] = []
    /// Which conversation a reply belongs to. Starting a new one retires the old id, so a late reply
    /// to an earlier question can't land in the new conversation.
    @State private var session = UUID()
    @State private var path: [AskRoute] = []
    /// Recents for the hub; nil where this connection keeps no conversations (an older server).
    @State private var recents: [ChatSessionSummary]?
    @State private var memoryCount: Int?
    /// Bumped after every answer, so Recents is read again.
    @State private var historyVersion = 0
    @State private var isOpening = false
    @State private var renaming: ChatSessionSummary?
    @State private var deletingSession: ChatSessionSummary?
    @State private var toast: DSToastMessage?

    static let starters = [
        "What did we spend on dining in Q3 vs Q2?",
        "Where did my money go this month?",
        "How much do subscriptions cost me?",
        "Can I set aside $5,000 by March?",
    ]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DSSpace.lg) {
                        if entries.isEmpty { intro }
                        ForEach(entries) { entry in
                            Group {
                                switch entry.kind {
                                case let .user(text):
                                    DSUserBubble(text)
                                case let .answer(reply):
                                    AnswerView(reply: reply, phases: phases, refreshed: refreshed, onApply: { apply($0) },
                                               onDismiss: { phases[$0.id] = .dismissed }, onRefresh: refresh) { followUp in
                                        if followUp == "Open the plan" { app.selectedTab = .plan } else { send(followUp) }
                                    }
                                case let .failure(message):
                                    Text(message).dsFont(.callout).foregroundStyle(Color.ds.caution)
                                }
                            }
                            .id(entry.id)
                        }
                        if isAsking {
                            DSThinkingLine("Running ledger tools…").id("thinking")
                        }
                        if isOpening {
                            DSThinkingLine("Opening the conversation…").id("opening")
                        }
                    }
                    .padding(.horizontal, DSSpace.gutter)
                    .padding(.vertical, DSSpace.md)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: entries.count) {
                    guard let last = entries.last else { return }
                    withAnimation(DSMotion.gentle) { proxy.scrollTo(last.id, anchor: .top) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                DSAskField(text: $draft, isBusy: isAsking) { send(draft) }
                    .padding(.horizontal, DSSpace.gutter)
                    .padding(.vertical, DSSpace.xs)
                    .background {
                        LinearGradient(colors: [Color.ds.canvas.opacity(0), Color.ds.canvas], startPoint: .top, endPoint: .center)
                            .ignoresSafeArea()
                    }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .dsScreenBackground(bloom: .ai)
            .toolbar {
                if recents != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Conversations", systemImage: "clock.arrow.circlepath") { path = [.conversations] }
                            .accessibilityIdentifier("askConversations")
                    }
                }
                if !entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New conversation", systemImage: "square.and.pencil") { startOver() }
                    }
                }
            }
            .navigationDestination(for: AskRoute.self) { route in
                switch route {
                case .conversations: ChatHistoryView { open($0) }
                case .memory: AssistantMemoryView()
                }
            }
            .task(id: "\(app.revision)|\(historyVersion)") { await loadHistory() }
            .dsToast($toast)
            .sheet(item: $reviewing) { proposal in
                ProposalReviewSheet(proposal: proposal) { apply(proposal, reviewed: true) }
            }
            .sheet(item: $renaming) { summary in
                RenameConversationSheet(initial: summary.title) { await rename(summary, to: $0) }
            }
            .confirmationDialog(deletingSession.map { "Delete “\($0.title)”?" } ?? "",
                                isPresented: Binding(get: { deletingSession != nil }, set: { if !$0 { deletingSession = nil } }),
                                titleVisibility: .visible, presenting: deletingSession) { summary in
                Button("Delete", role: .destructive) { Task { await delete(summary) } }
            } message: { _ in
                Text("The conversation is removed from this server. Changes you applied from it stay.")
            }
        }
        .onChange(of: app.askRoute, initial: true) {
            guard let route = app.askRoute else { return }
            app.askRoute = nil
            path = [route]
        }
        // A question handed over from another screen ("Ask about this") starts its own conversation, whether
        // Ask is opening for the first time or was already open — so it never continues an unrelated thread.
        .onChange(of: app.pendingQuestion, initial: true) {
            guard let question = app.pendingQuestion else { return }
            app.pendingQuestion = nil
            startOver()
            send(question)
        }
    }

    private func startOver() {
        session = UUID()
        entries = []
        conversationID = nil
        phases = [:]
        refreshed = [:]
        reviewing = nil
        queued = []
        isAsking = false
        isOpening = false
    }

    // MARK: Conversations

    private func loadHistory() async {
        guard let assistant = app.assistant else {
            (recents, memoryCount) = (nil, nil)
            return
        }
        do {
            recents = try await assistant.chatSessions()
        } catch BudgetAPIError.notFound {
            recents = nil
        } catch {
            // Offline: keep what was shown.
        }
        if let memories = try? await assistant.assistantMemories() { memoryCount = memories.count }
    }

    /// Reopens a kept conversation where it left off: its turns as they were answered, and the next question continues
    /// it. Proposals from back then show as earlier, not to apply again.
    private func open(_ summary: ChatSessionSummary) {
        path = []
        startOver()
        guard let assistant = app.assistant else { return }
        isOpening = true
        let opened = session
        Task {
            do {
                let kept = try await assistant.chatSession(id: summary.id)
                guard session == opened else { return }
                entries = kept.turns.flatMap { [ChatEntry(kind: .user($0.question)), ChatEntry(kind: .answer($0.reply))] }
                for proposal in kept.turns.flatMap(\.reply.proposedActions) { phases[proposal.id] = .earlier }
                conversationID = kept.id
            } catch {
                guard session == opened else { return }
                entries = [ChatEntry(kind: .failure(error.localizedDescription))]
            }
            isOpening = false
        }
    }

    /// Nil once renamed; otherwise why not, for the sheet to show.
    private func rename(_ summary: ChatSessionSummary, to title: String) async -> String? {
        guard let assistant = app.assistant else { return "This connection doesn't keep conversations." }
        do {
            _ = try await assistant.renameChatSession(id: summary.id, title: title)
            historyVersion += 1
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func delete(_ summary: ChatSessionSummary) async {
        guard let assistant = app.assistant else { return }
        do {
            try await assistant.deleteChatSession(id: summary.id)
            if conversationID == summary.id { startOver() }
            historyVersion += 1
        } catch {
            toast = DSToastMessage("Couldn't delete it: \(error.localizedDescription)")
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: DSSpace.lg) {
            PageTitle("Ask about\nyour money.", eyebrow: "Ask")
            Text("Answers are computed by your ledger. The model reads the results and explains them — it never does the math.")
                .dsFont(.callout)
                .foregroundStyle(Color.ds.inkSecondary)
            VStack(spacing: DSSpace.xs) {
                ForEach(Self.starters, id: \.self) { starter in
                    Button { send(starter) } label: {
                        HStack {
                            Text(starter).dsFont(.body).foregroundStyle(Color.ds.inkSoft).multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right").foregroundStyle(Color.ds.inkTertiary).accessibilityHidden(true)
                        }
                        .padding(DSSpace.md)
                        .background(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous).fill(Color.ds.surface))
                        .overlay(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous).strokeBorder(Color.ds.hairline))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if let recents, !recents.isEmpty {
                AskRecentsCard(sessions: recents, onOpen: open, onRename: { renaming = $0 }, onDelete: { deletingSession = $0 })
            }
            if let memoryCount {
                NavigationLink(value: AskRoute.memory) {
                    DSCard(padding: 0) {
                        DSListRow("Assistant memory", detail: memoryCount == 0 ? "Nothing kept yet" : "\(memoryCount) thing\(memoryCount == 1 ? "" : "s") Ask keeps in mind",
                                  systemImage: "sparkles", tone: .iris, showsChevron: true)
                            .padding(.horizontal, DSSpace.md)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("askAssistantMemory")
            }
        }
    }

    /// Applies a proposal with the basis it was made against, so the server refuses it (409) if its rows changed since.
    /// One changing more than a handful of rows shows its count and sample first.
    private func apply(_ proposal: ProposedAction, reviewed: Bool = false) {
        let proposal = refreshed[proposal.id] ?? proposal
        if proposal.needsReview, !reviewed {
            reviewing = proposal
            return
        }
        phases[proposal.id] = .applying
        Task {
            do {
                let message = try await app.perform(proposal.action, basis: proposal.basis)
                phases[proposal.id] = .applied(message)
            } catch let BudgetAPIError.server(status, message) where status == 409 {
                phases[proposal.id] = .stale(message ?? "Your data changed since this was proposed. Refresh it to see what it would do now.")
            } catch BudgetAPIError.notFound {
                // A row it changes is gone (a pending charge posted under a new id, or a sync swept it): trying again would
                // only be refused again, so it's retired with the reason, as Refresh does.
                phases[proposal.id] = .unavailable("That's no longer possible: what it changes is gone.")
            } catch {
                phases[proposal.id] = .failed(error.localizedDescription)
            }
        }
    }

    /// Works a stale proposal out again from the ledger as it is now — a preview, no model call — and offers it again.
    /// One that can't be done any more is retired with the reason, not offered again: retrying it would only be refused.
    private func refresh(_ proposal: ProposedAction) {
        guard case let .stale(message) = phases[proposal.id] else { return }
        phases[proposal.id] = .refreshing(message)
        Task {
            do {
                let preview = try await app.api.preview(proposal.action)
                refreshed[proposal.id] = ProposedAction(id: proposal.id, action: proposal.action, preview: preview, timeZone: .current) {
                    app.category($0)?.name
                }
                phases[proposal.id] = .proposed
            } catch BudgetAPIError.notFound {
                phases[proposal.id] = .unavailable("That's no longer possible: what it changes is gone.")
            } catch let BudgetAPIError.rejected(reason) {
                phases[proposal.id] = .unavailable("That's no longer possible: \(reason)")
            } catch {
                phases[proposal.id] = .stale("Couldn't refresh it: \(error.localizedDescription)")
            }
        }
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        guard !isAsking else {
            queued.append(question)
            return
        }
        entries.append(ChatEntry(kind: .user(question)))
        isAsking = true
        let api = app.api
        let conversation = conversationID
        let asked = session
        Task {
            let entry: ChatEntry
            do {
                let reply = try await api.ask(question, conversationID: conversation)
                guard session == asked else { return }
                conversationID = reply.conversationID
                entry = ChatEntry(kind: .answer(reply))
                historyVersion += 1
            } catch {
                guard session == asked else { return }
                entry = ChatEntry(kind: .failure(error.localizedDescription))
            }
            entries.append(entry)
            isAsking = false
            if !queued.isEmpty { send(queued.removeFirst()) }
        }
    }
}

struct AnswerView: View {
    let reply: AskReply
    var phases: [String: DSActionCard.Phase] = [:]
    var refreshed: [String: ProposedAction] = [:]
    var onApply: (ProposedAction) -> Void = { _ in }
    var onDismiss: (ProposedAction) -> Void = { _ in }
    var onRefresh: (ProposedAction) -> Void = { _ in }
    let onFollowUp: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.md) {
            HStack(spacing: DSSpace.xs) {
                Image(systemName: "sparkle").foregroundStyle(Color.ds.iris).accessibilityHidden(true)
                DSEyebrow("Answer")
            }
            Text(reply.text)
                .dsFont(.body)
                .foregroundStyle(Color.ds.inkSoft)
                .fixedSize(horizontal: false, vertical: true)

            if !reply.figures.isEmpty {
                DSCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(reply.figures.enumerated()), id: \.element.id) { index, figure in
                            DSFigureRow(label: figure.label, detail: figure.detail, value: figure.value.decimal, currencyCode: figure.value.currencyCode)
                            if index < reply.figures.count - 1 { DSDivider() }
                        }
                    }
                    .padding(.horizontal, DSSpace.md)
                    .padding(.vertical, DSSpace.xs)
                }
            }

            ForEach(reply.proposedActions) { proposal in
                proposalCard(refreshed[proposal.id] ?? proposal)
            }

            let reads = reply.toolCalls.filter { ToolCatalog.spec(named: $0.name)?.kind == .read }
            if !reads.isEmpty || reply.proposedActions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if !reads.isEmpty { DSEyebrow("Computed by the ledger") }
                    ForEach(reads) { call in
                        DSToolTrace(name: call.name, arguments: call.displayArguments)
                    }
                    Text(reply.model).dsFont(.caption).foregroundStyle(Color.ds.inkTertiary)
                }
            }

            if !reply.followUps.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DSSpace.xs) {
                        ForEach(reply.followUps, id: \.self) { followUp in
                            DSChip(followUp) { onFollowUp(followUp) }
                        }
                    }
                }
            }
        }
    }

    private func proposalCard(_ proposal: ProposedAction) -> DSActionCard {
        let effects: [DSActionCard.Effect] = proposal.effects.map { figure in
            let value = figure.id == "change" ? figure.value.signedString : figure.value.formatted()
            return DSActionCard.Effect(id: figure.id, label: figure.label, value: value, emphasized: figure.id == "new")
        }
        let arguments = (try? proposal.action.argumentsJSON()).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let display = ToolCall(id: proposal.id, name: proposal.action.toolName, arguments: arguments).displayArguments
        let isClient = proposal.action.isClientOnly
        return DSActionCard(
            eyebrow: isClient ? "Suggested" : "Proposed change",
            title: proposal.title,
            detail: proposal.detail,
            effects: effects,
            trace: (name: proposal.action.toolName, arguments: display),
            phase: phases[proposal.id] ?? .proposed,
            applyTitle: isClient ? "Open" : proposal.needsReview ? "Review \(proposal.reviewCount)" : "Apply",
            onApply: { onApply(proposal) },
            onDismiss: { onDismiss(proposal) },
            onRefresh: { onRefresh(proposal) })
    }
}
