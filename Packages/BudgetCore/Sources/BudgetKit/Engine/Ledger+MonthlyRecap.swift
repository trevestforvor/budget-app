import Foundation

extension Ledger {
    /// How long into a month Home shows last month's recap.
    static let monthlyRecapDays = 7
    /// A category has to move at least this much against the month before to be one of the recap's changes.
    static let recapChangeFloor = Money(20)

    /// A finished month in review (`MonthlyRecap`). Nil `key` is last month. Income, spending and what was left are cash
    /// flow's figures for the month; the buckets are the budget month's (`budgetMonth`), each against what the budget
    /// planned for it then.
    /// - Parameters:
    ///   - snapshots: the balances recorded at sync (net worth history, `BalanceHistoryStore`). Given, the recap carries
    ///     the month's change in net worth when that history covers both ends of the month (`recapNetWorthChange`).
    ///     Nil (no history at hand) or a month the history only estimates leaves it out, and the recap shows the
    ///     change in cash.
    ///   - netWorthChange: a change worked out elsewhere, used as given (tests).
    func monthlyRecap(_ key: String?, snapshots: [BalanceSnapshot]? = nil, netWorthChange: Money? = nil) throws -> MonthlyRecap {
        let lastMonth = interval(for: .lastMonth).start
        let key = key ?? monthKey(lastMonth)
        guard let start = monthStart(key) else { throw BudgetAPIError.rejected("A month is written like 2026-09.") }
        let name = start.formatted(Self.monthStyle(calendar, year: false))
        guard start < startOfMonth else { throw BudgetAPIError.rejected("\(name) isn't over yet, so there's no recap of it.") }
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        guard !transactions.isEmpty else { throw BudgetAPIError.rejected("There's nothing in the ledger yet, so there's no recap of \(name).") }
        guard transactions.contains(where: { $0.postedAt < end }) else {
            throw BudgetAPIError.rejected("The ledger starts after \(start.formatted(Self.monthStyle(calendar))), so there's no recap of it.")
        }

        let flow = flow(from: start, to: end)
        let budget = try budgetMonth(key)
        let hasBudget = budget.hasBudget
        let buckets = budget.groups.map { RecapBucket(group: $0.group, spent: $0.spent, planned: hasBudget ? $0.planned : nil) }
        let changes = recapCategoryChanges(from: start, to: end)
        let (before, after) = (start.addingTimeInterval(-0.001), end.addingTimeInterval(-0.001))
        let cashChange = cash(through: after) - cash(through: before)
        let showsUntil = key == monthKey(lastMonth) ? calendar.date(byAdding: .day, value: Self.monthlyRecapDays, to: startOfMonth) : nil
        return MonthlyRecap(month: key, asOf: now, showsUntil: showsUntil, income: flow.income, spending: flow.spending, saved: flow.net,
                            movedToSavings: movedToSavings(from: start, to: end), buckets: buckets, hasBudget: hasBudget,
                            categoryChanges: changes, cashChange: cashChange,
                            netWorthChange: netWorthChange ?? recapNetWorthChange(from: start, to: end, snapshots: snapshots),
                            summary: Self.recapSummary(name: name, flow: flow, buckets: buckets, changes: changes))
    }

    /// Net worth at the end of the month's last day less at the end of the day before it starts, from the net worth
    /// history (`netWorth(range:snapshots:)`: cash and cards walked back through their rows, investments at their
    /// recorded balances, hand-kept values). Nil without a history (`snapshots` nil), when the ledger doesn't reach back
    /// to the day before the month, or when either end is estimated (an investment with no balance recorded by then),
    /// so a change that is only a guess never stands in for the cash figure. The API and the Ask tool both read here.
    func recapNetWorthChange(from start: Date, to end: Date, snapshots: [BalanceSnapshot]?) -> Money? {
        guard let snapshots, let before = calendar.date(byAdding: .day, value: -1, to: start),
              let last = calendar.date(byAdding: .day, value: -1, to: end), last <= now else { return nil }
        let history = netWorth(range: .all, snapshots: snapshots, thinned: false)
        let byDay = Dictionary(history.points.map { (dayName($0.date), $0) }, uniquingKeysWith: { a, _ in a })
        guard let opening = byDay[dayName(before)], let closing = byDay[dayName(last)],
              opening.isEstimated != true, closing.isEstimated != true else { return nil }
        return closing.netWorth - opening.netWorth
    }

    /// The spending categories that moved most against the whole month before, at least `recapChangeFloor` either way,
    /// biggest first — none when the ledger doesn't cover that month from its start.
    func recapCategoryChanges(from start: Date, to end: Date, limit: Int = 3) -> [RecapCategoryChange] {
        let previousStart = calendar.date(byAdding: .month, value: -1, to: start)!
        guard covers(from: previousStart) else { return [] }
        let now = Dictionary(sumByCategory(from: start, to: end, includeTargets: false).map { ($0.category.id, $0.spent) }, uniquingKeysWith: { a, _ in a })
        let then = Dictionary(sumByCategory(from: previousStart, to: start, includeTargets: false).map { ($0.category.id, $0.spent) },
                              uniquingKeysWith: { a, _ in a })
        return Set(now.keys).union(then.keys).compactMap { id -> RecapCategoryChange? in
            guard let category = category(id) else { return nil }
            let (spent, previous) = (now[id] ?? .zero, then[id] ?? .zero)
            let change = spent - previous
            guard change.magnitude >= Self.recapChangeFloor else { return nil }
            return RecapCategoryChange(categoryID: id, name: category.name, spent: spent, previous: previous, change: change)
        }
        .sorted { ($0.change.magnitude, $1.categoryID) > ($1.change.magnitude, $0.categoryID) }
        .prefix(limit).map { $0 }
    }

    /// Money moved into savings accounts over a window: transfers in, as the budget's "saved first" counts them.
    func movedToSavings(from start: Date, to end: Date) -> Money {
        transactions(from: start, to: end)
            .filter { savingsAccountIDs.contains($0.accountID) && $0.categorization?.categoryID == "transfer" && !$0.amount.isNegative }
            .map(\.amount).sum()
    }

    /// "You kept $1,240 of the $8,200 that came in. Everyday spending came in $180 under its budget."
    static func recapSummary(name: String, flow: Flow, buckets: [RecapBucket], changes: [RecapCategoryChange]) -> String {
        var sentences: [String] = []
        if flow.income.minorUnits == 0 && flow.spending.minorUnits == 0 {
            return "Nothing came in or went out in \(name)."
        } else if flow.net.isNegative {
            sentences.append("Spending ran \(flow.net.magnitude.formatted(fractionDigits: 0)) past what came in during \(name).")
        } else {
            sentences.append("You kept \(flow.net.formatted(fractionDigits: 0)) of the \(flow.income.formatted(fractionDigits: 0)) that came in during \(name).")
        }
        if let everyday = buckets.first(where: { $0.group == .everyday }), let over = everyday.overBy, everyday.planned?.minorUnits ?? 0 > 0 {
            sentences.append(over.minorUnits == 0 ? "Everyday spending landed right on its budget."
                : over.isNegative ? "Everyday spending came in \(over.magnitude.formatted(fractionDigits: 0)) under its budget."
                : "Everyday spending went \(over.formatted(fractionDigits: 0)) over its budget.")
        } else if let top = changes.first {
            sentences.append("\(top.name) was \(top.change.isNegative ? "down" : "up") \(top.change.magnitude.formatted(fractionDigits: 0)) on the month before.")
        }
        return sentences.joined(separator: " ")
    }
}
