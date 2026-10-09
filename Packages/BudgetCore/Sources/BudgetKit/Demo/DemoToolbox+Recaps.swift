import Foundation

/// The read tools behind the recurring review and the monthly recap.
extension DemoToolbox {
    /// `recurringReview`: "Is this recurring?" and "Did this stop?", as the Recurring screen asks them.
    func recurringReview() -> (result: JSONValue, figures: [Figure]) {
        let review = ledger.recurringReview()
        var figures: [Figure] = []
        func item(_ s: Subscription) -> JSONValue {
            figures.append(Figure(id: "review-\(s.merchant)", label: s.merchant, detail: s.cadence.rawValue, value: s.amount))
            return .object(["merchant": .string(s.merchant), "kind": .string(s.kind.rawValue), "cadence": .string(s.cadence.rawValue),
                            "amount": .string(s.amount.display), "timesCharged": .number(Double(s.charges)),
                            "lastCharged": .string(day(s.lastCharged)), "nextExpected": .string(day(s.nextExpected))])
        }
        return (.object([
            "mightBeRecurring": .array(review.candidates.map(item)),
            "mightHaveStopped": .array(review.maybeStopped.map(item)),
            "markedStopped": .array((review.ended ?? []).map(JSONValue.string)),
            "note": .string("mightBeRecurring: repeat charges not on the recurring list yet; the user confirms or dismisses them on the Recurring screen. mightHaveStopped: recurring charges with no charge for about a cycle and a half; the user says whether they canceled. Only the user answers these, in the app."),
        ]), figures)
    }

    /// `monthlyRecap`: a finished month — income, spending, what was left, each bucket against its budget, the categories
    /// that moved most, and the change in cash.
    func monthlyRecap(month: String?) throws -> (result: JSONValue, figures: [Figure]) {
        let recap = try ledger.monthlyRecap(month)
        let name = ledger.monthStart(recap.month).map { $0.formatted(Ledger.monthStyle(ledger.calendar)) } ?? recap.month
        var figures = [Figure(id: "recap-income", label: "Income · \(name)", detail: nil, value: recap.income),
                       Figure(id: "recap-spending", label: "Spending · \(name)", detail: nil, value: recap.spending),
                       Figure(id: "recap-saved", label: recap.saved.isNegative ? "Spent past income" : "Left over", detail: nil, value: recap.saved.magnitude),
                       Figure(id: "recap-moved", label: "Moved to savings", detail: nil, value: recap.movedToSavings),
                       Figure(id: "recap-cash", label: "Change in cash", detail: nil, value: recap.cashChange)]
        var o: [String: JSONValue] = [
            "month": .string(name), "income": .string(recap.income.display), "spending": .string(recap.spending.display),
            "leftOver": .string(recap.saved.display), "movedToSavings": .string(recap.movedToSavings.display),
            "cashChange": .string(recap.cashChange.display), "summary": .string(recap.summary),
            "buckets": .array(recap.buckets.map { b in
                figures.append(Figure(id: "recap-\(b.group.rawValue)", label: "\(b.group.label) · \(name)", detail: nil, value: b.spent))
                var bucket: [String: JSONValue] = ["bucket": .string(b.group.label), "spent": .string(b.spent.display)]
                if let planned = b.planned {
                    bucket["budget"] = .string(planned.display)
                    figures.append(Figure(id: "recap-\(b.group.rawValue)-budget", label: "\(b.group.label) budget · \(name)", detail: nil, value: planned))
                    if let over = b.overBy {
                        bucket[over.isNegative ? "under" : "over"] = .string(over.magnitude.display)
                        figures.append(Figure(id: "recap-\(b.group.rawValue)-diff", label: "\(b.group.label) \(over.isNegative ? "under" : "over")", detail: nil, value: over.magnitude))
                    }
                }
                return .object(bucket)
            }),
            "biggestChanges": .array(recap.categoryChanges.map { c in
                figures.append(Figure(id: "recap-change-\(c.categoryID)", label: "\(c.name) change", detail: nil, value: c.change.magnitude))
                figures.append(Figure(id: "recap-before-\(c.categoryID)", label: "\(c.name) the month before", detail: nil, value: c.previous))
                figures.append(Figure(id: "recap-now-\(c.categoryID)", label: c.name, detail: nil, value: c.spent))
                return .object(["category": .string(c.name), "spent": .string(c.spent.display), "monthBefore": .string(c.previous.display),
                                "change": .string((c.change.isNegative ? "down " : "up ") + c.change.magnitude.display)])
            }),
        ]
        if let change = recap.netWorthChange {
            o["netWorthChange"] = .string(change.display)
            figures.append(Figure(id: "recap-networth", label: "Change in net worth", detail: nil, value: change))
        }
        if !recap.hasBudget { o["note"] = .string("The ledger didn't have three full months before this one, so there's no budget to compare against.") }
        return (.object(o), figures)
    }

    private func day(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: ledger.calendar.timeZone).year().month().day())
    }
}
