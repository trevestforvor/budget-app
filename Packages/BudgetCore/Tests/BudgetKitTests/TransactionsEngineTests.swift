import Foundation
import Testing
@testable import BudgetKit

/// Small hand-built ledgers: three accounts and rows placed a given number of days before `EngineFixture.now`.
enum Rows {
    static let accounts = [
        Account(id: "chk", name: "Total Checking", institution: "Harbor", kind: .checking, balance: Money(5000), source: .plaid, mask: "0909"),
        Account(id: "sav", name: "Cash Account", institution: "Meadow", kind: .savings, balance: Money(9000), source: .plaid),
        Account(id: "card", name: "Gold Card", institution: "Summit Card", kind: .credit, balance: Money(-300), source: .plaid),
    ]

    static func row(_ id: String, _ account: String, _ daysAgo: Double, _ amount: Decimal, _ raw: String, _ category: String?,
                    tier: CategorizationTier = .merchantMemory, review: Bool = false, pending: Bool = false, hidden: Bool = false,
                    note: String? = nil, decidedBy: String? = nil, peer: String? = nil) -> LedgerTransaction {
        LedgerTransaction(id: id, accountID: account, postedAt: EngineFixture.now.addingTimeInterval(-daysAgo * 86_400), merchant: raw.capitalized,
                          rawDescription: raw, amount: Money(amount),
                          categorization: category.map { Categorization(categoryID: $0, confidence: review ? 0.4 : 0.9, tier: tier, needsReview: review, decidedBy: decidedBy) },
                          isPending: pending, source: .plaid, isHidden: hidden, note: note, transferPeerID: peer)
    }

    static func state(_ rows: [LedgerTransaction], suggestions: [String: [CategorySuggestion]] = [:]) -> LedgerState {
        var state = LedgerState.empty
        state.accounts = accounts
        state.transactions = rows
        state.suggestions = suggestions
        return state
    }

    static func ledger(_ rows: [LedgerTransaction], suggestions: [String: [CategorySuggestion]] = [:]) -> Ledger {
        Ledger(state: state(rows, suggestions: suggestions), now: EngineFixture.now, calendar: Fixture.calendar)
    }

    static func api(_ rows: [LedgerTransaction], persistence: (any LedgerPersistence)? = nil) -> LedgerBudgetAPI {
        LedgerBudgetAPI(state: state(rows), calendar: Fixture.calendar, clock: { EngineFixture.now }, chatModel: nil, decisions: DecisionRouting(),
                        persistence: persistence, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
    }

    static func edit(_ ids: [String], categoryID: String? = nil, acceptGuess: Bool? = nil, isHidden: Bool? = nil, note: String? = nil,
                     merchant: String? = nil, renameSimilar: Bool? = nil) -> AppAction {
        .editTransactions(EditTransactions(transactionIDs: ids, categoryID: categoryID, acceptGuess: acceptGuess, isHidden: isHidden,
                                           note: note, merchant: merchant, renameSimilar: renameSimilar))
    }
}

extension Ledger {
    func row(_ id: String) -> LedgerTransaction? { transactions.first { $0.id == id } }
}

// MARK: - Confirming a review answer

@Suite("Confirming a review answer")
struct ConfirmTests {
    @Test("A correction reaches rows still waiting with the same descriptor, never settled or hand-filed rows; undo puts them back")
    func fanOut() throws {
        let rows = [
            Rows.row("a", "card", 1, -20, "SQ *CASA TACO 0423", "shopping", tier: .model, review: true),
            Rows.row("b", "card", 2, -15, "SQ *CASA TACO 0501", "shopping", tier: .model, review: true),
            Rows.row("c", "card", 3, -18, "SQ *CASA TACO 0610", "groceries", tier: .user),
            Rows.row("d", "card", 4, -12, "SQ *CASA TACO 0611", "groceries", tier: .merchantMemory),
            Rows.row("e", "chk", 5, -9, "CASA TACO", "shopping", tier: .decisionModel, review: true),
            Rows.row("f", "card", 6, -30, "BLUE BOTTLE", "shopping", tier: .model, review: true),
        ]
        let suggestions = ["a": [CategorySuggestion(categoryID: "shopping", confidence: 0.41), CategorySuggestion(categoryID: "dining", confidence: 0.3)]]
        var ledger = Rows.ledger(rows, suggestions: suggestions)
        let result = try ledger.confirm(transactionID: "a", categoryID: "dining")
        #expect(result.affectedTransactions == 3)
        #expect(result.message == "Filed 3 transactions under Dining.")
        for id in ["a", "b", "e"] {
            #expect(ledger.row(id)?.categorization == Categorization(categoryID: "dining", confidence: 1, tier: .user, needsReview: false))
        }
        #expect(ledger.row("c")?.categorization?.categoryID == "groceries") // the person's own answer stands
        #expect(ledger.row("d")?.categorization?.tier == .merchantMemory)   // settled rows aren't touched
        #expect(ledger.reviewItems.map(\.id) == ["f"])
        #expect(ledger.suggestions["a"] == nil)

        let undo = try #require(result.undo)
        _ = try ledger.perform(undo)
        #expect(ledger.transactions == Rows.ledger(rows, suggestions: suggestions).transactions)
        #expect(ledger.suggestions["a"] == suggestions["a"])
        #expect(Set(ledger.reviewItems.map(\.id)) == ["a", "b", "e", "f"])
    }

    @Test("A generic descriptor only reaches rows on the same account going the same way")
    func genericDescriptor() throws {
        var ledger = Rows.ledger([
            Rows.row("w1", "sav", 1, -1250, "Withdrawal", "shopping", tier: .model, review: true),
            Rows.row("w2", "sav", 3, -300, "Withdrawal", "shopping", tier: .model, review: true),
            Rows.row("w3", "chk", 2, -45, "WITHDRAWAL", "shopping", tier: .model, review: true),
            Rows.row("w4", "sav", 4, 200, "Withdrawal", "income", tier: .model, review: true),
        ])
        let result = try ledger.confirm(transactionID: "w1", categoryID: "transfer")
        #expect(result.affectedTransactions == 2)
        #expect(ledger.row("w2")?.categorization?.categoryID == "transfer")
        #expect(Set(ledger.reviewItems.map(\.id)) == ["w3", "w4"])
    }

    @Test("Filing a deposit as income never files money going out under the same descriptor as income")
    func incomeStaysIncoming() throws {
        var ledger = Rows.ledger([
            Rows.row("p1", "chk", 1, 3850, "PARAMOUNT PAYROLL", "transfer", tier: .model, review: true),
            Rows.row("p2", "chk", 2, -50, "PARAMOUNT PAYROLL", "transfer", tier: .model, review: true),
            Rows.row("p3", "chk", 16, 3850, "PARAMOUNT PAYROLL", "transfer", tier: .model, review: true),
        ])
        #expect(try ledger.confirm(transactionID: "p1", categoryID: "income").affectedTransactions == 2)
        #expect(ledger.reviewItems.map(\.id) == ["p2"])
    }

    @Test("The API returns what changed, and the undo goes through perform")
    func throughTheAPI() async throws {
        let api = Fixture.api()
        let item = try #require(try await api.reviewQueue().first { $0.transaction.merchant == "Casa Taco" })
        let result = try await api.confirmCategory(transactionID: item.id, categoryID: "dining")
        #expect(result.affectedTransactions == 1 && result.message == "Filed under Dining.")
        #expect(try await api.reviewQueue().count == 10)
        _ = try await api.perform(try #require(result.undo))
        #expect(try await api.reviewQueue().count == 11)
        #expect(try await api.transaction(id: item.id) == item.transaction)
    }
}

// MARK: - Hidden transactions

@Suite("Hidden transactions")
struct HiddenTests {
    @Test("A hidden charge leaves spending, its category, flexible spending and its merchant, but not balances")
    func leavesTotalsNotBalances() throws {
        var ledger = Fixture.ledger()
        let month = ledger.interval(for: .thisMonth)
        let row = try #require(ledger.transactions.first { $0.categorization?.categoryID == "dining" && $0.postedAt >= month.start && !$0.isPending })
        func dining(_ l: Ledger) -> Money { l.sumByCategory(from: month.start, to: month.end, includeTargets: false).first { $0.category.id == "dining" }?.spent ?? .zero }
        let before = (spent: ledger.spent(from: month.start, to: month.end), dining: dining(ledger), flex: ledger.flexBudget().flexSpent,
                      merchant: ledger.merchantSpend(row.merchant, from: month.start, to: month.end).total, cash: ledger.cash(through: ledger.now),
                      card: ledger.balance(of: row.accountID, through: ledger.now))
        let result = try ledger.perform(Rows.edit([row.id], isHidden: true))
        #expect(result.message == "Hidden from your totals.")
        let amount = row.amount.magnitude
        #expect(ledger.spent(from: month.start, to: month.end) == before.spent - amount)
        #expect(dining(ledger) == before.dining - amount)
        #expect(ledger.flexBudget().flexSpent == before.flex - amount)
        #expect(ledger.merchantSpend(row.merchant, from: month.start, to: month.end).total == before.merchant - amount)
        #expect(ledger.cash(through: ledger.now) == before.cash)
        #expect(ledger.balance(of: row.accountID, through: ledger.now) == before.card)

        // The assistant still sees the row, marked, but not in its total.
        let (result2, _) = DemoToolbox(ledger: ledger, decisions: nil).queryTransactions(search: row.merchant, categoryID: nil, needsReviewOnly: false, since: nil, until: nil, limit: 200)
        guard case let .object(o) = result2, case let .array(listed)? = o["rows"], case let .string(total)? = o["spent"] else { Issue.record("shape"); return }
        #expect(listed.contains { if case let .object(r) = $0 { r["id"] == .string(row.id) && r["hidden"] == .bool(true) } else { false } })
        let expected = ledger.netSpend(ledger.matching(TransactionFilter(search: row.merchant)).filter { !$0.isHidden })
        #expect(total == expected.display)
        #expect(total == ledger.summary(TransactionFilter(search: row.merchant)).spent.display)

        // Counting it again restores every figure.
        _ = try ledger.perform(Rows.edit([row.id], isHidden: false))
        #expect(ledger.spent(from: month.start, to: month.end) == before.spent)
    }

    @Test("Hiding takes a row out of review")
    func leavesReview() throws {
        var ledger = Fixture.ledger()
        let item = try #require(ledger.reviewItems.first)
        _ = try ledger.perform(Rows.edit([item.id], isHidden: true))
        #expect(ledger.reviewItems.count == 10)
        #expect(ledger.row(item.id)?.categorization?.needsReview == false)
        #expect(ledger.suggestions[item.id] == nil)
    }

    @Test("Hidden charges aren't recurring charges")
    func notSubscriptions() throws {
        var ledger = Fixture.ledger()
        #expect(ledger.subscriptions().items.contains { $0.merchant == "Netflix" })
        let ids = ledger.transactions.filter { $0.merchant == "Netflix" }.map(\.id)
        _ = try ledger.perform(Rows.edit(ids, isHidden: true))
        #expect(!ledger.subscriptions().items.contains { $0.merchant == "Netflix" })
    }

    @Test("Safe to spend counts on the lower of the 3-month average income and the last two biweekly paychecks")
    func paychecksCapIncome() throws {
        // Every two weeks (now is Friday Sept 25): $5,500 to checking and $250 to savings a day later, named
        // differently along the way; interest each month; a bonus off-cycle; a third paycheck in July.
        var rows: [LedgerTransaction] = []
        for (i, daysAgo) in stride(from: 2.0, through: 114, by: 14).enumerated() {
            rows.append(Rows.row("pay-\(i)", "chk", daysAgo, 5500, i < 3 ? "PARAMOUNT GLOBAL PAYROLL DEPOSIT" : "DEPOSIT", "income", tier: .rule))
            rows.append(Rows.row("split-\(i)", "sav", daysAgo - 1, 250, "PARAMOUNT PAYROLL TRAN", "income", tier: .rule))
        }
        for month in 0..<4 { rows.append(Rows.row("interest-\(month)", "sav", Double(24 + 30 * month), 45, "INTEREST", "income", tier: .rule)) }
        rows.append(Rows.row("bonus", "chk", 61, 3000, "PARAMOUNT BONUS", "income", tier: .rule))
        let ledger = Rows.ledger(rows)
        let paychecks = try #require(ledger.recentPaychecks())
        #expect(paychecks.perMonth == 2)
        #expect(paychecks.latest == [Money(5750), Money(5750)]) // interest and the bonus aren't paydays
        let flex = ledger.flexBudget()
        let average = try #require(flex.averageIncome)
        #expect(average > Money(11_500)) // the bonus and July's third paycheck are in the average
        #expect(flex.expectedIncome == Money(11_500))
        #expect(flex.incomeSource == .recentPaychecks && flex.recentPaychecks == Money(11_500) && flex.paycheckCount == 2)
        #expect(flex.incomeSourcePhrase == "your last 2 paychecks")

        // Pay that doesn't keep a schedule isn't paychecks: the average stands.
        let irregular = Rows.ledger([Rows.row("a", "chk", 3, 4000, "CLIENT A", "income", tier: .rule),
                                     Rows.row("b", "chk", 40, 9000, "CLIENT B", "income", tier: .rule),
                                     Rows.row("c", "chk", 49, 1200, "CLIENT C", "income", tier: .rule),
                                     Rows.row("d", "chk", 95, 6000, "CLIENT D", "income", tier: .rule)])
        #expect(irregular.recentPaychecks() == nil)
        #expect(irregular.flexBudget().incomeSource == .threeMonthAverage)
        #expect(irregular.flexBudget().expectedIncome == irregular.flexBudget().averageIncome)
    }

    @Test("A hidden one-off stays in cash but out of the projection's monthly pace and out of income")
    func projectionPace() {
        let calendar = Fixture.calendar
        let startOfMonth = calendar.dateInterval(of: .month, for: EngineFixture.now)!.start
        var rows: [LedgerTransaction] = []
        for back in 1...3 {
            let month = calendar.date(byAdding: .month, value: -back, to: startOfMonth)!
            func at(_ day: Int) -> Double { EngineFixture.now.timeIntervalSince(calendar.date(byAdding: .day, value: day, to: month)!) / 86_400 }
            rows.append(Rows.row("pay-\(back)", "chk", at(2), 3000, "ACME PAYROLL", "income", tier: .rule))
            rows.append(Rows.row("rent-\(back)", "chk", at(9), -2000, "MAPLE CT APTS", "housing", tier: .rule))
            if back == 1 { rows.append(Rows.row("gift", "chk", at(14), 5000, "ZELLE FROM MOM", "income", tier: .user, hidden: true)) }
        }
        let ledger = Rows.ledger(rows)
        #expect(ledger.monthlyNets(count: 3) == [Money(1000), Money(1000), Money(1000)])
        #expect(ledger.projection(horizonMonths: 3, goal: nil).monthlyNet == Money(1000))
        #expect(ledger.cash(through: ledger.now) == Money(3 * 1000 + 5000))
        let last = ledger.interval(for: .lastMonth)
        #expect(ledger.income(from: last.start, to: last.end) == Money(3000))
    }

    @Test("The checkup says what this month's totals leave out")
    func checkupFinding() throws {
        var ledger = Fixture.ledger()
        let month = ledger.interval(for: .thisMonth)
        let rows = ledger.transactions.filter { $0.categorization?.categoryID == "dining" && $0.postedAt >= month.start }.prefix(2)
        _ = try ledger.perform(Rows.edit(rows.map(\.id), isHidden: true))
        let finding = try #require(ledger.checkup().sections.first { $0.id == "data" }?.findings.first { $0.id == "hidden" })
        #expect(finding.title == "2 transactions are hidden from this month's totals.")
        #expect(finding.metrics.first?.money == rows.map(\.amount.magnitude).sum())
        #expect(finding.status == .good)
    }

    @Test("Hidden rows and transfers don't count; income, spending and uncategorized rows do")
    func counted() {
        let categories = Dictionary(uniqueKeysWithValues: Ledger.categoryList.map { ($0.id, $0) })
        func counted(_ category: String?, hidden: Bool = false) -> Bool {
            Rows.row("x", "chk", 1, -5, "X", category, hidden: hidden).isCounted(category: category.flatMap { categories[$0] })
        }
        #expect(counted("dining") && counted("income") && counted(nil))
        #expect(!counted("transfer"))
        #expect(!counted("dining", hidden: true))
        let ledger = Rows.ledger([Rows.row("t", "chk", 1, -500, "ONLINE TRANSFER", "transfer")])
        #expect(!ledger.isCounted(ledger.transactions[0]))
    }

    @Test("Rows saved before hiding existed decode as counted, with no note or pair")
    func legacyRowsDecode() throws {
        let json = #"{"id":"r","accountID":"chk","postedAt":0,"merchant":"Harvest Table","rawDescription":"HARVEST TABLE","amount":{"minor":-1000,"currency":"USD"},"isPending":false,"source":"plaid"}"#
        let row = try JSONDecoder().decode(LedgerTransaction.self, from: Data(json.utf8))
        #expect(!row.isHidden && row.note == nil && row.transferPeerID == nil && row.originalMerchant == nil)
        var state = try JSONValue.parse(JSONEncoder().encode(LedgerState.empty))
        if case var .object(o) = state { o["merchantAliases"] = nil; state = .object(o) }
        #expect(try JSONDecoder().decode(LedgerState.self, from: state.data()).merchantAliases.isEmpty)
    }
}

// MARK: - Editing transactions

@Suite("Editing transactions")
struct EditTransactionsTests {
    @Test("Keep the guess files what the model picked as the person's answer")
    func keepGuess() throws {
        var ledger = Fixture.ledger()
        let item = try #require(ledger.reviewItems.first { $0.transaction.merchant == "Casa Taco" })
        #expect(try ledger.preview(Rows.edit([item.id], acceptGuess: true)).title == "Keep 1 transaction as Dining")
        let result = try ledger.perform(Rows.edit([item.id], acceptGuess: true))
        #expect(result.message == "Kept as Dining.")
        #expect(ledger.row(item.id)?.categorization == Categorization(categoryID: "dining", confidence: 1, tier: .user, needsReview: false))
        #expect(ledger.reviewItems.count == 10)
    }

    @Test("A category edit re-files exactly the rows given, and undo restores them to the field")
    func categoryAndUndo() throws {
        var ledger = Fixture.ledger()
        let original = ledger
        let ids = ledger.reviewItems.prefix(3).map(\.id)
        let result = try ledger.perform(Rows.edit(ids, categoryID: "shopping"))
        #expect(result.affectedTransactions == 3 && result.message == "Filed 3 transactions under Shopping.")
        #expect(ledger.reviewItems.count == 8)
        _ = try ledger.perform(try #require(result.undo))
        #expect(ledger.transactions == original.transactions)
        #expect(ledger.suggestions == original.suggestions)
    }

    @Test("Edits that can't apply are refused with a reason")
    func refusals() throws {
        let ledger = Fixture.ledger()
        let id = try #require(ledger.transactions.first?.id)
        func reason(_ action: AppAction) -> String? {
            do { _ = try ledger.preview(action); return nil } catch { return error.localizedDescription }
        }
        #expect(reason(Rows.edit([id], categoryID: "dining", acceptGuess: true)) == "Choose a category or keep the one it has, not both.")
        #expect(reason(Rows.edit([id])) == "Nothing to change.")
        #expect(reason(Rows.edit([])) == "Choose at least one transaction.")
        #expect(reason(Rows.edit([id], merchant: "  ")) == "A merchant needs a name.")
        #expect(reason(Rows.edit([id], renameSimilar: true)) == "Renaming similar transactions needs the new name.")
        #expect(reason(Rows.edit([id], categoryID: "pets")) == "Unknown category “pets”.")
        #expect(throws: BudgetAPIError.notFound) { try ledger.preview(Rows.edit(["nope"], isHidden: true)) }
    }

    @Test("A note is saved, searchable, and removed by an empty one")
    func notes() throws {
        var ledger = Fixture.ledger()
        let row = try #require(ledger.transactions.first { $0.merchant == "Harvest Table" })
        #expect(try ledger.perform(Rows.edit([row.id], note: "  Birthday dinner, split with Sam  ")).message == "Note saved.")
        #expect(ledger.row(row.id)?.note == "Birthday dinner, split with Sam")
        #expect(ledger.matching(TransactionFilter(search: "split with sam")).map(\.id) == [row.id])
        _ = try ledger.perform(Rows.edit([row.id], note: ""))
        #expect(ledger.row(row.id)?.note == nil)
    }

    @Test("Renaming one row keeps the bank's name as its original; renaming it back clears that")
    func renameOne() throws {
        var ledger = Fixture.ledger()
        let rows = ledger.transactions.filter { $0.merchant == "Blue Bottle Coffee" }
        let first = try #require(rows.first)
        #expect(try ledger.perform(Rows.edit([first.id], merchant: "Blue Bottle")).message == "Renamed to “Blue Bottle”.")
        #expect(ledger.row(first.id)?.merchant == "Blue Bottle" && ledger.row(first.id)?.originalMerchant == "Blue Bottle Coffee")
        #expect(ledger.transactions.filter { $0.merchant == "Blue Bottle Coffee" }.count == rows.count - 1)
        #expect(ledger.merchantAliases.isEmpty)
        _ = try ledger.perform(Rows.edit([first.id], merchant: "Blue Bottle Coffee"))
        #expect(ledger.row(first.id)?.merchant == "Blue Bottle Coffee" && ledger.row(first.id)?.originalMerchant == nil)
    }

    @Test("Renaming all like it renames every row with the descriptor, moves the cap, keeps the subscription whole — and undoes")
    func renameSimilar() throws {
        var ledger = Fixture.ledger()
        _ = try ledger.perform(.setMerchantTarget(SetMerchantTarget(merchant: "Netflix", monthlyAmount: DecimalAmount(string: "20")!)))
        let original = ledger
        let netflix = ledger.transactions.filter { $0.rawDescription == "NETFLIX.COM" }
        let charges = try #require(ledger.subscriptions().items.first { $0.merchant == "Netflix" }).charges
        let action = Rows.edit([netflix[0].id], merchant: "Netflix Premium", renameSimilar: true)
        let preview = try ledger.preview(action)
        #expect(preview.title == "Rename \(netflix.count) transactions to “Netflix Premium”")
        #expect(preview.detail?.contains("New ones get the name too.") == true && preview.detail?.contains("The Netflix cap moves with it.") == true)

        let result = try ledger.perform(action)
        #expect(result.affectedTransactions == netflix.count)
        #expect(ledger.transactions.filter { $0.rawDescription == "NETFLIX.COM" }.allSatisfy { $0.merchant == "Netflix Premium" && $0.originalMerchant == "Netflix" })
        #expect(ledger.merchantAliases == ["NETFLIX.COM": "Netflix Premium"])
        #expect(ledger.merchantTargets["Netflix Premium"] == Money(20) && ledger.merchantTargets["Netflix"] == nil)
        #expect(ledger.subscriptions().items.first { $0.merchant == "Netflix Premium" }?.charges == charges)

        _ = try ledger.perform(try #require(result.undo))
        #expect(ledger.transactions == original.transactions)
        #expect(ledger.merchantAliases.isEmpty)
        #expect(ledger.merchantTargets == original.merchantTargets)
    }

    @Test("New rows from a renamed descriptor arrive with the new name")
    func aliasOnIngest() async throws {
        let api = EngineFixture.api(decisions: DecisionRouting(local: StubDecisions(["NETFLIX": ("subscriptions", 0.97)])))
        _ = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "sync-1")
        let row = try #require(try await api.transactions(TransactionFilter(search: "netflix")).first)
        _ = try await api.perform(Rows.edit([row.id], merchant: "Netflix Premium", renameSimilar: true))
        var next = EngineFixture.plaidSnapshot()
        next.accounts[0].transactions = [SourceTransaction(externalID: "p10", posted: EngineFixture.day(0), amount: Money(-15.49), description: "NETFLIX.COM", payee: "Netflix")]
        _ = try await api.ingest(next, batchID: "sync-2")
        let arrived = try await api.transaction(id: "plaid:p10")
        #expect(arrived.merchant == "Netflix Premium" && arrived.originalMerchant == "Netflix")
    }

    @Test("A generic descriptor gets no name for other rows: only the chosen row is renamed")
    func genericRename() throws {
        var ledger = Rows.ledger([Rows.row("w1", "sav", 1, -1250, "Withdrawal", "housing"), Rows.row("w2", "sav", 30, -1250, "Withdrawal", "housing")])
        let action = Rows.edit(["w1"], merchant: "Rent to Sam", renameSimilar: true)
        #expect(try ledger.preview(action).detail?.contains("“Withdrawal” doesn't name a merchant") == true)
        _ = try ledger.perform(action)
        #expect(ledger.row("w1")?.merchant == "Rent to Sam" && ledger.row("w2")?.merchant == "Withdrawal")
        #expect(ledger.merchantAliases.isEmpty)
    }

    @Test("Several changes at once read as one edit")
    func combined() throws {
        var ledger = Fixture.ledger()
        let ids = ledger.transactions.filter { $0.merchant == "Harvest Table" }.prefix(2).map(\.id)
        let action = Rows.edit(ids, categoryID: "entertainment", isHidden: true, note: "Work dinner")
        let preview = try ledger.preview(action)
        #expect(preview.title == "Edit 2 transactions: file under Entertainment, hide from your totals and add a note")
        #expect(preview.effects.first?.id == "hidden-spend")
        #expect(try ledger.perform(action).message == "Updated 2 transactions.")
        #expect(ids.allSatisfy { ledger.row($0)?.isHidden == true && ledger.row($0)?.note == "Work dinner" && ledger.row($0)?.categorization?.categoryID == "entertainment" })
    }
}

// MARK: - Transfer pairs

@Suite("Transfer pairs")
struct TransferPairTests {
    @Test("A matched transfer records each side on the other")
    func ingestPairs() async throws {
        let api = IncomeTransferTests.api(extra: [IncomeTransferTests.row("harbor-pay", "freedom", 19, 1250, "AUTOMATIC PAYMENT - THANK", category: "income")])
        _ = try await api.ingest(try FileImport.parse(IncomeTransferTests.qfx), batchID: "qfx", into: "cash")
        let withdrawal = try #require(await api.state.transactions.first { $0.rawDescription == "Withdrawal" && $0.amount == Money(-1250) })
        #expect(withdrawal.transferPeerID == "harbor-pay")
        #expect(try await api.transaction(id: "harbor-pay").transferPeerID == withdrawal.id)

        // Rolling the import back leaves no half of a pair behind.
        _ = try await api.rollback(batchID: "qfx")
        #expect(try await api.transaction(id: "harbor-pay").transferPeerID == nil)
    }

    @Test("Older matched transfers get their pairs on load, preferring the named account; loading writes that back once")
    func legacyPairs() async throws {
        let rows = [
            Rows.row("out", "chk", 3, -500, "ONLINE TRANSFER TO SAV", "transfer", tier: .rule, decidedBy: "Matched transfer · Cash Account"),
            Rows.row("in", "sav", 3.1, 500, "ONLINE TRANSFER FROM CHK", "transfer"),
            Rows.row("card-in", "card", 2.9, 500, "PAYMENT THANK YOU", "transfer"),   // nearer, but not the account named
            Rows.row("refund", "card", 3, 500, "UNIQLO REFUND", "shopping"),            // not a transfer
        ]
        let ledger = Rows.ledger(rows)
        #expect(ledger.row("out")?.transferPeerID == "in" && ledger.row("in")?.transferPeerID == "out")
        #expect(ledger.row("card-in")?.transferPeerID == nil && ledger.row("refund")?.transferPeerID == nil)

        let persistence = RecordingPersistence()
        let state = Rows.state(rows)
        let api = Rows.api(rows, persistence: persistence)
        try await api.persistUpgrades(from: state)
        #expect(await persistence.saves.count == 1)
        #expect(await persistence.saves.first?.new.transactions.first { $0.id == "out" }?.transferPeerID == "in")
        try await api.persistUpgrades(from: await api.state)
        #expect(await persistence.saves.count == 1)
    }

    @Test("Filing one side as something other than a transfer ends the pair; undo restores it")
    func unpairOnRefile() throws {
        var ledger = Fixture.ledger()
        let side = try #require(ledger.transactions.first { $0.transferPeerID != nil && $0.accountID == "sav" })
        let peer = try #require(side.transferPeerID)
        #expect(ledger.row(peer)?.transferPeerID == side.id)
        let result = try ledger.perform(.recategorize(Recategorize(transactionIDs: [side.id], categoryID: "income")))
        #expect(ledger.row(side.id)?.transferPeerID == nil && ledger.row(peer)?.transferPeerID == nil)
        _ = try ledger.perform(try #require(result.undo))
        #expect(ledger.row(side.id)?.transferPeerID == peer && ledger.row(peer)?.transferPeerID == side.id)
    }

    @Test("Removing one side clears the other's pair")
    func orphans() throws {
        var ledger = Fixture.ledger()
        let side = try #require(ledger.transactions.first { $0.transferPeerID != nil })
        #expect(ledger.removeRows([side.transferPeerID!]) == 1)
        #expect(ledger.row(side.id)?.transferPeerID == nil)
    }
}

// MARK: - Pending to posted

@Suite("Pending rows posting")
struct PendingPostedTests {
    @Test("Plaid's pending_transaction_id becomes the row a posted transaction replaces")
    func parse() throws {
        let page = try PlaidSource.parseSync(try JSONValue.parse(Data(#"""
        {"added": [{"transaction_id": "posted-1", "pending_transaction_id": "pend-1", "account_id": "a", "amount": 6.5, "date": "2026-09-20", "name": "BLUE BOTTLE", "pending": false},
                   {"transaction_id": "pend-2", "pending_transaction_id": "x", "account_id": "a", "amount": 4, "date": "2026-09-21", "name": "SWEETGREEN", "pending": true}],
         "modified": [], "removed": [{"transaction_id": "pend-1"}], "next_cursor": "c", "has_more": false}
        """#.utf8)))
        #expect(page.added[0].transaction.replacesExternalID == "pend-1")
        #expect(page.added[1].transaction.replacesExternalID == nil)
        #expect(page.removed == ["pend-1"])
    }

    static func snapshot(_ rows: [SourceTransaction], account: String = "summit-1", kind: AccountKind = .credit) -> SourceSnapshot {
        SourceSnapshot(source: .plaid, accounts: [
            SourceAccount(externalID: account, institution: "Bank", institutionDomain: nil, name: account, kind: kind, balance: .zero,
                          availableBalance: nil, balanceDate: EngineFixture.now, transactions: rows, holdings: []),
        ], warnings: [])
    }

    @Test("The posted row keeps what the person did to the pending one, without asking the model again")
    func carryOver() async throws {
        let model = StubDecisions(["BLUE BOTTLE": ("dining", 0.95)])
        let api = EngineFixture.api(decisions: DecisionRouting(local: model))
        let pending = SourceTransaction(externalID: "q1", posted: EngineFixture.day(2), amount: Money(-6.5), description: "BLUE BOTTLE COFFEE 0423", payee: "Blue Bottle", isPending: true)
        _ = try await api.ingest(Self.snapshot([pending]), batchID: "sync-1")
        _ = try await api.perform(Rows.edit(["plaid:q1"], categoryID: "groceries", isHidden: true, note: "Team coffee", merchant: "Blue Bottle (team)"))

        let calls = await model.calls
        let posted = SourceTransaction(externalID: "q2", posted: EngineFixture.day(1), amount: Money(-6.5), description: "BLUE BOTTLE COFFEE 0423",
                                       payee: "Blue Bottle", replacesExternalID: "q1")
        _ = try await api.ingest(Self.snapshot([posted]), batchID: "sync-2")
        #expect(try await api.removeSourceRows(.plaid, externalIDs: ["q1"]) == 1)
        let row = try await api.transaction(id: "plaid:q2")
        #expect(row.isHidden && row.note == "Team coffee")
        #expect(row.merchant == "Blue Bottle (team)" && row.originalMerchant == "Blue Bottle")
        #expect(row.categorization?.categoryID == "groceries" && row.categorization?.tier == .user)
        #expect(await model.calls == calls)
        #expect(try await api.transactions(TransactionFilter()).count == 1)
    }

    @Test("Both sides of a payment in one sync pair, neither goes to review, and the pair moves to the posted row")
    func pairMoves() async throws {
        let api = EngineFixture.api(decisions: DecisionRouting(local: StubDecisions([:])))
        let snapshot = SourceSnapshot(source: .plaid, accounts: [
            Self.snapshot([SourceTransaction(externalID: "t1", posted: EngineFixture.day(3), amount: Money(-200), description: "SUMMIT EPAYMENT ACH PMT", isPending: true)],
                          account: "chk", kind: .checking).accounts[0],
            Self.snapshot([SourceTransaction(externalID: "t2", posted: EngineFixture.day(2), amount: Money(200), description: "PAYMENT RECEIVED - THANK YOU")]).accounts[0],
        ], warnings: [])
        let report = try await api.ingest(snapshot, batchID: "sync-1")
        #expect(report.needsReview == 0 && report.modelCalls == 0)
        #expect(try await api.transaction(id: "plaid:t2").transferPeerID == "plaid:t1")
        #expect(try await api.transaction(id: "plaid:t1").categorization?.categoryID == "transfer")

        let posted = SourceTransaction(externalID: "t3", posted: EngineFixture.day(2), amount: Money(-200), description: "SUMMIT EPAYMENT ACH PMT", replacesExternalID: "t1")
        _ = try await api.ingest(Self.snapshot([posted], account: "chk", kind: .checking), batchID: "sync-2")
        _ = try await api.removeSourceRows(.plaid, externalIDs: ["t1"])
        let card = try await api.transaction(id: "plaid:t2"), cash = try await api.transaction(id: "plaid:t3")
        #expect(card.transferPeerID == "plaid:t3" && cash.transferPeerID == "plaid:t2")
        #expect(cash.categorization?.categoryID == "transfer")
    }
}

// MARK: - Filters, pages and summaries

@Suite("Transaction filter")
struct TransactionFilterTests {
    static let rows = [
        Rows.row("r1", "card", 1, -12, "SQ *CASA TACO", "dining", tier: .decisionModel, note: "Lunch with Sam"),
        Rows.row("r2", "card", 2, -12.49, "BLUE BOTTLE", "dining"),
        Rows.row("r3", "chk", 3, 3850, "ACME PAYROLL", "income", tier: .rule),
        Rows.row("r4", "chk", 4, -500, "ONLINE TRANSFER TO SAV", "transfer", peer: "r5"),
        Rows.row("r5", "sav", 4, 500, "ONLINE TRANSFER FROM CHK", "transfer", peer: "r4"),
        Rows.row("r6", "card", 40, -250, "UNITED AIRLINES", "travel", hidden: true),
        Rows.row("r7", "card", 0.04, -30, "HARVEST TABLE", "dining", tier: .model, review: true, pending: true),
        Rows.row("r8", "card", 100, -80, "SAFEWAY", "groceries", tier: .user),
    ]

    func ids(_ filter: TransactionFilter) -> [String] { Rows.ledger(Self.rows).matching(filter).map(\.id) }

    @Test("Every criterion narrows")
    func criteria() {
        #expect(ids(TransactionFilter()) == ["r7", "r1", "r2", "r3", "r5", "r4", "r6", "r8"])
        #expect(ids(TransactionFilter(search: "sam")) == ["r1"])                       // the note
        #expect(ids(TransactionFilter(search: "12.00")) == ["r1"])                     // an exact amount
        #expect(ids(TransactionFilter(search: "$12")) == ["r1", "r2"])                 // whole dollars
        #expect(ids(TransactionFilter(search: "$3,850")) == ["r3"])
        #expect(ids(TransactionFilter(search: "blue")) == ["r2"])
        #expect(ids(TransactionFilter(categoryIDs: ["dining", "groceries"])) == ["r7", "r1", "r2", "r8"])
        #expect(ids(TransactionFilter(categoryIDs: [])) == ids(TransactionFilter()))
        #expect(ids(TransactionFilter(accountIDs: ["chk", "sav"])) == ["r3", "r5", "r4"])
        #expect(ids(TransactionFilter(period: "last_30_days")) == ["r7", "r1", "r2", "r3", "r5", "r4"])
        #expect(ids(TransactionFilter(period: "nonsense")).isEmpty)
        #expect(ids(TransactionFilter(since: EngineFixture.day(5), until: EngineFixture.day(1))) == ["r2", "r3", "r5", "r4"])
        #expect(ids(TransactionFilter(direction: .moneyIn)) == ["r3", "r5"])
        #expect(ids(TransactionFilter(minAmount: Money(100))) == ["r3", "r5", "r4", "r6"])
        #expect(ids(TransactionFilter(maxAmount: Money(20))) == ["r1", "r2"])
        #expect(ids(TransactionFilter(needsReviewOnly: true)) == ["r7"])
        #expect(ids(TransactionFilter(pendingOnly: true)) == ["r7"])
        #expect(ids(TransactionFilter(modelFiledOnly: true)) == ["r1"])
        #expect(ids(TransactionFilter(visibility: .notCounted)) == ["r5", "r4", "r6"])
        #expect(ids(TransactionFilter(visibility: .counted)) == ["r7", "r1", "r2", "r3", "r8"])
    }

    @Test("Sorts, and pages that neither overlap nor skip")
    func sortAndPages() {
        #expect(ids(TransactionFilter(sort: .largest)).prefix(4) == ["r3", "r5", "r4", "r6"])
        #expect(ids(TransactionFilter(sort: .oldest)) == ids(TransactionFilter()).reversed())
        let ledger = Rows.ledger(Self.rows)
        let pages = stride(from: 0, to: 9, by: 3).map { ledger.query(TransactionFilter(limit: 3, offset: $0)).map(\.id) }
        #expect(pages.map(\.count) == [3, 3, 2])
        #expect(pages.flatMap { $0 } == ids(TransactionFilter()))
    }

    @Test("The summary counts what the list shows, by the Spending tab's rules")
    func summary() {
        let ledger = Rows.ledger(Self.rows)
        let month = ledger.summary(TransactionFilter(period: "last_30_days"))
        #expect(month.count == 6 && month.earliest == EngineFixture.day(4) && month.latest == Self.rows[6].postedAt)
        #expect(month.spent == Money(54.49) && month.income == Money(3850))
        #expect(month.notCountedCount == 2 && month.notCountedTotal == Money(500) && month.hiddenCount == 0)
        #expect(month.needsReviewCount == 1 && month.pendingCount == 1)
        let all = ledger.summary(TransactionFilter(limit: 1, offset: 5))  // paging doesn't matter
        #expect(all.count == 8 && all.spent == Money(134.49))
        #expect(all.hiddenCount == 1 && all.notCountedCount == 3 && all.notCountedTotal == Money(750))
    }

    @Test("A month's summary matches the Spending tab and income to the cent, before and after hiding a row")
    func matchesSpending() throws {
        var ledger = Fixture.ledger()
        func check() {
            let summary = ledger.summary(TransactionFilter(period: "this_month"))
            let month = ledger.interval(for: .thisMonth)
            #expect(summary.spent == ledger.spendingSummary(.thisMonth).total)
            #expect(summary.income == ledger.income(from: month.start, to: month.end))
        }
        check()
        let row = try #require(ledger.matching(TransactionFilter(categoryIDs: ["groceries"], period: "this_month")).first)
        _ = try ledger.perform(Rows.edit([row.id], isHidden: true))
        check()
        #expect(ledger.summary(TransactionFilter(period: "this_month")).hiddenCount == 1)
    }

    @Test("New period names resolve")
    func periods() throws {
        let ledger = Fixture.ledger()
        let lastYear = try #require(ledger.interval(forPeriod: "last_year"))
        #expect(lastYear.start == Fixture.calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)))
        #expect(lastYear.end == Fixture.calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)) && lastYear.label == "2025")
        #expect(ledger.interval(forPeriod: "last_30_days")?.start == Fixture.calendar.date(byAdding: .day, value: -30, to: Fixture.now))
        #expect(ledger.interval(forPeriod: "last_6_months")?.start == Fixture.calendar.date(byAdding: .month, value: -6, to: Fixture.now))
        #expect(ledger.interval(forPeriod: "all")?.start == .distantPast)
    }

    @Test("Query items round-trip, through a URL too")
    func queryItems() throws {
        let filter = TransactionFilter(search: "taco + tip", categoryIDs: ["dining", "groceries"], accountIDs: ["plaid:a", "card"], period: "last_30_days",
                                       since: Date(timeIntervalSince1970: 1_780_000_000), until: Date(timeIntervalSince1970: 1_790_000_000),
                                       direction: .moneyOut, minAmount: Money(12.5), maxAmount: Money(400), needsReviewOnly: true, pendingOnly: true,
                                       modelFiledOnly: true, visibility: .notCounted, sort: .largest, limit: 50, offset: 100)
        #expect(try TransactionFilter(queryItems: filter.queryItems) == filter)
        var components = URLComponents(string: "https://budget.example/v1/transactions")!
        components.queryItems = filter.queryItems
        let back = URLComponents(url: components.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
        #expect(try TransactionFilter(queryItems: back) == filter)
        #expect(TransactionFilter().queryItems == [URLQueryItem(name: "limit", value: "200")])
    }

    @Test("The parser reads days in the ledger's zone, caps the page, and refuses what it can't read")
    func parsing() throws {
        let day = try TransactionFilter(queryItems: [URLQueryItem(name: "since", value: "2026-09-01"), URLQueryItem(name: "limit", value: "99999"),
                                                     URLQueryItem(name: "category", value: ""), URLQueryItem(name: "color", value: "red")],
                                        calendar: Fixture.calendar)
        #expect(day.since == Fixture.calendar.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        #expect(day.limit == 5000 && day.categoryIDs == nil)
        #expect(throws: BudgetAPIError.decoding("sort must be newest, oldest or largest, got “biggest”")) {
            try TransactionFilter(queryItems: [URLQueryItem(name: "sort", value: "biggest")])
        }
        #expect(throws: BudgetAPIError.self) { try TransactionFilter(queryItems: [URLQueryItem(name: "min", value: "ten")]) }
        #expect(throws: BudgetAPIError.self) { try TransactionFilter(queryItems: [URLQueryItem(name: "offset", value: "-3")]) }
    }

    @Test("Only the plain first page is the default list")
    func isDefault() {
        #expect(TransactionFilter().isDefault && TransactionFilter(search: " ", categoryIDs: [], limit: 50).isDefault)
        #expect(!TransactionFilter(offset: 200).isDefault && !TransactionFilter(sort: .largest).isDefault && !TransactionFilter(categoryID: "dining").isDefault)
        #expect(TransactionFilter(categoryID: "dining").categoryIDs == ["dining"])
    }

    @Test("The API refuses an unknown period, and finds one row by id")
    func api() async throws {
        let api = Fixture.api()
        await #expect(throws: BudgetAPIError.rejected("Unknown period “fortnight”.")) { try await api.transactions(TransactionFilter(period: "fortnight")) }
        let first = try #require(try await api.transactions(TransactionFilter(limit: 1)).first)
        #expect(try await api.transaction(id: first.id) == first)
        await #expect(throws: BudgetAPIError.notFound) { try await api.transaction(id: "nope") }
        #expect(try await api.transactionSummary(TransactionFilter(period: "this_month")).spent == (try await api.spending(.thisMonth)).total)
    }

    @Test("Offline, one row comes from the cached list")
    func offlineRow() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "budget-cache-\(UUID().uuidString)")
        let cache = ResponseCache(directory: dir)
        let rows = try await CachingBudgetAPI(upstream: Fixture.api(), cache: cache).transactions(TransactionFilter())
        let offline = CachingBudgetAPI(upstream: CacheTests.Down(), cache: cache)
        #expect(try await offline.transaction(id: rows[3].id) == rows[3])
        await #expect(throws: BudgetAPIError.unreachable) { try await offline.transaction(id: "nope") }
    }
}
