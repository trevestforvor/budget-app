import BudgetKit
@testable import BudgetServerCore
import Foundation
import Testing

/// P0.6: numbers in legacy statement ids that sit in prose (Ask replies, markdown), and the scrubs a server without
/// BUDGET_TOKEN_KEY still runs.
@Suite("Statement id scrubbing")
struct StatementIDScrubTests {
    typealias M = StatementIDMigrationTests

    @Test("A legacy id followed by punctuation is still swapped or masked, and the punctuation stays")
    func punctuation() {
        let account = "fileImport:stmt-h1-0123456789abcdef"
        let maps = (accounts: [M.legacyAccount: account], rows: [M.legacyRow(1): "fileImport:\(account):ofxh1-12345678901234567890"])
        let cases: [(String, String)] = [
            ("The card is \(M.legacyAccount).", "The card is \(account)."),
            ("(\(M.legacyAccount))", "(\(account))"),
            ("`\(M.legacyAccount)`", "`\(account)`"),
            ("[\(M.legacyAccount)]", "[\(account)]"),
            ("row `\(M.legacyRow(1))`;", "row `\(maps.rows[M.legacyRow(1)]!)`;"),
        ]
        for (text, expected) in cases {
            #expect(StatementIDKeys.scrubChat(text, accounts: maps.accounts, rows: maps.rows) == expected)
        }
        // Without maps (or an id the maps don't know), the number is masked.
        let unmapped = [
            "The card is fileImport:9876543210123.", "(fileImport:9876543210123)", "`fileImport:9876543210123`",
            "fileImport:9876543210123]", "see x; fileImport:1234567890.", "file ofx-9876543210123-F1).",
        ]
        for text in unmapped {
            let scrubbed = StatementIDKeys.scrubChat(text)
            #expect(!scrubbed.contains("9876543210") && !scrubbed.contains("1234567890"), "\(text) → \(scrubbed)")
            #expect(scrubbed.last == text.last)
            #expect(StatementIDKeys.scrubChat(scrubbed) == scrubbed)
        }
    }

    @Test("The dry run counts a chat whose only legacy id is followed by punctuation")
    func dryRunCountsProse() async throws {
        let session = ChatSession(id: "chat-2", title: "Card", createdAt: Date(), updatedAt: Date())
        let record = ChatSessionRecord(session: session, transcripts: ["turn-1": [StoredChatMessage(.user("Which card is fileImport:9876543210123?"))]])
        let chats = InMemoryChatSessionStore(records: [record])
        let service = try await M.service(MemoryStore(ledger: LedgerBudgetAPI.demoState(now: Date(), calendar: TestServer.config().calendar)), chats: chats)
        #expect(await LedgerMigrations.outsideCounts(service).chats == 1)
    }

    @Test("Without BUDGET_TOKEN_KEY on Postgres, import labels and chats are still masked; the ledger's ids wait for a key")
    func noKeyStillScrubs() async throws {
        var config = TestServer.config()
        config.tokenKey = nil
        config.database = .init(host: "127.0.0.1", port: 1, username: "nobody", password: nil, database: "none") // never connected: the store is in memory
        let store = MemoryStore(ledger: M.legacy())
        try await store.upsertImport(M.importRecord())
        let chats = InMemoryChatSessionStore(records: [M.chat()])
        let service = try await M.service(store, chats: chats, config: config)
        try await BudgetServerApp.prepare(service)
        #expect(service.statementIDs == nil)
        let record = try #require(try await store.imports().first)
        #expect(record.label == "Checking_••0123.qfx")
        #expect(!(try M.json(record)).contains("9876543210"))
        let chat = try #require(await chats.chatRecord(id: "chat-1"))
        #expect(!(try M.json(chat)).contains("9876543210"))
        // Nothing to rename them with, so the ledger keeps its ids until a key is set.
        #expect(await service.api.statementIDAudit().accounts == 1)
    }
}
