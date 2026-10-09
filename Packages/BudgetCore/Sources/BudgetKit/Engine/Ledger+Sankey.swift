import Foundation

// A month's cash flow as a Sankey: income sources → Bills / Subscriptions / Everyday / Saved → each bucket's top
// categories. The figures are the ones the rest of the app shows for the month: income is everything filed under a
// money-in category (`netIncome`), and spending is the budget's (`budgetTotals`: each category net of its refunds and
// never below zero, a charge spread over the year at a twelfth, hidden rows and transfers left out), so the buckets
// match Spending's to the cent.

extension Ledger {
    /// Income sources named before the rest are put together as "Other income".
    static let sankeySourceLimit = 4
    /// Categories named in each bucket before the rest are put together.
    static let sankeyCategoryLimit = 4

    /// The tone each bucket and the month's other nodes wear (design-system tone names).
    static func sankeyColor(_ group: CategoryGroup) -> String {
        switch group {
        case .bills: CategoryColor.azure.rawValue
        case .subscriptions: CategoryColor.violet.rawValue
        case .everyday: CategoryColor.lilac.rawValue
        }
    }

    /// The month `key` ("2026-09"; nil is this month so far) as a Sankey whose every node takes in what it gives out.
    func cashFlowSankey(month key: String?) throws -> CashFlowSankey {
        let current = monthKey(now)
        let key = key ?? current
        guard let start = monthStart(key) else { throw BudgetAPIError.rejected("A month is written like 2026-09.") }
        guard start <= now else { throw BudgetAPIError.rejected("\(start.formatted(Self.monthStyle(calendar))) hasn't started yet.") }
        guard key != current else { return sankey(month: key, from: start, to: now, isPartial: true) }
        // A past month as the ledger stood at its end, the way Spending works it out (`budgetMonth`).
        var then = self
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        then.now = end.addingTimeInterval(-0.001)
        return then.sankey(month: key, from: start, to: end, isPartial: false)
    }

    private func sankey(month key: String, from start: Date, to end: Date, isPartial: Bool) -> CashFlowSankey {
        typealias Node = CashFlowSankey.Node
        let rows = transactions(from: start, to: end)
        let income = Money(minorUnits: max(0, netIncome(rows).minorUnits))

        // Sources: each payer's money in, largest first; the smaller ones together. Their total is the month's income
        // exactly — a payer that took money back (a reversed deposit) comes off the smallest named one.
        let moneyIn = moneyInCategoryIDs
        var byPayer: [String: Int64] = [:]
        for row in rows where moneyIn.contains(row.categorization?.categoryID ?? "") {
            byPayer[row.merchant, default: 0] += row.amount.minorUnits
        }
        let payers = byPayer.filter { $0.value > 0 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var sources: [Node] = []
        var left = income.minorUnits
        for (index, payer) in payers.prefix(Self.sankeySourceLimit).enumerated() {
            let value = min(payer.value, left)
            guard value > 0 else { break }
            sources.append(Node(id: "in-\(index)", label: payer.key, kind: .income, column: 0, value: Money(minorUnits: value),
                                color: CategoryColor.cyan.rawValue))
            left -= value
        }
        if left > 0 {
            sources.append(Node(id: "in-other", label: sources.isEmpty ? "Income" : "Other income", kind: sources.isEmpty ? .income : .other,
                                column: 0, value: Money(minorUnits: left), color: CategoryColor.cyan.rawValue))
        }

        // Buckets and their categories, as the budget counts them; a category's spread share joins its own month's.
        let totals = budgetTotals(from: start, to: end)
        var buckets: [Node] = []
        var categories: [Node] = []
        var bucketLinks: [CashFlowSankey.Link] = []
        for group in CategoryGroup.allCases {
            var byCategory: [String: (category: BudgetCategory, spent: Int64)] = [:]
            for total in totals[group] ?? [] where total.spent.minorUnits > 0 {
                byCategory[total.category.id, default: (total.category, 0)].spent += total.spent.minorUnits
            }
            let ranked = byCategory.values.sorted { $0.spent != $1.spent ? $0.spent > $1.spent : $0.category.id < $1.category.id }
            let value = ranked.map(\.spent).reduce(0, +)
            guard value > 0 else { continue }
            let bucketID = "bucket-\(group.rawValue)"
            buckets.append(Node(id: bucketID, label: group.label, kind: .bucket, column: 1, value: Money(minorUnits: value), group: group,
                                color: Self.sankeyColor(group)))
            // The rest go together only when there are two or more of them; a lone one is named.
            let named = ranked.count <= Self.sankeyCategoryLimit + 1 ? ranked[...] : ranked.prefix(Self.sankeyCategoryLimit)
            for entry in named {
                let node = Node(id: "cat-\(group.rawValue)-\(entry.category.id)", label: entry.category.name, kind: .category, column: 2,
                                value: Money(minorUnits: entry.spent), group: group, categoryID: entry.category.id,
                                color: entry.category.effectiveColor.rawValue)
                categories.append(node)
                bucketLinks.append(CashFlowSankey.Link(source: bucketID, target: node.id, value: node.value))
            }
            let rest = ranked.dropFirst(named.count).map(\.spent).reduce(0, +)
            if rest > 0 {
                let node = Node(id: "other-\(group.rawValue)", label: "Other \(group.label.lowercased())", kind: .other, column: 2,
                                value: Money(minorUnits: rest), group: group)
                categories.append(node)
                bucketLinks.append(CashFlowSankey.Link(source: bucketID, target: node.id, value: node.value))
            }
        }
        let spending = buckets.map(\.value).sum()
        let saved = Money(minorUnits: max(0, income.minorUnits - spending.minorUnits))
        let drawn = Money(minorUnits: max(0, spending.minorUnits - income.minorUnits))
        if drawn.minorUnits > 0 {
            sources.append(Node(id: "drawn", label: "From cash", kind: .drawn, column: 0, value: drawn, color: CategoryColor.amber.rawValue))
        }
        var targets = buckets
        if saved.minorUnits > 0 {
            targets.append(Node(id: "saved", label: "Saved", kind: .saved, column: 1, value: saved, color: CategoryColor.teal.rawValue))
        }

        return CashFlowSankey(month: key, isPartial: isPartial, income: income, spending: spending, saved: saved, drawnFromCash: drawn,
                              nodes: sources + targets + categories, links: Self.fill(sources, into: targets) + bucketLinks)
    }

    /// Links from each source to the targets in order, each filling the next target with what it has left, so both
    /// columns' totals hold to the cent (they're equal: income and cash drawn are spending and saved).
    static func fill(_ sources: [CashFlowSankey.Node], into targets: [CashFlowSankey.Node]) -> [CashFlowSankey.Link] {
        var links: [CashFlowSankey.Link] = []
        var needs = targets.map(\.value.minorUnits)
        var t = 0
        for source in sources {
            var has = source.value.minorUnits
            while has > 0, t < targets.count {
                let amount = min(has, needs[t])
                if amount > 0 { links.append(CashFlowSankey.Link(source: source.id, target: targets[t].id, value: Money(minorUnits: amount))) }
                has -= amount
                needs[t] -= amount
                if needs[t] == 0 { t += 1 }
            }
        }
        return links
    }
}
