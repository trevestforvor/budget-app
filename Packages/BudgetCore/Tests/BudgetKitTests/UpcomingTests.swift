import Foundation
import Testing
@testable import BudgetKit

/// Ledgers with paychecks on given days (6 a.m. in the fixture's time zone), on the `Rows` accounts.
enum PayRows {
    static func day(_ month: Int, _ day: Int, hour: Int = 6) -> Date {
        Fixture.calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    static func pay(_ month: Int, _ d: Int, _ amount: Decimal = 2000, merchant: String = "Bright Labs") -> LedgerTransaction {
        LedgerTransaction(id: "pay-\(month)-\(d)", accountID: "chk", postedAt: day(month, d), merchant: merchant, rawDescription: "\(merchant.uppercased()) PAYROLL",
                          amount: Money(amount), categorization: Categorization(categoryID: "income", confidence: 1, tier: .rule, needsReview: false),
                          isPending: false, source: .plaid)
    }

    static func ledger(_ rows: [LedgerTransaction], now: Date = Fixture.now, cardBills: [CardBill] = []) -> Ledger {
        var state = Rows.state(rows)
        state.cardBills = Dictionary(uniqueKeysWithValues: cardBills.map { ($0.accountID, $0) })
        return Ledger(state: state, now: now, calendar: Fixture.calendar)
    }

    static func days(_ items: [UpcomingItem], _ ledger: Ledger) -> [String] { items.map { ledger.dayKey($0.date) } }
}

@Suite("Upcoming income")
struct UpcomingIncomeTests {
    @Test("Every two weeks: the next paydays keep the 14-day step, at the typical recent paycheck")
    func biweekly() throws {
        // Fridays from Jun 12 through Sep 18, 2026; one paycheck with overtime.
        let fridays = [(6, 12), (6, 26), (7, 10), (7, 24), (8, 7), (8, 21), (9, 4), (9, 18)]
        let rows = fridays.map { PayRows.pay($0.0, $0.1, $0 == (9, 4) ? 2100 : 2000) }
        let ledger = PayRows.ledger(rows)
        let upcoming = ledger.upcoming(days: 30)
        let income = upcoming.items.filter { $0.kind == .income }
        #expect(PayRows.days(income, ledger) == ["2026-10-02", "2026-10-16"])
        #expect(income.allSatisfy { $0.amount == Money(2000) && $0.title == "Bright Labs" && $0.isEstimate })
        #expect(upcoming.payCadence == "every 2 weeks")
        #expect(upcoming.nextPaycheck?.id == income.first?.id)
        #expect(upcoming.totals.income == Money(4000))
    }

    @Test("Twice a month: each payday's usual day of the month, a weekend one on the Friday before")
    func semimonthly() throws {
        // The 15th and the last day; Aug 15, 2026 was a Saturday, so it came on the 14th.
        let days = [(6, 15), (6, 30), (7, 15), (7, 31), (8, 14), (8, 31), (9, 15)]
        let ledger = PayRows.ledger(days.map { PayRows.pay($0.0, $0.1) })
        let upcoming = ledger.upcoming(days: 40)
        // Sep 30 (the month has 30 days), Oct 15, and Oct 31 is a Saturday, so Oct 30.
        #expect(PayRows.days(upcoming.items.filter { $0.kind == .income }, ledger) == ["2026-09-30", "2026-10-15", "2026-10-30"])
        #expect(upcoming.payCadence == "twice a month")
    }

    @Test("Monthly: the usual day, Sunday's on the Friday before")
    func monthly() throws {
        // Aug 1, 2026 was a Saturday: paid Jul 31.
        let ledger = PayRows.ledger([PayRows.pay(6, 1, 4100), PayRows.pay(7, 1, 4100), PayRows.pay(7, 31, 4100), PayRows.pay(9, 1, 4100)])
        let upcoming = ledger.upcoming(days: 45)
        // Nov 1, 2026 is a Sunday.
        #expect(PayRows.days(upcoming.items.filter { $0.kind == .income }, ledger) == ["2026-10-01", "2026-10-30"])
        #expect(upcoming.payCadence == "every month")
        #expect(upcoming.nextPaycheck?.amount == Money(4100))
    }

    @Test("A payday that hasn't come in shows on today, marked late; one a week late is left out")
    func late() throws {
        let fridays = [(6, 26), (7, 10), (7, 24), (8, 7), (8, 21), (9, 4)]
        let rows = fridays.map { PayRows.pay($0.0, $0.1) }
        let sunday = PayRows.day(9, 20, hour: 12)
        let soon = PayRows.ledger(rows, now: sunday).upcoming(days: 14)
        let first = try #require(soon.items.first { $0.kind == .income })
        #expect(first.isLate == true)
        #expect(first.date == Fixture.calendar.startOfDay(for: sunday))
        #expect(first.id == "income-2026-09-18")

        let later = PayRows.ledger(rows, now: Fixture.now)
        #expect(PayRows.days(later.upcoming(days: 14).items.filter { $0.kind == .income }, later) == ["2026-10-02"])
    }

    @Test("Split deposits and a one-off bonus: the payday is the sum, the bonus isn't a payday")
    func splitAndBonus() throws {
        var rows = [(6, 15), (6, 30), (7, 15), (7, 31), (8, 14), (8, 31), (9, 15)].map { PayRows.pay($0.0, $0.1, 1500) }
        // Each payday also lands $500 in savings, the same day.
        rows += [(6, 15), (6, 30), (7, 15), (7, 31), (8, 14), (8, 31), (9, 15)].map { m, d in
            var row = PayRows.pay(m, d, 500)
            row.id += "-sav"
            row.accountID = "sav"
            return row
        }
        rows.append(PayRows.pay(9, 22, 1200, merchant: "Bonus"))
        let upcoming = PayRows.ledger(rows).upcoming(days: 30)
        #expect(upcoming.nextPaycheck?.amount == Money(2000))
        #expect(upcoming.payCadence == "twice a month")
    }

    @Test("Pay that stopped two paydays ago has no schedule")
    func stopped() {
        let fridays = [(6, 12), (6, 26), (7, 10), (7, 24), (8, 7), (8, 21)]
        let rows = fridays.map { PayRows.pay($0.0, $0.1) }
        // Sep 4 and Sep 18 never came: 35 days after the last one.
        let upcoming = PayRows.ledger(rows).upcoming(days: 30)
        #expect(upcoming.nextPaycheck == nil)
        #expect(!upcoming.items.contains { $0.kind == .income })
        // Within two paydays it's still expected.
        #expect(PayRows.ledger(rows, now: PayRows.day(9, 10, hour: 12)).upcoming(days: 30).nextPaycheck != nil)
    }

    @Test("No regular pay: no income expected, and no cadence")
    func none() {
        let upcoming = PayRows.ledger([PayRows.pay(9, 1)]).upcoming(days: 30)
        #expect(upcoming.nextPaycheck == nil)
        #expect(upcoming.payCadence == nil)
        #expect(!upcoming.items.contains { $0.kind == .income })
    }
}

@Suite("Card bills")
struct CardBillTests {
    static func bill(owed: Decimal? = 500, statement: (Int, Int) = (9, 1), due: (Int, Int) = (10, 1), minimum: Decimal? = 40,
                     overdue: Bool? = false, lastPayment: (amount: Decimal, month: Int, day: Int)? = nil) -> CardBill {
        CardBill(accountID: "card", statementBalance: owed.map { Money($0) }, statementDate: PlaidSource.day(String(format: "2026-%02d-%02d", statement.0, statement.1)),
                 minimumPayment: minimum.map { Money($0) }, dueDate: PlaidSource.day(String(format: "2026-%02d-%02d", due.0, due.1)), isOverdue: overdue,
                 lastPaymentAmount: lastPayment.map { Money($0.amount) },
                 lastPaymentDate: lastPayment.flatMap { PlaidSource.day(String(format: "2026-%02d-%02d", $0.month, $0.day)) }, updatedAt: Fixture.now)
    }

    /// A payment into the card from checking: both sides of the move.
    static func payment(_ amount: Decimal, daysAgo: Double) -> [LedgerTransaction] {
        [Rows.row("pay-out-\(daysAgo)", "chk", daysAgo, -amount, "SUMMIT EPAYMENT", "transfer", peer: "pay-in-\(daysAgo)"),
         Rows.row("pay-in-\(daysAgo)", "card", daysAgo, amount, "PAYMENT RECEIVED", "transfer", peer: "pay-out-\(daysAgo)")]
    }

    @Test("A part payment since the statement leaves the rest due on the due date, with the minimum")
    func partPaid() throws {
        let ledger = PayRows.ledger(Self.payment(200, daysAgo: 10), cardBills: [Self.bill()])
        let card = try #require(ledger.presentedCardBills().first)
        #expect(card.status == .due)
        #expect(card.paidSinceStatement == Money(200))
        #expect(card.remaining == Money(300))
        #expect(card.accountName == "Gold Card")
        let item = try #require(ledger.upcoming(days: 30).items.first { $0.kind == .cardBill })
        #expect(item.amount == Money(-300))
        #expect(item.minimumPayment == Money(40))
        #expect(!item.isEstimate)
        #expect(ledger.dayKey(item.date) == "2026-10-01")
    }

    @Test("Paid in full: listed as paid, nothing coming up")
    func paid() throws {
        let ledger = PayRows.ledger(Self.payment(500, daysAgo: 3), cardBills: [Self.bill()])
        #expect(ledger.presentedCardBills().first?.status == .paid)
        let upcoming = ledger.upcoming(days: 30)
        #expect(!upcoming.items.contains { $0.kind == .cardBill })
        #expect(upcoming.cardBills.count == 1)
        #expect(upcoming.totals.cardBills == .zero)
    }

    @Test("The issuer's last payment counts when the ledger hasn't seen it yet; one before the statement doesn't")
    func issuerPayment() {
        let after = PayRows.ledger([], cardBills: [Self.bill(lastPayment: (500, 9, 20))])
        #expect(after.presentedCardBills().first?.status == .paid)
        let before = PayRows.ledger([], cardBills: [Self.bill(lastPayment: (500, 8, 25))])
        #expect(before.presentedCardBills().first?.remaining == Money(500))
    }

    @Test("Past the due date with a balance, or flagged by the issuer: overdue, on today")
    func overdue() throws {
        let passed = PayRows.ledger([], cardBills: [Self.bill(due: (9, 20))])
        #expect(passed.presentedCardBills().first?.status == .overdue)
        let item = try #require(passed.upcoming(days: 7).items.first { $0.kind == .cardBill })
        #expect(item.isLate == true)
        #expect(item.date == Fixture.calendar.startOfDay(for: Fixture.now))
        let flagged = PayRows.ledger([], cardBills: [Self.bill(overdue: true)])
        #expect(flagged.presentedCardBills().first?.status == .overdue)
    }

    @Test("No statement balance: nothing due; every field may be missing")
    func sparse() {
        let ledger = PayRows.ledger([], cardBills: [CardBill(accountID: "card", updatedAt: Fixture.now), CardBill(accountID: "gone", statementBalance: Money(90), updatedAt: Fixture.now)])
        // A card the ledger no longer holds is left out.
        #expect(ledger.presentedCardBills().map(\.status) == [.nothingDue])
        #expect(!ledger.upcoming(days: 30).items.contains { $0.kind == .cardBill })
    }

    @Test("A statement the issuer hasn't confirmed in over a month is left out, not shown as past due forever")
    func stale() {
        var old = Self.bill(due: (8, 25))
        old.updatedAt = Fixture.calendar.date(byAdding: .day, value: -36, to: Fixture.now)!
        let ledger = PayRows.ledger([], cardBills: [old])
        #expect(ledger.presentedCardBills().isEmpty)
        #expect(!ledger.upcoming(days: 30).items.contains { $0.kind == .cardBill })
        #expect(ledger.dueSoonFacts(from: Fixture.now).isEmpty)
    }

    @Test("Issuer statements are stored only on credit cards the ledger holds")
    func apply() {
        var state = LedgerState.empty
        state.accounts = [Account(id: "plaid:c1", name: "Gold Card", institution: "Summit Card", kind: .credit, balance: Money(-300), source: .plaid),
                          Account(id: "plaid:k1", name: "Checking", institution: "Harbor", kind: .checking, balance: Money(900), source: .plaid)]
        var ledger = Ledger(state: state, now: Fixture.now, calendar: Fixture.calendar)
        let stored = ledger.applyCardBills([SourceCardBill(externalAccountID: "c1", statementBalance: Money(250)),
                                            SourceCardBill(externalAccountID: "k1", statementBalance: Money(1)),
                                            SourceCardBill(externalAccountID: "zz", statementBalance: Money(2))], source: .plaid, at: Fixture.now)
        #expect(stored == 1)
        #expect(ledger.cardBills.keys.sorted() == ["plaid:c1"])
        #expect(ledger.cardBills["plaid:c1"]?.statementBalance == Money(250))
        #expect(ledger.cardBills["plaid:c1"]?.updatedAt == Fixture.now)
    }

    @Test("The morning summary says when a card is due within three days, or past due")
    func digest() {
        let start = Fixture.calendar.date(byAdding: .day, value: -1, to: Fixture.calendar.startOfDay(for: Fixture.now))!
        let soon = PayRows.ledger([], cardBills: [Self.bill(due: (9, 26))])
        #expect(soon.dayDigest("2026-09-24", from: start).facts.filter { $0.text.hasPrefix("Gold Card") }.map(\.text)
                == ["Gold Card is due tomorrow: $500 (minimum $40)."])
        // A kind apps before 0.5.0 know, so their decoding never fails on it.
        #expect(soon.dueSoonFacts(from: Fixture.now).map(\.kind) == [.bills])
        let today = PayRows.ledger([], cardBills: [Self.bill(due: (9, 25), minimum: nil)])
        #expect(today.dueSoonFacts(from: Fixture.now).map(\.text) == ["Gold Card is due today: $500."])
        let far = PayRows.ledger([], cardBills: [Self.bill(due: (10, 1))])
        #expect(far.dueSoonFacts(from: Fixture.now).isEmpty)
        let late = PayRows.ledger([], cardBills: [Self.bill(due: (9, 20))])
        #expect(late.dueSoonFacts(from: Fixture.now).map(\.text) == ["Gold Card is past due: $500 is left on its statement."])
        let paid = PayRows.ledger(Self.payment(500, daysAgo: 2), cardBills: [Self.bill(due: (9, 26))])
        #expect(paid.dueSoonFacts(from: Fixture.now).isEmpty)
    }

    @Test("Card bills persist with the ledger; a ledger saved before them loads with none")
    func persistence() throws {
        let ledger = PayRows.ledger([], cardBills: [Self.bill()])
        let data = try JSONEncoder().encode(ledger.state)
        #expect(try JSONDecoder().decode(LedgerState.self, from: data).cardBills == ledger.state.cardBills)
        guard case var .object(fields) = try JSONValue.parse(data) else { Issue.record("not an object"); return }
        fields["cardBills"] = nil
        #expect(try JSONDecoder().decode(LedgerState.self, from: JSONValue.object(fields).data()).cardBills.isEmpty)
    }
}

@Suite("Upcoming, all together")
struct UpcomingTests {
    @Test("Days hold their items in order; the days' totals add up to the window's; card bills stay apart from charges")
    func reconciles() throws {
        let ledger = Fixture.ledger()
        let upcoming = ledger.upcoming(days: 30)
        #expect(!upcoming.items.isEmpty)
        #expect(Set(upcoming.items.map(\.id)).count == upcoming.items.count)
        #expect(upcoming.items.map(\.date) == upcoming.items.map(\.date).sorted())
        let today = Fixture.calendar.startOfDay(for: Fixture.now)
        let end = Fixture.calendar.date(byAdding: .day, value: 30, to: today)!
        #expect(upcoming.items.allSatisfy { $0.date >= today && $0.date < end })
        #expect(upcoming.byDay.flatMap(\.itemIDs) == upcoming.items.map(\.id))
        let sum = upcoming.byDay.reduce(UpcomingTotals()) {
            UpcomingTotals(income: $0.income + $1.totals.income, bills: $0.bills + $1.totals.bills,
                           subscriptions: $0.subscriptions + $1.totals.subscriptions, cardBills: $0.cardBills + $1.totals.cardBills)
        }
        #expect(sum == upcoming.totals)
        #expect(upcoming.totals.charges == upcoming.totals.bills + upcoming.totals.subscriptions)
        let week = Fixture.calendar.date(byAdding: .day, value: 7, to: today)!
        #expect(upcoming.nextSevenDays == Ledger.totals(upcoming.items.filter { $0.date < week }))
        #expect(upcoming.items(within: 7, calendar: Fixture.calendar).count == upcoming.items.filter { $0.date < week }.count)
        // Money in is positive, money out negative.
        #expect(upcoming.items.allSatisfy { ($0.kind == .income) == !$0.amount.isNegative })
    }

    @Test("Bills and subscriptions match the recurring list's next 30 days")
    func matchesRecurring() {
        let ledger = Fixture.ledger()
        let found = ledger.subscriptions()
        let upcoming = ledger.upcoming(days: 30)
        // Every bill and subscription coming up is an active one on the recurring list.
        #expect(Set(upcoming.items.filter { $0.kind == .bill || $0.kind == .subscription }.map(\.title))
                .isSubset(of: Set(found.items.filter { $0.status == .active }.map(\.merchant))))
    }

    @Test("The demo: paid twice a month by Acme Corp; before the 25th the Gold Card's statement is due, from then on it's paid")
    func demo() throws {
        let before = Ledger(now: PayRows.day(9, 20, hour: 12), calendar: Fixture.calendar, seed: 7)
        let upcoming = before.upcoming(days: 30)
        #expect(upcoming.payCadence == "twice a month")
        let pay = try #require(upcoming.nextPaycheck)
        #expect(pay.title == "Acme Corp")
        #expect(pay.amount == Money(3850))
        #expect(before.dayKey(pay.date) == "2026-10-01")
        let card = try #require(upcoming.items.first { $0.kind == .cardBill })
        #expect(card.title == "Gold Card ••1008")
        #expect(before.dayKey(card.date) == "2026-09-25")
        #expect(upcoming.nextSevenDays.cardBills == card.amount.magnitude)

        let after = Fixture.ledger().upcoming(days: 30)
        #expect(after.cardBills.map(\.status) == [.paid])
        #expect(!after.items.contains { $0.kind == .cardBill })
    }

    @Test("A monthly charge keeps its day of the month across months, not a fixed count of days")
    func monthlyDay() {
        let rows = [4, 5, 6, 7, 8].map { month in
            LedgerTransaction(id: "box-\(month)", accountID: "card", postedAt: PayRows.day(month, 30, hour: 12), merchant: "Stream Box",
                              rawDescription: "STREAM BOX", amount: Money(-12),
                              categorization: Categorization(categoryID: "subscriptions", confidence: 1, tier: .rule, needsReview: false),
                              isPending: false, source: .plaid)
        }
        let ledger = PayRows.ledger(rows)
        let charges = ledger.upcoming(days: 120).items.filter { $0.title == "Stream Box" }
        // Every one stays on the 30th, the first included, and it's the recurring list's own next expected charge.
        #expect(PayRows.days(charges, ledger) == ["2026-09-30", "2026-10-30", "2026-11-30", "2026-12-30"])
        #expect(Set(charges.map(\.id)).count == charges.count)
        #expect(ledger.subscriptions().items.first { $0.merchant == "Stream Box" }.map { ledger.dayKey($0.nextExpected) } == "2026-09-30")
    }

    /// Rows posted Plaid-style, at noon UTC on the day.
    static func utcRows(_ merchant: String, _ amount: Decimal, _ category: String, _ days: [(Int, Int, Int)]) -> [LedgerTransaction] {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return days.enumerated().map { index, d in
            LedgerTransaction(id: "\(merchant)-\(index)", accountID: "chk", postedAt: utc.date(from: DateComponents(year: d.0, month: d.1, day: d.2, hour: 12))!,
                              merchant: merchant, rawDescription: merchant.uppercased(), amount: Money(amount),
                              categorization: Categorization(categoryID: category, confidence: 1, tier: .rule, needsReview: false),
                              isPending: false, source: .plaid)
        }
    }

    @Test("Rent on the 1st is next due on the 1st, not 30.4 days on: never the 31st, and not late on the morning it's due")
    func firstOfMonth() {
        let rows = Self.utcRows("Oak Apartments", -2_000, "housing", [(2026, 10, 1), (2026, 11, 1), (2026, 12, 1), (2027, 1, 1)])
        func at(_ m: Int, _ d: Int, hour: Int) -> Date { Fixture.calendar.date(from: DateComponents(year: 2027, month: m, day: d, hour: hour))! }
        let mid = PayRows.ledger(rows, now: at(1, 20, hour: 10))
        let rent = mid.upcoming(days: 45).items.filter { $0.title == "Oak Apartments" }
        #expect(PayRows.days(rent, mid) == ["2027-02-01", "2027-03-01"])
        let morning = PayRows.ledger(rows, now: at(2, 1, hour: 8))
        let due = morning.upcoming(days: 30).items.filter { $0.title == "Oak Apartments" }
        #expect(PayRows.days(due, morning).first == "2027-02-01")
        #expect(due.first?.isLate == nil)
    }

    @Test("A charge on the 31st takes February's last day, then March 31st: one a month, none skipped or doubled")
    func endOfMonth() {
        let rows = Self.utcRows("StreamCo", -15.99, "subscriptions", [(2026, 10, 31), (2026, 11, 30), (2026, 12, 31), (2027, 1, 31)])
        let ledger = PayRows.ledger(rows, now: Fixture.calendar.date(from: DateComponents(year: 2027, month: 2, day: 10, hour: 10))!)
        let charges = ledger.upcoming(days: 60).items.filter { $0.title == "StreamCo" }
        #expect(PayRows.days(charges, ledger) == ["2027-02-28", "2027-03-31"])
    }

    @Test("Asking for an out-of-range window is clamped")
    func clamps() {
        let ledger = Fixture.ledger()
        #expect(ledger.upcoming(days: 0).days == 1)
        #expect(ledger.upcoming(days: 1000).days == 366)
    }

    @Test("Upcoming round-trips through the API's JSON coding, and unknown kinds and statuses still decode")
    func wire() throws {
        let upcoming = Fixture.ledger().upcoming(days: 30)
        let data = try RemoteBudgetAPI.encoder.encode(upcoming)
        #expect(try RemoteBudgetAPI.decoder.decode(Upcoming.self, from: data) == upcoming)
        #expect(try JSONDecoder().decode(UpcomingItem.Kind.self, from: Data(#""loanPayment""#.utf8)) == .bill)
        #expect(try JSONDecoder().decode(CardBill.Status.self, from: Data(#""deferred""#.utf8)) == .due)
        #expect(try JSONDecoder().decode(DayDigest.Fact.Kind.self, from: Data(#""somethingNew""#.utf8)) == .bills)
    }

    @Test("The API serves it; a client without it says not found")
    func api() async throws {
        let upcoming = try await Fixture.api().upcoming(days: 14)
        #expect(upcoming.days == 14)
        await #expect(throws: BudgetAPIError.notFound) { try await UnconfiguredStub().upcoming(days: 14) }
    }
}

@Suite("Ask about what's coming up")
struct UpcomingAskTests {
    @Test("The demo answers from findUpcoming, with valid arguments and every amount grounded", arguments: [
        "When is my next paycheck?", "What's coming up this week?", "When is my card bill due?",
    ])
    func grounded(question: String) async throws {
        let api = DemoBudgetAPI(now: PayRows.day(9, 20, hour: 12), calendar: Fixture.calendar, seed: 7, latency: .zero)
        let reply = try await api.ask(question, conversationID: nil)
        #expect(reply.toolCalls.map(\.name) == ["findUpcoming"])
        for call in reply.toolCalls {
            #expect(throws: Never.self) {
                try ToolCatalog.validateArguments(tool: call.name, json: Data(call.arguments.utf8), categoryIDs: DemoLedger.categoryList.map(\.id))
            }
        }
        #expect(Grounding.ungroundedAmounts(in: reply.text, allowed: reply.figures.map(\.value)).isEmpty, "\(reply.text)")
        #expect(reply.text.contains("Acme Corp"))
        #expect(reply.text.contains("Gold Card ••1008 is due"))
    }

    @Test("The read tool returns the ledger's figures as display strings")
    func tool() throws {
        let toolbox = DemoToolbox(ledger: Ledger(now: PayRows.day(9, 20, hour: 12), calendar: Fixture.calendar, seed: 7), decisions: nil)
        let (result, figures) = toolbox.findUpcoming(days: 30)
        guard case let .object(o) = result, case let .object(pay)? = o["nextPaycheck"], case let .array(items)? = o["items"] else {
            Issue.record("unexpected shape"); return
        }
        #expect(pay["amount"] == .string(Money(3850).display))
        #expect(pay["from"] == .string("Acme Corp"))
        #expect(!items.isEmpty)
        #expect(figures.contains { $0.id == "next-pay" && $0.value == Money(3850) })
    }
}

/// A conformer written before `upcoming` existed: it gets the protocol's default.
private struct UnconfiguredStub: BudgetAPI {
    func overview() async throws -> Overview { throw BudgetAPIError.unreachable }
    func budget(month: String?) async throws -> BudgetMonth { throw BudgetAPIError.unreachable }
    func categoryHistory(id: String, months: Int) async throws -> CategoryHistory { throw BudgetAPIError.unreachable }
    func categories() async throws -> [BudgetCategory] { [] }
    func rules() async throws -> [RuleSummary] { [] }
    func rememberedMerchants() async throws -> [RememberedMerchant] { [] }
    func spending(_ range: SpendingRange) async throws -> SpendingSummary { throw BudgetAPIError.unreachable }
    func transactions(_ filter: TransactionFilter) async throws -> [LedgerTransaction] { [] }
    func transaction(id: String) async throws -> LedgerTransaction { throw BudgetAPIError.notFound }
    func transactionSummary(_ filter: TransactionFilter) async throws -> TransactionSummary { throw BudgetAPIError.unreachable }
    func reviewQueue() async throws -> [ReviewItem] { [] }
    func confirmCategory(transactionID: String, categoryID: String) async throws -> ActionResult { throw BudgetAPIError.unreachable }
    func ask(_ question: String, conversationID: String?) async throws -> AskReply { throw BudgetAPIError.unreachable }
    func projection(horizonMonths: Int, goal: GoalQuery?) async throws -> Projection { throw BudgetAPIError.unreachable }
    func serverStatus() async throws -> ServerStatus { throw BudgetAPIError.unreachable }
    func syncNow() async throws -> [LinkSyncResult] { [] }
    func savingsPlan() async throws -> SavingsPlan { throw BudgetAPIError.unreachable }
    func checkup() async throws -> Checkup { throw BudgetAPIError.unreachable }
    func subscriptions() async throws -> SubscriptionSummary { throw BudgetAPIError.unreachable }
    func perform(_ action: AppAction) async throws -> ActionResult { throw BudgetAPIError.unreachable }
    func preview(_ action: AppAction) async throws -> ActionPreview { throw BudgetAPIError.unreachable }
    func assistantConfig() async throws -> AssistantConfig { throw BudgetAPIError.unreachable }
}
