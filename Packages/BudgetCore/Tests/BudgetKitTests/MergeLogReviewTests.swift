import Foundation
import Testing
@testable import BudgetKit

/// P1.3 review fixes: a merge the person made stays made when the same rows come in again, rows skipped again are
/// counted as skipped before, Bring back works in one pass and files what it brings back, undoing a Same charge asks the
/// question again, and merge-log ids never hold an account number.
@Suite("Merge log follow-ups")
struct MergeLogReviewTests {
    typealias Base = MergeLogTests

    @Test("After Same charge, importing the statement again doesn't add the row back or flag it again")
    func sameChargeRemembered() async throws {
        let api = try await Base.api()
        _ = try await Base.importStatement(api)
        let id = try await Base.flaggedID(api)
        _ = try #require(try await api.resolveDuplicate(rowID: id, sameAs: "plaid:p-park"))
        let count = try await api.transactions(TransactionFilter()).count

        let again = try await Base.importStatement(api, batchID: "file-2")
        #expect(again.rowsAdded == 0 && again.possibleDuplicates == nil)
        #expect(again.duplicatesSkipped == 2 && again.duplicatesSkippedBefore == 2)
        #expect(await api.possibleDuplicates().isEmpty)
        #expect(try await api.transactions(TransactionFilter()).count == count)
        // Nothing new is logged: both rows are listed under the import that first let them go.
        #expect(await api.merges(batchID: "file-2").isEmpty)
        // Once brought back, the row is the statement's again, and a later import finds it by id.
        let merge = try #require(await api.merges(batchID: "file-1").first { $0.kind == .duplicateResolved })
        _ = try await api.undoMerge(id: merge.id)
        #expect(try await Base.importStatement(api, batchID: "file-3").rowsAdded == 0)
    }

    @Test("A row skipped again by a later import counts as skipped before, and is listed under the first one")
    func reSkippedCountedBefore() async throws {
        let api = try await Base.api()
        let first = try await Base.importStatement(api)
        #expect(first.duplicatesSkipped == 1 && first.duplicatesSkippedBefore == nil)
        let second = try await Base.importStatement(api, batchID: "file-2")
        #expect(second.duplicatesSkipped == 1 && second.duplicatesSkippedBefore == 1)
        #expect(await api.merges(batchID: "file-2").isEmpty)
        #expect(await api.openMergeCounts() == ["file-1": 1])
    }

    @Test("Undoing Same charge asks the question again and drops the kept row's \"you said\" reason")
    func undoSameChargeAsksAgain() async throws {
        // Statement rows first (still waiting for a category), then the bank's own row, which can't tell them apart.
        var state = LedgerState.empty
        state.rules = [BudgetRule(id: "rule-purchase", match: RuleMatch(merchantContains: "purchase"), categoryID: "shopping")]
        state.accounts = [Account(id: "plaid:card", name: "Card", institution: "Harbor", kind: .credit, balance: .zero, source: .plaid)]
        let waiting = Categorization(categoryID: "shopping", confidence: 0.3, tier: .model, needsReview: true)
        state.transactions = [("deli", "CORNER DELI"), ("park", "HARBOR PARKING")].map { id, raw in
            LedgerTransaction(id: "fileImport:plaid:card:\(id)", accountID: "plaid:card", postedAt: FileImport.day(2026, 9, 21)!, merchant: raw.capitalized,
                              rawDescription: raw, amount: Money(-15), categorization: waiting, isPending: false, source: .fileImport, batchID: "file-0")
        }
        let api = LedgerBudgetAPI(state: state, calendar: Fixture.calendar, clock: { EngineFixture.now }, chatModel: nil, decisions: DecisionRouting(),
                                  persistence: nil, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
        let snapshot = SourceSnapshot(source: .plaid, accounts: [
            SourceAccount(externalID: "card", institution: "Harbor", institutionDomain: nil, name: "Card", kind: .credit, balance: Money(-15),
                          availableBalance: nil, balanceDate: EngineFixture.now, transactions: [
                              SourceTransaction(externalID: "p-x", posted: FileImport.day(2026, 9, 21)!, amount: Money(-15), description: "PURCHASE AUTHORIZED ON 09/21"),
                          ], holdings: [], mask: nil),
        ], warnings: [])
        #expect(try await api.ingest(snapshot, batchID: "sync-1").possibleDuplicates == 1)
        let merged = try #require(try await api.resolveDuplicate(rowID: "plaid:p-x", sameAs: "fileImport:plaid:card:deli"))
        #expect(merged.keptID == "plaid:p-x" && merged.droppedID == "fileImport:plaid:card:deli")
        #expect(try await api.reviewQueue().first { $0.transaction.id == "plaid:p-x" }?.reason.hasPrefix(Ledger.sameChargeLead) == true)

        _ = try await api.undoMerge(id: merged.id)
        let flagged = try #require(await api.possibleDuplicates().first)
        #expect(flagged.id == "fileImport:plaid:card:deli" && flagged.candidates.map(\.id) == ["plaid:p-x"])
        let queue = try await api.reviewQueue()
        #expect(queue.first { $0.transaction.id == flagged.id }?.reason.hasPrefix(Ledger.possibleDuplicateLead) == true)
        #expect(queue.first { $0.transaction.id == "plaid:p-x" }?.reason.hasPrefix(Ledger.sameChargeLead) == false)
    }

    @Test("Bring back all restores thousands of rows in one pass")
    func bulkBringBack() {
        let n = 2_600, total = 8_000
        var state = LedgerState.empty
        state.accounts = [Account(id: "plaid:card", name: "Card", institution: "Harbor", kind: .credit, balance: .zero, source: .plaid)]
        let start = FileImport.day(2025, 1, 1)!
        state.transactions = (0..<total).map { i in
            LedgerTransaction(id: "plaid:\(i)", accountID: "plaid:card", postedAt: start.addingTimeInterval(Double(i) * 3_600), merchant: "Shop \(i)",
                              rawDescription: "SHOP \(i)", amount: Money(-Decimal(i % 90 + 1)), categorization: nil, isPending: false, source: .plaid)
        }
        var ledger = Ledger(state: state, now: Fixture.now, calendar: Fixture.calendar)
        ledger.appendMerges((0..<n).map { i in
            var copy = state.transactions[i]
            copy.id = "fileImport:plaid:card:\(i)"
            copy.source = .fileImport
            copy.batchID = "file-big"
            return RowMergeRecord(id: "", kind: .skippedIncoming, at: Fixture.now, batchID: "file-big", keptID: "plaid:\(i)", droppedID: copy.id, dropped: copy)
        })
        let clock = ContinuousClock()
        let started = clock.now
        let restored = ledger.undoSkipped(batchID: "file-big")
        let elapsed = clock.now - started
        #expect(restored.count == n && ledger.transactions.count == total + n)
        #expect(ledger.mergeLog.allSatisfy { $0.undoneAt != nil })
        #expect(zip(ledger.transactions, ledger.transactions.dropFirst()).allSatisfy { $0.postedAt >= $1.postedAt })
        // One rows' sort however many come back (it was one per row: 45 s for this many in a debug build).
        #expect(elapsed < .seconds(10))
    }

    @Test("A swept statement copy is listed under its import even though that import skipped nothing")
    func sweptCopyCounted() async throws {
        var state = LedgerState.empty
        state.accounts = [Account(id: "card", name: "Card", institution: "Harbor", kind: .credit, balance: .zero, source: .plaid)]
        state.transactions = [
            LedgerTransaction(id: "plaid:amc", accountID: "card", postedAt: FileImport.day(2026, 6, 8)!, merchant: "AMC Theatres",
                              rawDescription: "AplPay AMC 0001 EXAMPLE", amount: Money(-23.45), categorization: nil, isPending: false, source: .plaid),
            LedgerTransaction(id: "fileImport:card:1", accountID: "card", postedAt: FileImport.day(2026, 6, 6)!, merchant: "Aplpay Amc Example",
                              rawDescription: "AplPay AMC 0001 EXAMPLE", amount: Money(-23.45), categorization: nil, isPending: false,
                              source: .fileImport, batchID: "file-0"),
        ]
        let api = LedgerBudgetAPI(state: state, calendar: Fixture.calendar, clock: { EngineFixture.now }, chatModel: nil, decisions: DecisionRouting(),
                                  persistence: nil, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
        #expect(try await api.importDuplicates(apply: true).removed == 1)
        #expect(await api.openMergeCounts() == ["file-0": 1])
        let swept = try #require(await api.merges(batchID: "file-0").first)
        let result = try await api.undoMerge(id: swept.id)
        #expect(result.restored == 1)
        #expect(await api.openMergeCounts().isEmpty)
    }

    @Test("With a decision model on, rows brought back that rules and memory can't file are left for it, not sent to review")
    func bringBackLeavesRowsForTheModel() async throws {
        let api = try await Base.api()
        _ = try await Base.importStatement(api)
        var state = await api.state
        state.decisionPolicy.provider = .jev
        await api.replaceStateWithoutPersisting(state)
        let result = try await api.undoSkipped(batchID: "file-1")
        #expect(result.restored == 1 && result.waiting + result.filed == 1 && result.toReview == 0)
    }

    @Test("A merchant renamed to the bank's own new name keeps the person's name when the bank renames it again")
    func renameSurvivesLaterBankName() async throws {
        let api = try await Base.api()
        let row = { (payee: String?) in
            SourceTransaction(externalID: "p-new", posted: FileImport.day(2026, 9, 23)!, amount: Money(-42), description: "SQ *NOMAD 0423", payee: payee)
        }
        _ = try await api.ingest(Base.plaid([row(nil)]), batchID: "sync-2")
        _ = try await api.perform(.editTransactions(EditTransactions(transactionIDs: ["plaid:p-new"], merchant: "Nomad Bistro")))
        _ = try await api.ingest(Base.plaid([row("Nomad Bistro")]), batchID: "sync-3")
        _ = try await api.ingest(Base.plaid([row("Nomad Bistro & Bar")]), batchID: "sync-4")
        let bistro = try #require(try await api.transactions(TransactionFilter()).first { $0.id == "plaid:p-new" })
        #expect(bistro.merchant == "Nomad Bistro" && bistro.originalMerchant == "Nomad Bistro & Bar")
    }

    @Test("A merge-log entry logged before the statement-id upgrade holds no account number after it")
    func mergeLogIDsHoldNoNumber() throws {
        var ledger = IDMigrationTests.ledger()
        let dropped = IDMigrationTests.row(IDMigrationTests.legacyRow("D2"), IDMigrationTests.legacyAccount, day: 12, -250, "MEADOW ROW 5")
        ledger.appendMerges([RowMergeRecord(id: "", kind: .skippedIncoming, at: Fixture.now, batchID: "file-legacy", keptID: IDMigrationTests.legacyRow("F5"),
                                            droppedID: dropped.id, dropped: dropped)])
        #expect(!(ledger.mergeLog.last?.id.contains("9876543210") ?? true))
        _ = ledger.hashStatementIDs(.test)
        #expect(!(try IDMigrationTests.encoded(ledger.state).contains("9876543210")))
    }
}
