import Foundation

/// Assistant memory (in the ledger, through `write`) and chat history (in `chatStore`).
extension LedgerBudgetAPI: AssistantAPI {
    // MARK: Assistant memory

    public func assistantMemories() async throws -> [AssistantMemory] {
        tick()
        return ledger.assistantMemoriesNewestFirst
    }

    public func addAssistantMemory(_ text: String) async throws -> AssistantMemory {
        tick(); await pause(0.3)
        return try await write { try ledger.addAssistantMemory(text, source: .person) }
    }

    public func updateAssistantMemory(id: String, text: String) async throws -> AssistantMemory {
        tick(); await pause(0.3)
        return try await write { try ledger.updateAssistantMemory(id: id, text: text) }
    }

    public func deleteAssistantMemory(id: String) async throws {
        tick(); await pause(0.3)
        try await write { try ledger.deleteAssistantMemory(id: id) }
    }

    // MARK: Chat history

    /// Where conversations are kept from now on (the server's database). Conversations kept before stay where they were.
    public func setChatSessionStore(_ store: any ChatSessionStore) {
        chatStore = store
        seedsDemoChats = false
    }

    public func chatSessions() async throws -> [ChatSessionSummary] {
        tick()
        await seedDemoChatsIfNeeded()
        return try await chatStore.chatSummaries()
    }

    public func chatSession(id: String) async throws -> ChatSession {
        tick()
        await seedDemoChatsIfNeeded()
        guard let record = try await chatStore.chatRecord(id: id) else { throw BudgetAPIError.notFound }
        return record.session
    }

    public func renameChatSession(id: String, title: String) async throws -> ChatSessionSummary {
        tick()
        let text = AssistantMemory.normalized(title)
        guard !text.isEmpty else { throw BudgetAPIError.rejected("Give the conversation a name.") }
        guard text.count <= ChatSession.maxTitleLength else {
            throw BudgetAPIError.rejected("Keep the name to \(ChatSession.maxTitleLength) characters.")
        }
        await seedDemoChatsIfNeeded()
        return try await oneAtATime {
            guard var record = try await chatStore.chatRecord(id: id) else { throw BudgetAPIError.notFound }
            record.session.title = text
            try await chatStore.saveChatRecord(record)
            return record.session.summary
        }
    }

    public func deleteChatSession(id: String) async throws {
        tick()
        await seedDemoChatsIfNeeded()
        try await oneAtATime {
            guard try await chatStore.chatRecord(id: id) != nil else { throw BudgetAPIError.notFound }
            try await chatStore.deleteChatRecord(id: id)
        }
    }

    /// Every conversation goes with the ledger it talked about (an admin reset).
    public func clearChatSessions() async throws {
        seedsDemoChats = false
        await demoChatSeeding?.value
        try await oneAtATime { try await chatStore.deleteAllChatRecords() }
    }

    /// What the model sees of the conversation before the next question; nothing for a new one, or when the
    /// conversation can't be read (the question is still answered, on its own).
    /// `existed` says whether the conversation was kept when the question came in (`recordTurn` needs it).
    func chatHistory(for id: String) async -> (messages: [ChatMessage], existed: Bool) {
        await seedDemoChatsIfNeeded()
        let record = (try? await chatStore.chatRecord(id: id)) ?? nil
        return (record?.modelHistory() ?? [], record != nil)
    }

    /// Keeps the turn with its conversation (starting one for a new id), then drops the least recently used past
    /// `ChatSession.maxSessions`. A store that can't be written loses the turn, not the answer. A conversation that
    /// existed when the question came in (`existed`) and is gone now was deleted while the answer was on its way: it
    /// stays deleted.
    func recordTurn(_ question: String, reply: AskReply, transcript: [ChatMessage], in id: String, existed: Bool = false) async {
        let askedAt = ledger.now
        try? await oneAtATime {
            let existing = try await chatStore.chatRecord(id: id)
            if existing == nil, existed { return }
            var record = existing ?? .new(id: id, question: question, at: askedAt)
            record.append(ChatTurn(id: reply.id, question: question, askedAt: askedAt, reply: reply), transcript: transcript)
            try await chatStore.saveChatRecord(record)
            guard existing == nil else { return }
            let all = try await chatStore.chatSummaries()
            for old in all.dropFirst(ChatSession.maxSessions) { try await chatStore.deleteChatRecord(id: old.id) }
        }
    }

    /// Chat-history changes take turns: each reads a conversation, changes it and saves it back, and two overlapping
    /// there (two questions in one conversation) would lose one's turn.
    private func oneAtATime<T>(_ body: () async throws -> T) async throws -> T {
        if recordingChat { await withCheckedContinuation { waitingChatRecorders.append($0) } } else { recordingChat = true }
        defer { if waitingChatRecorders.isEmpty { recordingChat = false } else { waitingChatRecorders.removeFirst().resume() } }
        return try await body()
    }

    /// The demo's history: a few conversations answered by the templated engine over today's demo ledger, so
    /// Recents has something to open.
    private func seedDemoChatsIfNeeded() async {
        if seedsDemoChats {
            seedsDemoChats = false
            let engine = DemoAskEngine(ledger: ledger, institutions: deployment.institutions)
            let now = ledger.now
            let conversations: [(id: String, ago: TimeInterval, questions: [String])] = [
                ("demo-chat-month", 50 * 60, ["Where did my money go this month?"]),
                ("demo-chat-dining", 26 * 3600, ["What did we spend on dining in Q3 vs Q2?", "Set the dining target to $500"]),
                ("demo-chat-subscriptions", 6 * 86_400, ["How much do subscriptions cost me?"]),
            ]
            let records = conversations.map { conversation in
                let start = now.addingTimeInterval(-conversation.ago)
                var record = ChatSessionRecord.new(id: conversation.id, question: conversation.questions[0], at: start)
                for (index, question) in conversation.questions.enumerated() {
                    let reply = engine.answer(question, conversationID: conversation.id)
                    record.append(ChatTurn(id: "\(conversation.id)-\(index + 1)", question: question,
                                           askedAt: start.addingTimeInterval(Double(index) * 90), reply: reply), transcript: [])
                }
                return record
            }
            let store = chatStore
            demoChatSeeding = Task { for record in records { try? await store.saveChatRecord(record) } }
        }
        await demoChatSeeding?.value
    }
}
