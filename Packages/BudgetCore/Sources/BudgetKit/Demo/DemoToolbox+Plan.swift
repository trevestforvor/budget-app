import Foundation

// Read tools for Plan scenarios and the month's flow. Every amount is the ledger's, as `Money.display`.
extension DemoToolbox {
    /// A tool's `goal` argument ({"amount": "5000", "targetDate": "2027-03-31"}), or nil.
    func goalArgument(_ value: JSONValue?) -> GoalQuery? {
        guard case let .object(g)? = value, case let .string(a)? = g["amount"], case let .string(d)? = g["targetDate"],
              let amount = DecimalAmount(string: a), let date = isoDate(d) else { return nil }
        return GoalQuery(amount: amount.money(), targetDate: date)
    }

    func planScenarios(scenarioID: String?, horizon: Int, goal: GoalQuery?) throws -> (result: JSONValue, figures: [Figure]) {
        let list = ledger.scenarioList(horizonMonths: horizon)
        var figures = [Figure(id: "plain-end", label: "Plain forecast in \(list.horizonMonths) months", detail: "Cash after cards", value: list.baselineEnd)]
        let scenarios: [JSONValue] = list.scenarios.map { scenario in
            let outcome = list.outcome(for: scenario.id)!
            figures += [Figure(id: "end-\(scenario.id)", label: "\(scenario.name) in \(list.horizonMonths) months", detail: "Cash after cards", value: outcome.endBalance),
                        Figure(id: "effect-\(scenario.id)", label: "\(scenario.name) against the plain forecast", detail: nil, value: outcome.effect)]
            return .object([
                "id": .string(scenario.id), "name": .string(scenario.name),
                "endWithScenario": .string(outcome.endBalance.display), "differenceFromPlainForecast": .string(outcome.effect.display),
                "changes": .array(scenario.events.map { event in
                    figures.append(Figure(id: "event-\(scenario.id)-\(event.id)", label: event.name, detail: event.summary(calendar: ledger.calendar),
                                          value: event.signedAmount))
                    var o: [String: JSONValue] = [
                        "name": .string(event.name), "direction": .string(event.kind == .income ? "money in" : "money out"),
                        "amount": .string(event.amount.display), "cadence": .string(event.cadence.rawValue), "from": .string(event.startMonth),
                        "switchedOn": .bool(event.isEnabled), "summary": .string(event.summary(calendar: ledger.calendar)),
                    ]
                    if let end = event.endMonth { o["through"] = .string(end) }
                    return .object(o)
                }),
            ])
        }
        var o: [String: JSONValue] = [
            "horizonMonths": .number(Double(list.horizonMonths)), "plainForecastEnd": .string(list.baselineEnd.display),
            "plainForecastIs": .string("cash after cards carried forward at the last three complete months' income less spending, with no planned changes"),
            "scenarios": .array(scenarios),
        ]
        if list.scenarios.isEmpty { o["note"] = .string("No scenarios yet. The user can add them on the Plan screen.") }
        if let scenarioID {
            let scenario = try ledger.planScenario(scenarioID)
            let p = ledger.projection(horizonMonths: horizon, goal: goal, scenario: scenario)
            let plain = p.baseline ?? p.projected
            o["projection"] = .object([
                "scenario": .string(scenario.name),
                "months": .array(zip(p.projected, plain).dropFirst().map { point, base in
                    .object(["month": .string(isoDay(point.date)), "withScenario": .string(point.expected.display), "plainForecast": .string(base.expected.display)])
                }),
            ])
            if let g = p.goal {
                o["goal"] = .object(["amount": .string(g.query.amount.display), "by": .string(isoDay(g.query.targetDate)), "scenario": .string(scenario.name),
                                     "projectedSavings": .string(g.projectedSavings.display), "onTrack": .bool(g.isOnTrack),
                                     "shortfall": .string(g.shortfall.display), "monthlyNeeded": .string(g.monthlyNeeded.display)])
                figures += [Figure(id: "goal-saved", label: "Projected savings by then, with \(scenario.name)", detail: nil, value: g.projectedSavings),
                            Figure(id: "goal-need", label: "Needed per month", detail: nil, value: g.monthlyNeeded)]
                if !g.isOnTrack { figures.append(Figure(id: "goal-short", label: "Shortfall", detail: nil, value: g.shortfall)) }
            }
        }
        return (.object(o), figures)
    }

    func monthFlow(month: String?) throws -> (result: JSONValue, figures: [Figure]) {
        let flow = try ledger.cashFlowSankey(month: month)
        let label = monthLabel(flow.month)
        var figures = [Figure(id: "flow-income", label: "Income · \(label)", detail: flow.isPartial ? "So far" : nil, value: flow.income),
                       Figure(id: "flow-spending", label: "Spending · \(label)", detail: flow.isPartial ? "So far" : nil, value: flow.spending)]
        var o: [String: JSONValue] = [
            "month": .string(flow.month), "income": .string(flow.income.display), "spending": .string(flow.spending.display),
            "spendingIs": .string("as the budget counts it: each category net of its refunds, a yearly charge a twelfth a month"),
            "sources": .array(flow.nodes.filter { $0.column == 0 }.map { node in
                figures.append(Figure(id: "flow-\(node.id)", label: node.label, detail: label, value: node.value))
                return .object(["name": .string(node.label), "amount": .string(node.value.display)])
            }),
            "buckets": .array(flow.nodes.filter { $0.kind == .bucket }.map { bucket in
                figures.append(Figure(id: "flow-\(bucket.id)", label: "\(bucket.label) · \(label)", detail: nil, value: bucket.value))
                return .object([
                    "bucket": .string(bucket.label), "amount": .string(bucket.value.display),
                    "categories": .array(flow.nodes.filter { $0.column == 2 && $0.group == bucket.group }.map { node in
                        figures.append(Figure(id: "flow-\(node.id)", label: node.label, detail: "\(bucket.label) · \(label)", value: node.value))
                        return .object(["name": .string(node.label), "amount": .string(node.value.display)])
                    }),
                ])
            }),
        ]
        if flow.isPartial { o["partial"] = .string("this month so far") }
        // Only the one that happened: income left after spending, or spending past income paid from cash.
        if flow.saved.minorUnits > 0 {
            o["saved"] = .string(flow.saved.display)
            figures.append(Figure(id: "flow-saved", label: "Saved · \(label)", detail: "Income left after spending", value: flow.saved))
        }
        if flow.drawnFromCash.minorUnits > 0 {
            o["drawnFromCash"] = .string(flow.drawnFromCash.display)
            figures.append(Figure(id: "flow-drawn", label: "From cash · \(label)", detail: "Spending past income", value: flow.drawnFromCash))
        }
        return (.object(o), figures)
    }
}
