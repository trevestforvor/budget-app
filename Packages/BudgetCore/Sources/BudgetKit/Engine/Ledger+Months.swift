import Foundation

extension Ledger {
    // MARK: Months

    /// Up to `count` months ending with this one, oldest first, none that ended before the ledger's first row (the
    /// months before any data would only read as zeros). `end` is capped at now; `isFullyCovered` says the ledger has
    /// rows from the month's first day or earlier and the month is over — what an average may use.
    func recentMonths(_ count: Int) -> [(key: String, start: Date, end: Date, isCurrent: Bool, isFullyCovered: Bool)] {
        let firstDay = self.firstDay
        return (0..<max(count, 1)).reversed().compactMap { back in
            let start = calendar.date(byAdding: .month, value: -back, to: startOfMonth)!
            let next = calendar.date(byAdding: .month, value: 1, to: start)!
            if back > 0, next <= firstDay ?? now { return nil }
            return (monthKey(start), start, min(next, now), back == 0, back > 0 && covers(from: start))
        }
    }

    /// The day of the ledger's first row.
    private var firstDay: Date? { transactions.map(\.postedAt).min().map { calendar.startOfDay(for: $0) } }

    /// Whether the ledger has rows from `start` or earlier — so a period from `start` on isn't missing its beginning.
    func covers(from start: Date) -> Bool { firstDay.map { start >= $0 } == true }

    /// Whether the months the flex budget averages (the three before this one) are all in the ledger. When they
    /// aren't, expected income and the usual month of bills and subscriptions count months with no data as zero.
    var flexHasFullHistory: Bool {
        covers(from: calendar.date(byAdding: .month, value: -Self.flexMonthsAveraged, to: startOfMonth)!)
    }

    /// How many complete months the flex budget averages (`capacity()`'s default).
    static let flexMonthsAveraged = 3

    // MARK: Budget month

    /// The budget for one month, as it stood at the end of it (this month: as of now). Nil means this month.
    func budgetMonth(_ key: String?) throws -> BudgetMonth {
        let current = monthKey(now)
        let key = key ?? current
        guard let start = monthStart(key) else { throw BudgetAPIError.rejected("A month is written like 2026-09.") }
        guard start <= now else { throw BudgetAPIError.rejected("\(start.formatted(Self.monthStyle(calendar))) hasn't started yet.") }
        guard key != current else { return budgetMonthSoFar(isCurrent: true) }
        // A past month is worked out by the ledger as it stood in its last instant: its own flex budget (the three
        // months before it), its own spending, no days left.
        var then = self
        then.now = calendar.date(byAdding: .month, value: 1, to: start)!.addingTimeInterval(-0.001)
        return then.budgetMonthSoFar(isCurrent: false)
    }

    private func budgetMonthSoFar(isCurrent: Bool) -> BudgetMonth {
        let month = interval(for: .thisMonth)
        var flex = flexBudget()
        if !isCurrent { flex.perDayLeft = nil }
        // Each bucket with its categories; a charge spread over the year counts its twelfth, listed apart.
        let totals = budgetTotals(from: month.start, to: month.end, includeTargets: true)
        let planned: [CategoryGroup: Money] = [.bills: flex.bills, .subscriptions: flex.subscriptions, .everyday: flex.flexNumber]
        let groups = CategoryGroup.allCases.map { group in
            let categories = totals[group] ?? []
            return BudgetGroup(group: group, planned: planned[group] ?? .zero, spent: categories.map(\.spent).sum(), categories: categories)
        }
        let everyday = groups.first { $0.group == .everyday }!
        let everydayTargets = activeCategories.filter { $0.countsAsSpending && $0.group == .everyday }.compactMap { monthlyTargets[$0.id] }.sum()
        let recurringSpent = groups.filter { $0.group != .everyday }.map(\.spent).sum()
        let hasHistory = flexHasFullHistory
        return BudgetMonth(
            month: monthKey(month.start), isCurrent: isCurrent, flex: flex,
            summary: monthSummary(isCurrent: isCurrent, flex: flex, hasHistory: hasHistory),
            groups: groups, unallocatedFlex: flex.flexNumber - everydayTargets,
            everythingElseSpent: everyday.categories.filter { $0.target == nil }.map(\.spent).sum(),
            stillToCome: isCurrent ? Money(minorUnits: max(0, (flex.bills + flex.subscriptions - recurringSpent).minorUnits)) : .zero,
            hasFullHistory: hasHistory)
    }

    /// The month in a sentence or two, from ledger figures only. This month says what the checkup's first section says;
    /// a finished month says how it ended against the whole month before and what was left of the everyday budget —
    /// each only when the ledger holds what it compares against.
    private func monthSummary(isCurrent: Bool, flex: FlexBudget, hasHistory: Bool) -> String {
        let name = startOfMonth.formatted(Self.monthStyle(calendar))
        if isCurrent {
            let titles = monthFindings().map(\.title)
            if !titles.isEmpty { return titles.joined(separator: " ") }
            let spent = spent(from: startOfMonth, to: now)
            return spent.minorUnits == 0 ? "No spending yet in \(name)." : "\(spent.formatted(fractionDigits: 0)) spent so far in \(name)."
        }
        var sentences: [String] = []
        if let change = finishedMonthChange() {
            let before = calendar.date(byAdding: .month, value: -1, to: startOfMonth)!.formatted(Self.monthStyle(calendar, year: false))
            sentences.append(change == 0 ? "Spending came in about the same as \(before)."
                : "Spending came in \(abs(change))% \(change > 0 ? "above" : "below") \(before).")
        }
        if hasHistory, flex.expectedIncome.minorUnits > 0 {
            sentences.append(flex.safeToSpend.isNegative
                ? "Everyday spending went \(flex.safeToSpend.magnitude.formatted(fractionDigits: 0)) past its budget."
                : "\(flex.safeToSpend.formatted(fractionDigits: 0)) of the everyday budget was left.")
        }
        if !sentences.isEmpty { return sentences.joined(separator: " ") }
        let spent = spent(from: startOfMonth, to: now)
        return spent.minorUnits == 0 ? "No spending in \(name)." : "\(spent.formatted(fractionDigits: 0)) spent in \(name)."
    }

    /// A finished month's spending against the whole month before it, as a percentage change — nil when the ledger
    /// doesn't cover all of that month or it spent nothing. (This month compares against the same point last month:
    /// `monthPace`.)
    private func finishedMonthChange() -> Int? {
        let previous = interval(for: .lastMonth)
        guard covers(from: previous.start) else { return nil }
        let before = spent(from: previous.start, to: previous.end)
        guard before.minorUnits > 0 else { return nil }
        return Self.pct(spent(from: startOfMonth, to: now) - before, of: before)
    }

    /// "September 2026" (or "September") in the ledger's time zone.
    static func monthStyle(_ calendar: Calendar, year: Bool = true) -> Date.FormatStyle {
        var style = year ? Date.FormatStyle.dateTime.month(.wide).year() : Date.FormatStyle.dateTime.month(.wide)
        style.timeZone = calendar.timeZone
        return style
    }

    // MARK: Category history

    /// One spending category's months, this one last, each against today's target, and the average of the complete
    /// months the ledger fully covers.
    func categoryHistory(_ categoryID: String, months count: Int) throws -> CategoryHistory {
        guard let category = category(categoryID) else { throw BudgetAPIError.notFound }
        guard category.countsAsSpending else { throw BudgetAPIError.rejected("\(category.name) isn't spending, so it has no spending history.") }
        let target = monthlyTargets[categoryID]
        let months = recentMonths(min(max(count, 1), Self.historyMonthsLimit))
        var spends: [MonthSpend] = []
        var averaged: [Money] = []
        for month in months {
            let spent = spent(from: month.start, to: month.end, categoryID: categoryID)
            spends.append(MonthSpend(month: month.key, spent: spent, target: target))
            if month.isFullyCovered { averaged.append(spent) }
        }
        return CategoryHistory(categoryID: categoryID, months: spends, averageMonthly: Self.average(averaged), monthsAveraged: averaged.count)
    }

    static let historyMonthsLimit = 36

    // MARK: Cash flow

    /// Income against spending for up to `months` complete months, then this month so far — oldest first.
    func cashFlowHistory(months count: Int = 6) -> [MonthFlow] {
        recentMonths(count + 1).map { month in
            let flow = flow(from: month.start, to: month.end)
            return MonthFlow(month: month.key, income: flow.income, spending: flow.spending, net: flow.net, isPartial: month.isCurrent)
        }
    }
}
