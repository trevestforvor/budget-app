import Foundation
import Testing
@testable import BudgetKit

/// The monthly recap: a finished month's income, spending per bucket against its budget, the categories that moved,
/// and what changed in cash.
@Suite("Monthly recap")
struct MonthlyRecapTests {
    static func on(_ month: Int, _ day: Int) -> Double {
        let date = Fixture.calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
        return EngineFixture.now.timeIntervalSince(date) / 86_400
    }

    /// Now is 25 Sep 2026; the recap is of August, against July.
    static func rows() -> [LedgerTransaction] {
        [
            Rows.row("first", "card", on(6, 20), -10, "SAFEWAY", "groceries"),
            Rows.row("jul-pay", "chk", on(7, 15), 3000, "ACME PAYROLL", "income"),
            Rows.row("jul-dinner", "card", on(7, 10), -100, "HARVEST TABLE", "dining"),
            Rows.row("jul-food", "card", on(7, 12), -200, "SAFEWAY", "groceries"),
            Rows.row("aug-pay", "chk", on(8, 15), 3000, "ACME PAYROLL", "income"),
            Rows.row("aug-out", "chk", on(8, 3), -500, "TRANSFER TO SAVINGS", "transfer", peer: "aug-in"),
            Rows.row("aug-in", "sav", on(8, 3), 500, "TRANSFER FROM CHECKING", "transfer", peer: "aug-out"),
            Rows.row("aug-dinner", "card", on(8, 10), -250, "HARVEST TABLE", "dining"),
            Rows.row("aug-refund", "card", on(8, 20), 30, "HARVEST TABLE", "dining"),
            Rows.row("aug-food", "card", on(8, 12), -190, "SAFEWAY", "groceries"),
            Rows.row("aug-cab", "card", on(8, 14), -40, "CITY CAB", "travel"),
            // Hidden: out of every total.
            Rows.row("aug-hidden", "card", on(8, 18), -999, "UNIQLO", "shopping", hidden: true),
            Rows.row("sep-dinner", "card", on(9, 5), -70, "HARVEST TABLE", "dining"),
        ]
    }

    @Test("Last month by default: income and spending as cash flow counts them, the categories that moved, cash change")
    func lastMonth() throws {
        let recap = try Rows.ledger(Self.rows()).monthlyRecap(nil)
        #expect(recap.month == "2026-08")
        #expect(recap.income == Money(3000))
        // Dining net of its refund, groceries, the cab; the hidden row left out.
        #expect(recap.spending == Money(450))
        #expect(recap.saved == Money(2550))
        #expect(recap.movedToSavings == Money(500))
        // Pay in; the move to savings stays within cash.
        #expect(recap.cashChange == Money(3000))
        #expect(recap.netWorthChange == nil)
        // Groceries moved only $10, under the floor.
        #expect(recap.categoryChanges.map(\.categoryID) == ["dining", "travel"])
        #expect(recap.categoryChanges[0].change == Money(120) && recap.categoryChanges[0].previous == Money(100))
        // The ledger starts in June, so August's budget doesn't rest on three full months: spending only, no plans.
        #expect(!recap.hasBudget)
        #expect(recap.buckets.map(\.group) == [.bills, .subscriptions, .everyday])
        #expect(recap.buckets.allSatisfy { $0.planned == nil })
        #expect(recap.buckets.first { $0.group == .everyday }?.spent == Money(450))
        #expect(recap.summary == "You kept $2,550 of the $3,000 that came in during August. Dining was up $120 on the month before.")
        // News until the 8th: on the 25th it's not.
        #expect(recap.showsUntil == Fixture.calendar.date(from: DateComponents(year: 2026, month: 9, day: 8)))
        #expect(!recap.isFresh)
    }

    @Test("Shown in the first week of the month, for last month only")
    func freshness() throws {
        var ledger = Rows.ledger(Self.rows())
        ledger.now = Fixture.calendar.date(from: DateComponents(year: 2026, month: 9, day: 3, hour: 9))!
        #expect(try ledger.monthlyRecap(nil).isFresh)
        let july = try ledger.monthlyRecap("2026-07")
        #expect(july.showsUntil == nil && !july.isFresh)
        // The ledger doesn't hold all of June, so July has nothing to compare against.
        #expect(july.categoryChanges.isEmpty)
    }

    @Test("A net-worth change, when there's a history, rides along")
    func netWorthSeam() throws {
        #expect(try Rows.ledger(Self.rows()).monthlyRecap(nil, netWorthChange: Money(4100)).netWorthChange == Money(4100))
    }

    @Test("Net worth from the history: every account's rows in the month, cards included; nil with no history at hand")
    func netWorthFromHistory() throws {
        let ledger = Rows.ledger(Self.rows())
        // Pay in (+3,000), the move to savings nets out, and the card's August rows (hidden ones still move the
        // balance): −250 + 30 − 190 − 40 − 999 = −1,449.
        #expect(try ledger.monthlyRecap(nil, snapshots: []).netWorthChange == Money(1551))
        #expect(try ledger.monthlyRecap(nil, snapshots: []).cashChange == Money(3000))
        // No history store: the cash figure stands alone.
        #expect(try ledger.monthlyRecap(nil, snapshots: nil).netWorthChange == nil)
        // The ledger starts in June: July has the day before it (30 June), May's end it hasn't.
        #expect(try ledger.monthlyRecap("2026-07", snapshots: []).netWorthChange != nil)
    }

    @Test("An investment with no balance recorded by the month's start leaves net worth out (a guess isn't shown)")
    func netWorthEstimated() throws {
        var state = Rows.state(Self.rows())
        state.accounts.append(Account(id: "inv", name: "Brokerage", institution: "Northwind", kind: .investment, balance: Money(20_000), source: .plaid))
        state.openingBalances["inv"] = Money(20_000)
        let ledger = Ledger(state: state, now: EngineFixture.now, calendar: Fixture.calendar)
        #expect(try ledger.monthlyRecap(nil, snapshots: []).netWorthChange == nil)
        // Recorded on both ends: the investment's move counts.
        let recorded = [BalanceSnapshot(accountID: "inv", day: "2026-07-31", balance: Money(19_000)),
                        BalanceSnapshot(accountID: "inv", day: "2026-08-31", balance: Money(19_500))]
        #expect(try ledger.monthlyRecap(nil, snapshots: recorded).netWorthChange == Money(1551 + 500))
    }

    @Test("The demo API's recap reads its recorded balances; Ask says net worth then")
    func demoNetWorth() async throws {
        let recap = try await Fixture.api().monthlyRecap(month: nil)
        let change = try #require(recap.netWorthChange)
        #expect(change != recap.cashChange)
        let reply = try await Fixture.api().ask("How did last month go?", conversationID: nil)
        #expect(reply.text.contains("Net worth"))
        #expect(reply.figures.contains { $0.id == "recap-networth" && $0.value == change })
    }

    @Test("Only a finished month the ledger holds")
    func refusals() {
        let ledger = Rows.ledger(Self.rows())
        #expect(throws: BudgetAPIError.rejected("September isn't over yet, so there's no recap of it.")) { try ledger.monthlyRecap("2026-09") }
        #expect(throws: BudgetAPIError.rejected("A month is written like 2026-09.")) { try ledger.monthlyRecap("August") }
        #expect(throws: BudgetAPIError.rejected("The ledger starts after May 2026, so there's no recap of it.")) { try ledger.monthlyRecap("2026-05") }
        #expect(throws: BudgetAPIError.rejected("There's nothing in the ledger yet, so there's no recap of August.")) {
            try Rows.ledger([]).monthlyRecap(nil)
        }
    }

    @Test("Spending ran past income: said so")
    func overspent() {
        let summary = Ledger.recapSummary(name: "August", flow: .init(income: Money(1000), spending: Money(1250)),
                                          buckets: [RecapBucket(group: .everyday, spent: Money(900), planned: Money(800))], changes: [])
        #expect(summary == "Spending ran $250 past what came in during August. Everyday spending went $100 over its budget.")
    }

    @Test("The demo's August agrees with cash flow and the budget month, to the cent")
    func demo() async throws {
        let ledger = Fixture.ledger()
        let recap = try await Fixture.api().monthlyRecap(month: nil)
        let flow = try #require(ledger.cashFlowHistory(months: 6).first { $0.month == "2026-08" })
        #expect(recap.month == "2026-08" && recap.hasBudget)
        #expect(recap.income == flow.income && recap.spending == flow.spending && recap.saved == flow.net)
        let budget = try ledger.budgetMonth("2026-08")
        #expect(recap.buckets.map(\.spent) == budget.groups.map(\.spent))
        #expect(recap.buckets.map(\.planned) == budget.groups.map { Optional($0.planned) })
        #expect(recap.categoryChanges.count <= 3)
        #expect(recap.categoryChanges.map(\.change.magnitude) == recap.categoryChanges.map(\.change.magnitude).sorted(by: >))
        #expect(!recap.summary.isEmpty)
    }

    @Test("Ask: last month's recap is one monthlyRecap call, grounded in its figures", arguments: [
        "How did last month go?", "Give me a recap of August",
    ])
    func ask(question: String) async throws {
        let reply = try await Fixture.api().ask(question, conversationID: nil)
        #expect(reply.toolCalls.map(\.name) == ["monthlyRecap"])
        for call in reply.toolCalls {
            #expect(throws: Never.self) { try ToolCatalog.validateArguments(tool: call.name, json: Data(call.arguments.utf8)) }
        }
        #expect(Grounding.ungroundedAmounts(in: reply.text, allowed: reply.figures.map(\.value)).isEmpty, "\(reply.text)")
    }
}
