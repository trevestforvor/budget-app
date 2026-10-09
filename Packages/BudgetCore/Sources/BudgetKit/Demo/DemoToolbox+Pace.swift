import Foundation

extension DemoToolbox {
    /// `checkPace`: the month's pace against the everyday budget, targets and caps, as pace alerts work it out. Money is
    /// display strings, each amount also a figure, so the model's prose is checked against them.
    func checkPace() -> (result: JSONValue, figures: [Figure]) {
        let report = ledger.paceAlerts()
        var figures: [Figure] = []
        func status(_ s: PaceStatus, id: String, name: String, limitLabel: String) -> [String: JSONValue] {
            figures += [Figure(id: "\(id)-spent", label: "\(name) spent", detail: "This month so far", value: s.spent),
                        Figure(id: "\(id)-limit", label: "\(name) \(limitLabel)", detail: nil, value: s.limit)]
            var o: [String: JSONValue] = ["spent": .string(s.spent.display), limitLabel: .string(s.limit.display),
                                          "usedPercent": .number(Double(s.usedPercent))]
            if let projected = s.projected {
                o["onPaceFor"] = .string(projected.display)
                figures.append(Figure(id: "\(id)-pace", label: "\(name) on pace for", detail: "At the pace so far", value: projected))
            }
            if let over = s.over {
                o["overBy"] = .string(over.display)
                figures.append(Figure(id: "\(id)-over", label: "\(name) over by", detail: nil, value: over))
            } else if let over = s.projectedOver {
                o["onPaceToFinishOverBy"] = .string(over.display)
                figures.append(Figure(id: "\(id)-pace-over", label: "\(name) on pace to finish over by", detail: nil, value: over))
            }
            if let perDay = s.perDayLeft {
                o["perDayToStayOnBudget"] = .string(perDay.display)
                figures.append(Figure(id: "\(id)-per-day", label: "\(name) a day for the rest of the month", detail: nil, value: perDay))
            }
            return o
        }
        var result: [String: JSONValue] = [
            "month": .string(report.month), "day": .number(Double(report.day)), "daysInMonth": .number(Double(report.daysInMonth)),
            "projecting": .bool(report.projecting),
        ]
        if !report.projecting {
            result["note"] = .string("Before the second week there's no projection: only what's already spent.")
        }
        result["everyday"] = report.everyday.map { .object(status($0, id: "everyday", name: "Everyday", limitLabel: "budget")) } ?? .null
        result["pastAThreshold"] = .array(report.alerts.map { alert in
            var o = status(alert.status, id: alert.targetKey, name: alert.name, limitLabel: alert.kind == .merchant ? "cap" : alert.kind == .everyday ? "budget" : "target")
            o["kind"] = .string(alert.kind.rawValue)
            o["name"] = .string(alert.name)
            o["threshold"] = .string(alert.threshold == .used80 ? "80% used" : alert.status.over != nil ? "over" : "on pace to finish over")
            return .object(o)
        })
        return (.object(result), figures)
    }
}
