import Foundation
import Testing
@testable import BudgetKit

/// A ledger built from a few accounts and rows, at the fixture's clock.
enum MonthFixture {
    static let calendar = Fixture.calendar
    static let now = Fixture.now
    static func day(_ back: Double) -> Date { now.addingTimeInterval(-back * 86_400) }

    static func row(_ id: String, _ account: String, daysAgo: Double, _ amount: Decimal, category: String = "dining", source: SourceKind = .plaid) -> LedgerTransaction {
        LedgerTransaction(id: id, accountID: account, postedAt: day(daysAgo), merchant: "Merchant \(id)", rawDescription: "MERCHANT \(id)",
                          amount: Money(amount), categorization: Categorization(categoryID: category, confidence: 0.99, tier: .merchantMemory, needsReview: false),
                          isPending: false, source: source)
    }

    static func ledger(accounts: [Account], rows: [LedgerTransaction], now: Date = now) -> Ledger {
        var state = LedgerState.empty
        state.accounts = accounts
        state.transactions = rows
        return Ledger(state: state, now: now, calendar: calendar)
    }
}

@Suite("Overview: attention, balances, the last seven days")
struct OverviewAdditionsTests {
    @Test("Balances add up by kind, and the old month target is no longer sent")
    func balances() throws {
        let ledger = Fixture.ledger()
        let overview = ledger.overview()
        let b = try #require(overview.balances)
        #expect(b.cash == overview.cashOnHand)
        let cards = ledger.accounts.filter { $0.kind == .credit }.map(\.balance).sum()
        #expect(b.cardsOwed == -cards && b.cardsOwed.minorUnits > 0)
        #expect(b.investments == Money(32_418.77) + Money(48_210.10) + Money(6_852.40))
        #expect(b.netWorth == b.cash - b.cardsOwed + b.investments)
        #expect(b.cashAfterCards == b.cash - b.cardsOwed)
        #expect(overview.monthTarget == nil && overview.leftToBudget == nil)
    }

    @Test("Seven days of everyday spending, today last, by the same rules as safe to spend")
    func lastSevenDays() throws {
        let ledger = Fixture.ledger()
        let days = try #require(ledger.overview().lastSevenDays)
        let today = Fixture.calendar.startOfDay(for: Fixture.now)
        #expect(days.count == 7)
        #expect(days.last?.date == today)
        #expect(days.first?.date == Fixture.calendar.date(byAdding: .day, value: -6, to: today))
        #expect(days.map(\.flexibleSpent).sum() == ledger.everydaySpent(from: days[0].date, to: Fixture.now))
        // Days inside this month are part of the month's everyday spending.
        let month = ledger.interval(for: .thisMonth)
        #expect(days.filter { $0.date >= month.start }.map(\.flexibleSpent).sum() <= ledger.flexBudget().flexSpent)
        #expect(days.contains { $0.flexibleSpent.minorUnits > 0 })
    }

    @Test("Per day left spreads safe to spend over the rest of the month, today included, and is zero once it's gone")
    func perDayLeft() throws {
        var ledger = Fixture.ledger()
        let flex = ledger.flexBudget()
        #expect(flex.daysLeft == 5)  // September 25th
        #expect(flex.perDayLeft == Money(minorUnits: flex.safeToSpend.minorUnits / 6))
        _ = try ledger.perform(.setMonthlySavings(SetMonthlySavings(monthlyAmount: DecimalAmount(string: "20000")!)))
        #expect(ledger.flexBudget().safeToSpend.isNegative)
        #expect(ledger.flexBudget().perDayLeft == .zero)
    }

    @Test("Every insight carries a question for Ask")
    func askPrompts() {
        let insights = Fixture.ledger().insights()
        #expect(!insights.isEmpty)
        #expect(insights.allSatisfy { !($0.askPrompt ?? "").isEmpty })
    }

    @Test("Idle cash: checking well past a month and a half of essentials, and quiet when it isn't")
    func idleCash() throws {
        let ledger = Fixture.ledger()
        let essentials = ledger.capacity().essentialMonthly
        let checking = ledger.balance(of: "chk", through: Fixture.now)
        // The demo's checking runs well past its cushion.
        let insight = try #require(ledger.insights().first { $0.id == "idle-cash" })
        #expect(insight.kind == .savings)
        #expect(insight.title.contains((checking - Money(minorUnits: essentials.minorUnits * 3 / 2)).formatted(fractionDigits: 0)))
        // Emptying checking into savings leaves nothing idle.
        var state = ledger.state
        state.openingBalances["chk"] = (state.openingBalances["chk"] ?? .zero) - checking
        #expect(!Ledger(state: state, now: Fixture.now, calendar: Fixture.calendar).insights().contains { $0.id == "idle-cash" })
    }
}

@Suite("Data health")
struct DataHealthTests {
    static let accounts = [
        Account(id: "chk", name: "Total Checking", institution: "Harbor", kind: .checking, balance: Money(900), source: .plaid),
        Account(id: "sav", name: "Cash Account", institution: "Meadow", kind: .savings, balance: Money(5000), source: .plaid),
        Account(id: "card", name: "Gold Card", institution: "Summit Card", kind: .credit, balance: Money(-300), source: .plaid),
        Account(id: "keystone", name: "Keystone Card", institution: "Keystone", kind: .credit, balance: Money(-80), source: .fileImport),
        Account(id: "inv", name: "Brokerage", institution: "Northwind Brokerage", kind: .investment, balance: Money(9000), source: .plaid),
    ]

    static func rows() -> [LedgerTransaction] {
        var rows: [LedgerTransaction] = []
        // Checking: every other day until 20 days ago — overdue by its own rhythm (max(10, 3 × 2) days).
        for i in 0..<30 { rows.append(MonthFixture.row("c\(i)", "chk", daysAgo: 20 + Double(i) * 2, -12)) }
        // Savings: once a month, last 25 days ago — fine (3 × ~30 days).
        for i in 0..<5 { rows.append(MonthFixture.row("s\(i)", "sav", daysAgo: 25 + Double(i) * 30, 500, category: "transfer")) }
        // Card: daily until yesterday.
        for i in 1...40 { rows.append(MonthFixture.row("a\(i)", "card", daysAgo: Double(i), -20)) }
        // A statement account whose newest statement ends 40 days ago.
        for i in 0..<10 { rows.append(MonthFixture.row("b\(i)", "keystone", daysAgo: 40 + Double(i) * 3, -30, source: .fileImport)) }
        return rows
    }

    @Test("Stale accounts by their own rhythm, investments left out, statement accounts told to import")
    func stale() {
        let ledger = MonthFixture.ledger(accounts: Self.accounts, rows: Self.rows())
        let health = ledger.dataHealth(institutions: [])
        #expect(health.map(\.id) == ["stale-chk", "stale-keystone"])
        #expect(health.allSatisfy { $0.kind == .stale })
        let keystone = health.first { $0.accountID == "keystone" }!
        #expect(keystone.institution == "Keystone")
        #expect(keystone.title.hasPrefix("Nothing new from Keystone Card since "))  // not "Keystone Keystone Card"
        #expect(health.first { $0.accountID == "chk" }!.title.hasPrefix("Nothing new from Harbor Total Checking since "))
        #expect(keystone.detail.contains("Import a newer one"))
        #expect(health.first { $0.accountID == "chk" }!.detail.contains("still connected"))
    }

    @Test("A connection to sign in to again comes first and speaks for its institution's quiet accounts")
    func reauthFirst() {
        let ledger = MonthFixture.ledger(accounts: Self.accounts, rows: Self.rows())
        let chase = InstitutionLink(id: "plaid-1", institution: "harbor", primary: .plaid, fallback: nil, accountKinds: [], status: .needsReauth, note: "")
        let health = ledger.dataHealth(institutions: [chase])
        #expect(health.map(\.id) == ["reauth-plaid-1", "stale-keystone"])
        #expect(health[0].kind == .needsReauth)
        // Home and the checkup say the same thing.
        let overview = ledger.overview(institutions: [chase])
        #expect(overview.attention == health)
        let data = ledger.checkup(institutions: [chase]).sections.first { $0.id == "data" }!
        #expect(data.findings.first { $0.id == "reauth-plaid-1" }?.status == .act)
        #expect(data.findings.first { $0.id == "stale-keystone" }?.status == .watch)
        #expect(data.findings.first { $0.id == "stale-keystone" }?.title == health[1].title)
    }

    @Test("A statement-only account isn't stale until its next statement is overdue")
    func statementCycle() {
        let accounts = [Account(id: "keystone", name: "Keystone Card", institution: "Keystone", kind: .credit, balance: Money(-80), source: .fileImport)]
        func health(newestDaysAgo: Double) -> [String] {
            let rows = (0..<10).map { MonthFixture.row("b\($0)", "keystone", daysAgo: newestDaysAgo + Double($0) * 3, -30, source: .fileImport) }
            return MonthFixture.ledger(accounts: accounts, rows: rows).dataHealth(institutions: []).map(\.id)
        }
        #expect(health(newestDaysAgo: 20).isEmpty, "a statement from three weeks ago is the newest there can be")
        #expect(health(newestDaysAgo: 37).isEmpty)
        #expect(health(newestDaysAgo: 40) == ["stale-keystone"], "a month's statement plus a week has passed")
    }

    @Test("A card with nothing on it at a bank that's syncing is unused, not stale; with a balance, or a quiet link, it still counts")
    func unusedCard() {
        let accounts = [Account(id: "united", name: "United Explorer", institution: "Harbor", kind: .credit, balance: .zero, source: .plaid),
                        Account(id: "owed", name: "Freedom", institution: "Harbor", kind: .credit, balance: Money(-240), source: .plaid)]
        let rows = (0..<6).flatMap { i in
            [MonthFixture.row("u\(i)", "united", daysAgo: 100 + Double(i) * 20, -50),
             MonthFixture.row("u\(i)r", "united", daysAgo: 100 + Double(i) * 20, 50, category: "transfer"),
             MonthFixture.row("f\(i)", "owed", daysAgo: 100 + Double(i) * 20, -40)]
        }
        let ledger = MonthFixture.ledger(accounts: accounts, rows: rows)
        func chase(syncedDaysAgo: Double?, error: String? = nil) -> InstitutionLink {
            var link = InstitutionLink(id: "plaid-1", institution: "Harbor", primary: .plaid, fallback: nil, accountKinds: [], status: .connected, note: "")
            link.lastSync = syncedDaysAgo.map { MonthFixture.now.addingTimeInterval(-$0 * 86_400) }
            link.lastError = error
            return link
        }
        #expect(ledger.dataHealth(institutions: [chase(syncedDaysAgo: 0.1)]).map(\.id) == ["stale-owed"], "the unused card isn't flagged; the one with a balance is")
        #expect(ledger.dataHealth(institutions: [chase(syncedDaysAgo: 9)]).map(\.id) == ["stale-united", "stale-owed"], "a link not heard from lately proves nothing")
        #expect(ledger.dataHealth(institutions: [chase(syncedDaysAgo: 0.1, error: "timeout")]).map(\.id) == ["stale-united", "stale-owed"])
        #expect(ledger.dataHealth(institutions: []).map(\.id) == ["stale-united", "stale-owed"])
    }

    @Test("An empty ledger is one item; the demo has Tidewater waiting for a sign-in, and its recent Keystone statement is fine")
    func emptyAndDemo() {
        let empty = Ledger(state: .empty, now: Fixture.now, calendar: Fixture.calendar)
        #expect(empty.dataHealth(institutions: []).map(\.kind) == [.emptyLedger])
        #expect(empty.overview().attention?.first?.id == "no-data")
        #expect(Fixture.ledger().dataHealth(institutions: Ledger.institutionPlan).map(\.id) == ["reauth-tidewater"])
    }
}

@Suite("Institutions and sync")
struct InstitutionTests {
    @Test("Links hold their accounts and how far they reach; statement-only institutions are listed after them")
    func institutions() async throws {
        let accounts = [
            Account(id: "chk", name: "Total Checking", institution: "Harbor", kind: .checking, balance: Money(900), source: .plaid),
            Account(id: "old", name: "Old Checking", institution: "Harbor", kind: .checking, balance: Money(10), source: .fileImport),
            Account(id: "keystone", name: "Keystone Card", institution: "Keystone", kind: .credit, balance: Money(-80), source: .fileImport),
        ]
        var state = LedgerState.empty
        state.accounts = accounts
        state.transactions = [MonthFixture.row("1", "chk", daysAgo: 1, -5), MonthFixture.row("2", "chk", daysAgo: 3, -5),
                              MonthFixture.row("3", "keystone", daysAgo: 12, -30, source: .fileImport)]
        let api = LedgerBudgetAPI(state: state, calendar: Fixture.calendar, clock: { Fixture.now }, chatModel: nil, decisions: DecisionRouting(),
                                  persistence: nil, deployment: DeploymentInfo(endpoint: "t", version: "t", sources: [.plaid], institutions: []))
        let synced = MonthFixture.day(0.5)
        await api.setInstitutions([InstitutionLink(id: "plaid-1", institution: "Harbor", primary: .plaid, fallback: nil, accountKinds: [],
                                                   status: .connected, note: "", lastSync: synced)])
        await api.setDashboardURL("https://dash.example")
        let status = try await api.serverStatus()
        #expect(status.institutions.map(\.id) == ["plaid-1", "statements-harbor", "statements-keystone"])
        let harbor = status.institutions[0]
        #expect(harbor.accountIDs == ["chk"] && harbor.accountKinds == [.checking])
        #expect(harbor.coversThrough == MonthFixture.day(1))
        #expect(harbor.priority == .core) // for apps before 0.2.0
        #expect(status.institutions[1].accountIDs == ["old"])
        let keystone = status.institutions[2]
        #expect(keystone.primary == .fileImport && keystone.status == .connected && keystone.lastSync == nil)
        #expect(keystone.accountIDs == ["keystone"] && keystone.coversThrough == MonthFixture.day(12))
        #expect(status.lastSync == synced)
        #expect(status.dashboardURL == "https://dash.example")
        // Real links sync through the server's SyncService; the ledger's own sync never pretends to.
        #expect(try await api.syncNow().isEmpty)
        #expect(try await api.serverStatus().lastSync == synced)
    }

    @Test("Last sync is the newest link's, not the clock; the demo's sync reports its connected institutions")
    func demoSync() async throws {
        let api = Fixture.api()
        let before = try await api.serverStatus()
        #expect(before.lastSync == Fixture.now.addingTimeInterval(-2 * 3600))
        let results = try await api.syncNow()
        #expect(results.map(\.institution) == Ledger.institutionPlan
            .filter { $0.status == .demo && $0.id != LedgerBudgetAPI.demoExpiredLinkID }.map(\.institution))
        #expect(results.allSatisfy { $0.ok && $0.report?.rowsAdded == 0 })
        #expect(try await api.serverStatus().lastSync == Fixture.now)
    }

    @Test("Institutions from older servers decode: a priority on every link, none of the new fields")
    func legacyInstitution() throws {
        let old = #"{"id":"plaid-1","institution":"Harbor","priority":"core","primary":"plaid","accountKinds":[],"status":"needsReauth","note":"Last sync failed"}"#
        let link = try RemoteBudgetAPI.decoder.decode(InstitutionLink.self, from: Data(old.utf8))
        #expect(link.priority == .core && link.lastSync == nil && link.accountIDs == nil)
        let new = #"{"id":"plaid-1","institution":"Harbor","primary":"plaid","accountKinds":[],"status":"connected","note":"","lastError":"Plaid: expired"}"#
        let current = try RemoteBudgetAPI.decoder.decode(InstitutionLink.self, from: Data(new.utf8))
        #expect(current.priority == nil && current.lastError == "Plaid: expired")
    }
}

@Suite("Budget month")
struct BudgetMonthTests {
    @Test("This month: the flex budget, groups that reconcile with it, and the checkup's sentences")
    func current() async throws {
        let api = Fixture.api()
        let ledger = Fixture.ledger()
        let month = try await api.budget(month: nil)
        let flex = try await api.overview().flex
        #expect(month.month == "2026-09" && month.isCurrent)
        #expect(month.flex == flex)
        #expect(month.groups.map(\.group) == [.bills, .subscriptions, .everyday])
        let bills = month.groups[0], subscriptions = month.groups[1], everyday = month.groups[2]
        #expect(everyday.planned == flex.flexNumber && everyday.spent == flex.flexSpent)
        #expect(bills.planned == flex.bills && subscriptions.planned == flex.subscriptions)
        let window = ledger.interval(for: .thisMonth)
        // Nothing in the demo is spread over the year, so the buckets add up to the month's spending.
        #expect(ledger.yearlyIDs.isEmpty)
        #expect(month.groups.map(\.spent).sum() == ledger.spent(from: window.start, to: window.end))
        #expect(everyday.categories.allSatisfy { $0.category.group == .everyday })
        #expect(everyday.categories.contains { $0.category.id == "dining" && $0.target == Money(450) })
        // The demo's streaming charges are on the recurring list, so they're subscriptions.
        #expect(subscriptions.categories.contains { $0.category.id == "subscriptions" })
        // Groceries 650 + dining 450 + transport 250 + shopping 300 + health 250 are the everyday targets.
        #expect(month.unallocatedFlex == flex.flexNumber - Money(1900))
        #expect(month.everythingElseSpent == everyday.categories.filter { $0.target == nil }.map(\.spent).sum())
        #expect(month.stillToCome == Money(minorUnits: max(0, (flex.bills + flex.subscriptions - bills.spent - subscriptions.spent).minorUnits)))
        #expect(month.summary == ledger.monthFindings().map(\.title).joined(separator: " "))
        #expect(month.summary.contains("safe to spend") || month.summary.contains("past this month's room"))
        #expect(try await api.budget(month: "2026-09") == month)
    }

    @Test("A past month is worked out as of its end: its own spending, the three months before it, no days left")
    func past() async throws {
        let ledger = Fixture.ledger()
        let august = try ledger.budgetMonth("2026-08")
        let start = Fixture.calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let end = Fixture.calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        #expect(!august.isCurrent && august.month == "2026-08")
        #expect(august.flex.daysLeft == 0 && august.flex.perDayLeft == nil)
        #expect(august.flex.flexSpent == ledger.budgetSpent(.everyday, from: start, to: end))
        #expect(august.groups.map(\.spent).sum() == ledger.spent(from: start, to: end))
        #expect(august.stillToCome == .zero)
        // Its flex budget averages May through July.
        var asOfAugust = ledger
        asOfAugust.now = end.addingTimeInterval(-1)
        #expect(august.flex.averageIncome == asOfAugust.capacity().income)
        #expect(august.flex.expectedIncome == asOfAugust.expectedIncome(average: asOfAugust.capacity().income).amount)
        #expect(august.flex.expectedIncome <= asOfAugust.capacity().income)
        #expect(august.summary.contains("Spending came in") && august.summary.contains("July"))
        #expect(august.summary.contains("of the everyday budget was left") || august.summary.contains("past its budget"))
    }

    @Test("Months that haven't started or aren't months are refused")
    func refused() {
        let ledger = Fixture.ledger()
        #expect(throws: BudgetAPIError.rejected("October 2026 hasn't started yet.")) { try ledger.budgetMonth("2026-10") }
        #expect(throws: BudgetAPIError.rejected("A month is written like 2026-09.")) { try ledger.budgetMonth("2026-13") }
        #expect(throws: BudgetAPIError.rejected("A month is written like 2026-09.")) { try ledger.budgetMonth("September") }
    }

    @Test("The same point last month never runs past its end, so the 31st compares whole months")
    func samePointCapped() throws {
        let calendar = Fixture.calendar
        let march31 = calendar.date(from: DateComponents(year: 2026, month: 3, day: 31, hour: 20))!
        func row(_ id: String, _ month: Int, _ day: Int, _ amount: Decimal) -> LedgerTransaction {
            LedgerTransaction(id: id, accountID: "card", postedAt: calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!,
                              merchant: id, rawDescription: id, amount: Money(amount),
                              categorization: Categorization(categoryID: "dining", confidence: 1, tier: .user, needsReview: false),
                              isPending: false, source: .plaid)
        }
        let accounts = [Account(id: "card", name: "Card", institution: "Summit", kind: .credit, balance: .zero, source: .plaid)]
        let ledger = MonthFixture.ledger(accounts: accounts, rows: [row("feb", 2, 10, -100), row("mar2", 3, 2, -40), row("mar20", 3, 20, -60)], now: march31)
        let pace = try #require(ledger.monthPace())
        #expect(pace.before == Money(100))  // February only, not March 1–3
        #expect(pace.soFar == Money(100) && pace.change == 0)
        #expect(ledger.previousInterval(for: .thisMonth)!.end == ledger.startOfMonth)
    }
}

@Suite("Category history and cash flow")
struct HistoryTests {
    @Test("A category's months, oldest first, against today's target, averaged over the months the ledger fully covers")
    func categoryHistory() async throws {
        let api = Fixture.api()
        let ledger = Fixture.ledger()
        let history = try await api.categoryHistory(id: "dining", months: 12)
        // The fixtures start on March 29, so March is the first month listed and the first one left out of the average.
        #expect(history.months.map(\.month) == ["2026-03", "2026-04", "2026-05", "2026-06", "2026-07", "2026-08", "2026-09"])
        #expect(history.months.allSatisfy { $0.target == Money(450) })
        #expect(history.monthsAveraged == 5)
        let averaged = history.months.dropFirst().dropLast().map(\.spent)
        #expect(history.averageMonthly == Ledger.average(Array(averaged)))
        let window = ledger.interval(for: .thisMonth)
        #expect(history.months.last?.spent == ledger.spent(from: window.start, to: window.end, categoryID: "dining"))
        #expect(try await api.categoryHistory(id: "dining", months: 3).months.map(\.month) == ["2026-07", "2026-08", "2026-09"])
        #expect(try await api.categoryHistory(id: "travel", months: 12).months.allSatisfy { $0.target == nil })
    }

    @Test("Unknown categories are not found; income and transfers have no spending history")
    func refused() async {
        let api = Fixture.api()
        await #expect(throws: BudgetAPIError.notFound) { try await api.categoryHistory(id: "pets", months: 12) }
        await #expect(throws: BudgetAPIError.rejected("Income isn't spending, so it has no spending history.")) {
            try await api.categoryHistory(id: "income", months: 12)
        }
    }

    @Test("Cash flow: six complete months and this one, and the last three average to exactly what a typical month can save")
    func cashFlow() async throws {
        let api = Fixture.api()
        let ledger = Fixture.ledger()
        let plan = try await api.savingsPlan()
        let history = try #require(plan.history)
        #expect(history.map(\.month) == ["2026-03", "2026-04", "2026-05", "2026-06", "2026-07", "2026-08", "2026-09"])
        #expect(history.map(\.isPartial) == [false, false, false, false, false, false, true])
        #expect(history.allSatisfy { $0.net == $0.income - $0.spending })
        let lastThree = history.dropLast().suffix(3).map(\.net)
        #expect(Ledger.average(Array(lastThree)) == plan.canSaveTypical)
        #expect(plan.averageCashChange == ledger.averageCashChange)
        // The projection runs at income less spending, the same three months (nothing in the fixture is spread).
        #expect(ledger.spendingNets(count: 3).reversed() == Array(lastThree)) // newest first
        let august = history[5]
        let start = Fixture.calendar.date(from: DateComponents(year: 2026, month: 8, day: 1))!
        let end = Fixture.calendar.date(from: DateComponents(year: 2026, month: 9, day: 1))!
        #expect(august.income == ledger.income(from: start, to: end))
        #expect(august.spending == ledger.spent(from: start, to: end))
    }

    @Test("An empty ledger's history is just this month")
    func empty() throws {
        let ledger = Ledger(state: .empty, now: Fixture.now, calendar: Fixture.calendar)
        #expect(ledger.cashFlowHistory().map(\.month) == ["2026-09"])
        #expect(try ledger.categoryHistory("dining", months: 12).monthsAveraged == 0)
    }
}

@Suite("Recurring and navigation")
struct RecurringNavigationTests {
    @Test("Due in the next 30 days: each expected charge in the window, weekly ones each week, a late one once")
    func dueNext30Days() async throws {
        let found = try await Fixture.api().subscriptions()
        let active = found.items.filter { $0.status == .active }
        #expect(found.dueNext30Days == Ledger.due(active, from: Fixture.now, days: 30))
        #expect((found.dueNext30Days ?? .zero) >= active.filter { $0.nextExpected <= Fixture.now.addingTimeInterval(30 * 86_400) }.map(\.amount).sum())

        func charge(_ cadence: Subscription.Cadence, next: Date, amount: Decimal) -> Subscription {
            Subscription(merchant: "\(cadence)", kind: .subscription, cadence: cadence, status: .active, amount: Money(amount), previousAmount: nil,
                         monthlyCost: Money(amount), yearlyCost: Money(amount), lastCharged: next, nextExpected: next, charges: 4, categoryID: nil, accountName: nil)
        }
        let now = Fixture.now
        let weekly = charge(.weekly, next: now.addingTimeInterval(2 * 86_400), amount: 10)       // days 2, 9, 16, 23, 30
        let late = charge(.monthly, next: now.addingTimeInterval(-3 * 86_400), amount: 15)       // due now, then day ~27
        let yearly = charge(.yearly, next: now.addingTimeInterval(60 * 86_400), amount: 99)      // outside the window
        #expect(Ledger.due([weekly], from: now, days: 30) == Money(50))
        #expect(Ledger.due([late], from: now, days: 30) == Money(30))
        #expect(Ledger.due([yearly], from: now, days: 30) == .zero)
    }

    @Test("Navigate takes a budget month and the recurring screen, and the schema checks them")
    func navigate() throws {
        let recurring = try AppAction(toolName: "navigate", arguments: Data(#"{"screen":"recurring"}"#.utf8))
        #expect(recurring == .navigate(Navigate(screen: .recurring)))
        let month = try AppAction(toolName: "navigate", arguments: Data(#"{"screen":"spending","month":"2026-08"}"#.utf8))
        #expect(month == .navigate(Navigate(screen: .spending, month: "2026-08")))
        #expect(throws: ToolArgumentError.self) { try AppAction(toolName: "navigate", arguments: Data(#"{"screen":"spending","month":"2026-13"}"#.utf8)) }
        let wire = try RemoteBudgetAPI.encoder.encode(AppAction.navigate(Navigate(screen: .spending, month: "2026-08")))
        #expect(try RemoteBudgetAPI.decoder.decode(AppAction.self, from: wire) == month)
        #expect(try Fixture.ledger().preview(month).title == "Open Spending · August 2026")
    }

    @Test("The demo's Ask opens the recurring charges")
    func demoOpensRecurring() async throws {
        let reply = try await Fixture.api().ask("Open my recurring charges", conversationID: nil)
        #expect(reply.proposedActions.map(\.action) == [.navigate(Navigate(screen: .recurring))])
        #expect(reply.proposedActions.first?.title == "Open Recurring")
    }
}

@Suite("Month payloads on the wire")
struct MonthWireTests {
    /// Encodes `value`, drops `keys` at the top level (or inside `nested`), and decodes it back — what an older payload looks like.
    static func withoutKeys<T: Codable>(_ value: T, _ keys: [String], nested: String? = nil) throws -> T {
        var object = try #require(try JSONSerialization.jsonObject(with: RemoteBudgetAPI.encoder.encode(value)) as? [String: Any])
        if let nested, var inner = object[nested] as? [String: Any] {
            for key in keys { inner[key] = nil }
            object[nested] = inner
        } else {
            for key in keys { object[key] = nil }
        }
        return try RemoteBudgetAPI.decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test("Payloads from before these fields decode, and the new ones round-trip")
    func legacy() async throws {
        let api = Fixture.api()
        let overview = try await api.overview()
        let old = try Self.withoutKeys(overview, ["attention", "balances", "lastSevenDays"])
        #expect(old.attention == nil && old.balances == nil && old.lastSevenDays == nil && old.cashOnHand == overview.cashOnHand)
        #expect(try Self.withoutKeys(overview, ["perDayLeft"], nested: "flex").flex.perDayLeft == nil)
        let plan = try await api.savingsPlan()
        #expect(try Self.withoutKeys(plan, ["history", "averageCashChange"]).history == nil)
        let subs = try await api.subscriptions()
        #expect(try Self.withoutKeys(subs, ["dueNext30Days"]).dueNext30Days == nil)
        let status = try await api.serverStatus()
        #expect(try Self.withoutKeys(status, ["dashboardURL"]).dashboardURL == nil)
        #expect(try Self.withoutKeys(overview.insights[0], ["askPrompt"]).askPrompt == nil)
        let month = try await api.budget(month: nil)
        #expect(try RemoteBudgetAPI.decoder.decode(BudgetMonth.self, from: RemoteBudgetAPI.encoder.encode(month)) == month)
        let history = try await api.categoryHistory(id: "dining", months: 12)
        #expect(try RemoteBudgetAPI.decoder.decode(CategoryHistory.self, from: RemoteBudgetAPI.encoder.encode(history)) == history)
    }

    @Test("Offline, the budget month and a category's history come from the last good copy; a sync never does")
    func offline() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "budget-cache-\(UUID().uuidString)")
        let cache = ResponseCache(directory: dir)
        let live = CachingBudgetAPI(upstream: Fixture.api(), cache: cache)
        let month = try await live.budget(month: nil)
        let history = try await live.categoryHistory(id: "dining", months: 12)
        let offline = CachingBudgetAPI(upstream: CacheTests.Down(), cache: cache)
        #expect(try await offline.budget(month: nil) == month)
        #expect(try await offline.categoryHistory(id: "dining", months: 12) == history)
        await #expect(throws: BudgetAPIError.unreachable) { try await offline.budget(month: "2026-08") }
        await #expect(throws: BudgetAPIError.unreachable) { try await offline.syncNow() }
    }
}
