import Foundation
import Testing
@testable import BudgetKit

/// B4 review fixes: undoing a sync batch puts back what its sweep settled or dropped, a pending row settles into a posted
/// row already here when the bank listed both for a while, the one-to-one rule both ways, each account guard on its own,
/// Bring back of a carried category and a transfer pairing, and the shrink rule's floor.
@Suite("Stale-pending sweep, review fixes")
struct PendingSweepReviewTests {
    typealias Row = PendingSweepTests.Row
    static let base = PendingSweepTests.base
    static let checking = PendingSweepTests.checking
    static let rent = PendingSweepTests.rent
    static func pull(_ rows: [Row], coveredFrom days: Double = 30) throws -> SourceSnapshot { try PendingSweepTests.pull(rows, coveredFrom: days) }
    static func rows(_ api: LedgerBudgetAPI) async -> [LedgerTransaction] { await PendingSweepTests.rows(api) }

    static let bistro = Row(id: "p-1", days: 2, amount: "-40.00", description: "BLUE DOOR BISTRO", pending: true)
    static let bistroPosted = Row(id: "t-1", days: 1, amount: "-48.00", description: "BLUE DOOR BISTRO")

    @Test("Undoing the sync that settled a pending row puts it back, and the next sync settles it again with its edits")
    func rollbackSettledBatch() async throws {
        let clock = SweepClock(Self.base)
        let api = PendingSweepTests.api(clock)
        _ = try await api.ingest(Self.pull([Self.rent, Self.bistro]), batchID: "sync-1")
        _ = try await api.perform(.editTransactions(EditTransactions(transactionIDs: ["simplefin:p-1"], categoryID: "dining", note: "dinner with Sam")))
        clock.advance(hours: 6)
        let settled = try await api.ingest(Self.pull([Self.rent, Self.bistroPosted]), batchID: "sync-2")
        #expect(settled.pendingSettled == 1)

        let window = Self.base.addingTimeInterval(-30 * 86_400)
        let plan = await api.rollbackPlan(batchID: "sync-2", nextWindowStart: window)
        #expect(plan.verdict == .undoReturns && plan.rows == 1)
        #expect(plan.message.contains("It also puts back the pending charge this sync settled or dropped."))
        #expect(try await api.rollback(batchID: "sync-2", nextWindowStart: window, acknowledgeReturning: true) == 1)
        var rows = await Self.rows(api)
        #expect(rows.map(\.id).sorted() == ["simplefin:p-1", "simplefin:t-rent"])
        let back = try #require(rows.first { $0.id == "simplefin:p-1" })
        #expect(back.note == "dinner with Sam" && back.categorization?.categoryID == "dining")
        // The batch's sweep entries went with it: the row isn't "brought back by the person".
        #expect(await api.merges(batchID: "sync-2").isEmpty)

        clock.advance(hours: 6)
        let again = try await api.ingest(Self.pull([Self.rent, Self.bistroPosted]), batchID: "sync-3")
        #expect(again.pendingSettled == 1)
        rows = await Self.rows(api)
        #expect(rows.map(\.id).sorted() == ["simplefin:t-1", "simplefin:t-rent"])
        let posted = try #require(rows.first { $0.id == "simplefin:t-1" })
        #expect(posted.note == "dinner with Sam" && posted.categorization?.categoryID == "dining" && posted.categorization?.tier == .user)
    }

    @Test("Undoing the sync that dropped a pending row puts it back, and it can be dropped again")
    func rollbackDroppedBatch() async throws {
        let clock = SweepClock(Self.base)
        let api = PendingSweepTests.api(clock)
        _ = try await api.ingest(Self.pull([Self.rent, Row(id: "p-deli", days: 1, amount: "-18.00", description: "CORNER DELI", pending: true)]), batchID: "sync-1")
        clock.advance(hours: 2)
        _ = try await api.ingest(Self.pull([Self.rent]), batchID: "sync-2")
        clock.advance(hours: 13)
        #expect(try await api.ingest(Self.pull([Self.rent]), batchID: "sync-3").pendingDropped == 1)

        let plan = await api.rollbackPlan(batchID: "sync-3", nextWindowStart: nil)
        #expect(plan.rows == 0 && plan.verdict == .undo && plan.message == "Undo puts back the pending charge this sync settled or dropped.")
        #expect(try await api.rollback(batchID: "sync-3") == 0)
        #expect(await Self.rows(api).contains { $0.id == "simplefin:p-deli" })
        #expect(await api.merges(batchID: "sync-3").isEmpty)
        // Still not sent: missed twice again, half a day apart, it goes again.
        clock.advance(hours: 1)
        _ = try await api.ingest(Self.pull([Self.rent]), batchID: "sync-4")
        clock.advance(hours: 13)
        #expect(try await api.ingest(Self.pull([Self.rent]), batchID: "sync-5").pendingDropped == 1)
        #expect(await !Self.rows(api).contains { $0.id == "simplefin:p-deli" })
    }

    @Test("A bank that sends the posted row while still listing the pending one: the pending row settles into it later")
    func settlesIntoPostedRowAlreadyHere() async throws {
        let clock = SweepClock(Self.base)
        let api = PendingSweepTests.api(clock)
        _ = try await api.ingest(Self.pull([Self.rent, Self.bistro]), batchID: "sync-1")
        _ = try await api.perform(.editTransactions(EditTransactions(transactionIDs: ["simplefin:p-1"], categoryID: "dining", note: "dinner with Sam",
                                                                     addTags: ["date night"])))
        clock.advance(hours: 6)
        let both = try await api.ingest(Self.pull([Self.rent, Self.bistro, Self.bistroPosted]), batchID: "sync-2")
        #expect(both.pendingSettled == nil && both.rowsAdded == 1)
        #expect(await Self.rows(api).first { $0.id == "simplefin:t-1" }?.note == nil)

        clock.advance(hours: 6)
        let report = try await api.ingest(Self.pull([Self.rent, Self.bistroPosted]), batchID: "sync-3")
        #expect(report.pendingSettled == 1 && report.pendingDropped == nil && report.rowsAdded == 0)
        let rows = await Self.rows(api)
        #expect(rows.map(\.id).sorted() == ["simplefin:t-1", "simplefin:t-rent"])
        let posted = try #require(rows.first { $0.id == "simplefin:t-1" })
        #expect(posted.note == "dinner with Sam" && posted.tags?.isEmpty == false)
        #expect(posted.categorization?.categoryID == "dining" && posted.categorization?.tier == .user)
        let logged = try #require(await api.merges(batchID: "sync-3").first)
        #expect(logged.kind == .pendingSettled && logged.keptID == "simplefin:t-1" && logged.keptBefore?.note == nil)

        // Brought back: the posted row gives back what it took, and the pending row isn't settled into it again.
        _ = try await api.undoMerge(id: logged.id)
        #expect(await Self.rows(api).first { $0.id == "simplefin:t-1" }?.note == nil)
        clock.advance(hours: 13)
        let later = try await api.ingest(Self.pull([Self.rent, Self.bistroPosted]), batchID: "sync-4")
        #expect(later.pendingSettled == nil && later.pendingDropped == nil)
        #expect(await Self.rows(api).contains { $0.id == "simplefin:p-1" })
    }

    @Test("A posted row already here that the person filed keeps their category when a pending row settles into it")
    func settledRowHereKeepsPersonsCategory() async throws {
        let clock = SweepClock(Self.base)
        let api = PendingSweepTests.api(clock)
        _ = try await api.ingest(Self.pull([Self.rent, Self.bistro]), batchID: "sync-1")
        _ = try await api.perform(.editTransactions(EditTransactions(transactionIDs: ["simplefin:p-1"], categoryID: "dining", note: "dinner with Sam")))
        clock.advance(hours: 6)
        _ = try await api.ingest(Self.pull([Self.rent, Self.bistro, Self.bistroPosted]), batchID: "sync-2")
        _ = try await api.perform(.editTransactions(EditTransactions(transactionIDs: ["simplefin:t-1"], categoryID: "entertainment")))
        clock.advance(hours: 6)
        #expect(try await api.ingest(Self.pull([Self.rent, Self.bistroPosted]), batchID: "sync-3").pendingSettled == 1)
        let posted = try #require(await Self.rows(api).first { $0.id == "simplefin:t-1" })
        #expect(posted.note == "dinner with Sam" && posted.categorization?.categoryID == "entertainment")
    }

    @Test("Two pending rows that both fit one posted row: nothing settles, and both wait for the miss rule")
    func twoPendingOnePosted() async throws {
        let clock = SweepClock(Self.base)
        let api = PendingSweepTests.api(clock)
        _ = try await api.ingest(Self.pull([
            Row(id: "p-a", days: 2, amount: "-20.00", description: "TRADER JOES #552", pending: true),
            Row(id: "p-b", days: 2, amount: "-21.00", description: "TRADER JOES #552", pending: true),
        ]), batchID: "sync-1")
        _ = try await api.perform(.editTransactions(EditTransactions(transactionIDs: ["simplefin:p-a"], note: "party snacks")))
        clock.advance(hours: 6)
        let report = try await api.ingest(Self.pull([Row(id: "t-1", days: 1, amount: "-21.00", description: "TRADER JOES #552")]), batchID: "sync-2")
        #expect(report.pendingSettled == nil && report.rowsAdded == 1)
        #expect(await Self.rows(api).count == 3)
        #expect(await Self.rows(api).first { $0.id == "simplefin:t-1" }?.note == nil)
        let misses = await api.ledger.pendingMisses
        #expect(misses["simplefin:p-a"] == clock.now() && misses["simplefin:p-b"] == clock.now())
    }

    @Test("Each account guard holds on its own: no coveredFrom, or an account problem with coveredFrom set")
    func accountGuardsApart() async throws {
        let deli = Row(id: "p-deli", days: 1, amount: "-18.00", description: "CORNER DELI", pending: true)
        for guardCase in ["no coveredFrom", "account problem"] {
            let clock = SweepClock(Self.base)
            let api = PendingSweepTests.api(clock)
            _ = try await api.ingest(Self.pull([Self.rent, deli]), batchID: "sync-1")
            for n in 0..<3 {
                clock.advance(hours: 13)
                var snapshot = try Self.pull([Self.rent])
                if guardCase == "no coveredFrom" {
                    snapshot.accounts[0].coveredFrom = nil
                    #expect(snapshot.accountProblems.isEmpty)
                } else {
                    snapshot.accountProblems["ACT-1"] = .needsSignIn(code: "con.auth")
                    #expect(snapshot.accounts[0].coveredFrom != nil)
                }
                let report = try await api.ingest(snapshot, batchID: "sync-\(n)")
                #expect(report.pendingDropped == nil && report.pendingSettled == nil, "\(guardCase)")
            }
            #expect(await Self.rows(api).contains { $0.id == "simplefin:p-deli" }, "\(guardCase)")
            #expect(await api.ledger.pendingMisses.isEmpty, "\(guardCase)")
        }
    }

    @Test("Bring back of a settle that carried the person's category: the posted row goes back to no category and is filed again")
    func undoCarriedCategory() async throws {
        let clock = SweepClock(Self.base)
        let api = PendingSweepTests.api(clock)
        _ = try await api.ingest(Self.pull([Self.rent, Self.bistro]), batchID: "sync-1")
        _ = try await api.perform(.editTransactions(EditTransactions(transactionIDs: ["simplefin:p-1"], categoryID: "dining")))
        clock.advance(hours: 6)
        _ = try await api.ingest(Self.pull([Self.rent, Self.bistroPosted]), batchID: "sync-2")
        #expect(await Self.rows(api).first { $0.id == "simplefin:t-1" }?.categorization?.tier == .user)
        let entry = try #require(await api.merges(batchID: "sync-2").first)

        let result = try await api.undoMerge(id: entry.id)
        #expect(result.restored == 1 && result.filed == 1)
        var rows = await Self.rows(api)
        #expect(rows.first { $0.id == "simplefin:p-1" }?.categorization?.categoryID == "dining")
        #expect(rows.first { $0.id == "simplefin:t-1" }?.categorization == nil)
        #expect(await api.ledger.awaitingModel.contains("simplefin:t-1"))
        clock.advance(hours: 1)
        _ = try await api.ingest(Self.pull([Self.rent, Self.bistroPosted]), batchID: "sync-3")
        rows = await Self.rows(api)
        #expect(rows.first { $0.id == "simplefin:t-1" }?.categorization != nil)
        #expect(rows.contains { $0.id == "simplefin:p-1" })
    }

    @Test("A pending row that's one side of a transfer: the pairing moves to the posted row, and back on Bring back")
    func transferPairingMovesAndBack() async throws {
        let clock = SweepClock(Self.base)
        let savings = "simplefin:ACT-9"
        var state = LedgerState.empty
        state.accounts = [
            Account(id: Self.checking, name: "Total Checking", institution: "Harbor Credit Union", kind: .checking, balance: Money(1000), source: .simplefin),
            Account(id: savings, name: "Savings", institution: "Harbor Credit Union", kind: .savings, balance: Money(5000), source: .simplefin),
        ]
        let transfer = Categorization(categoryID: BudgetCategory.transferID, confidence: 1, tier: .transferMatch, needsReview: false)
        state.transactions = [
            LedgerTransaction(id: "simplefin:p-move", accountID: Self.checking, postedAt: Self.base.addingTimeInterval(-2 * 86_400), merchant: "Transfer To Savings",
                              rawDescription: "TRANSFER TO SAVINGS", amount: Money(-500), categorization: transfer, isPending: true, source: .simplefin,
                              batchID: "sync-0", transferPeerID: "simplefin:s-in"),
            LedgerTransaction(id: "simplefin:s-in", accountID: savings, postedAt: Self.base.addingTimeInterval(-2 * 86_400), merchant: "Transfer From Checking",
                              rawDescription: "TRANSFER FROM CHECKING", amount: Money(500), categorization: transfer, isPending: false, source: .simplefin,
                              batchID: "sync-0", transferPeerID: "simplefin:p-move"),
        ]
        let api = LedgerBudgetAPI(state: state, calendar: Fixture.calendar, clock: { clock.now() }, chatModel: nil, decisions: DecisionRouting(),
                                  persistence: nil, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.simplefin], institutions: []))
        clock.advance(hours: 6)
        let report = try await api.ingest(Self.pull([Row(id: "t-move", days: 1, amount: "-500.00", description: "TRANSFER TO SAVINGS")]), batchID: "sync-1")
        #expect(report.pendingSettled == 1)
        func row(_ id: String) async -> LedgerTransaction? { await api.ledger.transactions.first { $0.id == id } }
        #expect(await row("simplefin:p-move") == nil)
        #expect(await row("simplefin:t-move")?.transferPeerID == "simplefin:s-in")
        #expect(await row("simplefin:t-move")?.categorization?.categoryID == BudgetCategory.transferID)
        #expect(await row("simplefin:s-in")?.transferPeerID == "simplefin:t-move")

        let entry = try #require(await api.merges(batchID: "sync-1").first)
        _ = try await api.undoMerge(id: entry.id)
        #expect(await row("simplefin:p-move")?.transferPeerID == "simplefin:s-in")
        #expect(await row("simplefin:s-in")?.transferPeerID == "simplefin:p-move")
        #expect(await row("simplefin:t-move")?.transferPeerID == nil)
    }

    @Test("A hold that came down settles only into a charge at least a quarter of it")
    func shrinkFloor() {
        #expect(!PendingSweep.amountsFit(pending: Money(-200), posted: Money(-4.99), similarity: 1))
        #expect(!PendingSweep.amountsFit(pending: Money(-200), posted: Money(-49.99), similarity: 1))
        #expect(PendingSweep.amountsFit(pending: Money(-200), posted: Money(-50), similarity: 1))
        #expect(PendingSweep.amountsFit(pending: Money(-200), posted: Money(-120), similarity: 0.85))
        // A placeholder hold still settles into any amount, and the plain band doesn't need the near-identical wording.
        #expect(PendingSweep.amountsFit(pending: Money(-1), posted: Money(-52.37), similarity: 0.9))
        #expect(PendingSweep.amountsFit(pending: Money(-40), posted: Money(-31), similarity: 0.5))
    }
}
