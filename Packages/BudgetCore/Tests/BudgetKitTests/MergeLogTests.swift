import Foundation
import Testing
@testable import BudgetKit

/// P1.3 through the engine: possible duplicates wait in review instead of being dropped on a guess, every row merged
/// away is logged with both ids and can come back, and a provider row that comes back better named is renamed.
@Suite("Possible duplicates and the merge log")
struct MergeLogTests {
    static let card = "plaid:harbor-card"

    /// A Plaid card with two same-day $15 rows at different places, a coffee, and a rule filing anything "Purchase".
    static func api(persistence: (any LedgerPersistence)? = nil) async throws -> LedgerBudgetAPI {
        var state = LedgerState.empty
        state.rules = [BudgetRule(id: "rule-purchase", match: RuleMatch(merchantContains: "purchase"), categoryID: "shopping")]
        let api = LedgerBudgetAPI(state: state, calendar: Fixture.calendar, clock: { EngineFixture.now }, chatModel: nil, decisions: DecisionRouting(),
                                  persistence: persistence, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
        _ = try await api.ingest(plaid(), batchID: "sync-1")
        return api
    }

    static func plaid(_ rows: [SourceTransaction]? = nil) -> SourceSnapshot {
        SourceSnapshot(source: .plaid, accounts: [
            SourceAccount(externalID: "harbor-card", institution: "Harbor Bank", institutionDomain: nil, name: "Harbor Card", kind: .credit,
                          balance: Money(-500), availableBalance: nil, balanceDate: EngineFixture.now, transactions: rows ?? [
                              SourceTransaction(externalID: "p-deli", posted: FileImport.day(2026, 9, 21)!, amount: Money(-15), description: "CORNER DELI", payee: "Corner Deli"),
                              SourceTransaction(externalID: "p-park", posted: FileImport.day(2026, 9, 21)!, amount: Money(-15), description: "HARBOR PARKING", payee: "Harbor Parking"),
                              SourceTransaction(externalID: "p-coffee", posted: FileImport.day(2026, 9, 22)!, amount: Money(-6.50), description: "BLUE BOTTLE COFFEE", payee: "Blue Bottle"),
                          ], holdings: [], mask: "0042"),
        ], warnings: [])
    }

    /// A statement for the same card: a $15 row its generic descriptor can't place, and the coffee.
    static let statement = """
    Transaction Date,Post Date,Description,Category,Type,Amount,Memo
    09/21/2026,09/21/2026,PURCHASE AUTHORIZED ON 09/21,,Sale,-15.00,
    09/22/2026,09/22/2026,BLUE BOTTLE COFFEE,Food & Drink,Sale,-6.50,
    """

    static func importStatement(_ api: LedgerBudgetAPI, batchID: String = "file-1") async throws -> IngestReport {
        try await api.ingest(try FileImport.parse(statement, options: .init(accountKind: .credit)), batchID: batchID, into: card)
    }

    static func flaggedID(_ api: LedgerBudgetAPI) async throws -> String {
        try #require(await api.possibleDuplicates().first?.id)
    }

    @Test("An ambiguous statement row is added and waits in review naming both candidates, even when a rule files it")
    func ambiguousWaitsInReview() async throws {
        let api = try await Self.api()
        let report = try await Self.importStatement(api)
        #expect(report.rowsAdded == 1 && report.duplicatesSkipped == 1 && report.possibleDuplicates == 1)
        let flagged = try #require(await api.possibleDuplicates().first)
        #expect(Set(flagged.candidates.map(\.id)) == ["plaid:p-deli", "plaid:p-park"])
        #expect(flagged.row.categorization?.tier == .rule && flagged.row.categorization?.needsReview == true)
        let item = try #require(try await api.reviewQueue().first { $0.transaction.id == flagged.id })
        #expect(item.reason.hasPrefix(Ledger.possibleDuplicateLead))
        #expect(item.suggestions.first?.categoryID == "shopping")
        // A preview says so too, and changes nothing.
        #expect(try await api.previewIngest(try FileImport.parse(Self.statement, options: .init(accountKind: .credit)), into: Self.card).rowsAdded == 0)
    }

    @Test("Same charge merges into the synced row, keeps the note, logs both ids; undo brings the statement row back")
    func sameChargeThenUndo() async throws {
        let api = try await Self.api()
        _ = try await Self.importStatement(api)
        let id = try await Self.flaggedID(api)
        _ = try await api.perform(.editTransactions(EditTransactions(transactionIDs: [id], note: "lunch with Sam")))
        let before = try await api.transactions(TransactionFilter()).count
        let merged = try #require(try await api.resolveDuplicate(rowID: id, sameAs: "plaid:p-park"))
        #expect(merged.kind == .duplicateResolved && merged.keptID == "plaid:p-park" && merged.droppedID == id && merged.batchID == "file-1")
        #expect(merged.dropped.note == "lunch with Sam" && merged.keptBefore?.note == nil)
        var rows = try await api.transactions(TransactionFilter())
        #expect(rows.count == before - 1 && !rows.contains { $0.id == id })
        #expect(rows.first { $0.id == "plaid:p-park" }?.note == "lunch with Sam")
        #expect(await api.possibleDuplicates().isEmpty)
        #expect(await api.merges(batchID: "file-1").contains { $0.id == merged.id })

        #expect(try await api.undoMerge(id: merged.id) == 1)
        rows = try await api.transactions(TransactionFilter())
        #expect(rows.count == before && rows.contains { $0.id == id })
        #expect(rows.first { $0.id == "plaid:p-park" }?.note == nil) // the kept row gets back what it had
        #expect(await api.merges().first { $0.id == merged.id }?.undoneAt != nil)
        await #expect(throws: BudgetAPIError.self) { try await api.undoMerge(id: merged.id) }
    }

    @Test("Undo leaves the kept row alone when the person changed it after the merge")
    func undoKeepsLaterEdits() async throws {
        let api = try await Self.api()
        _ = try await Self.importStatement(api)
        let id = try await Self.flaggedID(api)
        _ = try await api.perform(.editTransactions(EditTransactions(transactionIDs: [id], note: "lunch")))
        let merged = try #require(try await api.resolveDuplicate(rowID: id, sameAs: "plaid:p-deli"))
        _ = try await api.perform(.editTransactions(EditTransactions(transactionIDs: ["plaid:p-deli"], note: "my own note")))
        _ = try await api.undoMerge(id: merged.id)
        #expect(try await api.transactions(TransactionFilter()).first { $0.id == "plaid:p-deli" }?.note == "my own note")
    }

    @Test("Same charge refuses a row that isn't a candidate; Keep both clears the flag; answering the category does too")
    func keepBothAndAnswers() async throws {
        let api = try await Self.api()
        _ = try await Self.importStatement(api)
        var id = try await Self.flaggedID(api)
        await #expect(throws: BudgetAPIError.self) { try await api.resolveDuplicate(rowID: id, sameAs: "plaid:p-coffee") }
        #expect(try await api.resolveDuplicate(rowID: id, sameAs: nil) == nil)
        #expect(await api.possibleDuplicates().isEmpty)
        #expect(try await api.transactions(TransactionFilter()).contains { $0.id == id }) // still there, still in review
        #expect(try await api.reviewQueue().contains { $0.transaction.id == id })

        // Answering by confirming, by re-filing, and by editing with a category each clear it.
        let answers: [(LedgerBudgetAPI, String) async throws -> Void] = [
            { api, id in _ = try await api.confirmCategory(transactionID: id, categoryID: "dining") },
            { api, id in _ = try await api.perform(.recategorize(Recategorize(transactionIDs: [id], categoryID: "dining"))) },
            { api, id in _ = try await api.perform(.editTransactions(EditTransactions(transactionIDs: [id], categoryID: "dining"))) },
        ]
        for answer in answers {
            let api = try await Self.api()
            _ = try await Self.importStatement(api)
            id = try await Self.flaggedID(api)
            try await answer(api, id)
            #expect(await api.possibleDuplicates().isEmpty)
        }
    }

    @Test("Every row skipped as already here is logged with both ids, and bringing one back adds it uncategorized for the next sync to file")
    func skippedRowsLoggedAndBroughtBack() async throws {
        let api = try await Self.api()
        let report = try await Self.importStatement(api)
        let skipped = await api.merges(batchID: "file-1").filter { $0.kind == .skippedIncoming }
        #expect(skipped.count == report.duplicatesSkipped)
        let coffee = try #require(skipped.first)
        #expect(coffee.keptID == "plaid:p-coffee" && coffee.droppedID == coffee.dropped.id && coffee.dropped.categorization == nil)
        #expect(coffee.dropped.batchID == "file-1" && coffee.dropped.source == .fileImport)

        #expect(try await api.undoSkipped(batchID: "file-1") == 1)
        let back = try #require(try await api.transactions(TransactionFilter()).first { $0.id == coffee.droppedID })
        #expect(back.categorization == nil)
        #expect(try await api.undoSkipped(batchID: "file-1") == 0) // nothing left to bring back
        // The next ingest files it.
        _ = try await api.ingest(Self.plaid([]), batchID: "sync-2")
        #expect(try await api.transactions(TransactionFilter()).first { $0.id == coffee.droppedID }?.categorization != nil)
        // Undoing the batch takes it out again, with the batch's other row.
        #expect(try await api.rollback(batchID: "file-1") == 2)
        #expect(await api.possibleDuplicates().isEmpty)
    }

    @Test("A swept statement copy is logged; bringing it back hands the synced row its own fields back")
    func sweptCopyLogged() async throws {
        var state = LedgerState.empty
        state.accounts = [Account(id: "card", name: "Card", institution: "Harbor", kind: .credit, balance: .zero, source: .plaid)]
        state.transactions = [
            LedgerTransaction(id: "plaid:amc", accountID: "card", postedAt: FileImport.day(2026, 6, 8)!, merchant: "AMC Theatres",
                              rawDescription: "AplPay AMC 0001 EXAMPLE", amount: Money(-23.45), categorization: nil, isPending: false, source: .plaid),
            LedgerTransaction(id: "fileImport:card:1", accountID: "card", postedAt: FileImport.day(2026, 6, 6)!, merchant: "Aplpay Amc Example",
                              rawDescription: "AplPay AMC 0001 EXAMPLE", amount: Money(-23.45),
                              categorization: Categorization(categoryID: "entertainment", confidence: 1, tier: .user, needsReview: false),
                              isPending: false, source: .fileImport, batchID: "file-0"),
        ]
        let api = LedgerBudgetAPI(state: state, calendar: Fixture.calendar, clock: { EngineFixture.now }, chatModel: nil, decisions: DecisionRouting(),
                                  persistence: nil, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
        #expect(try await api.importDuplicates(apply: true).removed == 1)
        let swept = try #require(await api.merges().first)
        #expect(swept.kind == .sweptFileCopy && swept.keptID == "plaid:amc" && swept.droppedID == "fileImport:card:1" && swept.batchID == "file-0")
        #expect(try await api.transactions(TransactionFilter()).first?.categorization?.categoryID == "entertainment")
        _ = try await api.undoMerge(id: swept.id)
        let rows = try await api.transactions(TransactionFilter())
        #expect(rows.count == 2)
        #expect(rows.first { $0.id == "plaid:amc" }?.categorization == nil)
        #expect(rows.first { $0.id == "fileImport:card:1" }?.categorization?.categoryID == "entertainment")
    }

    @Test("A Plaid row that comes back with a better merchant name and category hint updates them, unless the person renamed it; its category stays")
    func betterNames() async throws {
        let api = try await Self.api()
        let pending = SourceTransaction(externalID: "p-new", posted: FileImport.day(2026, 9, 23)!, amount: Money(-42), description: "PENDING 8812 XX",
                                        isPending: true)
        let other = SourceTransaction(externalID: "p-other", posted: FileImport.day(2026, 9, 23)!, amount: Money(-9), description: "PENDING 9921 YY",
                                      isPending: true)
        _ = try await api.ingest(Self.plaid([pending, other]), batchID: "sync-2")
        _ = try await api.confirmCategory(transactionID: "plaid:p-new", categoryID: "dining")
        _ = try await api.perform(.editTransactions(EditTransactions(transactionIDs: ["plaid:p-other"], merchant: "Gym")))
        let posted = SourceTransaction(externalID: "p-new", posted: FileImport.day(2026, 9, 23)!, amount: Money(-42), description: "SQ *NOMAD BISTRO 0423",
                                       payee: "Nomad Bistro", providerCategory: "FOOD_AND_DRINK_RESTAURANT")
        let otherPosted = SourceTransaction(externalID: "p-other", posted: FileImport.day(2026, 9, 23)!, amount: Money(-9), description: "IRONWORKS FITNESS",
                                            payee: "Ironworks Fitness")
        let report = try await api.ingest(Self.plaid([posted, otherPosted]), batchID: "sync-3")
        #expect(report.namesImproved == 2 && report.rowsUpdated == 2 && report.rowsAdded == 0)
        let rows = try await api.transactions(TransactionFilter())
        let bistro = try #require(rows.first { $0.id == "plaid:p-new" })
        #expect(bistro.merchant == "Nomad Bistro" && bistro.rawDescription == "SQ *NOMAD BISTRO 0423")
        #expect(bistro.providerCategory == "FOOD_AND_DRINK_RESTAURANT")
        #expect(bistro.categorization?.categoryID == "dining" && bistro.categorization?.tier == .user)
        let gym = try #require(rows.first { $0.id == "plaid:p-other" })
        #expect(gym.merchant == "Gym" && gym.originalMerchant == "Ironworks Fitness")
        // The same rows again change nothing.
        #expect(try await api.ingest(Self.plaid([posted, otherPosted]), batchID: "sync-4").rowsUpdated == 0)
    }

    @Test("Merge-log entries older than 400 days go as new ones are added, ids never clash, and a row skipped again is logged once")
    func pruneAndIDs() {
        var state = LedgerState.empty
        let old = LedgerTransaction(id: "fileImport:a:old", accountID: "a", postedAt: Fixture.now, merchant: "Old", rawDescription: "OLD",
                                    amount: Money(-1), categorization: nil, isPending: false, source: .fileImport)
        state.mergeLog = [RowMergeRecord(id: "skippedIncoming-b-x", kind: .skippedIncoming, at: Fixture.now.addingTimeInterval(-401 * 86_400), batchID: "b",
                                         droppedID: old.id, dropped: old)]
        var ledger = Ledger(state: state, now: Fixture.now, calendar: Fixture.calendar)
        let record = RowMergeRecord(id: "", kind: .skippedIncoming, at: Fixture.now, batchID: "b", keptID: "k", droppedID: old.id, dropped: old)
        var swept = record
        swept.kind = .sweptFileCopy
        ledger.appendMerges([swept, swept])
        #expect(ledger.mergeLog.map(\.id) == ["sweptFileCopy-b-\(old.id)", "sweptFileCopy-b-\(old.id)-2"])
        // A row skipped again (a window source re-sends its last days every sync) is logged once.
        ledger.appendMerges([record])
        var again = record
        again.batchID = "c"
        ledger.appendMerges([again])
        #expect(ledger.mergeLog.filter { $0.kind == .skippedIncoming }.count == 1)
    }

    @Test("The merge log and possible duplicates survive a save and a reload through persistence")
    func persisted() async throws {
        let persistence = RecordingPersistence()
        let api = try await Self.api(persistence: persistence)
        _ = try await Self.importStatement(api)
        let saved = try #require(await persistence.saves.last).new
        #expect(!saved.mergeLog.isEmpty && saved.possibleDuplicates.count == 1)
        let data = try JSONEncoder().encode(saved)
        let loaded = try JSONDecoder().decode(LedgerState.self, from: data)
        #expect(loaded.mergeLog == saved.mergeLog && loaded.possibleDuplicates == saved.possibleDuplicates)
    }
}
