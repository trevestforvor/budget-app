import Foundation

/// When pay comes, read from the paydays `recentPaychecks` counts: weekly or every two weeks keep a fixed step;
/// twice a month and monthly keep days of the month, moved back to the Friday before when they fall on a weekend, the
/// way payroll does. The amount is the typical recent paycheck (the median of the last four).
struct PaySchedule: Equatable {
    enum Rhythm: Equatable {
        case weekly, biweekly
        /// Days of the month, one per payday in a month.
        case monthDays([Int])

        var phrase: String {
            switch self {
            case .weekly: "every week"
            case .biweekly: "every 2 weeks"
            case let .monthDays(days): days.count == 1 ? "every month" : "twice a month"
            }
        }
    }

    var rhythm: Rhythm
    /// The latest payday.
    var last: Date
    var typical: Money

    /// Expected paydays after the latest one, through `end`: each with whether it's late (its day is before `today`).
    /// One more than a few days late is left out: pay that stopped isn't coming.
    func expected(today: Date, through end: Date, calendar: Calendar) -> [(date: Date, late: Bool)] {
        var dates: [Date] = []
        switch rhythm {
        case .weekly, .biweekly:
            let step = rhythm == .weekly ? 7 : 14
            var next = calendar.date(byAdding: .day, value: step, to: calendar.startOfDay(for: last))!
            while next < end {
                dates.append(next)
                next = calendar.date(byAdding: .day, value: step, to: next)!
            }
        case let .monthDays(days):
            let firstMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: last))!
            var offset = 0
            while true {
                let month = calendar.date(byAdding: .month, value: offset, to: firstMonth)!
                // A month's first payday can move back into the month before (a Sunday the 1st).
                guard calendar.date(byAdding: .day, value: -3, to: month)! < end else { break }
                let length = calendar.range(of: .day, in: .month, for: month)!.count
                for day in days {
                    let date = Self.beforeWeekend(calendar.date(byAdding: .day, value: min(day, length) - 1, to: month)!, calendar)
                    // A few days' slack: a payday moved before a weekend can land before the latest one's day.
                    if date > calendar.date(byAdding: .day, value: 4, to: calendar.startOfDay(for: last))!, date < end { dates.append(date) }
                }
                offset += 1
            }
        }
        let graceStart = calendar.date(byAdding: .day, value: -4, to: today)!
        return dates.sorted().filter { $0 >= graceStart }.map { ($0, $0 < today) }
    }

    /// Saturday and Sunday paydays come on the Friday before.
    static func beforeWeekend(_ date: Date, _ calendar: Calendar) -> Date {
        switch calendar.component(.weekday, from: date) {
        case 7: calendar.date(byAdding: .day, value: -1, to: date)!
        case 1: calendar.date(byAdding: .day, value: -2, to: date)!
        default: date
        }
    }
}

extension Ledger {
    /// How pay comes, from the regular paydays in the last 120 days; nil when no regular pay shows. Two a month every
    /// 14 days (give or take a day) is every two weeks; two a month on varying gaps is twice a month, on the days of the
    /// month each payday usually lands.
    func paySchedule() -> PaySchedule? {
        guard let history = paydayHistory(), let last = history.paydays.last else { return nil }
        let amounts = history.paydays.suffix(4).map(\.amount.minorUnits).sorted()
        let typical = Money(minorUnits: amounts[amounts.count / 2])
        let rhythm: PaySchedule.Rhythm
        switch history.perMonth {
        case 4:
            rhythm = .weekly
        case 2:
            let gaps = zip(history.paydays.dropFirst(), history.paydays).map {
                calendar.dateComponents([.day], from: calendar.startOfDay(for: $1.date), to: calendar.startOfDay(for: $0.date)).day ?? 0
            }
            if gaps.allSatisfy({ (13...15).contains($0) }) {
                rhythm = .biweekly
            } else {
                // Alternating paydays fill two slots (the 1st and the 15th); each slot's usual day of the month.
                let ordered = Array(history.paydays.reversed())
                let slots = [0, 1].map { slot in stride(from: slot, to: ordered.count, by: 2).map { calendar.component(.day, from: ordered[$0].date) } }
                rhythm = .monthDays(slots.map(Self.usualDay).sorted())
            }
        default:
            rhythm = .monthDays([Self.usualDay(history.paydays.map { calendar.component(.day, from: $0.date) })])
        }
        return PaySchedule(rhythm: rhythm, last: last.date, typical: typical)
    }

    /// The day of the month a payday lands on most often; a tie goes to the latest day (a weekend moves pay earlier,
    /// never later).
    static func usualDay(_ days: [Int]) -> Int {
        let counts = Dictionary(grouping: days, by: { $0 }).mapValues(\.count)
        return counts.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key ?? 1
    }

    // MARK: Card bills

    /// Each card's statement from its issuer, read against the card's own rows: what's been paid into it since the
    /// statement (a move between accounts, or the issuer's own last payment when that's later), what's left, and
    /// whether it's due, paid or overdue. Cards no longer in the ledger are left out; soonest due first.
    func presentedCardBills() -> [CardBill] {
        let today = calendar.startOfDay(for: now)
        return cardBills.values.compactMap { stored -> CardBill? in
            guard let account = accounts.first(where: { $0.id == stored.accountID }) else { return nil }
            var bill = stored
            bill.accountName = account.shortLabel
            let owed = stored.statementBalance ?? .zero
            var paid = Money.zero
            if let statementDate = stored.statementDate {
                // Payments the statement doesn't hold: made after its day (a pending one is on its way, so it counts).
                let after = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: statementDate))!
                paid = transactions.filter {
                    $0.accountID == stored.accountID && !$0.amount.isNegative && $0.postedAt >= after
                        && ($0.transferPeerID != nil || Categorizer.looksLikePayment($0))
                }.map(\.amount).sum()
                if let date = stored.lastPaymentDate, let amount = stored.lastPaymentAmount, date >= after, amount > paid { paid = amount }
            }
            bill.paidSinceStatement = paid
            let remaining = owed.minorUnits > paid.minorUnits ? owed - paid : .zero
            bill.remaining = remaining
            if owed.minorUnits <= 0 {
                bill.status = .nothingDue
            } else if remaining.minorUnits == 0 {
                bill.status = .paid
            } else if stored.isOverdue == true || (stored.dueDate.map { calendar.startOfDay(for: $0) < today } ?? false) {
                bill.status = .overdue
            } else {
                bill.status = .due
            }
            return bill
        }
        .sorted { ($0.dueDate ?? .distantFuture, $0.accountID) < ($1.dueDate ?? .distantFuture, $1.accountID) }
    }

    /// Stores what the issuer said about each card in `bills` (from `source`), as of `date`. Only accounts the ledger
    /// holds as credit cards take one; the rest are ignored. Returns how many were stored.
    @discardableResult
    mutating func applyCardBills(_ bills: [SourceCardBill], source: SourceKind, at date: Date) -> Int {
        var stored = 0
        for bill in bills {
            let id = Self.accountID(source, bill.externalAccountID)
            guard accounts.contains(where: { $0.id == id && $0.kind == .credit }) else { continue }
            cardBills[id] = CardBill(accountID: id, statementBalance: bill.statementBalance, statementDate: bill.statementDate,
                                     minimumPayment: bill.minimumPayment, dueDate: bill.dueDate, isOverdue: bill.isOverdue,
                                     lastPaymentAmount: bill.lastPaymentAmount, lastPaymentDate: bill.lastPaymentDate,
                                     purchaseAPR: bill.purchaseAPR, updatedAt: date)
            stored += 1
        }
        return stored
    }

    // MARK: Upcoming

    /// What's expected from today through `days` ahead (1–366): paychecks from the pay schedule, every charge the
    /// recurring list expects at its latest amount (a weekly one each week; one that's late but not yet missed on
    /// today), and what's left of each card's statement on its due date (overdue ones on today). Each day's totals by
    /// kind, the window's and the next seven days'. Card bills pay for spending already made, so they're kept apart from
    /// new charges in every total.
    func upcoming(days requested: Int) -> Upcoming {
        let days = min(max(requested, 1), 366)
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: days, to: today)!
        var items: [UpcomingItem] = []

        let schedule = paySchedule()
        var nextPaycheck: UpcomingItem?
        if let schedule {
            let horizon = max(end, calendar.date(byAdding: .day, value: 45, to: today)!)
            for (date, late) in schedule.expected(today: today, through: horizon, calendar: calendar) {
                let item = UpcomingItem(id: "income-\(dayKey(date))", kind: .income, date: late ? today : date, title: payer ?? "Paycheck",
                                        amount: schedule.typical, categoryID: BudgetCategory.incomeID, isEstimate: true, isLate: late ? true : nil)
                if nextPaycheck == nil { nextPaycheck = item }
                if item.date < end { items.append(item) }
            }
        }

        for item in subscriptions().items where item.status == .active {
            // Only the first can be late (an active charge is within its grace, which is shorter than its cadence).
            var next = item.nextExpected
            while true {
                let day = calendar.startOfDay(for: next)
                let late = day < today
                let date = late ? today : day
                guard date < end else { break }
                items.append(UpcomingItem(id: "\(item.kind.rawValue)-\(item.merchant)-\(dayKey(day))", kind: item.kind == .bill ? .bill : .subscription,
                                          date: date, title: item.merchant, amount: -item.amount, categoryID: item.categoryID,
                                          cadence: item.cadence, isEstimate: true, isLate: late ? true : nil))
                next = next.addingTimeInterval(item.cadence.days * 86_400)
            }
        }

        let bills = presentedCardBills()
        for bill in bills where bill.status == .due || bill.status == .overdue {
            guard let remaining = bill.remaining, remaining.minorUnits > 0 else { continue }
            let due = bill.dueDate.map { calendar.startOfDay(for: $0) } ?? today
            let late = bill.status == .overdue
            let date = late ? today : max(due, today)
            guard date < end else { continue }
            items.append(UpcomingItem(id: "card-\(bill.accountID)-\(dayKey(due))", kind: .cardBill, date: date, title: bill.accountName ?? "Card",
                                      amount: -remaining, accountID: bill.accountID, isEstimate: false, isLate: late ? true : nil,
                                      minimumPayment: bill.minimumPayment))
        }

        let rank: [UpcomingItem.Kind: Int] = [.income: 0, .cardBill: 1, .bill: 2, .subscription: 3]
        items.sort { a, b in
            (a.date, rank[a.kind] ?? 9, -a.amount.magnitude.minorUnits, a.title) < (b.date, rank[b.kind] ?? 9, -b.amount.magnitude.minorUnits, b.title)
        }
        let week = calendar.date(byAdding: .day, value: 7, to: today)!
        let byDay = Dictionary(grouping: items, by: \.date).map { date, rows in
            UpcomingDay(date: date, totals: Self.totals(rows), itemIDs: rows.map(\.id))
        }.sorted { $0.date < $1.date }
        return Upcoming(asOf: now, days: days, items: items, byDay: byDay, totals: Self.totals(items),
                        nextSevenDays: Self.totals(items.filter { $0.date < week }), nextPaycheck: nextPaycheck,
                        payCadence: schedule?.rhythm.phrase, cardBills: bills)
    }

    /// The morning summary's word on card bills, read on the morning of `morning` (the day after the one it sums up): a
    /// card past due, or one due within three days, with what's left of its statement. Soonest first.
    func dueSoonFacts(from morning: Date) -> [DayDigest.Fact] {
        let day = calendar.startOfDay(for: morning)
        let soon = calendar.date(byAdding: .day, value: 3, to: day)!
        return presentedCardBills().compactMap { bill -> DayDigest.Fact? in
            guard let remaining = bill.remaining, remaining.minorUnits > 0, let name = bill.accountName else { return nil }
            if bill.status == .overdue {
                return .init(kind: .dueSoon, text: "\(name) is past due: \(Self.amount(remaining)) is left on its statement.")
            }
            guard bill.status == .due, let due = bill.dueDate.map({ calendar.startOfDay(for: $0) }), due >= day, due < soon else { return nil }
            let when = due == day ? "today" : calendar.date(byAdding: .day, value: 1, to: day) == due ? "tomorrow"
                : "on " + due.formatted(Date.FormatStyle(timeZone: calendar.timeZone).weekday(.wide))
            let minimum = bill.minimumPayment.map { " (minimum \(Self.amount($0)))" } ?? ""
            return .init(kind: .dueSoon, text: "\(name) is due \(when): \(Self.amount(remaining))\(minimum).")
        }
    }

    /// Each kind's amounts, as magnitudes.
    static func totals(_ items: [UpcomingItem]) -> UpcomingTotals {
        func sum(_ kind: UpcomingItem.Kind) -> Money { items.filter { $0.kind == kind }.map(\.amount.magnitude).sum() }
        return UpcomingTotals(income: sum(.income), bills: sum(.bill), subscriptions: sum(.subscription), cardBills: sum(.cardBill))
    }

    /// Who pays: the merchant on the latest paycheck's largest deposit.
    private var payer: String? {
        guard let history = paydayHistory(), let last = history.paydays.last else { return nil }
        return transactions.filter {
            $0.categorization?.categoryID == BudgetCategory.incomeID && !$0.amount.isNegative && abs($0.postedAt.timeIntervalSince(last.date)) < 3 * 86_400
        }.max { $0.amount < $1.amount }?.merchant
    }

    /// "2026-10-01" in the ledger's calendar.
    func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
