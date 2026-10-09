import Foundation

extension DemoAskEngine {
    /// "Am I on pace this month?", "Will I go over?" → one checkPace call: the everyday budget's pace, then whatever is
    /// past a threshold.
    func paceIntent(_ q: String, _ cid: String) -> AskReply? {
        let asks = ["on pace", "my pace", "going over", "go over", "overspend", "over budget", "pace alert"]
        guard asks.contains(where: q.contains) else { return nil }
        let out = DemoToolbox(ledger: ledger, decisions: nil).checkPace()
        let report = ledger.paceAlerts()
        var lines: [String] = []
        if let everyday = report.everyday {
            if let over = everyday.over {
                lines.append("Everyday spending is \(over.display) past this month's \(everyday.limit.display) budget.")
            } else if let projected = everyday.projected {
                let perDay = everyday.perDayLeft.map { " \($0.display) a day keeps you on budget." } ?? ""
                lines.append(projected > everyday.limit
                    ? "Everyday is on pace for \(projected.display) against a \(everyday.limit.display) budget.\(perDay)"
                    : "Everyday is on pace for \(projected.display), inside the \(everyday.limit.display) budget.\(perDay)")
            } else {
                lines.append("It's early in the month: \(everyday.spent.display) of the \(everyday.limit.display) everyday budget is spent, too soon to project.")
            }
        }
        let others = report.alerts.filter { $0.kind != .everyday }
        // Exact amounts, not the notification's rounded "about $220": every figure in the reply is one the tool returned.
        lines += others.prefix(4).map { alert in
            let s = alert.status
            let word = alert.kind == .merchant ? "cap" : "target"
            if let over = s.over { return "• \(alert.name) is \(over.display) past its \(s.limit.display) \(word)." }
            if alert.threshold == .projectedOver, let projected = s.projected {
                return "• \(alert.name) is on pace for \(projected.display) against its \(s.limit.display) \(word)."
            }
            return "• \(alert.name) has used \(s.spent.display) of its \(s.limit.display) \(word)."
        }
        if others.isEmpty { lines.append("No target or cap is at 80% or on pace to go over.") }
        return reply(cid, text: lines.joined(separator: "\n"), figures: out.figures, tools: [call("checkPace", [:])],
                     followUps: others.first.map { ["Why is \($0.name.lowercased()) up this month?"] } ?? ["Run a checkup"])
    }
}
