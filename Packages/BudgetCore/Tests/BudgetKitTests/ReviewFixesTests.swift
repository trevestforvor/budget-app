import Foundation
import Testing
@testable import BudgetKit

/// Regressions for the Origin-parity review: one spending rule everywhere, the income guard on re-runs, rule ids,
/// re-filing that spares the person's answers, undo, review grouping and the months without history.
enum Small {
    static let calendar = Fixture.calendar
    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))! }

    static func row(_ id: String, _ account: String = "chk", at: Date, _ amount: Decimal, category: String = "dining", raw: String? = nil,
                    tier: CategorizationTier = .merchantMemory, needsReview: Bool = false, pending: Bool = false) -> LedgerTransaction {
        LedgerTransaction(id: id, accountID: account, postedAt: at, merchant: "M \(id)", rawDescription: raw ?? "MERCHANT \(id.uppercased())",
                          amount: Money(amount), categorization: Categorization(categoryID: category, confidence: 0.99, tier: tier, needsReview: needsReview),
                          isPending: pending, source: .plaid)
    }

    static let accounts = [Account(id: "chk", name: "Checking", institution: "Bank", kind: .checking, balance: Money(5000), source: .plaid),
                           Account(id: "card", name: "Card", institution: "Bank", kind: .credit, balance: Money(-500), source: .plaid)]

    static func ledger(_ rows: [LedgerTransaction], now: Date = date(2026, 9, 25)) -> Ledger {
        var state = LedgerState.empty
        state.accounts = accounts
        state.transactions = rows
        return Ledger(state: state, now: now, calendar: calendar)
    }
}

@Suite("Review fixes: money math")
struct MoneyMathFixTests {
    @Test("A category that took in more than it spent adds nothing, and every total agrees")
    func netRefundCategoryReconciles() throws {
        let ledger = Small.ledger([
            Small.row("a", at: Small.date(2026, 9, 10), -100, category: "dining"),
            Small.row("b", at: Small.date(2026, 9, 12), 30, category: "shopping"), // a return of last month's purchase
            Small.row("c", at: Small.date(2026, 8, 12), -80, category: "shopping"),
            Small.row("i", at: Small.date(2026, 9, 1), 3000, category: "income"),
        ])
        let summary = ledger.spendingSummary(.thisMonth)
        let budget = try ledger.budgetMonth(nil)
        let expected = Money(100)
        #expect(summary.total == expected)
        #expect(summary.categories.map(\.spent).sum() == expected)
        #expect(budget.groups.map(\.spent).sum() == expected)
        #expect(ledger.overview().monthSpent == expected)
        #expect(ledger.summary(TransactionFilter(period: "this_month")).spent == expected)
        #expect(ledger.cashFlowHistory(months: 1).last?.spending == expected)
        #expect(budget.flex.flexSpent == expected)
    }

    @Test("The week's figure nets a refund against its charge, as safe to spend does")
    func weekNetsRefunds() {
        let ledger = Small.ledger([
            Small.row("a", at: Small.date(2026, 9, 21), -50, category: "dining"),
            Small.row("b", at: Small.date(2026, 9, 22), 50, category: "dining"),
        ])
        let overview = ledger.overview()
        let days = try! #require(overview.lastSevenDays)
        #expect(overview.lastSevenDaysSpent == ledger.everydaySpent(from: days[0].date, to: ledger.now))
        #expect(overview.lastSevenDaysSpent == .zero)
        #expect(days.map(\.flexibleSpent).sum() == Money(50)) // each bar is its own day
    }

    @Test("The assistant's query totals are the Activity summary's")
    func queryTotals() throws {
        let ledger = Small.ledger([Small.row("a", "card", at: Small.date(2026, 9, 1), -100), Small.row("b", "card", at: Small.date(2026, 9, 5), 40)])
        let (result, figures) = DemoToolbox(ledger: ledger, decisions: nil)
            .queryTransactions(search: nil, categoryID: "dining", needsReviewOnly: false, since: "2026-09-01", until: nil, limit: 50)
        guard case let .object(o) = result, case let .string(spent)? = o["spent"] else { Issue.record("shape"); return }
        #expect(spent == Money(60).display)
        #expect(figures.first?.value == Money(60))
    }
}

@Suite("Review fixes: months")
struct MonthFixTests {
    @Test("A finished month is compared with the whole month before it")
    func finishedMonthAgainstWholeMonth() throws {
        let ledger = Small.ledger([
            Small.row("s1", at: Small.date(2026, 9, 5), -100),
            Small.row("o1", at: Small.date(2026, 10, 5), -100),
            Small.row("o2", at: Small.date(2026, 10, 31, 18), -500),
            Small.row("n1", at: Small.date(2026, 11, 5), -300),
        ], now: Small.date(2026, 12, 10))
        let november = try ledger.budgetMonth("2026-11")
        #expect(november.summary.contains("50% below October"))
    }

    @Test("Without the whole month before it, a finished month makes no comparison")
    func noComparisonAgainstAPartialMonth() throws {
        let ledger = Small.ledger([Small.row("j", at: Small.date(2027, 1, 30), -300), Small.row("f", at: Small.date(2027, 2, 10), -300)],
                                  now: Small.date(2027, 3, 5))
        #expect(!(try ledger.budgetMonth("2027-02").summary.contains("January")))
    }

    @Test("The first months of a ledger say they have no history to budget from")
    func earlyMonthsHaveNoBudget() throws {
        let ledger = Fixture.ledger()
        let first = try #require(ledger.recentMonths(12).first)
        let early = try ledger.budgetMonth(first.key)
        #expect(early.hasFullHistory == false)
        #expect(!early.summary.contains("flexible budget"))
        #expect(!early.summary.contains("past its budget"))
        #expect(try ledger.budgetMonth(nil).hasFullHistory == true)
    }
}

@Suite("Review fixes: decisions and review")
struct DecisionFixTests {
    struct IncomeModel: DecisionModel {
        var label: String { "stub" }
        var runsLocally: Bool { true }
        func decide(_ requests: [DecisionRequest]) async throws -> [DecisionResponse] {
            requests.map { _ in DecisionResponse(answers: [CategoryDecisions.questionID: DecisionAnswer(value: "income", confidence: 0.97)], model: "stub") }
        }
    }

    @Test("Re-running the model on the queue never files money going out as income")
    func rerunKeepsIncomeGuard() async throws {
        var state = LedgerState.empty
        state.accounts = Small.accounts
        state.transactions = [Small.row("a", at: Small.date(2026, 9, 20), -45, category: "transfer", raw: "VENMO *J PARK", tier: .model, needsReview: true),
                              Small.row("b", at: Small.date(2026, 9, 21), 45, category: "transfer", raw: "VENMO *J PARK", tier: .model, needsReview: true)]
        let api = LedgerBudgetAPI(state: state, calendar: Small.calendar, clock: { Small.date(2026, 9, 25) }, chatModel: nil,
                                  decisions: DecisionRouting(local: IncomeModel()), persistence: nil,
                                  deployment: DeploymentInfo(endpoint: "x", version: "x", sources: [], institutions: []))
        _ = try await api.perform(.updateDecisionPolicy(UpdateDecisionPolicy(provider: .localDecide, autoAcceptPercent: 80)))
        let rows = await api.state.transactions
        let out = try #require(rows.first { $0.id == "a" }?.categorization)
        #expect(out.categoryID == "transfer" && out.needsReview)
        // Money coming in under the same descriptor is its own question, and income is fine there.
        let into = try #require(rows.first { $0.id == "b" }?.categorization)
        #expect(into.categoryID == "income" && !into.needsReview)
    }

    @Test("applyDecisions itself holds an income answer for money going out")
    func applyDecisionsGuard() {
        var ledger = Small.ledger([Small.row("a", at: Small.date(2026, 9, 20), -45, category: "transfer", raw: "VENMO *J PARK", tier: .model, needsReview: true)])
        ledger.decisionPolicy = DecisionPolicy(provider: .localDecide, autoAcceptPercent: 80, kinds: [.category])
        let outcome = ledger.applyDecisions([("a", DecisionAnswer(value: "income", confidence: 0.97), "stub")], agreed: ["a": "income"])
        #expect(outcome.accepted == 0 && outcome.pending == 1)
        #expect(ledger.transactions[0].categorization?.categoryID == "transfer")
        #expect(ledger.suggestions["a"]?.contains { $0.categoryID == "income" } == false)
    }

    @Test("With pending held back, the needs-review filter and counts match the queue")
    func holdPendingCounts() throws {
        var ledger = Small.ledger([
            Small.row("a", "card", at: Small.date(2026, 9, 24), -20, raw: "NEW PLACE", tier: .decisionModel, needsReview: true, pending: true),
            Small.row("b", "card", at: Small.date(2026, 9, 20), -30, raw: "OTHER PLACE", tier: .decisionModel, needsReview: true),
        ])
        _ = try ledger.perform(.updateDecisionPolicy(UpdateDecisionPolicy(holdPending: true)))
        #expect(ledger.reviewItems.map(\.id) == ["b"])
        #expect(ledger.matching(TransactionFilter(needsReviewOnly: true)).map(\.id) == ["b"])
        #expect(ledger.summary(TransactionFilter()).needsReviewCount == 1)
        #expect(ledger.overview().reviewCount == 1)
    }

    @Test("Review groups split code-only descriptors by merchant and answer big amounts on their own")
    func groupingMatchesTheDashboard() throws {
        var ledger = Small.ledger([
            { var r = Small.row("1", "card", at: Small.date(2026, 9, 24), -64, category: "shopping", raw: "PAYPAL *XJ29QK", tier: .model, needsReview: true); r.merchant = "PayPal"; return r }(),
            { var r = Small.row("2", "card", at: Small.date(2026, 9, 23), -6.5, category: "shopping", raw: "SQ *80123", tier: .model, needsReview: true); r.merchant = "Sq *80123"; return r }(),
            Small.row("3", "card", at: Small.date(2026, 9, 22), -900, category: "shopping", raw: "BESTBUY 00123", tier: .model, needsReview: true),
            Small.row("4", "card", at: Small.date(2026, 9, 21), -1200, category: "shopping", raw: "BESTBUY 00456", tier: .model, needsReview: true),
        ])
        #expect(ReviewGroup.groups(ledger.reviewItems).count == 3) // PayPal, Square, and the two Best Buys together
        _ = try ledger.perform(.updateDecisionPolicy(UpdateDecisionPolicy(reviewAbove: DecimalAmount(minorUnits: 50_000))))
        let groups = ReviewGroup.groups(ledger.reviewItems)
        #expect(groups.count == 4)
        #expect(groups.filter(\.isLarge).map(\.transactionIDs) == [["4"], ["3"]])
        #expect(ledger.overview().reviewDecisions == 4)
        // A group whose descriptor names no merchant never makes a rule with no text.
        let paypal = try #require(groups.first { $0.merchant == "PayPal" })
        #expect(paypal.scopedRule == RuleMatch(descriptorContains: "PAYPAL *XJ29QK", direction: .moneyOut, accountID: "card"))
        let bestBuy = try #require(groups.first { $0.transactionIDs == ["3"] })
        #expect(bestBuy.scopedRule == RuleMatch(descriptorContains: "BESTBUY", direction: .moneyOut))
    }

    @Test("Undo forgets a merchant again after filing one of its rows")
    func undoRestoresForgotten() throws {
        var ledger = Small.ledger([
            Small.row("a", at: Small.date(2026, 9, 1), -20, raw: "OLIVE GRILL MAIN"),
            Small.row("b", at: Small.date(2026, 9, 5), -20, raw: "OLIVE GRILL MAIN"),
            Small.row("c", at: Small.date(2026, 9, 20), -20, category: "shopping", raw: "OLIVE GRILL MAIN", tier: .decisionModel, needsReview: true),
        ])
        _ = try ledger.perform(.forgetMerchant(ForgetMerchant(descriptor: "OLIVE GRILL MAIN")))
        let edit = try ledger.perform(.editTransactions(EditTransactions(transactionIDs: ["c"], categoryID: "groceries")))
        #expect(ledger.forgottenMerchants.isEmpty)
        _ = try ledger.perform(try #require(edit.undo))
        #expect(ledger.forgottenMerchants == ["OLIVE GRILL MAIN"])
        #expect(ledger.merchantMemory(excluding: [])["OLIVE GRILL MAIN"] == nil)
    }
}

@Suite("Review fixes: rules and categories")
struct RuleFixTests {
    @Test("A deleted rule's id is never handed to a new rule")
    func ruleIDsNeverReused() throws {
        var ledger = Small.ledger([Small.row("a", at: Small.date(2026, 9, 1), -20, category: "transport", raw: "UBER TRIP")])
        _ = try ledger.perform(.createBudgetRule(CreateBudgetRule(match: RuleMatch(descriptorContains: "UBER"), categoryID: "transport", applyToExisting: true)))
        let uber = try #require(ledger.rules.last)
        #expect(ledger.transactions[0].categorization?.ruleID == uber.id)
        _ = try ledger.perform(.deleteBudgetRule(DeleteBudgetRule(ruleID: uber.id)))
        _ = try ledger.perform(.createBudgetRule(CreateBudgetRule(match: RuleMatch(descriptorContains: "NETFLIX"), categoryID: "subscriptions", applyToExisting: false)))
        let netflix = try #require(ledger.rules.last)
        #expect(netflix.id != uber.id)
        #expect(ledger.ruleSummaries().first { $0.id == netflix.id }?.hitCount == 0)
    }

    @Test("Re-filing with a rule leaves the person's own answers, and the preview says so")
    func refileSparesYourAnswers() throws {
        var ledger = Small.ledger([
            Small.row("a", at: Small.date(2026, 9, 1), -60, category: "groceries", raw: "AMAZON MKTP US", tier: .user),
            Small.row("b", at: Small.date(2026, 9, 5), -20, category: "dining", raw: "AMAZON MKTP US"),
        ])
        let action = AppAction.createBudgetRule(CreateBudgetRule(match: RuleMatch(descriptorContains: "AMAZON"), categoryID: "shopping", applyToExisting: true))
        let preview = try ledger.preview(action)
        #expect(preview.changeCount == 1)
        #expect(preview.detail?.contains("The 1 you filed yourself keeps its category.") == true)
        let result = try ledger.perform(action)
        #expect(result.affectedTransactions == 1)
        #expect(ledger.transactions.first { $0.id == "a" }?.categorization?.categoryID == "groceries")
        #expect(ledger.transactions.first { $0.id == "a" }?.categorization?.tier == .user)
    }

    @Test("The rule preview counts rows it takes out of review, as saving does")
    func previewCountsWaitingRows() throws {
        var ledger = Small.ledger([
            Small.row("a", at: Small.date(2026, 9, 1), -60, category: "shopping", raw: "AMAZON MKTP US", tier: .decisionModel, needsReview: true),
            Small.row("b", at: Small.date(2026, 9, 5), -20, category: "shopping", raw: "AMAZON MKTP US", tier: .decisionModel, needsReview: true),
        ])
        let action = AppAction.createBudgetRule(CreateBudgetRule(match: RuleMatch(descriptorContains: "AMAZON"), categoryID: "shopping", applyToExisting: true))
        let preview = try ledger.preview(action)
        let result = try ledger.perform(action)
        #expect(preview.changeCount == result.affectedTransactions)
        #expect(preview.detail?.contains("2 waiting for review get filed under Shopping") == true)
    }

    @Test("Merging across budget types shows what it does to safe to spend")
    func mergePreviewShowsSafeToSpend() throws {
        var ledger = Fixture.ledger()
        // Groceries (everyday) into Utilities (bills): its spending leaves safe to spend for the usual month of bills.
        let action = AppAction.mergeCategory(MergeCategory(from: "groceries", into: "utilities"))
        let preview = try ledger.preview(action)
        let after = try #require(preview.effects.first { $0.id == "safe-after" })
        _ = try ledger.perform(action)
        #expect(after.value == ledger.flexBudget().safeToSpend)
        #expect(preview.effects.first { $0.id == "safe-now" }?.value != after.value)
    }

    @Test("An undo made before a merge files its rows where the merged category went")
    func undoAfterMerge() throws {
        var ledger = Small.ledger([Small.row("a", at: Small.date(2026, 9, 10), -200, category: "travel"),
                                   Small.row("b", at: Small.date(2026, 9, 11), -50, category: "travel")])
        let edit = try ledger.perform(.editTransactions(EditTransactions(transactionIDs: ["a"], categoryID: "shopping")))
        _ = try ledger.perform(.mergeCategory(MergeCategory(from: "travel", into: "dining")))
        _ = try ledger.perform(try #require(edit.undo))
        #expect(ledger.transactions.first { $0.id == "a" }?.categorization?.categoryID == "dining")
        #expect(try ledger.budgetMonth(nil).groups.flatMap(\.categories).allSatisfy { !$0.category.isArchived })
    }

    @Test("Rule text names the account the way the app does")
    func accountLabels() {
        var ledger = Small.ledger([])
        ledger.accounts[0].mask = "3321"
        #expect(ledger.describe(RuleMatch(descriptorContains: "WITHDRAWAL", direction: .moneyOut, accountID: "chk"))
                == "Bank description contains “WITHDRAWAL” · money out · Checking ••3321")
    }
}

@Suite("Review fixes: duplicates")
struct DuplicateFixTests {
    @Test("When both sides of a paired move are file copies, the synced rows pair with each other")
    func sweepKeepsPairs() {
        func r(_ id: String, _ account: String, _ amount: Decimal, raw: String, source: SourceKind, peer: String?) -> LedgerTransaction {
            LedgerTransaction(id: id, accountID: account, postedAt: Small.date(2026, 9, 3), merchant: raw.capitalized, rawDescription: raw, amount: Money(amount),
                              categorization: Categorization(categoryID: "transfer", confidence: 1, tier: source == .fileImport ? .transferMatch : .model, needsReview: false),
                              isPending: false, source: source, transferPeerID: peer)
        }
        var state = LedgerState.empty
        state.accounts = [Account(id: "chk", name: "Checking", institution: "Bank", kind: .checking, balance: Money(5000), source: .plaid),
                          Account(id: "sav", name: "Savings", institution: "Bank", kind: .savings, balance: Money(5000), source: .plaid)]
        state.transactions = [r("fileA", "chk", -500, raw: "ONLINE TRANSFER TO SAV", source: .fileImport, peer: "fileB"),
                              r("fileB", "sav", 500, raw: "ONLINE TRANSFER FROM CHK", source: .fileImport, peer: "fileA"),
                              r("synA", "chk", -500, raw: "ONLINE TRANSFER TO SAV", source: .plaid, peer: nil),
                              r("synB", "sav", 500, raw: "ONLINE TRANSFER FROM CHK", source: .plaid, peer: nil)]
        var ledger = Ledger(state: state, now: Small.date(2026, 9, 25), calendar: Small.calendar)
        #expect(ledger.removeDuplicates(ledger.crossSourceDuplicates()) == 2)
        #expect(ledger.transactions.first { $0.id == "synA" }?.transferPeerID == "synB")
        #expect(ledger.transactions.first { $0.id == "synB" }?.transferPeerID == "synA")
    }
}

@Suite("Review fixes: Ask handoffs")
struct AskHandoffTests {
    /// Every question an "Ask about this" button or a checkup suggestion sends.
    static var prompts: [String] {
        let ledger = Fixture.ledger()
        let fromLedger = ledger.insights().compactMap(\.askPrompt) + ledger.checkup().sections.flatMap(\.findings).compactMap(\.suggestion)
        return fromLedger + [
            "Am I on track with safe to spend this month?", "Where did my flexible spending go in the last 7 days?",
            "How has my cash flow changed over the last six months?", "How has my dining spending changed over the last year?",
            "How much is safe to spend for the rest of September?", "How did my flexible spending go in August?",
            "Which of my subscriptions could I cancel?", "Where should the extra cash in checking go?",
            "How can I keep transport under its target this month?", "What's driving my cash down?",
            "What savings amount fits my last three months?", "How long would it take to build six months of essentials?",
            "Suggest targets for dining and transport from my last three months.", "Set aside $500 a month",
        ]
    }

    @Test("Every handoff gets an answer, not the fallback, and its tool calls validate")
    func handoffsAnswer() async throws {
        let api = Fixture.api()
        for prompt in Self.prompts {
            let reply = try await api.ask(prompt, conversationID: nil)
            #expect(!DemoAskEngine.isFallback(reply), "\(prompt) → \(reply.text)")
            for call in reply.toolCalls {
                #expect(throws: Never.self, "\(call.name) \(call.arguments)") {
                    try ToolCatalog.validateArguments(tool: call.name, json: Data(call.arguments.utf8), categoryIDs: DemoLedger.categoryList.map(\.id))
                }
            }
        }
    }

    @Test("Subscriptions come to one figure on every screen")
    func subscriptionsAgree() async throws {
        let ledger = Fixture.ledger()
        let monthly = ledger.subscriptions().subscriptionsMonthly.formatted(fractionDigits: 0)
        let insight = try #require(ledger.insights().first { $0.id == "subscriptions" })
        #expect(insight.title.hasPrefix(monthly))
        let reply = try await Fixture.api().ask("Which of my subscriptions could I cancel?", conversationID: nil)
        #expect(reply.text.contains(ledger.subscriptions().subscriptionsMonthly.formatted()))
        #expect(reply.text.contains("Peak Fitness"))
    }

    @Test("Days left count today, everywhere")
    func daysLeftAgree() throws {
        let ledger = Fixture.ledger()
        let flex = ledger.flexBudget()
        let metric = ledger.monthFindings().flatMap(\.metrics).first { $0.label == "Days left" }
        #expect(metric?.text == "\(flex.daysLeftIncludingToday)")
        #expect(flex.daysLeftIncludingToday == 6) // Sep 25 through Sep 30
    }
}

@Suite("Review fixes: compatibility")
struct CompatibilityFixTests {
    @Test("A tier from a later version loads as a model's guess instead of failing the ledger")
    func unknownTierDecodes() throws {
        let json = #"{"categoryID":"dining","confidence":0.9,"tier":"somethingNewer","needsReview":false}"#
        let decoded = try JSONDecoder().decode(Categorization.self, from: Data(json.utf8))
        #expect(decoded.tier == .model)
        #expect(try JSONDecoder().decode(Categorization.self, from: Data(#"{"categoryID":"dining","confidence":1,"tier":"transferMatch","needsReview":false}"#.utf8)).tier == .transferMatch)
    }

    @Test("Every institution link carries a priority, which apps before 0.2.0 need")
    func linksKeepPriority() {
        let links = Fixture.ledger().institutionLinks([InstitutionLink(id: "x", institution: "Harbor", primary: .plaid, fallback: nil, accountKinds: [], status: .connected, note: "")])
        #expect(!links.isEmpty && links.allSatisfy { $0.priority != nil })
    }

    @Test("Server versions compare number by number")
    func versions() {
        #expect(ServerStatus.version("0.2.0", isAtLeast: "0.2.0"))
        #expect(ServerStatus.version("0.10.0", isAtLeast: "0.2.0"))
        #expect(!ServerStatus.version("0.1.0", isAtLeast: "0.2.0"))
        #expect(!ServerStatus.version("garbage", isAtLeast: "0.2.0"))
    }
}
