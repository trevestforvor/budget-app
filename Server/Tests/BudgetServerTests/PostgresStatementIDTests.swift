import BudgetKit
@testable import BudgetServerCore
import Foundation
import Logging
import PostgresNIO
import Testing

/// P0.6 against a real database (POSTGRES_TEST_HOST): the statement-id rename is one transaction. Part of the serialized
/// "Postgres store" suite, so it never shares the tables with another of its tests.
extension PostgresStoreTests {
    static func rowIDs(_ store: PostgresStore) async throws -> Set<String> {
        var ids = Set<String>()
        for try await (id) in try await store.client.query("SELECT id FROM budget_rows").decode(String.self) { ids.insert(id) }
        return ids
    }

    /// Starts the API over `state` (already stored) the way `BudgetServerApp.prepare` does: loading applies the one-time
    /// upgrades, and `persistUpgrades` writes them back once, so the API's later diffs start from what the store holds.
    static func api(_ state: LedgerState, _ store: PostgresStore) async throws -> LedgerBudgetAPI {
        let api = LedgerBudgetAPI(state: state, calendar: .current, chatModel: nil, decisions: DecisionRouting(), persistence: store,
                                  deployment: DeploymentInfo(endpoint: "t", version: "t", sources: [.fileImport], institutions: []))
        try await api.persistUpgrades(from: state)
        return api
    }

    static var ids: StatementIDs { StatementIDKeys.make(sealer: try! TokenSealer(base64Key: TestServer.key), persistent: true)! }

    @Test("Renaming row ids deletes the old rows and writes the new ones in one save")
    func statementIDRename() async throws {
        try await withStore { store in
            let legacy = StatementIDMigrationTests.legacy()
            try await store.replaceLedger(legacy)
            let before = try await Self.rowIDs(store)
            let api = try await Self.api(legacy, store)
            let done = try await api.hashStatementIDs(Self.ids)
            #expect(done.report.rows == 4)
            let after = try await Self.rowIDs(store)
            #expect(after.count == before.count)
            #expect(!after.contains { $0.contains("9876543210") })
            let loaded = try #require(try await store.loadLedger())
            #expect(Self.sorted(loaded) == Self.sorted(await api.state))
            let docs = try await store.client.query("SELECT count(*) FROM budget_docs WHERE doc::text LIKE '%9876543210%'").decode(Int.self)
            for try await count in docs { #expect(count == 0) }
        }
    }

    @Test("A save that fails after the upserts (the connection's transaction aborted) leaves budget_rows and the ledger unchanged")
    func statementIDRenameRollsBack() async throws {
        try await withStore { store in
            let legacy = StatementIDMigrationTests.legacy()
            try await store.replaceLedger(legacy)
            let api = try await Self.api(legacy, store)
            let before = try await Self.rowIDs(store)
            let stored = try #require(try await store.loadLedger())
            // The deletes run after every upsert in `save`; failing the first aborts the transaction there.
            try await store.client.query(PostgresQuery(unsafeSQL: """
                CREATE OR REPLACE FUNCTION budget_test_fail() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'injected failure'; END $$ LANGUAGE plpgsql
                """))
            try await store.client.query("DROP TRIGGER IF EXISTS budget_test_fail ON budget_rows")
            try await store.client.query("CREATE TRIGGER budget_test_fail BEFORE DELETE ON budget_rows FOR EACH ROW EXECUTE FUNCTION budget_test_fail()")
            await #expect(throws: (any Error).self) { try await api.hashStatementIDs(Self.ids) }
            try await store.client.query("DROP TRIGGER IF EXISTS budget_test_fail ON budget_rows")
            try await store.client.query("DROP FUNCTION IF EXISTS budget_test_fail()")
            #expect(try await Self.rowIDs(store) == before)
            #expect(Self.sorted(try #require(try await store.loadLedger())) == Self.sorted(stored))
            #expect(await api.statementIDAudit() == StatementIDAudit(accounts: 1, rows: 4, rules: 0))
        }
    }

    @Test("On start against Postgres the migration runs once, and the next start changes nothing")
    func statementIDMigrationOnStart() async throws {
        try await withStore { store in
            try await store.replaceLedger(StatementIDMigrationTests.legacy())
            let (service, _) = try await BudgetServerApp.makeService(config: TestServer.config(), store: store, logger: Logger(label: "pg-test"))
            try await BudgetServerApp.prepare(service)
            #expect(await service.api.statementIDAudit().isClean && service.statementIDs?.gate.isOpen == true)
            let ids = try await Self.rowIDs(store)
            #expect(!ids.contains { $0.contains("9876543210") })
            let (again, _) = try await BudgetServerApp.makeService(config: TestServer.config(), store: store, logger: Logger(label: "pg-test"))
            try await BudgetServerApp.prepare(again)
            #expect(try await Self.rowIDs(store) == ids)
            #expect(try await store.setting(StatementIDKeys.checkSetting) != nil)
        }
    }
}
