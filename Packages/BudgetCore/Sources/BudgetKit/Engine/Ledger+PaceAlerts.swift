import Foundation

extension Ledger {
    /// This month's pace against the everyday budget, every category target and every merchant cap, and which of them
    /// are past a threshold: 80% of a target or cap used, or on pace to finish the month over it.
    ///
    /// Totals are the ones the rest of the app shows: the everyday budget is safe to spend's (`flexBudget`), a category
    /// is its own bucket's share as the Spending tab and the checkup count it (`budgetTotals`), and a cap is what the
    /// Spending tab lists against it (`merchantSpend`). The pace is the month so far spread over the whole month —
    /// the checkup's "on pace for" — and only from the second week: a projection from three days says little.
    /// Bills and subscriptions land once rather than through the month, so a target in those buckets alerts only once
    /// it's actually over.
    func paceAlerts() -> PaceAlerts {
        let month = interval(for: .thisMonth)
        let days = calendar.range(of: .day, in: .month, for: now)!.count
        let day = calendar.component(.day, from: now)
        var alerts: [PaceAlert] = []

        let flex = flexBudget()
        var everyday: PaceStatus?
        if flex.expectedIncome.minorUnits > 0, flex.flexNumber.minorUnits > 0 {
            let status = Self.paceStatus(spent: flex.flexSpent, limit: flex.flexNumber, day: day, days: days, accrues: true)
            everyday = status
            if let threshold = Self.threshold(status, kind: .everyday, accrues: true) {
                alerts.append(Self.alert(.everyday, threshold, id: "everyday", name: "Everyday", status: status, daysLeft: days - day + 1,
                                         link: .budget))
            }
        }

        let buckets = budgetTotals(from: month.start, to: now, includeTargets: true)
        for group in CategoryGroup.allCases {
            for total in buckets[group] ?? [] where total.isYearly != true {
                guard let target = total.target, target.minorUnits > 0 else { continue }
                // Everyday spending accrues through the month; bills and subscriptions land once.
                let accrues = group == .everyday
                let status = Self.paceStatus(spent: total.spent, limit: target, day: day, days: days, accrues: accrues)
                guard let threshold = Self.threshold(status, kind: .category, accrues: accrues) else { continue }
                alerts.append(Self.alert(.category, threshold, id: total.category.id, name: total.category.name, status: status,
                                         daysLeft: days - day + 1, link: .category(total.category.id)))
            }
        }

        for (merchant, cap) in merchantTargets.sorted(by: { $0.key < $1.key }) where cap.minorUnits > 0 {
            let status = Self.paceStatus(spent: merchantSpend(merchant, from: month.start, to: now).total, limit: cap, day: day, days: days,
                                         accrues: true)
            guard let threshold = Self.threshold(status, kind: .merchant, accrues: true) else { continue }
            alerts.append(Self.alert(.merchant, threshold, id: merchant, name: merchant, status: status, daysLeft: days - day + 1,
                                     link: .merchant(merchant)))
        }

        alerts.sort { a, b in
            if a.threshold.rank != b.threshold.rank { return a.threshold.rank > b.threshold.rank }
            if a.kind != b.kind { return Self.kindOrder(a.kind) < Self.kindOrder(b.kind) }
            if a.status.usedPercent != b.status.usedPercent { return a.status.usedPercent > b.status.usedPercent }
            return a.targetID < b.targetID
        }
        return PaceAlerts(month: monthKey(now), day: day, daysInMonth: days, projecting: day >= PaceAlerts.firstProjectingDay,
                          everyday: everyday, alerts: alerts)
    }

    private static func kindOrder(_ kind: PaceAlert.Kind) -> Int { PaceAlert.Kind.allCases.firstIndex(of: kind) ?? 9 }

    // MARK: The arithmetic

    /// One target's month so far on day `day` of `days`. A total that `accrues` is projected at its pace so far; one
    /// that lands once is projected at what it is.
    static func paceStatus(spent: Money, limit: Money, day: Int, days: Int, accrues: Bool) -> PaceStatus {
        let projected: Money? = day >= PaceAlerts.firstProjectingDay
            ? (accrues ? Money(minorUnits: Int64((Double(spent.minorUnits) * Double(days) / Double(max(day, 1))).rounded())) : spent)
            : nil
        let left = limit - spent
        let daysLeft = Int64(max(days - day + 1, 1))
        return PaceStatus(spent: spent, limit: limit, projected: projected,
                          perDayLeft: left.minorUnits > 0 ? Money(minorUnits: left.minorUnits / daysLeft) : nil,
                          usedPercent: pct(spent, of: limit))
    }

    /// The highest threshold `status` is past, or nil. Over by any whole dollar counts; on pace to finish over counts
    /// from $10 or 2% of the limit, whichever is more, so a projection a few dollars over doesn't ring the phone. The
    /// everyday budget alerts only on its pace (safe to spend already shows how much is used); a bill's target, only
    /// once it's over.
    static func threshold(_ status: PaceStatus, kind: PaceAlert.Kind, accrues: Bool) -> PaceAlert.Threshold? {
        if let over = status.over, over.minorUnits >= 100 { return .projectedOver }
        if accrues, let over = status.projectedOver, over.minorUnits >= max(1_000, status.limit.minorUnits / 50) { return .projectedOver }
        if kind != .everyday, accrues, status.spent.minorUnits * 100 >= status.limit.minorUnits * 80 { return .used80 }
        return nil
    }

    /// The alert with its words: what's happened, then what keeps it on track.
    static func alert(_ kind: PaceAlert.Kind, _ threshold: PaceAlert.Threshold, id: String, name: String, status: PaceStatus, daysLeft: Int,
                      link: Checkup.Link) -> PaceAlert {
        let limitWord = kind == .merchant ? "cap" : "target"
        let keeps = kind == .everyday ? "keeps you on budget" : kind == .merchant ? "keeps it under the cap" : "keeps it on target"
        let left = daysLeft <= 1 ? "on the last day of the month" : "with \(daysLeft) days left"
        let perDay = status.perDayLeft.map { " \(amount($0))/day \(keeps)." } ?? ""
        let title: String
        let body: String
        switch (threshold, status.over) {
        case let (.projectedOver, over?):
            if kind == .everyday {
                title = "Everyday is over budget"
                body = "Everyday spending is \(amount(over)) past this month's \(amount(status.limit)) budget, \(left)."
            } else {
                title = "\(name) is over its \(limitWord)"
                body = "\(name) is \(amount(over)) past its \(amount(status.limit)) \(limitWord), \(left)."
            }
        case (.projectedOver, nil):
            let over = status.projectedOver ?? .zero
            if kind == .everyday {
                title = "Everyday is on pace to go over"
                body = "Everyday is on pace to finish about \(approximately(over)) over.\(perDay)"
            } else {
                title = "\(name) is on pace to go over"
                body = "\(name) is on pace to finish about \(approximately(over)) over its \(amount(status.limit)) \(limitWord).\(perDay)"
            }
        default:
            title = "\(name): \(status.usedPercent)% of its \(limitWord)"
            body = "\(name) has used \(amount(status.spent)) of its \(amount(status.limit)) \(limitWord), \(left).\(perDay)"
        }
        return PaceAlert(kind: kind, threshold: threshold, targetID: id, name: name, status: status, title: title, body: body, link: link)
    }

    /// "about $220": to the $10 from $100, whole dollars below.
    static func approximately(_ money: Money) -> String {
        guard money.minorUnits >= 10_000 else { return Money(minorUnits: (money.minorUnits + 50) / 100 * 100).formatted(fractionDigits: 0) }
        return Money(minorUnits: (money.minorUnits + 500) / 1_000 * 1_000).formatted(fractionDigits: 0)
    }
}
