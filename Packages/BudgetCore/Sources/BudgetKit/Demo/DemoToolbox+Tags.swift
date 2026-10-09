import Foundation

extension DemoToolbox {
    /// One tag's totals and spending by category, or every tag's totals, by the Spending tab's rules.
    func sumByTag(_ tag: String?, period: String?) throws -> (result: JSONValue, figures: [Figure]) {
        let label = try period.map { p -> String in
            guard let w = ledger.interval(forPeriod: p) else { throw BudgetAPIError.rejected("Unknown period “\(p)”.") }
            return w.label
        } ?? "all time"
        let day = Date.ISO8601FormatStyle(timeZone: ledger.calendar.timeZone).year().month().day()
        func fields(_ s: TagSummary) -> [String: JSONValue] {
            var o: [String: JSONValue] = ["tag": .string(s.tag), "transactions": .number(Double(s.count)),
                                          "spent": .string(s.spent.display), "income": .string(s.income.display)]
            if let first = s.earliest { o["first"] = .string(first.formatted(day)) }
            if let last = s.latest { o["last"] = .string(last.formatted(day)) }
            return o
        }
        guard let tag else {
            let all = try ledger.tagSummaries(period: period)
            return (.object(["period": .string(label), "count": .number(Double(all.count)), "tags": .array(all.map { .object(fields($0)) })]),
                    all.map { Figure(id: "tag-\($0.id)", label: "\($0.tag) · \(label)", detail: "Net of refunds", value: $0.spent) })
        }
        let summary: TagSummary
        do {
            summary = try ledger.tagSummary(tag, period: period)
        } catch BudgetAPIError.notFound {
            let known = try ledger.tagSummaries().map(\.tag)
            var o: [String: JSONValue] = ["tag": .string(tag), "found": .bool(false), "note": .string("No transactions carry this tag.")]
            if !known.isEmpty { o["tagsInUse"] = .array(known.prefix(20).map(JSONValue.string)) }
            return (.object(o), [])
        }
        var o = fields(summary)
        o["period"] = .string(label)
        o["spentIs"] = .string("spending net of refunds; hidden transactions and transfers left out")
        o["byCategory"] = .array((summary.byCategory ?? []).map {
            .object(["id": .string($0.categoryID), "name": .string(ledger.category($0.categoryID)?.name ?? $0.categoryID), "spent": .string($0.spent.display)])
        })
        var figures = [Figure(id: "tag-spent", label: "\(summary.tag) · \(label)", detail: "\(summary.count) transaction\(summary.count == 1 ? "" : "s"), net of refunds",
                              value: summary.spent)]
        if summary.income.minorUnits != 0 { figures.append(Figure(id: "tag-income", label: "Income", detail: nil, value: summary.income)) }
        figures += (summary.byCategory ?? []).map {
            Figure(id: "tag-\($0.categoryID)", label: ledger.category($0.categoryID)?.name ?? $0.categoryID, detail: nil, value: $0.spent)
        }
        return (.object(o), figures)
    }
}
