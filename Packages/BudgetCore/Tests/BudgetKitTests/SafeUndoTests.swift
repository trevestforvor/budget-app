import Foundation
import Testing
@testable import BudgetKit

/// P0.4: Undo never silently loses synced rows. Plaid's cursor never re-sends a row, so its batches are refused and
/// hidden instead; a SimpleFIN batch says how many rows its next sync brings back; files undo as before.
@Suite("Safe Undo")
struct SafeUndoTests {
    static func simplefinSnapshot() -> SourceSnapshot {
        SourceSnapshot(source: .simplefin, accounts: [
            SourceAccount(externalID: "sf-1", institution: "Harbor Bank", institutionDomain: nil, name: "Everyday Checking", kind: .checking,
                          balance: Money(2400), availableBalance: nil, balanceDate: EngineFixture.now, transactions: [
                              SourceTransaction(externalID: "s1", posted: EngineFixture.day(1), amount: Money(-31.20), description: "CORNER MARKET"),
                              SourceTransaction(externalID: "s2", posted: EngineFixture.day(6), amount: Money(-9.75), description: "BLUE BOTTLE COFFEE"),
                              SourceTransaction(externalID: "s3", posted: EngineFixture.day(20), amount: Money(-120.00), description: "CITY WATER UTILITY"),
                          ], holdings: []),
        ], warnings: [])
    }

    @Test("Undo refuses a Plaid sync batch and every row stays")
    func plaidRefused() async throws {
        let persistence = RecordingPersistence()
        let api = EngineFixture.api(persistence: persistence, decisions: DecisionRouting(local: StubDecisions([:])))
        _ = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "plaid-l-1")
        let rowsBefore = try await api.transactions(TransactionFilter()).count
        let balanceBefore = try await api.overview().accounts.first?.balance
        let saves = await persistence.saves.count

        let plan = await api.rollbackPlan(batchID: "plaid-l-1", nextWindowStart: EngineFixture.day(10))
        #expect(plan.verdict == .refuse)
        #expect(plan.rows == 5 && plan.bySource == ["plaid": 5] && plan.returning == 0)
        #expect(plan.message.contains("Plaid") && plan.message.contains("Hide"))

        await #expect(throws: BudgetAPIError.server(status: 409, message: plan.message)) {
            try await api.rollback(batchID: "plaid-l-1", nextWindowStart: EngineFixture.day(10), acknowledgeReturning: true)
        }
        #expect(try await api.transactions(TransactionFilter()).count == rowsBefore)
        #expect(try await api.overview().accounts.first?.balance == balanceBefore)
        #expect(await persistence.saves.count == saves)   // nothing was written
    }

    @Test("Undo of a SimpleFIN batch says how many rows come back and needs a yes")
    func simplefinNeedsYes() async throws {
        let api = EngineFixture.api(decisions: DecisionRouting(local: StubDecisions([:])))
        _ = try await api.ingest(Self.simplefinSnapshot(), batchID: "simplefin-l-1")
        let next = EngineFixture.day(10)

        let plan = await api.rollbackPlan(batchID: "simplefin-l-1", nextWindowStart: next)
        #expect(plan.verdict == .undoReturns)
        #expect(plan.rows == 3 && plan.returning == 2 && plan.bySource == ["simplefin": 3])
        #expect(plan.message.contains("2 of them come back"))

        await #expect(throws: BudgetAPIError.server(status: 409, message: plan.message)) {
            try await api.rollback(batchID: "simplefin-l-1", nextWindowStart: next)
        }
        #expect(try await api.transactions(TransactionFilter()).count == 3)

        #expect(try await api.rollback(batchID: "simplefin-l-1", nextWindowStart: next, acknowledgeReturning: true) == 3)
        #expect(try await api.transactions(TransactionFilter()).isEmpty)

        // When nothing will sync it again (the link is gone), nothing comes back and Undo needs no yes.
        _ = try await api.ingest(Self.simplefinSnapshot(), batchID: "simplefin-l-2")
        #expect(await api.rollbackPlan(batchID: "simplefin-l-2", nextWindowStart: nil).verdict == .undo)
        #expect(try await api.rollback(batchID: "simplefin-l-2") == 3)
    }

    @Test("Hiding a sync batch keeps balances, takes the rows out of totals, and its undo shows them again")
    func hideBatch() async throws {
        let api = EngineFixture.api(decisions: DecisionRouting(local: StubDecisions([:])))
        _ = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "plaid-l-1")
        let balance = try await api.overview().accounts.first?.balance
        let spent = try await api.spending(.thisMonth).total
        #expect(spent != .zero)

        let result = try await api.hideBatch(batchID: "plaid-l-1")
        #expect(result.affectedTransactions == 5)
        #expect(try await api.transactions(TransactionFilter()).allSatisfy(\.isHidden))
        #expect(try await api.transactions(TransactionFilter()).count == 5)
        #expect(try await api.overview().accounts.first?.balance == balance)
        #expect(try await api.spending(.thisMonth).total == .zero)
        // A second hide finds nothing left to hide and offers no undo.
        #expect(try await api.hideBatch(batchID: "plaid-l-1").undo == nil)

        let undo = try #require(result.undo)
        _ = try await api.perform(undo)
        #expect(try await api.transactions(TransactionFilter()).allSatisfy { !$0.isHidden })
        #expect(try await api.spending(.thisMonth).total == spent)
        #expect(try await api.overview().accounts.first?.balance == balance)
    }

    @Test("A file import still rolls back exactly its rows")
    func fileRollsBack() async throws {
        let api = EngineFixture.api(decisions: DecisionRouting(local: StubDecisions([:])))
        _ = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "plaid-l-1")
        let accountID = try #require(try await api.overview().accounts.first?.id)
        let csv = """
        Date,Description,Amount
        09/10/2026,UNITED AIRLINES,486.20
        09/08/2026,HOTEL ARIA,212.00
        """
        let snapshot = try FileImport.parse(csv, options: .init(accountKind: .credit, institution: "Summit Card"))
        let report = try await api.ingest(snapshot, batchID: "file-1", into: accountID)
        #expect(report.rowsAdded == 2)
        let balance = try await api.overview().accounts.first?.balance

        let plan = await api.rollbackPlan(batchID: "file-1", nextWindowStart: EngineFixture.day(10))
        #expect(plan.verdict == .undo && plan.rows == 2 && plan.returning == 0 && plan.bySource == ["fileImport": 2])
        #expect(try await api.rollback(batchID: "file-1", nextWindowStart: EngineFixture.day(10)) == 2)
        let left = try await api.transactions(TransactionFilter())
        #expect(left.count == 5 && left.allSatisfy { $0.batchID == "plaid-l-1" })
        #expect(try await api.overview().accounts.first?.balance == balance)   // anchored to the provider's balance
    }
}
