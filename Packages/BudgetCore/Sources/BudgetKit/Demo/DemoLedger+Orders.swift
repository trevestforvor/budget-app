import Foundation

extension Ledger {
    /// What the demo household's three latest Amazon charges bought, as if their order history had been imported and
    /// matched (`matchOrders`): the items show on each charge and search finds them. The orders are made up. Nothing is
    /// re-filed or sent to review, so no total or count moves.
    mutating func addOrderExamples() {
        let baskets: [[String]] = [
            ["Pour-over coffee filters ×2", "Stainless steel water bottle"],
            ["Dotted notebook, A5", "Gel pens, 12 pack", "LED desk lamp"],
            ["USB-C charging cable", "Adjustable phone stand"],
        ]
        let charges = transactions.indices.filter { i in
            let row = transactions[i]
            return row.merchant == "Amazon" && row.amount.isNegative && !row.isPending
        }
        for (n, index) in charges.prefix(baskets.count).enumerated() {
            let posted = transactions[index].postedAt
            transactions[index].orderMatch = OrderMatch(
                store: OrderHistory.amazon, orderID: "113-50\(n + 1)0482-77\(n + 3)915\(n)", items: baskets[n],
                orderedAt: calendar.date(byAdding: .day, value: -2, to: posted))
        }
    }
}
