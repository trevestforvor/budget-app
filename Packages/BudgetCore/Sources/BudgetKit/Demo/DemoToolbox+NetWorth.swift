import Foundation

/// The `netWorth` read tool: today's figure, its change over a range, and the breakdown behind it — the numbers the
/// Net worth screen shows, formatted with `Money.display` so the model quotes them exactly.
extension DemoToolbox {
    func netWorth(range raw: String?) async throws -> (result: JSONValue, figures: [Figure]) {
        let range = raw.flatMap(NetWorthRange.init(rawValue:)) ?? .threeMonths
        let snapshots = try await balanceHistory?.balanceSnapshots() ?? []
        let worth = ledger.netWorth(range: range, snapshots: snapshots)
        var dayStyle = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        dayStyle.timeZone = ledger.calendar.timeZone
        let since = worth.start.formatted(dayStyle)
        let startValue = worth.points.first?.netWorth ?? worth.netWorth
        func line(_ l: NetWorthLine) -> JSONValue {
            var o: [String: JSONValue] = ["name": .string(l.name), "group": .string(l.group.label), "value": .string(l.value.display)]
            if let change = l.change, change != .zero { o["changeSinceStart"] = .string(change.display) }
            if l.isManual == true { o["keptByHand"] = .bool(true) }
            if l.isEstimated == true { o["partlyEstimated"] = .bool(true) }
            return .object(o)
        }
        var o: [String: JSONValue] = [
            "range": .string(range.rawValue), "since": .string(since),
            "netWorth": .string(worth.netWorth.display), "assets": .string(worth.assets.display), "debts": .string(worth.liabilities.display),
            "netWorthAtStart": .string(startValue.display), "change": .string(worth.change.display),
            "assetBreakdown": .array(worth.assetLines.map(line)), "debtBreakdown": .array(worth.liabilityLines.map(line)),
            "howItsCounted": .string("Cash and cards are traced back through their transactions; investments hold their latest recorded balance; assets and debts kept by hand count from the day they were added."),
        ]
        if let percent = worth.changePercent { o["changePercent"] = .number((percent * 10).rounded() / 10) }
        if let note = worth.note { o["estimated"] = .string(note) }
        var figures = [
            Figure(id: "net-worth", label: "Net worth", detail: "Today", value: worth.netWorth),
            Figure(id: "net-worth-start", label: "Net worth", detail: since, value: startValue),
            Figure(id: "net-worth-change", label: "Change", detail: "Since \(since)", value: worth.change),
            Figure(id: "assets", label: "Assets", detail: nil, value: worth.assets),
            Figure(id: "debts", label: "Debts", detail: nil, value: worth.liabilities),
        ]
        figures += (worth.assetLines + worth.liabilityLines).map { Figure(id: "line-\($0.id)", label: $0.name, detail: $0.group.label, value: $0.value) }
        return (.object(o), figures)
    }
}
