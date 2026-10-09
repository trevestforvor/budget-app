import Foundation

extension Ledger {
    /// A month of pay, from the latest paychecks.
    struct Paychecks: Equatable {
        /// Paydays in a month: 4 weekly, 2 every two weeks or twice a month, 1 monthly.
        var perMonth: Int
        /// The latest `perMonth` paydays, oldest first, each the sum of its deposits.
        var latest: [Money]
        var total: Money { latest.sum() }
    }

    /// The latest paychecks that make a month: two every two weeks or twice a month, one monthly, four weekly. A
    /// paycheck is income of $100 or more filed under Income in the last 120 days, its parts landing in different
    /// accounts within three days counting as one (so it doesn't matter what the bank named each part), and paydays have
    /// to keep a regular cadence. Interest is too small to count; a deposit well between paydays (a bonus, a
    /// reimbursement) isn't a payday. Nil when no regular pay shows.
    func recentPaychecks() -> Paychecks? {
        guard let history = paydayHistory() else { return nil }
        return Paychecks(perMonth: history.perMonth, latest: history.paydays.suffix(history.perMonth).map(\.amount))
    }

    /// Paydays as `recentPaychecks` reads them: the regular ones in the last 120 days, oldest first, each the sum of
    /// its deposits, with the median gap between deposits (days) and how many make a month. Nil when no regular pay
    /// shows. Upcoming income predicts from the same paydays (`PaySchedule`).
    func paydayHistory() -> (paydays: [(date: Date, amount: Money)], medianGap: Double, perMonth: Int)? {
        let since = calendar.date(byAdding: .day, value: -120, to: now)!
        let deposits = transactions.filter { row in
            row.postedAt >= since && row.postedAt <= now && !row.isPending && !row.isHidden && !row.amount.isNegative
                && row.amount.minorUnits >= 10_000 && row.categorization?.categoryID == BudgetCategory.incomeID
        }.sorted { $0.postedAt < $1.postedAt }
        var days: [(date: Date, amount: Money)] = []
        for row in deposits {
            if let last = days.last, row.postedAt.timeIntervalSince(last.date) < 3 * 86_400 {
                days[days.count - 1].amount = last.amount + row.amount
            } else {
                days.append((row.postedAt, row.amount))
            }
        }
        guard days.count >= 3 else { return nil }
        let gaps = zip(days.dropFirst(), days).map { $0.date.timeIntervalSince($1.date) / 86_400 }
        let median = gaps.sorted()[gaps.count / 2]
        let perMonth: Int
        switch median {
        case 5...9: perMonth = 4
        case 12...17: perMonth = 2
        case 26...35: perMonth = 1
        default: return nil
        }
        // Regular: most gaps land near the cadence.
        guard Double(gaps.filter { abs($0 - median) <= max(median * 0.2, 3) }.count) >= Double(gaps.count) * 0.6 else { return nil }
        var paydays: [(date: Date, amount: Money)] = []
        for day in days {
            if let last = paydays.last, day.date.timeIntervalSince(last.date) / 86_400 < median * 0.7 { continue }
            paydays.append(day)
        }
        guard paydays.count >= perMonth else { return nil }
        return (paydays, median, perMonth)
    }

    /// The income the budget counts on this month: the last three months' average, or a month of the latest paychecks
    /// when that's lower — so a month with a third biweekly paycheck, a bonus or a refund in the average doesn't pass
    /// for what comes in every month.
    func expectedIncome(average: Money) -> (amount: Money, source: FlexBudget.IncomeSource, paychecks: Paychecks?) {
        let paychecks = recentPaychecks()
        guard let paychecks, paychecks.total.minorUnits > 0, paychecks.total < average else { return (average, .threeMonthAverage, paychecks) }
        return (paychecks.total, .recentPaychecks, paychecks)
    }
}
