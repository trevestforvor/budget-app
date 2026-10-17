import Foundation
import Testing
@testable import BudgetKit

/// Money-in categories: Income and the ones the person makes (card rewards) count as money coming in everywhere income
/// is counted and nowhere spending is; and money coming in on a credit card is never filed as Income on its own.
enum MoneyIn {
    static let rewards = BudgetCategory(id: "card-rewards", name: "Card rewards", symbol: "gift", color: "amber", kind: .moneyIn)

    /// `LedgerState.empty` with Card rewards after Income, the three `Rows` accounts, and `rows`.
    static func state(_ rows: [LedgerTransaction] = [], rules: [BudgetRule] = [], policy: DecisionPolicy = .default,
                      suggestions: [String: [CategorySuggestion]] = [:]) -> LedgerState {
        var state = Setup.state(rows, rules: rules, policy: policy)
        state.categories.insert(rewards, at: state.categories.firstIndex { $0.id == "transfer" }!)
        state.suggestions = suggestions
        return state
    }

    static func ledger(_ rows: [LedgerTransaction] = [], rules: [BudgetRule] = []) -> Ledger { Setup.ledger(state(rows, rules: rules)) }

    static let modelOn = DecisionPolicy(provider: .localDecide, autoAcceptPercent: 80, kinds: [.category])

    /// Bank rows for one card, as a provider sends them (the payee is the merchant).
    static func cardSnapshot(_ rows: [(id: String, daysAgo: Int, amount: Decimal, description: String, payee: String?)],
                             source: SourceKind = .plaid, category: String? = nil) -> SourceSnapshot {
        SourceSnapshot(source: source, accounts: [
            SourceAccount(externalID: "gold", institution: "Summit Card", institutionDomain: nil, name: "Gold Card", kind: .credit,
                          balance: Money(-300), availableBalance: nil, balanceDate: EngineFixture.now,
                          transactions: rows.map { SourceTransaction(externalID: $0.id, posted: EngineFixture.day($0.daysAgo), amount: Money($0.amount),
                                                                     description: $0.description, payee: $0.payee, providerCategory: category) },
                          holdings: []),
        ], warnings: [])
    }
}

// MARK: - The model

@Suite("Money in: the category kind")
struct CategoryKindTests {
    @Test("Categories saved before kinds decode with Income as money in and the rest as spending; money in never counts as spending")
    func legacyDecode() throws {
        func decode(_ json: String) throws -> BudgetCategory { try JSONDecoder().decode(BudgetCategory.self, from: Data(json.utf8)) }
        let income = try decode(#"{"id":"income","name":"Income","symbol":"arrow.down.circle","countsAsSpending":false,"group":"flexible"}"#)
        let transfer = try decode(#"{"id":"transfer","name":"Transfer","symbol":"arrow.left.arrow.right","countsAsSpending":false,"group":"flexible","color":"violet"}"#)
        let pets = try decode(#"{"id":"pets","name":"Pets","symbol":"pawprint","countsAsSpending":true,"group":"fixed","isArchived":false}"#)
        #expect(income.kind == .moneyIn && income.isMoneyIn && income.isSystem)
        #expect(transfer.kind == .spending && !transfer.countsAsSpending && transfer.isSystem)
        #expect(pets.kind == .spending && pets.countsAsSpending && !pets.isSystem)
        // A money-in category never counts as spending, whatever a document says.
        let odd = try decode(#"{"id":"perks","name":"Perks","symbol":"gift","countsAsSpending":true,"group":"flexible","kind":"moneyIn"}"#)
        #expect(odd.isMoneyIn && !odd.countsAsSpending)
        #expect(BudgetCategory(id: "perks", name: "Perks", symbol: "gift", kind: .moneyIn).countsAsSpending == false)
        // The kind travels, and round-trips.
        let data = try JSONEncoder().encode(MoneyIn.rewards)
        #expect(String(decoding: data, as: UTF8.self).contains(#""kind":"moneyIn""#))
        #expect(try JSONDecoder().decode(BudgetCategory.self, from: data) == MoneyIn.rewards)
    }

    @Test("A whole ledger stored before kinds loads, and its income still counts")
    func legacyLedger() throws {
        var state = Rows.state([Rows.row("pay", "chk", 2, 3000, "ACME PAYROLL", "income")])
        guard case var .object(fields) = try JSONValue.parse(JSONEncoder().encode(state)), case let .array(categories)? = fields["categories"] else {
            Issue.record("not an object"); return
        }
        fields["categories"] = .array(categories.map { category in
            guard case var .object(c) = category else { return category }
            c["kind"] = nil
            return .object(c)
        })
        let old = JSONValue.object(fields)
        if case let .array(stored)? = fields["categories"] {
            #expect(stored.allSatisfy { if case let .object(c) = $0 { c["kind"] == nil && c["id"] != nil } else { false } })
        }
        let loaded = try JSONDecoder().decode(LedgerState.self, from: old.data())
        #expect(loaded.categories == state.categories)
        state = loaded
        let ledger = Setup.ledger(state)
        let month = ledger.interval(for: .thisMonth)
        #expect(ledger.income(from: month.start, to: month.end) == Money(3000))
    }
}

// MARK: - Totals

@Suite("Money in: totals")
struct MoneyInTotalsTests {
    /// Pay each month, Card rewards credits on the card, and a little spending, in the months before `Small`'s September 25.
    static func ledger() -> Ledger {
        var rows: [LedgerTransaction] = []
        for month in 6...9 {
            rows.append(Small.row("pay-\(month)", at: Small.date(2026, month, 1), 3000, category: "income", raw: "ACME PAYROLL"))
            rows.append(Small.row("rent-\(month)", at: Small.date(2026, month, 2), -1000, category: "housing", raw: "RENT"))
        }
        rows += [
            Small.row("credit-aug", "card", at: Small.date(2026, 8, 3), 30, category: "card-rewards", raw: "SUMMIT DINING CREDIT"),
            Small.row("credit-sep", "card", at: Small.date(2026, 9, 3), 50, category: "card-rewards", raw: "SUMMIT TABLESY CREDIT"),
            Small.row("dinner", "card", at: Small.date(2026, 9, 12), -100, category: "dining", raw: "HARVEST TABLE"),
        ]
        var state = LedgerState.empty
        state.accounts = Small.accounts
        state.transactions = rows
        state.categories.insert(MoneyIn.rewards, at: state.categories.firstIndex { $0.id == "transfer" }!)
        return Ledger(state: state, now: Small.date(2026, 9, 25), calendar: Small.calendar)
    }

    @Test("Income counts every money-in category; spending, category totals and budget groups leave them out")
    func incomeAndSpending() throws {
        let ledger = Self.ledger()
        let month = ledger.interval(for: .thisMonth)
        #expect(ledger.income(from: month.start, to: month.end) == Money(3050))
        #expect(ledger.spent(from: month.start, to: month.end) == Money(1100))
        let overview = ledger.overview()
        #expect(overview.monthIncome == Money(3050) && overview.monthSpent == Money(1100))
        #expect(!ledger.spendingSummary(.thisMonth).categories.contains { $0.category.isMoneyIn })
        let budget = try ledger.budgetMonth(nil)
        #expect(budget.groups.allSatisfy { group in !group.categories.contains { $0.category.isMoneyIn } })
        #expect(budget.groups.map(\.spent).sum() == Money(1100))
        #expect(ledger.isCounted(try #require(ledger.row("credit-sep"))))
        #expect(ledger.matching(TransactionFilter(period: "this_month", visibility: .counted)).contains { $0.id == "credit-sep" })
    }

    @Test("Expected income and savings capacity include money in; the flex math is unchanged in form")
    func flexMath() {
        let ledger = Self.ledger()
        let c = ledger.capacity()
        #expect(c.income == Money(3010)) // June, July and August: $9,000 of pay and a $30 credit, over three months
        #expect(c.bills == Money(1000) && c.subscriptions == .zero && c.everyday == .zero)
        let flex = ledger.flexBudget()
        #expect(flex.averageIncome == Money(3010))
        // Monthly $3,000 paychecks are lower than an average with the credit in it, so the budget counts on those.
        #expect(flex.expectedIncome == Money(3000) && flex.incomeSource == .recentPaychecks && flex.paycheckCount == 1)
        #expect(flex.flexNumber == flex.expectedIncome - flex.bills - flex.subscriptions - flex.plannedSavings)
        #expect(flex.flexSpent == Money(100)) // dining; the credit doesn't offset it
        #expect(ledger.savingsPlanIncome == c.income)
    }

    @Test("Cash flow and the transaction summary count money in as income")
    func cashFlowAndSummary() {
        let ledger = Self.ledger()
        let flows = ledger.cashFlowHistory(months: 3)
        #expect(flows.last?.income == Money(3050) && flows.last?.spending == Money(1100) && flows.last?.net == Money(1950))
        #expect(flows.first { $0.month == "2026-08" }?.income == Money(3030))
        let all = ledger.summary(TransactionFilter(period: "this_month"))
        #expect(all.income == Money(3050) && all.spent == Money(1100) && all.notCountedCount == 0)
        let rewards = ledger.summary(TransactionFilter(categoryIDs: ["card-rewards"], period: "this_month"))
        #expect(rewards.income == Money(50) && rewards.spent == .zero)
    }

    @Test("A money-in category has no spending history or target, and the assistant reads what it received")
    func toolsAndLimits() throws {
        var ledger = Self.ledger()
        #expect(throws: BudgetAPIError.rejected("Card rewards isn't spending, so it has no spending history.")) { try ledger.categoryHistory("card-rewards", months: 6) }
        #expect(throws: BudgetAPIError.rejected("Card rewards isn't a spending category, so it can't have a target.")) {
            try ledger.perform(.setCategoryTarget(SetCategoryTarget(categoryID: "card-rewards", monthlyAmount: DecimalAmount(string: "50")!)))
        }
        let toolbox = DemoToolbox(ledger: ledger, decisions: nil)
        let one = try toolbox.sumByCategory(period: "this_month", compareTo: "last_month", categoryID: "card-rewards")
        guard case let .object(o) = one.result, case let .object(before)? = o["compareTo"] else { Issue.record("shape"); return }
        #expect(o["received"] == .string(Money(50).display) && o["countsAs"] == .string("money in") && o["total"] == nil)
        #expect(before["received"] == .string(Money(30).display) && before["difference"] == .string(Money(20).display))
        #expect(one.figures.first?.value == Money(50))
        let all = try toolbox.sumByCategory(period: "this_month", compareTo: nil, categoryID: nil)
        guard case let .object(a) = all.result, case let .array(moneyIn)? = a["moneyIn"], case let .array(spending)? = a["byCategory"] else { Issue.record("shape"); return }
        #expect(moneyIn.count == 2 && a["total"] == .string(Money(1100).display))
        #expect(!spending.contains { if case let .object(c) = $0 { c["id"] == .string("card-rewards") } else { false } })
        let rows = toolbox.queryTransactions(search: "SUMMIT", categoryID: nil, needsReviewOnly: false, since: nil, until: nil, limit: 10)
        guard case let .object(q) = rows.result, case let .array(list)? = q["rows"] else { Issue.record("shape"); return }
        #expect(q["income"] == .string(Money(80).display) && q["spent"] == .string(Money.zero.display))
        #expect(list.allSatisfy { if case let .object(r) = $0 { r["moneyIn"] == .bool(true) } else { false } })
    }

    @Test("The demo's Card rewards count as income, never as spending")
    func demo() {
        let ledger = Fixture.ledger()
        let rewards = ledger.category("card-rewards")
        #expect(rewards?.isMoneyIn == true && rewards?.countsAsSpending == false)
        #expect(ledger.categories.map(\.id).suffix(3) == ["income", "card-rewards", "transfer"])
        let credits = ledger.transactions.filter { $0.categorization?.categoryID == "card-rewards" }
        #expect(credits.count >= 6 && credits.allSatisfy { $0.accountID == "card" && !$0.amount.isNegative && $0.categorization?.needsReview == false })
        let last = ledger.interval(for: .lastMonth)
        let pay = ledger.transactions(from: last.start, to: last.end).filter { $0.categorization?.categoryID == "income" }.map(\.amount).sum()
        let received = ledger.received(from: last.start, to: last.end, categoryID: "card-rewards")
        #expect(received.minorUnits > 0 && ledger.income(from: last.start, to: last.end) == pay + received)
        #expect(!ledger.spendingSummary(.lastMonth).categories.contains { $0.id == "card-rewards" })
    }
}

extension Ledger {
    /// What Plan's "average income" reads: the capacity's income.
    fileprivate var savingsPlanIncome: Money { capacity().income }
}

// MARK: - Card money in is never pay

@Suite("Money in: money coming in on a card")
struct CardCreditTests {
    static func api(_ state: LedgerState, _ model: StubDecisions, persistence: (any LedgerPersistence)? = nil) -> LedgerBudgetAPI {
        LedgerBudgetAPI(state: state, calendar: Fixture.calendar, clock: { EngineFixture.now }, chatModel: nil, decisions: DecisionRouting(local: model),
                        persistence: persistence, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
    }

    @Test("The model calling a card payment or refund Income sends it to review: Transfer first for a payment, the refunded category for a refund")
    func modelNeverFilesCardIncome() async throws {
        let prior = LedgerTransaction(id: "lunch", accountID: "card", postedAt: EngineFixture.day(20), merchant: "Sweetgreen", rawDescription: "SWEETGREEN NOMAD",
                                      amount: Money(-18), categorization: Categorization(categoryID: "dining", confidence: 1, tier: .user, needsReview: false),
                                      isPending: false, source: .plaid)
        let model = StubDecisions(["PAYMENT": ("income", 0.97), "SWEETGREEN": ("income", 0.95), "PAYROLL": ("income", 0.97)])
        let api = Self.api(MoneyIn.state([prior], policy: MoneyIn.modelOn), model)
        let report = try await api.ingest(MoneyIn.cardSnapshot([("pay", 2, 1042.89, "AUTOMATIC PAYMENT - THANK", nil),
                                                                ("refund", 3, 18, "SWEETGREEN REFUND 0923", "Sweetgreen")]), batchID: "b", into: "card")
        _ = try await api.ingest(Setup.snapshot([("salary", 1, 3850, "ACME PAYROLL")]), batchID: "c", into: "chk")
        #expect(report.needsReview == 2 && report.byModel == 0)
        let queue = Dictionary(uniqueKeysWithValues: try await api.reviewQueue().map { ($0.id, $0) })
        let pay = try #require(queue["plaid:pay"]), refund = try #require(queue["plaid:refund"])
        #expect(pay.suggestions.map(\.categoryID) == ["transfer"] && pay.transaction.categorization?.categoryID == "transfer")
        #expect(refund.suggestions.map(\.categoryID) == ["dining"] && refund.suggestions.first?.confidence == 0.6)
        let reason = "The decision model called this income, but money coming in on a credit card isn't pay: it's a payment to the card, a refund or a statement credit."
        #expect(pay.reason == reason && refund.reason == reason)
        #expect(!queue.values.contains { $0.suggestions.contains { $0.categoryID == "income" } })
        // Pay on a checking account is still pay.
        #expect(try await api.transaction(id: "plaid:salary").categorization?.categoryID == "income")
    }

    @Test("The bank's Income label is never offered for card money in, nor a money-in category for money going out")
    func hintsStayHonest() async throws {
        let api = Self.api(MoneyIn.state(policy: MoneyIn.modelOn), StubDecisions([:])) // unsure: shopping at 30%
        _ = try await api.ingest(MoneyIn.cardSnapshot([("credit", 1, 40, "MYSTERY CREDIT", nil), ("debit", 2, -40, "MYSTERY DEBIT", nil)],
                                                      category: "INCOME_OTHER_INCOME"), batchID: "b", into: "card")
        let queue = try await api.reviewQueue()
        #expect(queue.count == 2 && queue.allSatisfy { $0.suggestions.map(\.categoryID) == ["shopping"] })
    }

    @Test("A card credit the model files under a money-in category the person made is fine")
    func rewardsOnACardAreFine() async throws {
        let api = Self.api(MoneyIn.state(policy: MoneyIn.modelOn), StubDecisions(["DINING CREDIT": ("card-rewards", 0.95)]))
        _ = try await api.ingest(MoneyIn.cardSnapshot([("credit", 1, 10, "SUMMIT DINING CREDIT", nil)]), batchID: "b", into: "card")
        let row = try await api.transaction(id: "plaid:credit")
        #expect(row.categorization?.categoryID == "card-rewards" && row.categorization?.needsReview == false)
    }

    @Test("Merchant memory and a statement never file card money in as Income; the person's rule does")
    func memoryStatementAndRules() async throws {
        // The person once filed a card credit as Income themselves; memory learns it, but won't repeat it on a card.
        let mine = LedgerTransaction(id: "mine", accountID: "card", postedAt: EngineFixture.day(30), merchant: "Venmo Cashback", rawDescription: "VENMO CASHBACK",
                                     amount: Money(20), categorization: Categorization(categoryID: "income", confidence: 1, tier: .user, needsReview: false),
                                     isPending: false, source: .plaid)
        let rule = Setup.rule("rule-1", descriptor: "EMPLOYER REIMB", "income")
        let model = StubDecisions([:])
        let api = Self.api(MoneyIn.state([mine], rules: [rule], policy: MoneyIn.modelOn), model)
        _ = try await api.ingest(MoneyIn.cardSnapshot([("again", 1, 25, "VENMO CASHBACK", nil), ("reimb", 2, 200, "EMPLOYER REIMB 0923", nil)]),
                                 batchID: "b", into: "card")
        let again = try await api.transaction(id: "plaid:again"), reimb = try await api.transaction(id: "plaid:reimb")
        #expect(again.categorization?.categoryID != "income" && again.categorization?.needsReview == true)
        #expect(try await api.reviewQueue().first { $0.id == "plaid:again" }?.reason
                == "Merchant memory would file this as Income, but money coming in on a credit card isn't pay: it's a payment to the card, a refund or a statement credit.")
        #expect(reimb.categorization == Categorization(categoryID: "income", confidence: 1, tier: .rule, needsReview: false, decidedBy: "rule:rule-1"))
        #expect(try await api.transaction(id: "mine").categorization?.categoryID == "income") // the person's answer stays

        // A statement's interest row on a card goes to review too; on a cash account it's settled as Income.
        let statement = Self.api(MoneyIn.state(policy: MoneyIn.modelOn), StubDecisions(["DEPOSIT": ("income", 0.97)]))
        var state = await statement.state
        state.accounts.append(Account(id: "freedom", name: "Freedom", institution: "Harbor", kind: .credit, balance: Money(-90), source: .fileImport))
        await statement.replaceStateWithoutPersisting(state)
        _ = try await statement.ingest(try FileImport.parse(IncomeTransferTests.qfx, ids: .test), batchID: "qfx", into: "freedom")
        let rows = try await statement.transactions(TransactionFilter(limit: 50))
        let interest = try #require(rows.first { $0.rawDescription == "Interest" })
        #expect(interest.categorization?.categoryID == "transfer" && interest.categorization?.needsReview == true)
        let queue = try await statement.reviewQueue()
        #expect(queue.first { $0.id == interest.id }?.reason
                == "The statement calls this income, but money coming in on a credit card isn't pay: it's a payment to the card, a refund or a statement credit.")
        #expect(rows.first { $0.rawDescription == "Deposit" }?.categorization?.needsReview == true) // the model's Income held back too
    }

    @Test("Re-checking the queue never files card money in as Income, nor money going out under a money-in category")
    func recheckKeepsTheGuards() async throws {
        let rows = [Rows.row("pay", "card", 2, 500, "PAYMENT RECEIVED THANK YOU", "transfer", tier: .model, review: true),
                    Rows.row("clawback", "card", 3, -10, "SUMMIT DINING CREDIT REVERSAL", "dining", tier: .model, review: true)]
        let model = StubDecisions(["PAYMENT": ("income", 0.97), "REVERSAL": ("card-rewards", 0.95)])
        let api = Self.api(MoneyIn.state(rows, policy: MoneyIn.modelOn), model)
        _ = try await api.perform(.updateDecisionPolicy(UpdateDecisionPolicy(autoAcceptPercent: 85)))
        let queue = Dictionary(uniqueKeysWithValues: try await api.reviewQueue().map { ($0.id, $0) })
        #expect(queue["pay"]?.suggestions.first?.categoryID == "transfer" && queue["pay"]?.transaction.categorization?.categoryID != "income")
        #expect(queue["pay"]?.reason.hasPrefix("The decision model called this income, but money coming in on a credit card isn't pay") == true)
        #expect(queue["clawback"]?.suggestions.first?.categoryID == "transfer")
        #expect(queue["clawback"]?.reason == "The decision model filed this under Card rewards, but money going out never counts as money in.")
    }

    @Test("Loading sends card money in filed as Income back to review, honestly — never the person's own answers, rules or hidden rows; once")
    func upgradeOnLoad() async throws {
        let rows = [
            Rows.row("pay", "card", 2, 1042.89, "AUTOMATIC PAYMENT - THANK", "income", tier: .decisionModel),
            Rows.row("lunch", "card", 20, -45, "SWEETGREEN NOMAD", "dining", tier: .user),
            Rows.row("refund", "card", 3, 45, "SWEETGREEN NOMAD", "income", tier: .merchantMemory),
            Rows.row("stmt", "card", 4, 12, "Interest", "income", tier: .statement, decidedBy: "From the statement"),
            Rows.row("waiting", "card", 5, 30, "SOME CREDIT", "income", tier: .model, review: true),
            Rows.row("mine", "card", 6, 20, "VENMO CASHBACK", "income", tier: .user),
            Rows.row("ruled", "card", 7, 30, "EMPLOYER REIMB", "income", tier: .rule, decidedBy: "rule:rule-1"),
            Rows.row("hidden", "card", 8, 15, "ODD CREDIT", "income", tier: .decisionModel, hidden: true),
            Rows.row("rewards", "card", 9, 10, "SUMMIT DINING CREDIT", "card-rewards", tier: .decisionModel),
            Rows.row("salary", "chk", 10, 3850, "ACME PAYROLL", "income", tier: .decisionModel),
        ]
        let state = MoneyIn.state(rows, rules: [Setup.rule("rule-1", descriptor: "EMPLOYER REIMB", "income")],
                                  suggestions: ["waiting": [CategorySuggestion(categoryID: "income", confidence: 0.5), CategorySuggestion(categoryID: "shopping", confidence: 0.3)]])
        let ledger = Setup.ledger(state)
        let moved = ["pay", "refund", "stmt", "waiting"]
        for id in moved {
            let c = try #require(ledger.row(id)?.categorization)
            #expect(c.categoryID != "income" && c.needsReview, "\(id) goes back to review")
            #expect(ledger.reviewReasons[id] == "It was filed as Income, but money coming in on a credit card isn't pay: it's a payment to the card, a refund or a statement credit.")
            #expect(ledger.suggestions[id]?.contains { $0.categoryID == "income" } == false)
        }
        #expect(ledger.suggestions["pay"]?.map(\.categoryID) == ["transfer"])
        #expect(ledger.suggestions["refund"]?.map(\.categoryID) == ["dining"])
        #expect(ledger.suggestions["stmt"]?.map(\.categoryID) == ["transfer"]) // nothing to go on: a payment from elsewhere, maybe
        #expect(ledger.suggestions["waiting"]?.map(\.categoryID) == ["shopping"])
        #expect(ledger.row("pay")?.categorization?.tier == .decisionModel) // provenance kept
        for id in ["mine", "ruled", "hidden", "rewards", "salary", "lunch"] {
            #expect(ledger.row(id)?.categorization == state.transactions.first { $0.id == id }?.categorization, "\(id) is left alone")
        }
        #expect(Set(ledger.reviewItems.map(\.id)) == Set(moved))
        #expect(ledger.state.upgrades == [Ledger.cardIncomeUpgrade])
        #expect(Setup.ledger(ledger.state).state == ledger.state) // a no-op the second time
        #expect(Setup.ledger(state).state == ledger.state)        // and the same from the original every time

        // Once done it never runs again: card credits the person later merges into Income stay there.
        var later = ledger.state
        let index = try #require(later.transactions.firstIndex { $0.id == "pay" })
        later.transactions[index].categorization = Categorization(categoryID: "income", confidence: 0.99, tier: .merchantMemory, needsReview: false)
        #expect(Setup.ledger(later).row("pay")?.categorization?.categoryID == "income")

        // The server writes the upgrade back once.
        let persistence = RecordingPersistence()
        let api = Self.api(state, StubDecisions([:]), persistence: persistence)
        try await api.persistUpgrades(from: state)
        #expect(await persistence.saves.count == 1)
        #expect(await persistence.saves.first?.new.transactions.first { $0.id == "pay" }?.categorization?.needsReview == true)
        try await api.persistUpgrades(from: await api.state)
        #expect(await persistence.saves.count == 1)
    }

    @Test("Confirming a review answer as Income files that row, but never fans out to other card money in")
    func confirmFanOut() throws {
        var ledger = MoneyIn.ledger([
            Rows.row("a", "chk", 1, 200, "ZELLE FROM ALEX", "transfer", tier: .model, review: true),
            Rows.row("b", "card", 2, 200, "ZELLE FROM ALEX", "transfer", tier: .model, review: true),
        ])
        #expect(try ledger.confirm(transactionID: "a", categoryID: "income").affectedTransactions == 1)
        #expect(ledger.row("b")?.categorization?.needsReview == true)
        #expect(try ledger.confirm(transactionID: "b", categoryID: "income").affectedTransactions == 1)
        #expect(ledger.row("b")?.categorization == Categorization(categoryID: "income", confidence: 1, tier: .user, needsReview: false))
    }
}

// MARK: - Actions

@Suite("Money in: categories and rules")
struct MoneyInActionTests {
    @Test("A new money-in category comes after Income, ignores a budget type, takes no target and says what it is")
    func create() throws {
        var ledger = Setup.ledger(Setup.state())
        let preview = try ledger.preview(.createCategory(CreateCategory(name: "Card rewards", group: .bills, kind: .moneyIn)))
        #expect(preview.title == "Add a Card rewards category" && preview.detail == "Counts as money coming in, like income: never spending, never budgeted.")
        _ = try ledger.perform(.createCategory(CreateCategory(name: "Card rewards", group: .bills, kind: .moneyIn)))
        _ = try ledger.perform(.createCategory(CreateCategory(name: "Pets")))
        let rewards = try #require(ledger.category("card-rewards"))
        #expect(rewards.kind == .moneyIn && !rewards.countsAsSpending && rewards.group == .everyday && rewards.symbol == "arrow.down.circle")
        #expect(ledger.category("pets")?.kind == .spending)
        #expect(ledger.categories.suffix(3).map(\.id) == ["income", "card-rewards", "transfer"])
        #expect(throws: BudgetAPIError.rejected("Perks counts as money in, so it can't have a spending target.")) {
            try ledger.preview(.createCategory(CreateCategory(name: "Perks", monthlyTarget: DecimalAmount(string: "20")!, kind: .moneyIn)))
        }
        // A standard category merged away comes back as what it was.
        _ = try ledger.perform(.mergeCategory(MergeCategory(from: "travel", into: "shopping")))
        #expect(throws: BudgetAPIError.rejected("Travel was a spending category, so it comes back as one. Pick another name for a money in category.")) {
            try ledger.preview(.createCategory(CreateCategory(name: "Travel", kind: .moneyIn)))
        }
    }

    @Test("A money-in category can be renamed and recolored, never given a budget type; its kind never changes")
    func update() throws {
        var ledger = MoneyIn.ledger()
        #expect(try ledger.perform(.updateCategory(UpdateCategory(categoryID: "card-rewards", name: "Perks", color: "lime"))).message == "Renamed Card rewards to Perks.")
        #expect(throws: BudgetAPIError.rejected("Perks counts as money in, so it has no budget type.")) {
            try ledger.perform(.updateCategory(UpdateCategory(categoryID: "card-rewards", group: .bills)))
        }
        #expect(throws: BudgetAPIError.rejected("Income keeps its name and isn't budgeted; you can change its icon and color.")) {
            try ledger.perform(.updateCategory(UpdateCategory(categoryID: "income", name: "Pay")))
        }
        // The wire has no kind for an update: one sent along is ignored, and the assistant's schema refuses it.
        let action = try JSONDecoder().decode(AppAction.self, from: Data(#"{"type":"updateCategory","categoryID":"card-rewards","symbol":"star","kind":"spending"}"#.utf8))
        _ = try ledger.perform(action)
        #expect(ledger.category("card-rewards")?.kind == .moneyIn && ledger.category("card-rewards")?.symbol == "star")
        #expect(throws: ToolArgumentError.self) {
            try AppAction(toolName: "updateCategory", arguments: Data(#"{"categoryID":"card-rewards","kind":"spending"}"#.utf8))
        }
    }

    @Test("Merging money in into money in moves rows and rules; Income stays")
    func merge() throws {
        var ledger = MoneyIn.ledger([Rows.row("c", "card", 1, 10, "SUMMIT DINING CREDIT", "card-rewards", tier: .user)],
                                    rules: [Setup.rule("rule-1", descriptor: "SUMMIT", "card-rewards", direction: .moneyIn)])
        let preview = try ledger.preview(.mergeCategory(MergeCategory(from: "card-rewards", into: "income")))
        #expect(preview.detail == "Moves 1 transaction and 1 rule to Income. Card rewards is removed.")
        _ = try ledger.perform(.mergeCategory(MergeCategory(from: "card-rewards", into: "income")))
        #expect(ledger.category("card-rewards") == nil && ledger.row("c")?.categorization?.categoryID == "income" && ledger.rules[0].categoryID == "income")
        #expect(ledger.row("c")?.categorization?.tier == .user)
    }

    @Test("A rule for a money-in category files only money coming in, and says so; money out is refused")
    func rules() throws {
        var ledger = MoneyIn.ledger([Rows.row("in", "card", 1, 15, "SUMMIT OFFER CREDIT", "transfer", tier: .model, review: true),
                                     Rows.row("out", "card", 2, -15, "SUMMIT OFFER CREDIT", "shopping", tier: .model, review: true)])
        let result = try ledger.perform(.createBudgetRule(CreateBudgetRule(match: .init(descriptorContains: "SUMMIT OFFER"), categoryID: "card-rewards", applyToExisting: true)))
        #expect(result.affectedTransactions == 1)
        #expect(ledger.rules[0].match.direction == .moneyIn)
        #expect(ledger.ruleSummaries()[0].matchDescription == "Bank description contains “SUMMIT OFFER” · money in")
        #expect(ledger.row("in")?.categorization?.categoryID == "card-rewards" && ledger.row("out")?.categorization?.categoryID == "shopping")
        #expect(throws: BudgetAPIError.rejected("Money going out never counts as money in, so a rule can't file it under Card rewards.")) {
            try ledger.preview(.createBudgetRule(CreateBudgetRule(match: .init(descriptorContains: "SUMMIT", direction: .moneyOut), categoryID: "card-rewards", applyToExisting: false)))
        }
        // Moving a rule to a money-in category makes it money-in only, too.
        _ = try ledger.perform(.createBudgetRule(CreateBudgetRule(match: .init(merchantContains: "Venmo"), categoryID: "transfer", applyToExisting: false)))
        _ = try ledger.perform(.updateBudgetRule(UpdateBudgetRule(ruleID: "rule-2", categoryID: "card-rewards")))
        #expect(ledger.rules[1].match.direction == .moneyIn)

        // A rule stored without a direction (from before) still never takes money going out; turning it off leaves it as saved.
        var legacy = MoneyIn.ledger([Rows.row("out", "card", 2, -15, "SUMMIT OFFER CREDIT", nil)], rules: [Setup.rule("rule-1", descriptor: "SUMMIT OFFER", "card-rewards")])
        #expect(legacy.rule(for: try #require(legacy.row("out")), known: Set(legacy.activeCategories.map(\.id))) == nil)
        _ = try legacy.perform(.updateBudgetRule(UpdateBudgetRule(ruleID: "rule-1", isEnabled: false)))
        #expect(legacy.rules[0].match.direction == nil && !legacy.rules[0].isEnabled)
    }

    @Test("Tools know the kind: createCategory takes it, merging offers money in but never Transfer, targets stay spending-only; the prompt says money in")
    func tools() throws {
        let create = try #require(ToolCatalog.spec(named: "createCategory"))
        #expect(create.schema.properties["kind"]?.enumValues == ["spending", "moneyIn"])
        let action = try AppAction(toolName: "createCategory", arguments: Data(#"{"name":"Card rewards","kind":"moneyIn","symbol":"gift"}"#.utf8))
        #expect(action == .createCategory(CreateCategory(name: "Card rewards", symbol: "gift", kind: .moneyIn)))
        #expect(try JSONDecoder().decode(AppAction.self, from: Data(#"{"type":"createCategory","name":"Card rewards","kind":"moneyIn"}"#.utf8))
                == .createCategory(CreateCategory(name: "Card rewards", kind: .moneyIn)))
        let categories = MoneyIn.state().categories
        let specs = ToolCatalog.specs(for: categories)
        let merge = try #require(specs.first { $0.name == "mergeCategory" }?.schema.properties["from"]?.enumValues)
        #expect(merge.contains("card-rewards") && merge.contains("income") && merge.contains("dining") && !merge.contains("transfer"))
        let target = try #require(specs.first { $0.name == "setCategoryTarget" }?.schema.properties["categoryID"]?.enumValues)
        #expect(!target.contains("card-rewards") && !target.contains("income"))
        let prompt = AssistantPrompt.system(AssistantContext(now: EngineFixture.now, categories: categories, monthlyTargets: [:]))
        #expect(prompt.contains("- card-rewards — Card rewards — money in") && prompt.contains("- income — Income — money in"))
        #expect(prompt.contains("- transfer — Transfer — not spending"))
        #expect(CategoryDecisions.hint(for: MoneyIn.rewards) == "Card rewards — money coming in that the user counts like income, never spending")
    }
}
