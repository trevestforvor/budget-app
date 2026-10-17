import BudgetKit
@testable import BudgetServerCore
import Foundation
import Logging
import PostgresNIO
import Testing

/// B4's state as the Postgres store keeps it: `pendingMisses` is an ordinary `budget_docs` document, and settled or
/// dropped pending rows go to `budget_merges` with the rest of the merge log.
@Suite("Stale-pending sweep storage")
struct PendingSweepStoreTests {
    static let base = Date(timeIntervalSince1970: 1_790_000_000)

    static func pull(pending: Bool) throws -> SourceSnapshot {
        let t = Int(base.timeIntervalSince1970)
        let deli = pending ? #", {"id": "p-deli", "posted": 0, "transacted_at": \#(t - 86_400), "amount": "-18.00", "description": "CORNER DELI", "pending": true}"# : ""
        let set = #"""
        {"connections": [{"conn_id": "CON-1", "name": "Harbor Credit Union"}],
         "accounts": [{"id": "ACT-1", "name": "Total Checking", "conn_id": "CON-1", "currency": "USD", "balance": "1000.00", "balance-date": \#(t),
                       "transactions": [{"id": "t-rent", "posted": \#(t - 20 * 86_400), "amount": "-1500.00", "description": "HARBOR PROPERTY MGMT RENT"}\#(deli)]}]}
        """#
        var snapshot = try SimpleFINSource.parse(Data(set.utf8))
        // What the SimpleFIN sync sets: pending rows were asked for, and the last 30 days were covered.
        snapshot.includesPending = true
        snapshot.accounts[0].coveredFrom = base.addingTimeInterval(-30 * 86_400)
        return snapshot
    }

    /// A ledger after: the pending row added, missed once (sync 2), and dropped (sync 3, 13 hours later). Returns the
    /// state after each of the last two syncs.
    static func states() async throws -> (missed: LedgerState, dropped: LedgerState) {
        let clock = Clock(base)
        let api = LedgerBudgetAPI(state: .empty, calendar: .current, clock: { clock.now }, chatModel: nil, decisions: DecisionRouting(),
                                  persistence: nil, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.simplefin], institutions: []))
        _ = try await api.ingest(try pull(pending: true), batchID: "sync-1")
        clock.now = base.addingTimeInterval(3_600)
        _ = try await api.ingest(try pull(pending: false), batchID: "sync-2")
        let missed = await api.state
        clock.now = base.addingTimeInterval(14 * 3_600)
        _ = try await api.ingest(try pull(pending: false), batchID: "sync-3")
        return (missed, await api.state)
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ start: Date) { value = start }
        var now: Date {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    @Test("A miss is a budget_docs document and a dropped row a budget_merges entry")
    func split() async throws {
        let (missed, dropped) = try await Self.states()
        #expect(missed.pendingMisses.count == 1)
        let docs = try PostgresStore.split(missed).docs
        let stored = try JSONDecoder().decode([String: Date].self, from: try #require(docs["pendingMisses"]).data())
        #expect(stored == missed.pendingMisses)

        #expect(dropped.pendingMisses.isEmpty && !dropped.transactions.contains { $0.isPending })
        let merges = PostgresStore.merges(dropped)
        #expect(merges.values.map(\.kind) == [.pendingDropped])
        #expect(try PostgresStore.split(dropped).docs["mergeLog"] == nil)
    }
}

// In the Postgres suite, so it runs serialized with the other cases that empty the tables, and only with POSTGRES_TEST_HOST.
extension PostgresStoreTests {
    @Test("A miss and a dropped pending row survive a save and a reload")
    func postgresRoundTrip() async throws {
        let (missed, dropped) = try await PendingSweepStoreTests.states()
        try await withStore { store in
            try await store.replaceLedger(missed)
            #expect(try await store.loadLedger()?.pendingMisses == missed.pendingMisses)
            try await store.save(from: missed, to: dropped)
            let loaded = try #require(try await store.loadLedger())
            #expect(loaded.pendingMisses.isEmpty && loaded.mergeLog.map(\.kind) == [.pendingDropped])
            #expect(Self.sorted(loaded) == Self.sorted(dropped))
        }
    }
}
