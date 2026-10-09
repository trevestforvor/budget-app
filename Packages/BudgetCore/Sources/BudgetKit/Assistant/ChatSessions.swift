import Foundation

/// A chat message as it's stored with a conversation: what the model saw and said in a turn, tool calls and results
/// included, so a later question in the same conversation can be answered with them in view.
public struct StoredChatMessage: Hashable, Codable, Sendable {
    public struct Call: Hashable, Codable, Sendable {
        public var id: String
        public var name: String
        public var arguments: String
    }

    /// `ChatMessage.Role` raw value.
    public var role: String
    public var content: String?
    public var toolCalls: [Call]?
    public var toolCallID: String?

    public init(_ message: ChatMessage) {
        role = message.role.rawValue
        content = message.content
        toolCalls = message.toolCalls.isEmpty ? nil : message.toolCalls.map { Call(id: $0.id, name: $0.name, arguments: $0.arguments) }
        toolCallID = message.toolCallID
    }

    /// Nil for a role this version doesn't know.
    public var message: ChatMessage? {
        guard let role = ChatMessage.Role(rawValue: role) else { return nil }
        return ChatMessage(role: role, content: content, toolCalls: (toolCalls ?? []).map { ChatToolCall(id: $0.id, name: $0.name, arguments: $0.arguments) },
                           toolCallID: toolCallID)
    }

    var size: Int { (content?.count ?? 0) + (toolCalls ?? []).reduce(0) { $0 + $1.arguments.count + $1.name.count } }
}

/// A conversation as the server keeps it: what the app sees (`session`) and, for its latest turns only, what the model saw.
public struct ChatSessionRecord: Hashable, Codable, Sendable {
    public var session: ChatSession
    /// Turn id → that turn's messages (the question, tool calls and results, the answer). Only the latest
    /// `replayedTurns` keep theirs; older turns are replayed as question and answer alone.
    public var transcripts: [String: [StoredChatMessage]]

    public init(session: ChatSession, transcripts: [String: [StoredChatMessage]] = [:]) {
        self.session = session
        self.transcripts = transcripts
    }

    /// Turns the model sees again when the conversation continues.
    public static let historyTurns = 6
    /// Of those, the newest ones that come with their tool calls and results.
    public static let replayedTurns = 2
    /// Characters of earlier conversation the model is given at most; past it, older turns are left out.
    public static let historyBudget = 16_000

    /// A new conversation, titled from its first question.
    public static func new(id: String, question: String, at date: Date) -> ChatSessionRecord {
        ChatSessionRecord(session: ChatSession(id: id, title: ChatSession.title(for: question), createdAt: date, updatedAt: date))
    }

    /// Adds a turn, keeps at most `ChatSession.maxTurns`, and keeps the model's view only of the newest
    /// `replayedTurns`. A grounding retry (the "[system check]" note and the draft it rejected) isn't kept.
    public mutating func append(_ turn: ChatTurn, transcript: [ChatMessage]) {
        session.turns.append(turn)
        if session.turns.count > ChatSession.maxTurns { session.turns.removeFirst(session.turns.count - ChatSession.maxTurns) }
        session.updatedAt = max(session.updatedAt, turn.askedAt)
        let kept = Self.compacted(transcript)
        if !kept.isEmpty { transcripts[turn.id] = kept.map(StoredChatMessage.init) }
        let replayed = Set(session.turns.suffix(Self.replayedTurns).map(\.id))
        transcripts = transcripts.filter { replayed.contains($0.key) }
    }

    static func compacted(_ transcript: [ChatMessage]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for message in transcript {
            if message.role == .user, message.content?.hasPrefix("[system check]") == true {
                if out.last?.role == .assistant, out.last?.toolCalls.isEmpty == true { out.removeLast() }
                continue
            }
            out.append(message)
        }
        return out
    }

    /// The conversation so far as the model should see it before the next question: the latest turns, newest ones
    /// with their tool calls and results, within `historyBudget`.
    public func modelHistory() -> [ChatMessage] {
        var picked: [[ChatMessage]] = []
        var used = 0
        for (index, turn) in session.turns.reversed().prefix(Self.historyTurns).enumerated() {
            let full = index < Self.replayedTurns ? transcripts[turn.id]?.compactMap(\.message) : nil
            let plain = [ChatMessage.user(turn.question), ChatMessage(role: .assistant, content: turn.reply.text, toolCalls: [], toolCallID: nil)]
            func size(_ messages: [ChatMessage]) -> Int {
                messages.reduce(0) { $0 + StoredChatMessage($1).size }
            }
            if let full, full.first?.role == .user, used + size(full) <= Self.historyBudget {
                picked.append(full)
                used += size(full)
            } else if used + size(plain) <= Self.historyBudget {
                picked.append(plain)
                used += size(plain)
            } else {
                break
            }
        }
        return picked.reversed().flatMap { $0 }
    }
}

/// Where Ask's conversations are kept. The server keeps them in Postgres (one row per conversation); the demo and a
/// server without a database keep them in memory.
public protocol ChatSessionStore: Sendable {
    /// Most recently used first.
    func chatSummaries() async throws -> [ChatSessionSummary]
    func chatRecord(id: String) async throws -> ChatSessionRecord?
    func saveChatRecord(_ record: ChatSessionRecord) async throws
    func deleteChatRecord(id: String) async throws
    func deleteAllChatRecords() async throws
}

public actor InMemoryChatSessionStore: ChatSessionStore {
    private var records: [String: ChatSessionRecord] = [:]

    public init(records: [ChatSessionRecord] = []) {
        self.records = Dictionary(records.map { ($0.session.id, $0) }, uniquingKeysWith: { _, last in last })
    }

    public func chatSummaries() -> [ChatSessionSummary] {
        records.values.map(\.session.summary).sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
    }

    public func chatRecord(id: String) -> ChatSessionRecord? { records[id] }
    public func saveChatRecord(_ record: ChatSessionRecord) { records[record.session.id] = record }
    public func deleteChatRecord(id: String) { records[id] = nil }
    public func deleteAllChatRecords() { records = [:] }
}
