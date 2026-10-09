import Foundation

extension DemoAskEngine {
    /// "What's my net worth?": today's figure and what it's made of, from the ledger alone. (Its history needs the
    /// recorded balances, which the `netWorth` tool reads on the server.)
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
        let text = "Your net worth is \(b.netWorth.formatted()): \(owned.formatted()) you own (\(owns.spokenList)), less \(owed.formatted()) you owe (\(owes.spokenList))."
        return reply(cid, text: text, figures: figures, tools: [call("netWorth", ["range": .string(NetWorthRange.threeMonths.rawValue)])],
                     followUps: ["How much can I save?", "Where did my money go this month?"])
    }
}
