import BudgetKit
@testable import BudgetServerCore
import Foundation
import Logging
import PostgresNIO
import Testing

/// Part of the store's serialized suite: two suites migrating one scratch database at once race on its DDL.
extension PostgresStoreTests {
    @Test("Snapshots save, replace one per account and day, read back, and clear")
    func balanceSnapshotsRoundTrip() async throws {
        let store = PostgresStore(config: PostgresStoreTests.database, logger: Logger(label: "pg-test"))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await store.client.run() }
            try await store.migrate()
            let history = BudgetServerApp.balanceHistory(for: store, logger: Logger(label: "pg-test"))
            try await history.clearBalanceSnapshots()
            try await history.saveBalanceSnapshots([
                BalanceSnapshot(accountID: "a", day: "2026-09-01", balance: Money(10)),
                BalanceSnapshot(accountID: "a", day: "2026-09-02", balance: Money(-20.5)),
            ])
            try await history.saveBalanceSnapshots([BalanceSnapshot(accountID: "a", day: "2026-09-02", balance: Money(30))])
            let read = try await history.balanceSnapshots().sorted { $0.day < $1.day }
            #expect(read == [BalanceSnapshot(accountID: "a", day: "2026-09-01", balance: Money(10)),
                             BalanceSnapshot(accountID: "a", day: "2026-09-02", balance: Money(30))])
            try await history.clearBalanceSnapshots()
            #expect(try await history.balanceSnapshots().isEmpty)
            group.cancelAll()
        }
    }
}
