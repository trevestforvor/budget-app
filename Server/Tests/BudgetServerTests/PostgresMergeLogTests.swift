import BudgetKit
@testable import BudgetServerCore
import Foundation
import Logging
import PostgresNIO
import Testing

/// P1.3 against a real database (POSTGRES_TEST_HOST): the merge log lives in `budget_merges`, one row per entry, never in
/// a ledger document. Part of the serialized "Postgres store" suite.
extension PostgresStoreTests {
    static func count(_ store: PostgresStore, _ sql: String) async throws -> Int {
        var n = 0
        for try await value in try await store.client.query(PostgresQuery(unsafeSQL: sql)).decode(Int.self) { n = value }
        return n
    }

    static func entry(_ id: String, daysAgo: Double = 0, batch: String = "file-1") -> RowMergeRecord {
        let row = LedgerTransaction(id: "fileImport:card:\(id)", accountID: "card", postedAt: Date(timeIntervalSince1970: 1_790_000_000), merchant: "Corner Deli",
                                    rawDescription: "CORNER DELI", amount: Money(-15), categorization: nil, isPending: false, source: .fileImport, batchID: batch)
        return RowMergeRecord(id: "skippedIncoming-\(batch)-\(row.id)", kind: .skippedIncoming, at: Date().addingTimeInterval(-daysAgo * 86_400),
                              batchID: batch, keptID: "plaid:\(id)", droppedID: row.id, dropped: row)
    }

    @Test("Merge log entries live in budget_merges and survive a reload; saves upsert and delete only what changed")
    func mergeLogReload() async throws {
        try await withStore { store in
            var state = LedgerState.empty
            state.mergeLog = [Self.entry("a"), Self.entry("b")]
            try await store.replaceLedger(state)
            #expect(try await Self.count(store, "SELECT count(*) FROM budget_merges") == 2)
            #expect(try await Self.count(store, "SELECT count(*) FROM budget_docs WHERE key = 'mergeLog'") == 0)
            #expect(try #require(try await store.loadLedger()).mergeLog == state.mergeLog)

            var next = state
            next.mergeLog[0].undoneAt = Date(timeIntervalSince1970: 1_790_100_000)
            next.mergeLog.remove(at: 1)
            next.mergeLog.append(Self.entry("c", batch: "file-2"))
            try await store.save(from: state, to: next)
            #expect(try await Self.count(store, "SELECT count(*) FROM budget_merges") == 2)
            #expect(try await Self.count(store, "SELECT count(*) FROM budget_merges WHERE batch_id = 'file-2'") == 1)
            let loaded = try #require(try await store.loadLedger())
            #expect(Set(loaded.mergeLog) == Set(next.mergeLog))
        }
    }

    @Test("Migration 5 moves a merge log an earlier build kept as a document into budget_merges")
    func mergeLogDocumentMoves() async throws {
        try await withStore { store in
            try await store.replaceLedger(.empty)
            let legacy = [Self.entry("old")]
            let json = String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self)
            try await store.client.query("INSERT INTO budget_docs (key, doc) VALUES ('mergeLog', \(json)::jsonb)")
            try await store.client.query("UPDATE budget_meta SET value = '4' WHERE key = 'schema_version'")
            try await store.migrate()
            #expect(try await Self.count(store, "SELECT count(*) FROM budget_docs WHERE key = 'mergeLog'") == 0)
            let loaded = try #require(try await store.loadLedger())
            #expect(loaded.mergeLog.map(\.id) == legacy.map(\.id))
            #expect(abs(loaded.mergeLog[0].at.timeIntervalSince(legacy[0].at)) < 0.001)
        }
    }

    @Test("A merge through the API reaches budget_merges in the same save as its rows")
    func mergeThroughAPI() async throws {
        try await withStore { store in
            var state = LedgerState.empty
            state.accounts = [Account(id: "card", name: "Card", institution: "Harbor", kind: .credit, balance: .zero, source: .plaid)]
            state.transactions = [
                LedgerTransaction(id: "plaid:amc", accountID: "card", postedAt: Date(timeIntervalSince1970: 1_790_000_000), merchant: "AMC Theatres",
                                  rawDescription: "AplPay AMC 0001 EXAMPLE", amount: Money(-23.45), categorization: nil, isPending: false, source: .plaid),
                LedgerTransaction(id: "fileImport:card:1", accountID: "card", postedAt: Date(timeIntervalSince1970: 1_789_850_000), merchant: "Amc",
                                  rawDescription: "AplPay AMC 0001 EXAMPLE", amount: Money(-23.45), categorization: nil, isPending: false, source: .fileImport),
            ]
            try await store.replaceLedger(state)
            let api = Self.api(state, store)
            #expect(try await api.importDuplicates(apply: true).removed == 1)
            #expect(try await Self.count(store, "SELECT count(*) FROM budget_rows") == 1)
            #expect(try await Self.count(store, "SELECT count(*) FROM budget_merges") == 1)
            #expect(Self.sorted(try #require(try await store.loadLedger())) == Self.sorted(await api.state))
        }
    }
}
