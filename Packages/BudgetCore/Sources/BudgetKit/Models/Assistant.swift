import Foundation

// Ask's own state: what the person asked it to keep in mind (assistant memory), and their conversations (chat history).
// Not to be confused with merchant memory (`RememberedMerchant`, `/v1/memory`), which is how Budget files merchants.

/// One fact the person asked Ask to keep in mind across conversations: "Saving for a trip to Lisbon in March",
/// "Groceries include a weekly farm-box". It's background for the model, never ledger data: the prompt says so, and
/// grounding leaves memories out, so a figure in one can't be quoted as if a tool had worked it out.
public struct AssistantMemory: Identifiable, Hashable, Codable, Sendable {
    public enum Source: String, Hashable, Codable, Sendable {
        /// Typed in Settings or the dashboard.
        case person
        /// Proposed by the assistant (`rememberFact`) and applied by the person.
        case assistant

        /// An unknown value from a newer server reads as `person`.
        public init(from decoder: any Decoder) throws {
            self = Source(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .person
        }
    }

    public var id: String
    public var text: String
    public var createdAt: Date
    public var updatedAt: Date?
    public var source: Source?

    public init(id: String, text: String, createdAt: Date, updatedAt: Date? = nil, source: Source? = nil) {
        self.id = id; self.text = text; self.createdAt = createdAt; self.updatedAt = updatedAt; self.source = source
    }

    /// The most a person can keep; adding past it is refused (nothing is dropped behind their back).
    public static let maxCount = 30
    /// One fact, a sentence or two.
    public static let maxLength = 200
    /// How much of the system prompt memories may take; past it the most recently changed ones win.
    public static let promptBudget = 2_000

    /// One line, trimmed, inner whitespace collapsed — the form a memory is stored and compared in.
    public static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}

/// Keeps one fact in assistant memory (`{"type": "rememberFact", "fact": …}`). The assistant proposes it as a card;
/// nothing is remembered until the person applies it.
public struct RememberFact: Hashable, Sendable, Codable {
    public var fact: String
    public init(fact: String) { self.fact = fact }
}

/// Body for `POST /v1/assistant/memories` and `PATCH /v1/assistant/memories/{id}`.
public struct AssistantMemoryBody: Hashable, Codable, Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}

/// One question and the answer it got.
public struct ChatTurn: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var question: String
    public var askedAt: Date
    public var reply: AskReply

    public init(id: String, question: String, askedAt: Date, reply: AskReply) {
        self.id = id; self.question = question; self.askedAt = askedAt; self.reply = reply
    }
}

/// A conversation with Ask, kept on the server so it can be reopened and continued: `POST /v1/ask` with its id as
/// `conversationID` carries on from it.
public struct ChatSession: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    /// The first question, shortened, until the person renames it.
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// Oldest first; only the latest `maxTurns` are kept.
    public var turns: [ChatTurn]

    public init(id: String, title: String, createdAt: Date, updatedAt: Date, turns: [ChatTurn] = []) {
        self.id = id; self.title = title; self.createdAt = createdAt; self.updatedAt = updatedAt; self.turns = turns
    }

    /// Conversations kept; past it the least recently used is dropped.
    public static let maxSessions = 50
    /// Turns kept per conversation; past it the oldest go.
    public static let maxTurns = 40
    public static let maxTitleLength = 60

    /// "Where did my money go this month?" → itself; a long question is cut at a word, with an ellipsis.
    public static func title(for question: String) -> String {
        let text = AssistantMemory.normalized(question)
        guard text.count > maxTitleLength else { return text.isEmpty ? "New conversation" : text }
        let cut = text.prefix(maxTitleLength - 1)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return atWord.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:—-")) + "…"
    }

    public var summary: ChatSessionSummary {
        ChatSessionSummary(id: id, title: title, createdAt: createdAt, updatedAt: updatedAt, turnCount: turns.count,
                           lastQuestion: turns.last?.question)
    }
}

/// A conversation as the Recents list shows it, without its turns.
public struct ChatSessionSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var turnCount: Int
    public var lastQuestion: String?

    public init(id: String, title: String, createdAt: Date, updatedAt: Date, turnCount: Int, lastQuestion: String? = nil) {
        self.id = id; self.title = title; self.createdAt = createdAt; self.updatedAt = updatedAt; self.turnCount = turnCount
        self.lastQuestion = lastQuestion
    }
}

/// Body for `PATCH /v1/assistant/sessions/{id}`.
public struct ChatSessionRename: Hashable, Codable, Sendable {
    public var title: String
    public init(title: String) { self.title = title }
}

/// Assistant memory and chat history, beside `BudgetAPI` (reach it with `api as? any AssistantAPI`). Servers before
/// `ServerStatus.assistantSince` answer 404 (`BudgetAPIError.notFound`).
public protocol AssistantAPI: Sendable {
    /// Newest first.
    func assistantMemories() async throws -> [AssistantMemory]
    func addAssistantMemory(_ text: String) async throws -> AssistantMemory
    func updateAssistantMemory(id: String, text: String) async throws -> AssistantMemory
    func deleteAssistantMemory(id: String) async throws
    /// Most recently used first.
    func chatSessions() async throws -> [ChatSessionSummary]
    func chatSession(id: String) async throws -> ChatSession
    func renameChatSession(id: String, title: String) async throws -> ChatSessionSummary
    func deleteChatSession(id: String) async throws
}

extension ServerStatus {
    /// The first server with assistant memory (`/v1/assistant/memories`, the `rememberFact` action) and chat history
    /// (`/v1/assistant/sessions`, `/v1/ask` continuing a conversation). An older one refuses `rememberFact` as an
    /// unknown action and answers 404 to the rest.
    public static let assistantSince = "0.5.0"
}
