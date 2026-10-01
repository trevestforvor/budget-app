import Foundation

extension Ledger {
    /// The whole picture at once: this month's pace, categories against targets, merchants and caps,
    /// recurring charges, unusual transactions, saving, the cash outlook and data health.
    func checkup(institutions: [InstitutionLink] = []) -> Checkup {
        let sections = [monthSection(), categorySection(), merchantSection(), recurringSection(), unusualSection(),
                        savingSection(), outlookSection(), dataSection(institutions: institutions)]
            .filter { !$0.findings.isEmpty }
        var checkup = Checkup(asOf: now, headline: "", sections: sections)
        let (act, watch, _) = checkup.counts
        checkup.headline = act + watch == 0
            ? "Everything checks out."
            : [act > 0 ? "\(act) thing\(act == 1 ? "" : "s") to act on" : nil, watch > 0 ? "\(watch) to watch" : nil]
                .compactMap { $0 }.joined(separator: ", ") + "."
        return checkup
    }

    private var monthProgress: (day: Int, days: Int, fraction: Double) {
        let days = calendar.range(of: .day, in: .month, for: now)!.count
        let day = calendar.component(.day, from: now)
        return (day, days, Double(day) / Double(days))
    }

    /// Whole months since the first transaction (0 = less than a month).
    var historyMonths: Int {
        guard let first = transactions.map(\.postedAt).min() else { return 0 }
        return max(calendar.dateComponents([.month], from: first, to: now).month ?? 0, 0)
    }

    private static func money(_ minor: Double) -> Money { Money(minorUnits: Int64(minor.rounded())) }
    static func pct(_ part: Money, of whole: Money) -> Int {
        whole.minorUnits == 0 ? 0 : Int((Double(part.minorUnits) / Double(whole.minorUnits) * 100).rounded())
    }

    // MARK: Sections

    private func monthSection() -> Checkup.Section {
        .init(id: "month", title: "This month", symbol: "calendar", findings: monthFindings())
    }

    /// This month so far against the same point last month (the same number of days in), when last month spent anything.
    /// Yearly charges are left out of both: they're set aside over the year, so one landing this month isn't a faster
    /// pace. `leftOutYearly` says whether either month had any.
    func monthPace() -> (soFar: Money, before: Money, change: Int, leftOutYearly: Bool)? {
        let month = interval(for: .thisMonth)
        guard let previous = previousInterval(for: .thisMonth) else { return nil }
        let yearly = yearlyIDs
        let samePoint = calendar.date(byAdding: .day, value: monthProgress.day, to: previous.start) ?? previous.end
        let thisMonth = transactions(from: month.start, to: now)
        let lastMonth = transactions(from: previous.start, to: min(samePoint, previous.end))
        let soFar = netSpend(thisMonth.filter { !yearly.contains($0.id) })
        let before = netSpend(lastMonth.filter { !yearly.contains($0.id) })
        guard before.minorUnits > 0 else { return nil }
        let leftOut = (thisMonth + lastMonth).contains { yearly.contains($0.id) && isCounted($0) }
        return (soFar, before, Self.pct(soFar - before, of: before), leftOut)
    }

    /// The month's pace and safe to spend — the checkup's first section, and the budget month's summary.
    func monthFindings() -> [Checkup.Finding] {
        var findings: [Checkup.Finding] = []
        let progress = monthProgress
        if let pace = monthPace() {
            findings.append(.init(id: "month-pace", status: pace.change > 15 ? .watch : .good,
                                  title: pace.change >= 0 ? "Spending is \(pace.change)% ahead of this point last month." : "Spending is \(-pace.change)% behind this point last month.",
                                  detail: "Day \(progress.day) of \(progress.days).\(pace.leftOutYearly ? " Yearly charges are left out: they're set aside over the year." : "")",
                                  metrics: [.init("So far this month", money: pace.soFar), .init("Same point last month", money: pace.before)], suggestion: nil,
                                  link: .budget))
        }
        let flex = flexBudget()
        if flex.expectedIncome.minorUnits > 0 {
            let status: Checkup.Status = flex.safeToSpend.isNegative ? .act
                : flex.safeToSpend.minorUnits < flex.flexNumber.minorUnits / 10 ? .watch : .good
            findings.append(.init(id: "safe-to-spend", status: status,
                                  title: flex.safeToSpend.isNegative ? "Everyday spending is past this month's room."
                                      : "\(flex.safeToSpend.formatted(fractionDigits: 0)) is safe to spend for the rest of the month.",
                                  detail: "From \(flex.expectedIncome.formatted(fractionDigits: 0)) of income, \(flex.incomeSourcePhrase)\(flex.incomeSource == .recentPaychecks ? " (lower than the last 3 months' average, \((flex.averageIncome ?? .zero).formatted(fractionDigits: 0)))" : ""), after bills, subscriptions and \(flex.plannedSavings.formatted(fractionDigits: 0)) saved first.",
                                  metrics: [.init("Safe to spend", money: flex.safeToSpend), .init("Everyday budget", money: flex.flexNumber),
                                            .init("Everyday spent", money: flex.flexSpent), .init("Days left", text: "\(flex.daysLeftIncludingToday)")],
                                  suggestion: status == .good ? nil : "Where can I cut back for the rest of the month?", link: .budget))
        }
        return findings
    }

    private func categorySection() -> Checkup.Section {
        var findings: [Checkup.Finding] = []
        let month = interval(for: .thisMonth)
        let progress = monthProgress
        // As the Spending tab counts them: a category's target against its own bucket's share of it (a gym on the
        // recurring list isn't Health's everyday spending), a charge spread over the year at its twelfth.
        let buckets = budgetTotals(from: month.start, to: now, includeTargets: true)
        let entries = CategoryGroup.allCases.flatMap { group in (buckets[group] ?? []).map { (group: group, total: $0) } }
        let targeted = entries.filter { $0.total.target != nil }.sorted { $0.total.spent > $1.total.spent }
        for (group, total) in targeted {
            guard let target = total.target, target.minorUnits > 0 else { continue }
            // Everyday spending accrues through the month; bills and subscriptions land once.
            let projected = group == .everyday && progress.fraction > 0.1
                ? Self.money(Double(total.spent.minorUnits) / progress.fraction) : total.spent
            if total.spent > target {
                // A few dollars over is worth watching; well over is worth acting on.
                let over = total.spent - target
                let serious = over.minorUnits > max(2_500, target.minorUnits / 10)
                findings.append(.init(id: "over-\(total.category.id)", status: serious ? .act : .watch,
                                      title: "\(total.category.name) is over its target: \(total.spent.formatted(fractionDigits: 0)) of \(target.formatted(fractionDigits: 0)).",
                                      detail: nil, metrics: [.init("Spent", money: total.spent), .init("Target", money: target)],
                                      suggestion: "Why is \(total.category.name.lowercased()) over this month?", link: .category(total.category.id)))
            } else if projected > target {
                findings.append(.init(id: "pace-\(total.category.id)", status: .watch,
                                      title: "\(total.category.name) is on pace for \(projected.formatted(fractionDigits: 0)) against \(target.formatted(fractionDigits: 0)).",
                                      detail: "\(Self.pct(total.spent, of: target))% used, \(FlexBudget.daysLeftPhrase(progress.days - progress.day + 1).lowercased()).",
                                      metrics: [.init("Spent", money: total.spent), .init("On pace for", money: projected), .init("Target", money: target)],
                                      suggestion: nil, link: .category(total.category.id)))
            }
        }
        // Real everyday spending with no target to judge it against (bills and subscriptions don't need one).
        let untargeted = (buckets[.everyday] ?? []).filter { $0.target == nil && $0.isYearly != true && $0.spent.minorUnits >= 10_000 }
        if !untargeted.isEmpty {
            findings.append(.init(id: "no-targets", status: .watch,
                                  title: "\(untargeted.map(\.category.name).spokenList) \(untargeted.count == 1 ? "has" : "have") no target.",
                                  detail: "A target turns these into something the checkup can judge.",
                                  metrics: untargeted.map { .init($0.category.name, money: $0.spent, link: .category($0.category.id)) },
                                  suggestion: "Suggest targets for \(untargeted.map { $0.category.name.lowercased() }.spokenList) from my last three months."))
        }
        let shown = entries.map(\.total).filter { $0.isYearly != true }.sorted { $0.spent > $1.spent }
        if findings.isEmpty, !shown.isEmpty {
            findings.append(.init(id: "categories-ok", status: .good, title: "Every category with a target is on track.", detail: nil,
                                  metrics: shown.prefix(4).map { .init($0.category.name, money: $0.spent, link: .category($0.category.id)) }, suggestion: nil))
        }
        return .init(id: "categories", title: "Categories", symbol: "chart.pie", findings: findings)
    }

    private func merchantSection() -> Checkup.Section {
        var findings: [Checkup.Finding] = []
        let month = interval(for: .thisMonth)
        for (merchant, cap) in merchantTargets.sorted(by: { $0.key < $1.key }) {
            let spend = merchantSpend(merchant, from: month.start, to: now).total
            let used = Self.pct(spend, of: cap)
            guard used >= 80 else { continue }
            findings.append(.init(id: "cap-\(merchant)", status: used > 100 ? .act : .watch,
                                  title: used > 100 ? "\(merchant) is past its cap: \(spend.formatted(fractionDigits: 0)) of \(cap.formatted(fractionDigits: 0))."
                                                    : "\(merchant) has used \(used)% of its cap.",
                                  detail: nil, metrics: [.init("Spent", money: spend), .init("Cap", money: cap)], suggestion: nil, link: .merchant(merchant)))
        }
        let rows = transactions(from: month.start, to: now).filter { $0.amount.isNegative && (category($0.categorization?.categoryID ?? "")?.countsAsSpending ?? true) }
        let byMerchant = Dictionary(grouping: rows, by: \.merchant).mapValues { $0.map(\.amount.magnitude).sum() }
        let top = byMerchant.sorted { $0.value > $1.value }.prefix(5)
        if !top.isEmpty {
            findings.append(.init(id: "top-merchants", status: .good, title: "Where the month's money went.", detail: nil,
                                  metrics: top.map { .init($0.key, money: $0.value, link: .merchant($0.key)) }, suggestion: nil))
        }
        // First-ever charges this month.
        let earlier = Set(transactions.filter { $0.postedAt < month.start && !$0.isHidden }.map(\.merchant))
        let newcomers = Dictionary(grouping: rows.filter { !earlier.contains($0.merchant) }, by: \.merchant).mapValues { $0.map(\.amount.magnitude).sum() }
        if !newcomers.isEmpty, !earlier.isEmpty {
            findings.append(.init(id: "new-merchants", status: .good,
                                  title: "\(newcomers.count) new merchant\(newcomers.count == 1 ? "" : "s") this month.", detail: nil,
                                  metrics: newcomers.sorted { $0.value > $1.value }.prefix(5).map { .init($0.key, money: $0.value, link: .merchant($0.key)) },
                                  suggestion: nil))
        }
        return .init(id: "merchants", title: "Merchants", symbol: "storefront", findings: findings)
    }

    private func recurringSection() -> Checkup.Section {
        let found = subscriptions()
        let active = found.items.filter { $0.status == .active }
        guard !active.isEmpty else { return .init(id: "recurring", title: "Recurring", symbol: "repeat", findings: []) }
        var findings: [Checkup.Finding] = []
        let subs = active.filter { $0.kind == .subscription }
        if !subs.isEmpty {
            findings.append(.init(id: "recurring-total", status: .good,
                                  title: "\(subs.count) subscription\(subs.count == 1 ? "" : "s"), about \(found.subscriptionsMonthly.formatted(fractionDigits: 0)) a month.",
                                  detail: "Plus \(found.billsMonthly.formatted(fractionDigits: 0)) a month in bills. Found from repeat charges, not a list you keep.",
                                  metrics: subs.prefix(8).map { .init($0.merchant, money: $0.monthlyCost) },
                                  suggestion: "Which of my subscriptions could I cancel?", link: .recurring))
        }
        for charge in active where charge.previousAmount.map({ charge.amount.minorUnits > $0.minorUnits + max(50, $0.minorUnits / 20) }) ?? false {
            findings.append(.init(id: "raised-\(charge.merchant)", status: .watch,
                                  title: "\(charge.merchant) went up from \(charge.previousAmount!.formatted()) to \(charge.amount.formatted()).",
                                  detail: nil, metrics: [.init("Before", money: charge.previousAmount!), .init("Now", money: charge.amount)], suggestion: nil,
                                  link: .recurring))
        }
        return .init(id: "recurring", title: "Recurring", symbol: "repeat", findings: findings)
    }

    private func unusualSection() -> Checkup.Section {
        var findings: [Checkup.Finding] = []
        let recent = transactions(from: calendar.date(byAdding: .day, value: -30, to: now)!, to: now).filter { $0.amount.isNegative }
        let history = transactions(from: calendar.date(byAdding: .month, value: -6, to: now)!, to: calendar.date(byAdding: .day, value: -30, to: now)!)
        let typical = Dictionary(grouping: history.filter(\.amount.isNegative), by: \.merchant).mapValues { rows -> Money in
            let sorted = rows.map(\.amount.magnitude.minorUnits).sorted()
            return Money(minorUnits: sorted[sorted.count / 2])
        }
        // A yearly charge is expected and set aside for, not unusual.
        let yearly = yearlyIDs
        for row in recent where !yearly.contains(row.id) {
            let amount = row.amount.magnitude
            guard amount.minorUnits >= 10_000, category(row.categorization?.categoryID ?? "")?.countsAsSpending ?? true else { continue }
            if let median = typical[row.merchant], median.minorUnits > 0, amount.minorUnits >= median.minorUnits * 3 {
                findings.append(.init(id: "unusual-\(row.id)", status: .watch,
                                      title: "\(row.merchant): \(amount.formatted()) is \(amount.minorUnits / median.minorUnits)× its usual.",
                                      detail: row.postedAt.formatted(date: .abbreviated, time: .omitted),
                                      metrics: [.init("This charge", money: amount), .init("Usual", money: median)], suggestion: nil,
                                      link: .transaction(row.id)))
            } else if typical[row.merchant] == nil, amount.minorUnits >= 25_000, historyMonths >= 2 {
                findings.append(.init(id: "large-\(row.id)", status: .watch,
                                      title: "A first \(row.merchant) charge of \(amount.formatted()).",
                                      detail: row.postedAt.formatted(date: .abbreviated, time: .omitted),
                                      metrics: [.init("Charge", money: amount)], suggestion: nil, link: .transaction(row.id)))
            }
        }
        findings.sort { ($0.metrics.first?.money ?? .zero) > ($1.metrics.first?.money ?? .zero) }
        return .init(id: "unusual", title: "Unusual", symbol: "exclamationmark.magnifyingglass", findings: Array(findings.prefix(5)))
    }

    private func savingSection() -> Checkup.Section {
        var findings: [Checkup.Finding] = []
        // Capacity, the savings plan and the cushion average complete months; with fewer than two they'd
        // divide by almost nothing (a 259-month "cushion"). The data section already says history is short.
        guard historyMonths >= 2 else {
            return .init(id: "saving", title: "Saving", symbol: "banknote", findings: cashAccountIDs.isEmpty
                ? [.init(id: "no-cash-accounts", status: .watch, title: "No checking or savings account yet, so the cash cushion can't be measured.",
                         detail: "Link or import one on the Budget dashboard.", metrics: [], suggestion: nil, link: .accounts)] : [])
        }
        let c = capacity()
        let g = guidance()
        if c.income.minorUnits > 0 {
            let flex = flexBudget()
            if flex.plannedSavingsIsSet {
                let planned = flex.plannedSavings
                findings.append(planned > c.typical
                    ? .init(id: "plan-too-high", status: .watch,
                            title: "The \(planned.formatted(fractionDigits: 0)) savings plan is more than a typical month leaves (\(c.typical.formatted(fractionDigits: 0))).",
                            detail: nil, metrics: [.init("Planned", money: planned), .init("Typical room", money: c.typical)],
                            suggestion: "What savings amount fits my last three months?", link: .plan)
                    : .init(id: "plan-ok", status: .good, title: "Saving \(planned.formatted(fractionDigits: 0)) a month fits a typical month.",
                            detail: "A typical month leaves \(c.typical.formatted(fractionDigits: 0)).",
                            metrics: [.init("Planned", money: planned), .init("Typical room", money: c.typical)], suggestion: nil, link: .plan))
            } else if c.alreadySaving.minorUnits > 0 {
                findings.append(.init(id: "saving-unplanned", status: .watch,
                                      title: "You move about \(c.alreadySaving.formatted(fractionDigits: 0)) a month to savings, but it isn't set as a plan.",
                                      detail: "Setting it takes it off the top of safe-to-spend. A typical month leaves \(c.typical.formatted(fractionDigits: 0)).",
                                      metrics: [.init("Moving to savings", money: c.alreadySaving), .init("Typical room", money: c.typical)],
                                      suggestion: "Set aside \(c.alreadySaving.formatted(fractionDigits: 0)) a month", link: .plan))
            } else {
                findings.append(.init(id: "no-plan", status: .watch, title: "Nothing is going to savings, and no plan is set.",
                                      detail: "A typical month leaves \(c.typical.formatted(fractionDigits: 0)); 20% of take-home is \(g.twentyPercent.formatted(fractionDigits: 0)).",
                                      metrics: [.init("Typical room", money: c.typical), .init("20% of take-home", money: g.twentyPercent)],
                                      suggestion: "Set aside \(min(c.typical, g.twentyPercent).formatted(fractionDigits: 0)) a month", link: .plan))
            }
        }
        if cashAccountIDs.isEmpty {
            findings.append(.init(id: "no-cash-accounts", status: .watch, title: "No checking or savings account yet, so the cash cushion can't be measured.",
                                  detail: "Link or import one on the Budget dashboard.", metrics: [], suggestion: nil, link: .accounts))
        } else if c.essentialMonthly.minorUnits > 0 {
            let months = c.emergencyMonths
            findings.append(.init(id: "cushion", status: months < 3 ? .act : months < 6 ? .watch : .good,
                                  title: String(format: "Cash covers %.1f months of essentials.", months),
                                  detail: months < 6 ? "3–6 months is the usual cushion; \(g.gapToThree.minorUnits > 0 ? "\(g.gapToThree.formatted(fractionDigits: 0)) reaches three" : "\(g.gapToSix.formatted(fractionDigits: 0)) reaches six")." : nil,
                                  metrics: [.init("Cash", money: c.cashOnHand), .init("Essentials a month", money: c.essentialMonthly), .init("Six months", money: g.sixMonths)],
                                  suggestion: months < 6 ? "How long would it take to build six months of essentials?" : nil, link: .plan))
        }
        return .init(id: "saving", title: "Saving", symbol: "banknote", findings: findings)
    }

    private func outlookSection() -> Checkup.Section {
        guard historyMonths >= 2, !cashAccountIDs.isEmpty else { return .init(id: "outlook", title: "Outlook", symbol: "chart.line.uptrend.xyaxis", findings: []) }
        let plan = projection(horizonMonths: 6, goal: nil)
        let negative = plan.monthlyNet.isNegative
        // The three months the pace averages (the projection's own), oldest first, each shown: an average over income
        // reads as every month over, when it's often one big month.
        let names = (1...3).reversed().map { back in
            calendar.date(byAdding: .month, value: -back, to: startOfMonth)!.formatted(Self.monthStyle(calendar, year: false))
        }
        let months = Array(zip(names, spendingNets(count: 3).reversed()))
        let over = months.filter { $0.1.isNegative }
        let span = "\(names[0]) to \(names[2])"
        let pace = plan.monthlyNet.magnitude.formatted(fractionDigits: 0)
        let which: String? = switch over.count {
        case 1: "Only \(over[0].0) ran over, by \(over[0].1.magnitude.formatted(fractionDigits: 0)); the other two came out ahead."
        case 2: "\(over.map(\.0).spokenList) ran over; \(months.first { !$0.1.isNegative }!.0) came out ahead."
        default: nil
        }
        let finding = Checkup.Finding(id: "outlook", status: negative ? .watch : .good,
                                      title: negative ? "From \(span), spending ran about \(pace) a month over income."
                                                      : "From \(span), income beat spending by about \(pace) a month.",
                                      detail: [which, "At that pace, cash after cards is about \(plan.endBalance.formatted(fractionDigits: 0)) in six months."]
                                          .compactMap { $0 }.joined(separator: " "),
                                      metrics: months.map { .init($0.0, money: $0.1) } + [.init("In six months", money: plan.endBalance)],
                                      suggestion: !negative ? nil
                                          : over.count == 1 ? "Why did I spend more than came in during \(over[0].0)?" : "Where is my spending running over income?",
                                      link: .plan)
        return .init(id: "outlook", title: "Outlook", symbol: "chart.line.uptrend.xyaxis", findings: [finding])
    }

    private func dataSection(institutions: [InstitutionLink]) -> Checkup.Section {
        var findings: [Checkup.Finding] = []
        let waiting = reviewItems
        if !waiting.isEmpty {
            findings.append(.init(id: "review", status: .watch,
                                  title: ReviewGroup.headline(decisions: ReviewGroup.groups(waiting).count, transactions: waiting.count),
                                  detail: "Each has a best guess until you answer, so the numbers above may put some in the wrong place.",
                                  metrics: [], suggestion: nil, link: .review))
        }
        // Hidden rows are the person's call, but a total they're left out of should say so.
        let month = interval(for: .thisMonth)
        let hidden = transactions.filter { $0.isHidden && $0.postedAt >= month.start && $0.postedAt < now }
        if !hidden.isEmpty {
            let out = hidden.filter(\.amount.isNegative).map(\.amount.magnitude).sum()
            let moneyIn = hidden.filter { !$0.amount.isNegative }.map(\.amount).sum()
            var metrics: [Checkup.Metric] = []
            if out.minorUnits > 0 { metrics.append(.init("Money out hidden", money: out)) }
            if moneyIn.minorUnits > 0 { metrics.append(.init("Money in hidden", money: moneyIn)) }
            findings.append(.init(id: "hidden", status: .good,
                                  title: "\(hidden.count) transaction\(hidden.count == 1 ? " is" : "s are") hidden from this month's totals.",
                                  detail: "They still count in your balances.", metrics: metrics, suggestion: nil))
        }
        // Connections to sign in to again, accounts gone quiet, an empty ledger: the same list Home's attention shows.
        findings += dataHealth(institutions: institutions).map { item in
            .init(id: item.id, status: item.kind == .stale ? .watch : .act, title: item.title, detail: item.detail, metrics: [], suggestion: nil,
                  link: .accounts)
        }
        let months = historyMonths
        if !transactions.isEmpty, months < 3 {
            findings.append(.init(id: "short-history", status: .watch,
                                  title: months == 0 ? "Less than a month of history." : "Only \(months) month\(months == 1 ? "" : "s") of history.",
                                  detail: "Averages, recurring charges, unusual-charge checks and the outlook firm up after two to three months.",
                                  metrics: [], suggestion: nil, link: .accounts))
        }
        return .init(id: "data", title: "Data", symbol: "checklist", findings: findings)
    }
}
