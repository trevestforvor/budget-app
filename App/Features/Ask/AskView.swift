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
    /// Questions asked while one is still being answered, sent in order once it's done — never dropped.
    @State private var queued: [String] = []
    /// Which conversation a reply belongs to. Starting a new one retires the old id, so a late reply
    /// to an earlier question can't land in the new conversation.
    @State private var session = UUID()

    static let starters = [
        "What did we spend on dining in Q3 vs Q2?",
        "Where did my money go this month?",
        "How much do subscriptions cost me?",
        "Can I set aside $5,000 by March?",
    ]

    var body: some View {
        NavigationStack {
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
                                    AnswerView(reply: reply, phases: phases, onApply: apply, onDismiss: { phases[$0.id] = .dismissed }) { followUp in
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
                if !entries.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("New conversation", systemImage: "square.and.pencil") { startOver() }
                    }
                }
            }
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
        queued = []
        isAsking = false
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
        }
    }

    private func apply(_ proposal: ProposedAction) {
        phases[proposal.id] = .applying
        Task {
            do {
                let message = try await app.perform(proposal.action)
                phases[proposal.id] = .applied(message)
            } catch {
                phases[proposal.id] = .failed(error.localizedDescription)
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
    var onApply: (ProposedAction) -> Void = { _ in }
    var onDismiss: (ProposedAction) -> Void = { _ in }
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
                proposalCard(proposal)
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
            applyTitle: isClient ? "Open" : "Apply",
            onApply: { onApply(proposal) },
            onDismiss: { onDismiss(proposal) })
    }
}
