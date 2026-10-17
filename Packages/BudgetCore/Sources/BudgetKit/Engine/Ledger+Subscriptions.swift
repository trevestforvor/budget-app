import Foundation

extension Ledger {
    /// Recurring charges found in the ledger: a cadence read from the gaps between charges, steady amounts
    /// (the latest may be a new price), and a next expected date. One filed under a bill (rent, utilities, fees) is a
    /// bill; the person's say comes first.
    func subscriptions() -> SubscriptionSummary {
        var items: [Subscription] = []
        for series in recurringSeries() {
            // Long past its last charge, it's over: off the list (its charges keep their bucket). So is one the person
            // said they canceled, until it charges again.
            guard now.timeIntervalSince(series.billings.last!.date) <= series.cadence.staleAfter * 86_400, !isEnded(series) else { continue }
            items.append(subscription(series, kind: recurringKind(series)))
        }
        items.sort { ($0.status == .active ? 0 : 1, -$0.monthlyCost.minorUnits) < ($1.status == .active ? 0 : 1, -$1.monthlyCost.minorUnits) }
        let active = items.filter { $0.status == .active }
        let subs = active.filter { $0.kind == .subscription }.map(\.monthlyCost).sum()
        let months = transactions.map(\.postedAt).min().map { calendar.dateComponents([.month], from: $0, to: now).month ?? 0 } ?? 0
        return SubscriptionSummary(asOf: now, items: items, subscriptionsMonthly: subs,
                                   billsMonthly: active.filter { $0.kind == .bill }.map(\.monthlyCost).sum(),
                                   subscriptionsYearly: Money(minorUnits: subs.minorUnits * 12), monthsSearched: max(months, 0),
                                   dueNext30Days: Self.due(active, from: now, days: 30),
                                   notRecurring: recurringChoices.values.filter { !$0.isRecurring }.map(\.merchant).sorted())
    }

    /// A series as the recurring list shows it: its latest charge and the one before when the price changed, a cost per
    /// month and per year, and when the next charge is expected (missed once it's past the grace window).
    func subscription(_ series: RecurringSeries, kind: Subscription.Kind) -> Subscription {
        let (cadence, billings) = (series.cadence, series.billings)
        let amounts = billings.map(\.amount.minorUnits)
        let last = billings.last!
        // A calendar step, as Upcoming places it: a monthly charge on the 1st is next due on the 1st, not 30.4 days on.
        let next = Self.recurrence(after: last.date, cadence: cadence, number: 1, calendar: calendar)
        let status: Subscription.Status = now.timeIntervalSince(next) > cadence.grace * 86_400 ? .missed : .active
        let monthly = Double(last.amount.minorUnits) * 30.4 / cadence.days
        let previous = amounts.count >= 2 && amounts[amounts.count - 2] != amounts.last! ? Money(minorUnits: amounts[amounts.count - 2]) : nil
        let choice = recurringChoices[RecurringChoice.key(series.merchant)]
        return Subscription(
            merchant: series.merchant, kind: kind, cadence: cadence,
            status: status, amount: last.amount, previousAmount: previous,
            monthlyCost: Money(minorUnits: Int64(monthly.rounded())), yearlyCost: Money(minorUnits: Int64((monthly * 12).rounded())),
            lastCharged: last.date, nextExpected: next, charges: billings.count, categoryID: last.rows[0].categorization?.categoryID,
            accountName: accounts.first { $0.id == last.rows[0].accountID }.map { "\($0.institution) \($0.displayName)" },
            setByPerson: choice.map { $0.cadence != nil || $0.kind != nil },
            names: series.names.count > 1 ? series.names : nil)
    }

    typealias Billing = (date: Date, amount: Money, rows: [LedgerTransaction])

    /// One merchant's charges that repeat on a schedule: each billing (same-merchant charges within three days merged)
    /// with the rows in it.
    struct RecurringSeries {
        var merchant: String
        var cadence: Subscription.Cadence
        var billings: [Billing]
        var rowIDs: [String] { billings.flatMap { $0.rows.map(\.id) } }
        /// Every name its charges carry, when the bank wrote the merchant more than one way ("Google Fi", "Google*Fi Goo
        /// G.Co Helppay#").
        var names: [String] { Array(Set(billings.flatMap { $0.rows.map(\.merchant) })).sorted() }
    }

    /// Merchant names that are one merchant written differently — "Google*Fi Goo G.Co Helppay#", "Google *Fi G.Co/Helppay#
    /// Ca" — each mapped to the name that stands for them all (the one with fewest words). Two names are one merchant
    /// when they start with the same word, three quarters of the shorter's words are in the other, their charges are
    /// filed under the same category and are usually within 15% of each other, and they never charge within 15 days of
    /// each other: one merchant taking turns with its names, not two side by side. So "Plan Fee - Example Finance" and
    /// "Plan Fee - Example Coaching", both charging each month, stay two; so do Amazon orders and Amazon Prime.
    static func sameMerchants(_ rows: [LedgerTransaction]) -> [String: String] {
        struct Name { var name: String; var words: Set<String>; var category: String?; var typical: Int64; var dates: [Date] }
        func words(_ name: String) -> [String] { name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
        let names = Dictionary(grouping: rows, by: \.merchant).map { name, rows -> Name in
            let filed = Dictionary(grouping: rows.compactMap { $0.categorization?.categoryID }, by: { $0 })
            let amounts = rows.map(\.amount.magnitude.minorUnits).sorted()
            return Name(name: name, words: Set(words(name)), category: filed.max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key,
                        typical: amounts[amounts.count / 2], dates: rows.map(\.postedAt).sorted())
        }
        func apart(_ a: [Date], _ b: [Date]) -> Bool {
            a.allSatisfy { day in !b.contains { abs($0.timeIntervalSince(day)) < 15 * 86_400 } }
        }
        func same(_ short: Name, _ long: Name) -> Bool {
            guard !short.words.isEmpty, short.category != nil, short.category == long.category,
                  Double(short.words.intersection(long.words).count) >= Double(short.words.count) * 0.75,
                  Double(abs(short.typical - long.typical)) <= Double(max(short.typical, long.typical)) * 0.15 else { return false }
            return apart(short.dates, long.dates)
        }
        var sameAs: [String: String] = [:]
        for (_, group) in Dictionary(grouping: names, by: { words($0.name).first ?? "" }) where group.count > 1 {
            let ordered = group.sorted { ($0.words.count, $0.name) < ($1.words.count, $1.name) }
            for (i, long) in ordered.enumerated() {
                guard let short = ordered[..<i].first(where: { same($0, long) }) else { continue }
                sameAs[long.name] = sameAs[short.name] ?? short.name
            }
        }
        return sameAs
    }

    /// Every recurring series in the ledger: money out in spending categories, posted and counted, grouped by merchant,
    /// with a cadence read from the median gap, most gaps near it, and steady amounts (the latest may be a new price,
    /// not a new thing). The person's say comes first: a merchant they said doesn't recur never does, and one they gave
    /// a cadence recurs on it from its first charge. Subscriptions and yearly charges both come from here.
    func recurringSeries() -> [RecurringSeries] {
        var found: [RecurringSeries] = []
        for (merchant, billings) in merchantBillings() {
            let choice = recurringChoices[RecurringChoice.key(merchant)]
            if choice?.isRecurring == false { continue }
            if let cadence = choice?.cadence, let latest = billings.last?.amount {
                // The person's cadence covers the charge that recurs, not everything from the merchant.
                let anchor = choice?.amount ?? latest
                let recurring = billings.filter { RecurringChoice.matches($0.amount, anchor) }
                if !recurring.isEmpty { found.append(RecurringSeries(merchant: merchant, cadence: cadence, billings: recurring)) }
                continue
            }
            guard billings.count >= 2 else { continue }
            let gaps = Self.gaps(billings)
            guard let cadence = Self.cadence(medianGap: gaps.sorted()[gaps.count / 2]) else { continue }
            let needed = cadence == .yearly || cadence == .quarterly ? 2 : cadence == .weekly ? 4 : 3
            guard billings.count >= needed else { continue }
            // Regular: most gaps land near the cadence (a skipped month is fine, chaos isn't).
            let regular = gaps.filter { abs($0 - cadence.days) <= max(cadence.days * 0.2, 4) }.count
            guard Double(regular) >= Double(gaps.count) * 0.6 else { continue }
            // Steady: every earlier charge within 15% of their median, or four in five within 10% — a phone bill with
            // the odd month of extras, not a power bill that swings with the weather. The latest may be a new price, not
            // a new thing.
            let amounts = billings.map(\.amount.minorUnits)
            let earlier = amounts.dropLast().sorted()
            let typical = earlier[earlier.count / 2]
            func within(_ share: Double) -> Int { earlier.filter { Double(abs($0 - typical)) <= Double(typical) * share }.count }
            guard typical > 0, within(0.15) == earlier.count || Double(within(0.10)) >= Double(earlier.count) * 0.8,
                  Double(amounts.last!) <= Double(typical) * 1.6 else { continue }
            // Two visits a quarter or a year apart to a restaurant or a shop aren't a subscription: from an everyday
            // category, two charges have to match to within 2%, as a subscription's do.
            if billings.count == 2, cadence == .yearly || cadence == .quarterly,
               billings.last!.rows[0].categorization.flatMap({ category($0.categoryID) })?.group == .everyday,
               Double(abs(amounts[0] - amounts[1])) > Double(max(amounts[0], amounts[1])) * 0.02 { continue }
            found.append(RecurringSeries(merchant: merchant, cadence: cadence, billings: billings))
        }
        return found
    }

    /// Money out in spending categories, posted and counted, grouped by merchant (a merchant the bank writes more than
    /// one way as one, `sameMerchants`), each merchant's charges within three days of each other merged into one
    /// billing, oldest first. What both the recurring search and its review queue read.
    func merchantBillings() -> [(merchant: String, billings: [Billing])] {
        let rows = transactions.filter { row in
            guard row.amount.isNegative, !row.isPending, !row.isHidden else { return false }
            // Moves between accounts and money in are never a subscription or a bill.
            return row.categorization.flatMap { category($0.categoryID) }?.countsAsSpending ?? true
        }
        let sameAs = Self.sameMerchants(rows)
        return Dictionary(grouping: rows, by: { sameAs[$0.merchant] ?? $0.merchant }).map { merchant, charges in
            var billings: [Billing] = []
            for row in charges.sorted(by: { $0.postedAt < $1.postedAt }) {
                if let last = billings.last, row.postedAt.timeIntervalSince(last.date) < 3 * 86_400 {
                    billings[billings.count - 1].amount = last.amount + row.amount.magnitude
                    billings[billings.count - 1].rows.append(row)
                } else {
                    billings.append((row.postedAt, row.amount.magnitude, [row]))
                }
            }
            return (merchant, billings)
        }
    }

    /// Days between each billing and the one before it.
    static func gaps(_ billings: [Billing]) -> [Double] {
        zip(billings.dropFirst(), billings).map { $0.date.timeIntervalSince($1.date) / 86_400 }
    }

    /// The cadence a median gap between charges reads as, if any.
    static func cadence(medianGap median: Double) -> Subscription.Cadence? {
        switch median {
        case 5...9: .weekly
        case 25...36: .monthly
        case 80...100: .quarterly
        case 340...390: .yearly
        default: nil
        }
    }

    /// Every charge `items` are expected to make from now through `days` ahead, at their latest amounts: a weekly
    /// charge counts each week, and one that's late but not yet missed counts as due now.
    static func due(_ items: [Subscription], from now: Date, days: Double) -> Money {
        let horizon = now.addingTimeInterval(days * 86_400)
        return items.map { item in
            var total = Money.zero
            var next = item.nextExpected
            while next <= horizon {
                total = total + item.amount
                next = next.addingTimeInterval(item.cadence.days * 86_400)
            }
            return total
        }.sum()
    }
}
