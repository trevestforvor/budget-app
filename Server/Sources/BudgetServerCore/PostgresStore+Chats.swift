import BudgetKit
import Foundation
import Logging
import PostgresNIO

/// Ask's conversations in `budget_chats` (migration 3): one row per conversation, its whole record in `doc` and the
/// Recents line in `summary`, so the list never reads the turns. Outside the ledger: a conversation grows with every
/// question, and the ledger's documents are rewritten whole on every change.
extension PostgresStore: ChatSessionStore {
    /// Storage coding, as the ledger's: Foundation's default dates round-trip exactly.
    private static let chatEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let chatLogger = Logger(label: "budget-chats")

    public func chatSummaries() async throws -> [ChatSessionSummary] {
        var out: [ChatSessionSummary] = []
        let rows = try await client.query("SELECT summary::text FROM budget_chats ORDER BY updated_at DESC, id DESC", logger: Self.chatLogger)
        for try await (summary) in rows.decode(String.self) {
            out.append(try JSONDecoder().decode(ChatSessionSummary.self, from: Data(summary.utf8)))
        }
        return out
    }

    public func chatRecord(id: String) async throws -> ChatSessionRecord? {
        for try await (doc) in try await client.query("SELECT doc::text FROM budget_chats WHERE id = \(id)", logger: Self.chatLogger).decode(String.self) {
            return try JSONDecoder().decode(ChatSessionRecord.self, from: Data(doc.utf8))
        }
        return nil
    }

    public func saveChatRecord(_ record: ChatSessionRecord) async throws {
        let doc = String(decoding: try Self.chatEncoder.encode(record), as: UTF8.self)
        let summary = String(decoding: try Self.chatEncoder.encode(record.session.summary), as: UTF8.self)
        try await client.query("""
            INSERT INTO budget_chats (id, updated_at, summary, doc) VALUES (\(record.session.id), \(record.session.updatedAt), \(summary)::jsonb, \(doc)::jsonb)
            ON CONFLICT (id) DO UPDATE SET updated_at = EXCLUDED.updated_at, summary = EXCLUDED.summary, doc = EXCLUDED.doc
            """, logger: Self.chatLogger)
    }

    public func deleteChatRecord(id: String) async throws {
        try await client.query("DELETE FROM budget_chats WHERE id = \(id)", logger: Self.chatLogger)
    }

    public func deleteAllChatRecords() async throws {
        try await client.query("DELETE FROM budget_chats", logger: Self.chatLogger)
    }
}
