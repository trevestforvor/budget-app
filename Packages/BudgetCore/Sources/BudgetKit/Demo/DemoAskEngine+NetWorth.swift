import Foundation

extension DemoAskEngine {
    /// "What's my net worth?": today's figure, what it's made of, and how it moved over the last three months — the
    /// same history the Net worth screen draws, from the recorded balances.
    func netWorthIntent(_ q: String, _ cid: String) -> AskReply? {
        guard ["net worth", "networth", "what am i worth", "what i'm worth", "own and owe", "owe and own"].contains(where: q.contains) else { return nil }
        let b = ledger.balances()
        let owned = b.cash + b.investments + (b.otherAssets ?? .zero)
        let owed = b.cardsOwed + (b.otherDebts ?? .zero)
        var figures = [
            Figure(id: "net-worth", label: "Net worth", detail: "Today", value: b.netWorth),
            Figure(id: "assets", label: "Assets", detail: nil, value: owned),
            Figure(id: "debts", label: "Debts", detail: nil, value: owed),
            Figure(id: "cash", label: "Cash", detail: "Checking and savings", value: b.cash),
            Figure(id: "investments", label: "Investments", detail: nil, value: b.investments),
            Figure(id: "cards", label: "Cards owed", detail: nil, value: b.cardsOwed),
        ]
        var owns = ["\(b.cash.formatted()) in cash", "\(b.investments.formatted()) invested"]
        if let other = b.otherAssets {
            figures.append(Figure(id: "other-assets", label: "Kept by hand", detail: "Assets", value: other))
            owns.append("\(other.formatted()) in things you keep track of yourself")
        }
        var owes = ["\(b.cardsOwed.formatted()) on cards"]
        if let other = b.otherDebts {
            figures.append(Figure(id: "other-debts", label: "Kept by hand", detail: "Debts", value: other))
            owes.append("\(other.formatted()) in loans you keep track of yourself")
        }
        var text = "Your net worth is \(b.netWorth.formatted()): \(owned.formatted()) you own (\(owns.spokenList)), less \(owed.formatted()) you owe (\(owes.spokenList))."

        // How it moved: the history over the last three months, as the screen shows it.
        let range = NetWorthRange.threeMonths
        let worth = ledger.netWorth(range: range, snapshots: balanceSnapshots)
        if worth.points.count > 1 {
            var dayStyle = Date.FormatStyle.dateTime.month(.abbreviated).day()
            dayStyle.timeZone = ledger.calendar.timeZone
            let since = worth.start.formatted(dayStyle)
            figures.append(Figure(id: "net-worth-change", label: "Change", detail: "Since \(since)", value: worth.change))
            text += worth.change == .zero ? " It's where it was on \(since)."
                : " That's \(worth.change.isNegative ? "down" : "up") \(worth.change.magnitude.formatted()) since \(since)."
            if worth.estimatedThrough != nil { text += " Part of that stretch is estimated: investments before their first recorded balance are held at it." }
        }
        return reply(cid, text: text, figures: figures, tools: [call("netWorth", ["range": .string(range.rawValue)])],
                     followUps: ["How much can I save?", "Where did my money go this month?"])
    }
}
