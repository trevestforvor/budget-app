import Foundation

// Templated answers about Plan scenarios and the month's flow, from the same read tools the live agent calls.
extension DemoAskEngine {
    /// "What if…", "my scenarios": each scenario against the plain forecast, a year out.
    func scenarioIntent(_ q: String, _ cid: String) -> AskReply? {
        guard ["scenario", "what if", "what-if", "life event"].contains(where: q.contains) else { return nil }
        guard let out = try? toolbox.planScenarios(scenarioID: nil, horizon: 12, goal: nil) else { return nil }
        let list = ledger.scenarioList(horizonMonths: 12)
        let tools = [call("planScenarios", ["horizonMonths": .number(12)])]
        guard !list.scenarios.isEmpty else {
            return reply(cid, text: "You haven't set up any scenarios yet. On Plan, add one with the changes you expect — a car payment, a bonus, a rent rise — and the forecast shows it beside the plain one.",
                         figures: out.figures, tools: tools, followUps: ["Open the plan"])
        }
        var lines = ["A year out, the plain forecast puts cash after cards near \(list.baselineEnd.formatted())."]
        for (scenario, outcome) in zip(list.scenarios, list.outcomes) {
            let direction = outcome.effect.isNegative ? "less" : "more"
            let gap = outcome.effect.minorUnits == 0 ? "the same" : "\(outcome.effect.magnitude.formatted()) \(direction)"
            lines.append("• \(scenario.name): \(outcome.endBalance.formatted()), \(gap).")
        }
        return reply(cid, text: lines.joined(separator: "\n"), figures: out.figures + list.outcomes.map {
            Figure(id: "gap-\($0.scenarioID)", label: "Difference", detail: nil, value: $0.effect.magnitude)
        }, tools: tools, followUps: ["Open the plan", "Can I set aside $5,000 by March?"])
    }

    /// "Where did my income go in August?": the month's flow, source to bucket to category.
    func flowIntent(_ q: String, _ cid: String) -> AskReply? {
        guard ["money flow", "flow of", "where did my income go", "where did my paycheck go", "sankey", "flow view"].contains(where: q.contains) else { return nil }
        let key = pastMonthKey(q)
        guard let out = try? toolbox.monthFlow(month: key), let flow = try? ledger.cashFlowSankey(month: key) else { return nil }
        let name = ledger.monthStart(flow.month).map { $0.formatted(DemoLedger.monthStyle(calendar, year: false)) } ?? flow.month
        var args: [String: JSONValue] = [:]
        if let key { args["month"] = .string(key) }
        guard flow.income.minorUnits > 0 || flow.spending.minorUnits > 0 else {
            return reply(cid, text: "Nothing came in or went out in \(name).", figures: out.figures, tools: [call("monthFlow", args)])
        }
        let buckets = flow.nodes.filter { $0.kind == .bucket }.map { "\($0.label) \($0.value.formatted())" }
        var text = "In \(name)\(flow.isPartial ? " so far" : ""), \(flow.income.formatted()) came in and \(flow.spending.formatted()) went out: \(buckets.spokenList)."
        if flow.saved.minorUnits > 0 { text += " That left \(flow.saved.formatted()) saved." }
        if flow.drawnFromCash.minorUnits > 0 { text += " Spending passed income, so \(flow.drawnFromCash.formatted()) came from cash." }
        return reply(cid, text: text, figures: out.figures, tools: [call("monthFlow", args)], followUps: ["Where did my money go this month?"])
    }
}
