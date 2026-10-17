import Foundation
import Testing
@testable import BudgetKit

/// Ledgers built from `Rows` with rules and a decision policy, served by the real API, and bank rows to ingest into an account.
enum Setup {
    static func state(_ rows: [LedgerTransaction] = [], rules: [BudgetRule] = [], policy: DecisionPolicy = .default) -> LedgerState {
        var state = Rows.state(rows)
        state.rules = rules
        state.decisionPolicy = policy
        return state
    }

    static func api(_ state: LedgerState, decisions: DecisionRouting = DecisionRouting()) -> LedgerBudgetAPI {
        LedgerBudgetAPI(state: state, calendar: Fixture.calendar, clock: { EngineFixture.now }, chatModel: nil, decisions: decisions,
                        persistence: nil, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
    }

    static func ledger(_ state: LedgerState) -> Ledger { Ledger(state: state, now: EngineFixture.now, calendar: Fixture.calendar) }

    static func rule(_ id: String, merchant: String? = nil, descriptor: String? = nil, _ categoryID: String, direction: TransactionFilter.Direction? = nil,
                     account: String? = nil, on: Bool = true) -> BudgetRule {
        BudgetRule(id: id, match: RuleMatch(merchantContains: merchant, descriptorContains: descriptor, direction: direction, accountID: account),
                   categoryID: categoryID, isEnabled: on)
    }

    /// Bank rows as one Plaid account's snapshot; ingest with `into:` to land them on a ledger account.
    static func snapshot(_ rows: [(id: String, daysAgo: Int, amount: Decimal, description: String)], category: String? = nil) -> SourceSnapshot {
        SourceSnapshot(source: .plaid, accounts: [
            SourceAccount(externalID: "acct", institution: "Bank", institutionDomain: nil, name: "Account", kind: .checking, balance: Money(1000),
                          availableBalance: nil, balanceDate: EngineFixture.now,
                          transactions: rows.map { SourceTransaction(externalID: $0.id, posted: EngineFixture.day($0.daysAgo), amount: Money($0.amount),
                                                                     description: $0.description, providerCategory: category) },
                          holdings: []),
        ], warnings: [])
    }

    static func amount(_ text: String) -> DecimalAmount { DecimalAmount(string: text)! }
}

/// Answers every request with one choice and remembers the options each request offered.
actor RecordingDecisions: DecisionModel {
    nonisolated let label = "recording"
    nonisolated var runsLocally: Bool { true }
    private(set) var offered: [[String]] = []
    func decide(_ requests: [DecisionRequest]) async throws -> [DecisionResponse] {
        for request in requests {
            if case let .choice(_, options)? = request.questions[CategoryDecisions.questionID] { offered.append(options.map(\.id)) }
        }
        return requests.map { _ in DecisionResponse(answers: [CategoryDecisions.questionID: DecisionAnswer(value: "shopping", confidence: 0.2)], model: label) }
    }
}

// MARK: - Rules

@Suite("Rules")
struct RuleTests {
    @Test("Rules saved before they had ids load as rule-1, rule-2…, credited to the assistant and on; the next rule takes the next id")
    func legacyIDs() throws {
        let legacy = [CreateBudgetRule(match: .init(merchantContains: "venmo"), categoryID: "transfer", applyToExisting: true),
                      CreateBudgetRule(match: .init(descriptorContains: "ACME PAYROLL"), categoryID: "income", applyToExisting: false)]
        guard case var .object(fields) = try JSONValue.parse(JSONEncoder().encode(LedgerState.empty)) else { Issue.record("not an object"); return }
        fields["rules"] = try JSONValue.parse(JSONEncoder().encode(legacy))
        let state = try JSONDecoder().decode(LedgerState.self, from: JSONValue.object(fields).data())
        #expect(state.rules.map(\.id) == ["rule-1", "rule-2"])
        #expect(state.rules.allSatisfy { $0.createdBy == .assistant && $0.isEnabled && $0.createdAt == nil })
        #expect(state.rules[1].match == RuleMatch(descriptorContains: "ACME PAYROLL"))
        #expect(try JSONDecoder().decode(LedgerState.self, from: JSONEncoder().encode(state)) == state)

        var ledger = Setup.ledger(state)
        _ = try ledger.perform(.createBudgetRule(CreateBudgetRule(match: .init(merchantContains: "Blue Bottle"), categoryID: "dining", applyToExisting: false)))
        #expect(ledger.rules.last?.id == "rule-3")
        #expect(ledger.rules.last?.createdBy == .person && ledger.rules.last?.createdAt == EngineFixture.now)
    }

    @Test("An account- and direction-scoped rule files a generic descriptor; text ignores case and numbers; filed rows name the rule")
    func scopedRule() async throws {
        let rules = [Setup.rule("rule-1", descriptor: "withdrawal", "transfer", direction: .moneyOut, account: "sav"),
                     Setup.rule("rule-2", descriptor: "PARAMOUNT PAYROLL 0923", "income")]
        let api = Setup.api(Setup.state(rules: rules))
        let report = try await api.ingest(Setup.snapshot([("w1", 1, -1250, "Withdrawal"), ("w2", 2, -300, "WITHDRAWAL"), ("d1", 3, 200, "Withdrawal"),
                                                          ("p1", 4, 3850, "PARAMOUNT PAYROLL 1007 PPD")]), batchID: "b1", into: "sav")
        _ = try await api.ingest(Setup.snapshot([("w3", 1, -45, "Withdrawal")]), batchID: "b2", into: "chk")
        #expect(report.byRule == 3 && report.byTransferMatch == 0)
        let rows = Dictionary(uniqueKeysWithValues: try await api.transactions(TransactionFilter()).map { ($0.id, $0) })
        for id in ["plaid:w1", "plaid:w2"] {
            #expect(rows[id]?.categorization == Categorization(categoryID: "transfer", confidence: 1, tier: .rule, needsReview: false, decidedBy: "rule:rule-1"))
            #expect(rows[id]?.categorization?.ruleID == "rule-1")
        }
        #expect(rows["plaid:p1"]?.categorization?.ruleID == "rule-2") // "0923" and "1007" don't count
        #expect(rows["plaid:d1"]?.categorization?.tier != .rule)      // money in isn't covered
        #expect(rows["plaid:w3"]?.categorization?.tier != .rule)      // another account isn't either
        let summaries = try await api.rules()
        #expect(summaries.map(\.id) == ["rule-2", "rule-1"])
        #expect(summaries.map(\.hitCount) == [1, 2])
        #expect(summaries[1].matchDescription == "Bank description contains “withdrawal” · money out · Cash Account")
    }

    @Test("Rule text ignores spaces and punctuation, so one rule catches every way a bank spells a merchant")
    func spacingAndPunctuation() async throws {
        let api = Setup.api(Setup.state(rules: [Setup.rule("rule-1", descriptor: "Google Fi", "utilities")]))
        _ = try await api.ingest(Setup.snapshot([("a", 1, -5066, "GOOGLE *FI AB12CD   G.CO/HELPPAY#       CA"),
                                                 ("b", 2, -7544, "GOOGLE*FI EF34GH GOO G.CO HELPPAY#"),
                                                 ("c", 3, -7544, "GOOGLE *FI IJ56KL    G.CO/HELPPAY#      CA"),
                                                 ("d", 4, -3900, "GOOGLE *YOUTUBE PREM G.CO/HELPPAY#")]), batchID: "b1", into: "chk")
        let rows = Dictionary(uniqueKeysWithValues: try await api.transactions(TransactionFilter()).map { ($0.id, $0) })
        for id in ["plaid:a", "plaid:b", "plaid:c"] { #expect(rows[id]?.categorization?.ruleID == "rule-1", "\(id)") }
        #expect(rows["plaid:d"]?.categorization?.ruleID == nil) // another Google product isn't Fi
    }

    @Test("The newest rule that's on wins; one that's off, or whose category was merged away, files nothing")
    func precedence() throws {
        let uber = Rows.row("u", "card", 1, -20, "UBER *TRIP", nil)
        var ledger = Setup.ledger(Setup.state(rules: [Setup.rule("rule-1", descriptor: "UBER", "transport"), Setup.rule("rule-2", descriptor: "uber", "travel")]))
        func winner() -> String? { ledger.rule(for: uber, known: Set(ledger.activeCategories.map(\.id)))?.id }
        #expect(winner() == "rule-2")
        ledger.rules[1].isEnabled = false
        #expect(winner() == "rule-1")
        ledger.rules[1].isEnabled = true
        _ = try ledger.perform(.mergeCategory(MergeCategory(from: "travel", into: "shopping")))
        #expect(ledger.rules[1].categoryID == "shopping") // the merge took the rule along
        #expect(winner() == "rule-2")
        ledger.rules[1].categoryID = "travel"              // a rule left on an archived category is dead
        #expect(winner() == "rule-1")
        #expect(ledger.ruleSummaries().first { $0.id == "rule-2" }?.isDead == true)
    }

    @Test("A rule never files money going out as income, and one that asks to is refused")
    func incomeOnlyComesIn() throws {
        var ledger = Setup.ledger(Setup.state([Rows.row("in", "chk", 1, 3850, "ACME PAYROLL", "transfer", tier: .model, review: true),
                                               Rows.row("out", "chk", 2, -50, "ACME PAYROLL", "transfer", tier: .model, review: true)]))
        let result = try ledger.perform(.createBudgetRule(CreateBudgetRule(match: .init(descriptorContains: "ACME PAYROLL"), categoryID: "income", applyToExisting: true)))
        #expect(result.affectedTransactions == 1)
        #expect(ledger.row("in")?.categorization?.categoryID == "income" && ledger.row("out")?.categorization?.categoryID == "transfer")
        #expect(throws: BudgetAPIError.rejected("Money going out is never income.")) {
            try ledger.preview(.createBudgetRule(CreateBudgetRule(match: .init(descriptorContains: "ACME", direction: .moneyOut), categoryID: "income", applyToExisting: false)))
        }
    }

    @Test("A rule's conditions are checked: something to go on, sensible text, a known account, amounts in order, a live category")
    func validation() throws {
        var ledger = Setup.ledger(Setup.state())
        _ = try ledger.perform(.mergeCategory(MergeCategory(from: "travel", into: "shopping")))
        func problem(_ match: RuleMatch, _ category: String = "dining") -> String? {
            do { _ = try ledger.preview(.createBudgetRule(CreateBudgetRule(match: match, categoryID: category, applyToExisting: false))); return nil }
            catch { return error.localizedDescription }
        }
        #expect(problem(RuleMatch(direction: .moneyOut)) == "A rule needs text to match, or an account.")
        #expect(problem(RuleMatch(merchantContains: "  ")) == "A rule needs text to match, or an account.")
        #expect(problem(RuleMatch(merchantContains: "x")) == "Keep the text to match between 2 and 60 characters.")
        #expect(problem(RuleMatch(accountID: "nope")) == "That account isn't in the ledger.")
        #expect(problem(RuleMatch(merchantContains: "Uber", minAmount: Setup.amount("-5"))) == "Amounts in a rule are sizes, so they can't be negative.")
        #expect(problem(RuleMatch(merchantContains: "Uber", minAmount: Setup.amount("50"), maxAmount: Setup.amount("10"))) == "The smallest amount is more than the largest.")
        #expect(problem(RuleMatch(merchantContains: "Uber"), "travel") == Ledger.archivedMessage(ledger.category("travel")!))
        #expect(problem(RuleMatch(merchantContains: " Uber ", minAmount: Setup.amount("10"), maxAmount: Setup.amount("50"), accountID: "card")) == nil)
        let preview = try ledger.preview(.createBudgetRule(CreateBudgetRule(match: RuleMatch(direction: .moneyOut, accountID: "sav"), categoryID: "transfer", applyToExisting: false)))
        #expect(preview.title == "Always file everything on Cash Account (money out) under Transfer")
    }

    @Test("Editing a rule re-files what it now wins; turning it off or deleting it leaves what it filed alone")
    func editAndDelete() throws {
        var ledger = Setup.ledger(Setup.state([Rows.row("u1", "card", 1, -20, "UBER *TRIP", "shopping", tier: .decisionModel),
                                               Rows.row("u2", "card", 2, -18, "UBER *TRIP", "shopping", tier: .model, review: true)]))
        let created = try ledger.perform(.createBudgetRule(CreateBudgetRule(match: .init(descriptorContains: "UBER"), categoryID: "transport", applyToExisting: true)))
        #expect(created.affectedTransactions == 2 && created.message == "Rule saved. Filed 2 transactions under Transport.")
        #expect(ledger.reviewItems.isEmpty)

        let preview = try ledger.preview(.updateBudgetRule(UpdateBudgetRule(ruleID: "rule-1", categoryID: "travel", applyToExisting: true)))
        #expect(preview.matchCount == 2 && preview.changeCount == 2 && preview.title == "Always file “UBER” under Travel")
        _ = try ledger.perform(.updateBudgetRule(UpdateBudgetRule(ruleID: "rule-1", categoryID: "travel", applyToExisting: true)))
        #expect(["u1", "u2"].allSatisfy { ledger.row($0)?.categorization == Categorization(categoryID: "travel", confidence: 1, tier: .rule, needsReview: false, decidedBy: "rule:rule-1") })

        let off = try ledger.perform(.updateBudgetRule(UpdateBudgetRule(ruleID: "rule-1", isEnabled: false)))
        #expect(off.message == "Rule turned off. The transactions it filed keep their category.")
        #expect(ledger.rule(for: ledger.row("u1")!, known: Set(ledger.activeCategories.map(\.id))) == nil)
        #expect(throws: BudgetAPIError.rejected("Turn the rule on to re-file with it.")) {
            try ledger.perform(.updateBudgetRule(UpdateBudgetRule(ruleID: "rule-1", applyToExisting: true)))
        }
        #expect(try ledger.preview(.updateBudgetRule(UpdateBudgetRule(ruleID: "rule-1", isEnabled: true))).title == "Start filing “UBER” under Travel again")

        #expect(try ledger.preview(.deleteBudgetRule(DeleteBudgetRule(ruleID: "rule-1"))).detail == "The 2 transactions it filed keep their category.")
        #expect(try ledger.perform(.deleteBudgetRule(DeleteBudgetRule(ruleID: "rule-1"))).message == "Rule deleted. The 2 transactions it filed keep their category.")
        #expect(ledger.rules.isEmpty && ledger.row("u1")?.categorization?.categoryID == "travel")
        #expect(throws: BudgetAPIError.notFound) { try ledger.perform(.deleteBudgetRule(DeleteBudgetRule(ruleID: "rule-1"))) }
    }

    @Test("The rules list: newest first, hits and matches counted, disagreements flagged both ways, off rules left out, dead rules marked")
    func summaries() throws {
        let rows = [
            Rows.row("t1", "card", 1, -30, "UBER EATS 0412", "dining", tier: .rule, decidedBy: "rule:rule-2"),
            Rows.row("t2", "card", 2, -12, "UBER *TRIP", "transport", tier: .rule, decidedBy: "rule:rule-1"),
            Rows.row("t3", "card", 3, -15, "NETFLIX.COM", "subscriptions", tier: .user),
        ]
        var state = Setup.state(rows, rules: [
            Setup.rule("rule-1", descriptor: "UBER", "transport"),
            Setup.rule("rule-2", descriptor: "UBER EATS", "dining"),        // overlaps rule-1 on t1
            Setup.rule("rule-3", descriptor: "netflix", "entertainment", on: false),
            Setup.rule("rule-4", descriptor: "NETFLIX", "subscriptions"),   // rule-3 disagrees but is off
            Setup.rule("rule-5", merchant: "Spotify", "shopping"),
            Setup.rule("rule-6", merchant: "spotify ", "entertainment"),   // same match, no rows, different category
        ])
        state.categories = state.categories.map { var c = $0; if c.id == "shopping" { c.isArchived = true }; return c }
        let list = Setup.ledger(state).ruleSummaries()
        #expect(list.map(\.id) == ["rule-6", "rule-5", "rule-4", "rule-3", "rule-2", "rule-1"])
        let byID = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        #expect(byID["rule-1"]?.conflicts == ["rule-2"] && byID["rule-2"]?.conflicts == ["rule-1"])
        #expect(byID["rule-1"]?.hitCount == 1 && byID["rule-1"]?.matchCount == 2)
        #expect(byID["rule-3"]?.conflicts == [] && byID["rule-4"]?.conflicts == [] && byID["rule-3"]?.matchCount == 1)
        #expect(byID["rule-5"]?.isDead == true && byID["rule-5"]?.conflicts == [] && byID["rule-6"]?.conflicts == []) // a dead rule disagrees with nobody
        #expect(byID["rule-4"]?.isDead == false)
    }

    @Test("Identical matches with different categories disagree even before any row matches")
    func identicalMatches() {
        let ledger = Setup.ledger(Setup.state(rules: [Setup.rule("rule-1", merchant: "Spotify", "subscriptions"),
                                                      Setup.rule("rule-2", merchant: " spotify", "entertainment")]))
        #expect(ledger.ruleSummaries().map(\.conflicts) == [["rule-1"], ["rule-2"]])
    }

    @Test("A preview shows the rows an action reaches, what would move and which rules would disagree, and changes nothing")
    func preview() async throws {
        let rows = (0..<12).map { Rows.row("u\($0)", "card", Double($0) + 1, -20, "UBER *TRIP", $0 < 3 ? "travel" : "shopping", tier: .decisionModel) }
        let api = Setup.api(Setup.state(rows, rules: [Setup.rule("rule-1", merchant: "uber", "shopping")]))
        let before = await api.state
        let preview = try await api.preview(.createBudgetRule(CreateBudgetRule(match: .init(descriptorContains: "UBER"), categoryID: "travel", applyToExisting: true)))
        #expect(preview.title == "Always file “UBER” under Travel")
        #expect(preview.matchCount == 12 && preview.changeCount == 9 && preview.conflicts == ["rule-1"])
        #expect(preview.sample.map(\.id) == (0..<ActionPreview.sampleSize).map { "u\($0)" })
        #expect(preview.detail == "12 existing transactions match; 9 move to Travel. New matches are filed automatically. It disagrees with another rule on some transactions; the newer rule wins.")
        let refile = try await api.preview(.recategorize(Recategorize(transactionIDs: ["u0", "u5"], categoryID: "travel")))
        #expect(refile.matchCount == 2 && refile.changeCount == 1 && refile.sample.map(\.id) == ["u0", "u5"])
        let edit = try await api.preview(Rows.edit(["u4", "u3"], categoryID: "transport"))
        #expect(edit.sample.map(\.id) == ["u3", "u4"] && edit.changeCount == 2)
        await #expect(throws: BudgetAPIError.rejected("Unknown category “pets”.")) {
            try await api.preview(.recategorize(Recategorize(transactionIDs: ["u0"], categoryID: "pets")))
        }
        #expect(await api.state == before)
    }

    @Test("Matched transfers and statement rows are filed with their own tiers, not as the person's rule")
    func honestProvenance() async throws {
        let api = IncomeTransferTests.api(extra: [IncomeTransferTests.row("harbor-pay", "freedom", 19, 1250, "AUTOMATIC PAYMENT - THANK", category: "income")])
        let report = try await api.ingest(try FileImport.parse(IncomeTransferTests.qfx, ids: .test), batchID: "qfx", into: "cash")
        #expect(report.byRule == 0 && report.byTransferMatch == 1 && report.byStatement == 2)
        let rows = try await api.transactions(TransactionFilter(limit: 50))
        let withdrawal = try #require(rows.first { $0.rawDescription == "Withdrawal" && $0.amount == Money(-1250) })
        #expect(withdrawal.categorization?.tier == .transferMatch && withdrawal.categorization?.tier.displayName == "Matched transfer")
        #expect(rows.first { $0.id == "harbor-pay" }?.categorization?.tier == .transferMatch)
        #expect(rows.filter { ["Interest", "Transfer"].contains($0.rawDescription) }.allSatisfy { $0.categorization?.tier == .statement })
    }

    @Test("Loading an older ledger gives transfers and statement rows their tier and traces rule-filed rows to the rule")
    func legacyProvenance() {
        let ledger = Setup.ledger(Setup.state([
            Rows.row("m", "chk", 1, -500, "ONLINE TRANSFER TO SAV", "transfer", tier: .rule, decidedBy: "Matched transfer · Cash Account"),
            Rows.row("s", "sav", 2, 61, "Interest", "income", tier: .rule, decidedBy: "From the statement"),
            Rows.row("r", "card", 3, -20, "UBER *TRIP", "transport", tier: .rule),
            Rows.row("x", "card", 4, -9, "SOMETHING ELSE", "shopping", tier: .rule),
        ], rules: [Setup.rule("rule-1", descriptor: "UBER", "transport"), Setup.rule("rule-2", descriptor: "UBER", "dining")]))
        #expect(ledger.row("m")?.categorization?.tier == .transferMatch)
        #expect(ledger.row("s")?.categorization?.tier == .statement)
        #expect(ledger.row("r")?.categorization?.decidedBy == "rule:rule-1") // the newest rule that agrees with how it was filed
        #expect(ledger.row("x")?.categorization == Categorization(categoryID: "shopping", confidence: 0.9, tier: .rule, needsReview: false))
        #expect(ledger.ruleSummaries().map(\.hitCount) == [0, 1])
        #expect(Setup.ledger(ledger.state).state == ledger.state) // a no-op the second time
    }
}

// MARK: - Categories

@Suite("Categories")
struct CategoryTests {
    @Test("Categories saved before colors and archiving decode without them; each still has a color to wear")
    func legacyDecode() throws {
        let old = #"{"id":"pets","name":"Pets","symbol":"pawprint","countsAsSpending":true,"group":"flexible"}"#
        let pets = try JSONDecoder().decode(BudgetCategory.self, from: Data(old.utf8))
        #expect(pets.color == nil && !pets.isArchived && pets.effectiveColor == .amber)
        // Budget types from before bills, subscriptions and everyday read as the nearest: fixed as Bills (Subscriptions as
        // Subscriptions), flexible and non-monthly as Everyday.
        #expect(pets.group == .everyday)
        func group(_ id: String, _ raw: String) throws -> CategoryGroup {
            try JSONDecoder().decode(BudgetCategory.self, from: Data(#"{"id":"\#(id)","name":"X","symbol":"tag","countsAsSpending":true,"group":"\#(raw)"}"#.utf8)).group
        }
        #expect(try group("housing", "fixed") == .bills && group("subscriptions", "fixed") == .subscriptions && group("health", "fixed") == .everyday)
        #expect(try group("travel", "nonMonthly") == .everyday && group("gym", "subscriptions") == .subscriptions)
        #expect(BudgetCategory(id: "health", name: "Health", symbol: "heart").effectiveColor == .rose)
        #expect(BudgetCategory(id: "health", name: "Health", symbol: "heart", color: "teal").effectiveColor == .teal)
        #expect(BudgetCategory(id: "health", name: "Health", symbol: "heart", color: "hotpink").effectiveColor == .rose)
        #expect(CategoryColor.allCases.map(\.rawValue) == ["iris", "lilac", "orchid", "azure", "cyan", "irisDeep", "amber", "coral", "rose", "teal", "lime", "violet"])
        // No two standard spending categories wear the same color.
        let spending = Ledger.categoryList.filter(\.countsAsSpending).map(\.effectiveColor)
        #expect(Set(spending).count == spending.count)
    }

    @Test("A new category gets its budget type and the color the others wear least; bad colors and icons are refused")
    func create() throws {
        var ledger = Setup.ledger(Setup.state())
        _ = try ledger.perform(.createCategory(CreateCategory(name: "Pets", symbol: "pawprint", group: .bills)))
        _ = try ledger.perform(.createCategory(CreateCategory(name: "Kids")))
        _ = try ledger.perform(.createCategory(CreateCategory(name: "Gifts", color: "teal")))
        #expect(ledger.category("pets")?.color == "iris" && ledger.category("pets")?.group == .bills)
        #expect(ledger.category("kids")?.color == "lilac" && ledger.category("kids")?.group == .everyday)
        #expect(ledger.category("gifts")?.color == "teal")
        #expect(ledger.categories.suffix(2).map(\.id) == ["income", "transfer"])
        #expect(throws: BudgetAPIError.rejected("“red” isn't one of the category colors.")) { try ledger.preview(.createCategory(CreateCategory(name: "Fun", color: "red"))) }
        #expect(throws: BudgetAPIError.rejected("“Paw Print” isn't an icon name.")) { try ledger.preview(.createCategory(CreateCategory(name: "Fun", symbol: "Paw Print"))) }
        #expect(throws: BudgetAPIError.rejected("There's already a pets category.")) { try ledger.preview(.createCategory(CreateCategory(name: "pets"))) }
        #expect(try ledger.preview(.createCategory(CreateCategory(name: "Car", group: .bills))).detail
                == "No target yet. Budgeted as bills: a usual month is set aside for it before safe to spend is worked out.")
    }

    @Test("Renaming keeps the id; Income and Transfer take only an icon and a color; a budget type change shows safe to spend before and after")
    func update() throws {
        var ledger = Setup.ledger(Setup.state([Rows.row("d", "card", 1, -40, "HARVEST TABLE", "dining", tier: .user)]))
        #expect(try ledger.perform(.updateCategory(UpdateCategory(categoryID: "dining", name: " Eating out "))).message == "Renamed Dining to Eating out.")
        #expect(ledger.category("dining")?.name == "Eating out" && ledger.row("d")?.categorization?.categoryID == "dining")
        #expect(throws: BudgetAPIError.rejected("Income keeps its name and isn't budgeted; you can change its icon and color.")) {
            try ledger.perform(.updateCategory(UpdateCategory(categoryID: "income", name: "Pay")))
        }
        _ = try ledger.perform(.updateCategory(UpdateCategory(categoryID: "income", symbol: "banknote", color: "lime")))
        #expect(ledger.category("income")?.symbol == "banknote" && ledger.category("income")?.effectiveColor == .lime)
        #expect(throws: BudgetAPIError.rejected("There's already a groceries category.")) {
            try ledger.perform(.updateCategory(UpdateCategory(categoryID: "dining", name: "groceries")))
        }
        #expect(throws: BudgetAPIError.rejected("Nothing to change.")) { try ledger.perform(.updateCategory(UpdateCategory(categoryID: "dining", name: "Eating out"))) }
        let preview = try ledger.preview(.updateCategory(UpdateCategory(categoryID: "dining", color: "coral", group: .bills)))
        #expect(preview.title == "Change Eating out's color and budget type")
        #expect(preview.effects.map(\.id) == ["safe-now", "safe-after"])
    }

    @Test("Merging moves rows (each keeping how it was filed), rules, suggestions and targets, then archives a standard category or removes one the person made")
    func merge() throws {
        var state = Setup.state([
            Rows.row("a", "card", 1, -40, "HARVEST TABLE", "dining", tier: .user),
            Rows.row("b", "card", 2, -12, "UBER EATS", "dining", tier: .rule, decidedBy: "rule:rule-1"),
            Rows.row("c", "card", 3, -9, "SQ *CAFE", "dining", tier: .decisionModel, review: true),
            Rows.row("g", "card", 4, -60, "SAFEWAY", "groceries", tier: .user),
        ], rules: [Setup.rule("rule-1", descriptor: "UBER EATS", "dining")])
        state.suggestions = ["c": [CategorySuggestion(categoryID: "dining", confidence: 0.6), CategorySuggestion(categoryID: "groceries", confidence: 0.3)]]
        state.monthlyTargets = ["dining": Money(450), "groceries": Money(650)]
        var ledger = Setup.ledger(state)
        let preview = try ledger.preview(.mergeCategory(MergeCategory(from: "dining", into: "groceries", combineTargets: true)))
        #expect(preview.detail == "Moves 3 transactions and 1 rule to Groceries. Its $450 target is added to Groceries's. Dining is archived, so it won't come back.")
        #expect(preview.matchCount == 3 && preview.effects.first?.value == Money(1100))
        let result = try ledger.perform(.mergeCategory(MergeCategory(from: "dining", into: "groceries", combineTargets: true)))
        #expect(result.message == "Merged Dining into Groceries: moved 3 transactions and 1 rule.")
        #expect(ledger.row("a")?.categorization?.tier == .user && ledger.row("b")?.categorization?.ruleID == "rule-1")
        #expect(["a", "b", "c"].allSatisfy { ledger.row($0)?.categorization?.categoryID == "groceries" })
        #expect(ledger.reviewItems.map(\.id) == ["c"] && ledger.suggestions["c"] == [CategorySuggestion(categoryID: "groceries", confidence: 0.6)])
        #expect(ledger.rules[0].categoryID == "groceries")
        #expect(ledger.monthlyTargets == ["groceries": Money(1100)])
        #expect(ledger.category("dining")?.isArchived == true && !ledger.activeCategories.contains { $0.id == "dining" })
        // Loading again keeps it archived: the standard list doesn't add it back.
        let reloaded = Setup.ledger(ledger.state)
        #expect(reloaded.categories.filter { $0.id == "dining" }.map(\.isArchived) == [true])

        _ = try ledger.perform(.createCategory(CreateCategory(name: "Pets")))
        _ = try ledger.perform(.recategorize(Recategorize(transactionIDs: ["g"], categoryID: "pets")))
        _ = try ledger.perform(.mergeCategory(MergeCategory(from: "pets", into: "shopping")))
        #expect(ledger.category("pets") == nil && ledger.row("g")?.categorization?.categoryID == "shopping")
    }

    @Test("Merging refuses mixing spending and money in, merging Income away, Transfer, a category into itself, and one already merged away")
    func mergeRefusals() throws {
        var ledger = Setup.ledger(Setup.state())
        _ = try ledger.perform(.createCategory(CreateCategory(name: "Card rewards", kind: .moneyIn)))
        func problem(_ from: String, _ into: String) -> String? {
            do { _ = try ledger.preview(.mergeCategory(MergeCategory(from: from, into: into))); return nil } catch { return error.localizedDescription }
        }
        #expect(problem("dining", "income") == "Dining is spending and Income is money in, so one can't be merged into the other.")
        #expect(problem("card-rewards", "dining") == "Card rewards is money in and Dining is spending, so one can't be merged into the other.")
        #expect(problem("income", "card-rewards") == "Income is built in, so it can't be merged away. Merge the other category into it instead.")
        #expect(problem("card-rewards", "income") == nil) // money in into money in
        #expect(problem("transfer", "dining") == "Transfer can't be merged; it counts as neither spending nor money in.")
        #expect(problem("card-rewards", "transfer") == "Transfer can't be merged; it counts as neither spending nor money in.")
        #expect(problem("dining", "dining") == "Pick a different category to merge into.")
        _ = try ledger.perform(.mergeCategory(MergeCategory(from: "travel", into: "shopping")))
        #expect(problem("travel", "dining") == Ledger.archivedMessage(ledger.category("travel")!))
        #expect(problem("dining", "travel") == Ledger.archivedMessage(ledger.category("travel")!))
    }

    @Test("Nothing new is filed under a merged-away category: re-filing, the tools, the decision model and the prompt leave it out, but its id still resolves")
    func archivedLeftOut() async throws {
        let model = RecordingDecisions()
        let api = Setup.api(Setup.state(policy: DecisionPolicy(provider: .localDecide, autoAcceptPercent: 80, kinds: [.category])),
                            decisions: DecisionRouting(local: model))
        _ = try await api.perform(.mergeCategory(MergeCategory(from: "travel", into: "shopping")))
        let categories = try await api.categories()
        #expect(categories.first { $0.id == "travel" }?.isArchived == true)

        _ = try await api.ingest(Setup.snapshot([("x", 1, -80, "RIVERSIDE HOTEL")]), batchID: "b1", into: "card")
        let offered = await model.offered
        #expect(offered.count == 1 && offered.allSatisfy { !$0.contains("travel") && $0.contains("shopping") })
        await #expect(throws: BudgetAPIError.rejected(Ledger.archivedMessage(categories.first { $0.id == "travel" }!))) {
            try await api.perform(.recategorize(Recategorize(transactionIDs: ["plaid:x"], categoryID: "travel")))
        }
        let config = try await api.assistantConfig()
        let recategorize = try #require(config.tools.first { $0.name == "recategorize" })
        #expect(!String(decoding: try recategorize.parameters.data(), as: UTF8.self).contains("\"travel\""))
        #expect(!config.systemPrompt.contains("- travel —"))
        #expect(throws: ToolArgumentError.self) {
            try AppAction(toolName: "recategorize", arguments: Data(#"{"transactionIDs":["plaid:x"],"categoryID":"travel"}"#.utf8),
                          categoryIDs: ToolCatalog.specs(for: categories).first { $0.name == "recategorize" }!.schema.properties["categoryID"]!.enumValues)
        }
    }

    @Test("Creating a category with a merged-away one's name brings it back")
    func bringBack() throws {
        var ledger = Setup.ledger(Setup.state())
        _ = try ledger.perform(.mergeCategory(MergeCategory(from: "travel", into: "shopping")))
        #expect(try ledger.preview(.createCategory(CreateCategory(name: "travel"))).title == "Bring back Travel")
        #expect(try ledger.perform(.createCategory(CreateCategory(name: "Travel", color: "violet"))).message == "Brought back Travel.")
        #expect(ledger.category("travel")?.isArchived == false && ledger.category("travel")?.color == "violet")
        #expect(ledger.categories.filter { $0.id == "travel" }.count == 1)
    }
}

// MARK: - Review settings

@Suite("Review settings")
struct ReviewSettingsTests {
    static let modelOn = DecisionPolicy(provider: .localDecide, autoAcceptPercent: 80, kinds: [.category])

    @Test("Policies saved before the review toggles decode with them off")
    func legacyDecode() throws {
        let old = #"{"provider":"localDecide","autoAcceptPercent":75,"kinds":["category"],"escalateToJev":true}"#
        let policy = try JSONDecoder().decode(DecisionPolicy.self, from: Data(old.utf8))
        #expect(policy == DecisionPolicy(provider: .localDecide, autoAcceptPercent: 75, kinds: [.category], escalateToJev: true))
        #expect(!policy.reviewNewMerchants && !policy.holdPending && policy.reviewAbove == nil)
        var toggled = policy
        (toggled.reviewNewMerchants, toggled.reviewAbove) = (true, Setup.amount("500"))
        #expect(try JSONDecoder().decode(DecisionPolicy.self, from: JSONEncoder().encode(toggled)) == toggled)
    }

    @Test("New merchants come to you when asked, however sure the model is, and even when it agrees with the bank")
    func newMerchants() async throws {
        let answers: [String: (String, Double)] = ["CASA TACO": ("dining", 0.95), "NETFLIX": ("subscriptions", 0.97), "PAYPAL": ("shopping", 0.6)]
        var policy = Self.modelOn
        let control = try await EngineFixture.api(decisions: DecisionRouting(local: StubDecisions(answers))).ingest(EngineFixture.plaidSnapshot(), batchID: "s")
        #expect(control.byModel == 4) // Casa Taco ×2, Netflix, and PayPal because it agrees with the bank
        policy.reviewNewMerchants = true
        var state = Setup.state(rules: [Setup.rule("rule-1", merchant: "venmo", "transfer")], policy: policy)
        state.accounts = []
        let api = Setup.api(state, decisions: DecisionRouting(local: StubDecisions(answers)))
        let report = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "s")
        #expect(report.byModel == 0 && report.byRule == 1 && report.needsReview == 4)
        let review = try await api.reviewQueue()
        let taco = try #require(review.first { $0.transaction.merchant == "Casa Taco" })
        #expect(taco.reason == "New merchant. You asked to check new merchants before they're filed.")
        #expect(taco.suggestions.first == CategorySuggestion(categoryID: "dining", confidence: 0.95))
        #expect(taco.transaction.categorization?.categoryID == "dining" && taco.transaction.categorization?.tier == .decisionModel)
        #expect(review.first { $0.transaction.rawDescription.hasPrefix("PAYPAL") }?.suggestions.first?.categoryID == "shopping")
    }

    @Test("Big amounts come to you when the model or memory would file them; rules, matched transfers and your answers still file on their own")
    func bigAmounts() async throws {
        var policy = Self.modelOn
        policy.reviewAbove = Setup.amount("100")
        let state = Setup.state([Rows.row("tj", "chk", 30, -45, "TRADER JOE S", "groceries", tier: .user),
                                 Rows.row("in", "sav", 1, 500, "ONLINE TRANSFER FROM CHK", "transfer", tier: .merchantMemory)],
                                rules: [Setup.rule("rule-1", descriptor: "ACME PAYROLL", "income")], policy: policy)
        let api = Setup.api(state, decisions: DecisionRouting(local: StubDecisions(["NETFLIX": ("subscriptions", 0.97)])))
        let report = try await api.ingest(Setup.snapshot([("big", 1, -150, "TRADER JOE S"), ("small", 2, -40, "TRADER JOE S"), ("nf", 3, -120, "NETFLIX.COM"),
                                                          ("pay", 4, 3850, "ACME PAYROLL"), ("out", 1, -500, "ONLINE TRANSFER TO SAV")]),
                                          batchID: "b", into: "chk")
        #expect(report.byMemory == 1 && report.byRule == 1 && report.byTransferMatch == 1 && report.byModel == 0 && report.needsReview == 2)
        let review = Dictionary(uniqueKeysWithValues: try await api.reviewQueue().map { ($0.id, $0) })
        #expect(Set(review.keys) == ["plaid:big", "plaid:nf"])
        #expect(review["plaid:big"]?.reason == "More than $100. You asked to check big amounts before they're filed.")
        #expect(review["plaid:big"]?.suggestions == [CategorySuggestion(categoryID: "groceries", confidence: 0.99)])
        #expect(review["plaid:big"]?.transaction.categorization?.tier == .merchantMemory)
        #expect(review["plaid:nf"]?.suggestions.first?.categoryID == "subscriptions")
    }

    @Test("Answering one row doesn't file other big ones waiting under the same descriptor: each is checked on its own")
    func bigAmountsOneByOne() throws {
        var ledger = Setup.ledger(Setup.state([Rows.row("a", "card", 1, -40, "AMAZON MKTP", "shopping", tier: .model, review: true),
                                               Rows.row("b", "card", 2, -30, "AMAZON MKTP", "shopping", tier: .model, review: true),
                                               Rows.row("c", "card", 3, -700, "AMAZON MKTP", "shopping", tier: .merchantMemory, review: true)]))
        ledger.decisionPolicy.reviewAbove = Setup.amount("500")
        #expect(try ledger.confirm(transactionID: "a", categoryID: "groceries").affectedTransactions == 2)
        #expect(ledger.reviewItems.map(\.id) == ["c"])
        #expect(try ledger.confirm(transactionID: "c", categoryID: "shopping").affectedTransactions == 1)
    }

    @Test("Pending charges wait out of the review queue until they post")
    func holdPending() throws {
        var ledger = Setup.ledger(Setup.state([Rows.row("p", "card", 0.2, -20, "SQ *CAFE", "dining", tier: .model, review: true, pending: true),
                                               Rows.row("q", "card", 2, -30, "SQ *DELI", "dining", tier: .model, review: true)]))
        #expect(ledger.reviewItems.count == 2)
        let result = try ledger.perform(.updateDecisionPolicy(UpdateDecisionPolicy(holdPending: true)))
        #expect(result.message == "Review settings saved.")
        #expect(ledger.reviewItems.map(\.id) == ["q"] && ledger.overview().reviewCount == 1)
        ledger.transactions[ledger.transactions.firstIndex { $0.id == "p" }!].isPending = false
        #expect(ledger.reviewItems.count == 2)
    }

    @Test("Changing the toggles: the preview says what changes, \"0\" turns the amount off, a negative one is refused, and the queue isn't re-run for them")
    func updateToggles() async throws {
        let api = Setup.api(Setup.state(policy: Self.modelOn), decisions: DecisionRouting(local: StubDecisions([:])))
        let preview = try await api.preview(.updateDecisionPolicy(UpdateDecisionPolicy(reviewNewMerchants: true, reviewAbove: Setup.amount("500"))))
        #expect(preview.title == "Change what comes to you for review")
        #expect(preview.detail == "New merchants come to you before they're filed. Anything over $500 that a rule doesn't cover comes to you.")
        _ = try await api.perform(.updateDecisionPolicy(UpdateDecisionPolicy(reviewNewMerchants: true, reviewAbove: Setup.amount("500"))))
        #expect(try await api.serverStatus().decisionPolicy.reviewAbove == Setup.amount("500"))
        _ = try await api.perform(.updateDecisionPolicy(UpdateDecisionPolicy(reviewAbove: Setup.amount("0"))))
        let policy = try await api.serverStatus().decisionPolicy
        #expect(policy.reviewAbove == nil && policy.reviewNewMerchants)
        await #expect(throws: BudgetAPIError.rejected("The amount to check above can't be negative.")) {
            try await api.perform(.updateDecisionPolicy(UpdateDecisionPolicy(reviewAbove: Setup.amount("-5"))))
        }
        await #expect(throws: BudgetAPIError.rejected("Nothing to change.")) { try await api.perform(.updateDecisionPolicy(UpdateDecisionPolicy())) }
    }

    @Test("Re-deciding the queue holds back new merchants too, with the reason why")
    func rerunHolds() async throws {
        let api = Setup.api(Setup.state(), decisions: DecisionRouting(local: StubDecisions(["CASA TACO": ("dining", 0.95)])))
        _ = try await api.ingest(Setup.snapshot([("t", 1, -20, "SQ *CASA TACO 0423")]), batchID: "b", into: "card") // model off: to review
        let result = try await api.perform(.updateDecisionPolicy(UpdateDecisionPolicy(provider: .localDecide, reviewNewMerchants: true)))
        #expect(result.affectedTransactions == 0)
        let item = try #require(try await api.reviewQueue().first)
        #expect(item.reason == "New merchant. You asked to check new merchants before they're filed.")
        #expect(item.suggestions.first?.categoryID == "dining")
    }

    @Test("Review reasons say why: money out the model called income, and a descriptor that names no merchant with no other side found")
    func honestReasons() async throws {
        let sure = IncomeTransferTests.api(DecisionRouting(local: StubDecisions(["DEPOSIT": ("income", 0.97), "WITHDRAWAL": ("income", 0.97)])))
        _ = try await sure.ingest(try FileImport.parse(IncomeTransferTests.qfx, ids: .test), batchID: "q", into: "cash")
        let held = try await sure.reviewQueue()
        #expect(held.count == 2 && held.allSatisfy { $0.reason == "The decision model called this income, but money going out is never income." })

        let off = IncomeTransferTests.api()
        _ = try await off.ingest(try FileImport.parse(IncomeTransferTests.qfx, ids: .test), batchID: "q", into: "cash")
        let reasons = Set(try await off.reviewQueue().map(\.reason))
        #expect(reasons == ["“Deposit” doesn't name a merchant, and no matching withdrawal turned up in your other accounts within 5 days.",
                            "“Withdrawal” doesn't name a merchant, and no matching deposit turned up in your other accounts within 5 days."])
    }
}

// MARK: - Merchant memory

@Suite("Merchant memory")
struct MemoryTests {
    static let rows = [
        Rows.row("t1", "card", 1, -18, "SQ *CASA TACO 0501", "dining", tier: .merchantMemory),
        Rows.row("t2", "card", 9, -23, "SQ *CASA TACO 0423", "dining", tier: .user),
        Rows.row("t3", "card", 4, -12, "SQ *CASA TACO 0610", "dining", tier: .model, review: true),
        Rows.row("n1", "card", 5, -15, "NETFLIX.COM", "subscriptions", tier: .decisionModel),
        Rows.row("u1", "card", 6, -20, "UBER *TRIP", "transport", tier: .rule, decidedBy: "rule:rule-1"),
        Rows.row("w1", "sav", 2, -1250, "Withdrawal", "transfer", tier: .user),
        Rows.row("x1", "chk", 3, -500, "ONLINE TRANSFER TO SAV", "transfer", tier: .transferMatch),
        Rows.row("h1", "card", 7, -9, "HIDDEN CAFE", "dining", tier: .user, hidden: true),
    ]

    @Test("Each remembered merchant says where its answer came from, how many rows share it and when it was last seen; the lookup is the same list")
    func entries() {
        let ledger = Setup.ledger(Setup.state(Self.rows))
        let entries = ledger.merchantMemoryEntries()
        #expect(entries.map(\.descriptor) == ["CASA TACO", "NETFLIX.COM", "UBER *TRIP"]) // most recently seen first
        let taco = entries[0]
        #expect(taco.merchant == "Sq *Casa Taco 0501" && taco.categoryID == "dining" && taco.source == .user && taco.confidence == nil)
        #expect(taco.rowCount == 3 && taco.lastSeen == EngineFixture.now.addingTimeInterval(-86_400))
        #expect(entries[1].source == .decisionModel && entries[1].confidence == 0.9)
        #expect(entries[2].source == .rule)
        #expect(ledger.merchantMemory(excluding: []) == ["CASA TACO": "dining", "NETFLIX.COM": "subscriptions", "UBER *TRIP": "transport"])
    }

    @Test("Forgetting a merchant sends its next row to be decided afresh, until the person files one of its rows again")
    func forget() async throws {
        var policy = ReviewSettingsTests.modelOn
        policy.autoAcceptPercent = 90
        let api = Setup.api(Setup.state(Self.rows, policy: policy), decisions: DecisionRouting(local: StubDecisions(["CASA TACO": ("shopping", 0.4)])))
        let preview = try await api.preview(.forgetMerchant(ForgetMerchant(descriptor: "SQ *CASA TACO 0423")))
        #expect(preview.title == "Forget Sq *Casa Taco 0501" && preview.matchCount == 3)
        #expect(try await api.perform(.forgetMerchant(ForgetMerchant(descriptor: "CASA TACO"))).message
                == "Forgot Sq *Casa Taco 0501. Past transactions keep their category.")
        #expect(try await api.rememberedMerchants().map(\.descriptor) == ["NETFLIX.COM", "UBER *TRIP"])
        #expect(await api.state.forgottenMerchants == ["CASA TACO"])
        await #expect(throws: BudgetAPIError.rejected("Budget hasn't learned anything from “CASA TACO”.")) {
            try await api.perform(.forgetMerchant(ForgetMerchant(descriptor: "CASA TACO")))
        }

        let report = try await api.ingest(Setup.snapshot([("new", 0, -21, "SQ *CASA TACO 0701")]), batchID: "b", into: "card")
        #expect(report.byMemory == 0 && report.modelCalls == 1 && report.needsReview == 1)
        _ = try await api.confirmCategory(transactionID: "plaid:new", categoryID: "dining")
        #expect(await api.state.forgottenMerchants.isEmpty)
        #expect(try await api.rememberedMerchants().first?.descriptor == "CASA TACO")
    }
}
