import BudgetKit
@testable import BudgetServerCore
import Foundation
import Logging
import PostgresNIO
import Testing

/// Runs against a real database when POSTGRES_TEST_HOST is set (the build pod's scratch Postgres).
@Suite("Postgres store", .serialized, .enabled(if: ProcessInfo.processInfo.environment["POSTGRES_TEST_HOST"] != nil))
struct PostgresStoreTests {
    static var database: ServerConfig.Database {
        let env = ProcessInfo.processInfo.environment
        return .init(host: env["POSTGRES_TEST_HOST"]!, port: Int(env["POSTGRES_TEST_PORT"] ?? "") ?? 5432,
                     username: env["POSTGRES_TEST_USER"] ?? "postgres", password: env["POSTGRES_TEST_PASSWORD"],
                     database: env["POSTGRES_TEST_DB"] ?? "postgres")
    }

    /// Runs `body` with a migrated store on emptied tables.
    func withStore(_ body: (PostgresStore) async throws -> Void) async throws {
        let store = PostgresStore(config: Self.database, logger: Logger(label: "pg-test"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await store.client.run() }
            try await store.migrate()
            try await store.migrate() // idempotent
            for table in ["budget_rows", "budget_docs", "budget_links", "budget_imports", "budget_settings"] {
                try await store.client.query(PostgresQuery(unsafeSQL: "DELETE FROM \(table)"))
            }
            try await body(store)
            group.cancelAll()
        }
    }

    static func sorted(_ state: LedgerState) -> LedgerState {
        var s = state
        s.transactions.sort { $0.id < $1.id }
        return s
    }

    @Test("Empty database loads nothing; a replaced ledger loads back identically")
    func roundTrip() async throws {
        try await withStore { store in
            #expect(try await store.loadLedger() == nil)
            let demo = LedgerBudgetAPI.demoState(now: Date(), calendar: .current)
            try await store.replaceLedger(demo)
            let loaded = try #require(try await store.loadLedger())
            #expect(Self.sorted(loaded) == Self.sorted(demo))
        }
    }

    @Test("Saves write the diff: edits, inserts and deletes all persist")
    func diffSave() async throws {
        try await withStore { store in
            let old = LedgerBudgetAPI.demoState(now: Date(), calendar: .current)
            try await store.replaceLedger(old)
            var new = old
            new.monthlyTargets["dining"] = Money(500)
            let gone = new.transactions.removeLast()
            new.transactions[0].merchant = "Renamed Merchant"
            new.transactions[2].tags = ["Austin trip", "Reimbursable"] // a field inside the row's JSON: no migration
            var added = new.transactions[1]
            added.id = "file:new-row"
            added.batchID = "import-1"
            new.transactions.append(added)
            try await store.save(from: old, to: new)
            let loaded = try #require(try await store.loadLedger())
            #expect(Self.sorted(loaded) == Self.sorted(new))
            #expect(!loaded.transactions.contains { $0.id == gone.id })
        }
    }

    /// Regression (first deploy): a ledger saved only as a diff from `.empty` skipped the documents
    /// equal to the default (categories), and the next start failed to decode.
    @Test("A ledger saved as a diff from empty loads back, defaults included")
    func diffFromEmpty() async throws {
        try await withStore { store in
            var seeded = LedgerBudgetAPI.demoState(now: Date(), calendar: .current)
            seeded.decisionPolicy.provider = .localDecide
            try await store.save(from: .empty, to: seeded)
            let loaded = try #require(try await store.loadLedger())
            #expect(Self.sorted(loaded) == Self.sorted(seeded))
        }
    }

    @Test("Provider settings save and load (secrets stay sealed)")
    func providerSettings() async throws {
        try await withStore { store in
            #expect(try await store.providerSettings() == nil)
            let settings = StoredProviderSettings(plaid: .init(clientID: "cid", sealedSecret: "sealed-x", environment: "sandbox", redirectURI: "https://d/"),
                                                  teller: .init(applicationID: "app_1", environment: "sandbox", certificatePEM: nil, sealedKeyPEM: nil))
            try await store.saveProviderSettings(settings)
            try await store.saveProviderSettings(settings) // upsert
            let loaded = try #require(try await store.providerSettings())
            #expect(loaded.plaid == settings.plaid)
            #expect(loaded.teller == settings.teller)
        }
    }

    @Test("Links and imports upsert, list and delete")
    func records() async throws {
        try await withStore { store in
            var link = StoredLink(id: "l1", provider: .plaid, institution: "Harbor", externalID: "item-1", sealedToken: "sealed",
                                  cursor: nil, status: .connected, lastSync: nil, lastError: nil, createdAt: Date())
            try await store.upsertLink(link)
            link.cursor = "c2"
            try await store.upsertLink(link)
            #expect(try await store.links().map(\.cursor) == ["c2"])
            try await store.deleteLink("l1")
            #expect(try await store.links().isEmpty)

            let record = ImportRecord(batchID: "b1", kind: .file, linkID: nil, label: "summit.csv", report: IngestReport(batchID: "b1", source: .fileImport), createdAt: Date(), rolledBack: false)
            try await store.upsertImport(record)
            #expect(try await store.imports().map(\.batchID) == ["b1"])
        }
    }
}
