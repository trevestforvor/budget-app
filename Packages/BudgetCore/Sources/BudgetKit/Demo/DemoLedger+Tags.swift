import Foundation

extension Ledger {
    /// The demo's tags, on rows it already has, so no total moves:
    /// - "Austin trip": the flight and the hotel, with the rides and meals on the card while away;
    /// - "Reimbursable": the team dinner work paid back (hidden, so the tag's spending leaves it out) and the most
    ///   recent Uber.
    mutating func addTagExamples() {
        let ordered = transactions.indices.sorted { transactions[$0].postedAt < transactions[$1].postedAt }
        if let flight = ordered.first(where: { transactions[$0].merchant == "United Airlines" }),
           let hotel = ordered.first(where: { transactions[$0].merchant == "Riverside Hotel" }) {
            let start = calendar.startOfDay(for: transactions[flight].postedAt)
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: transactions[hotel].postedAt))!
            for index in ordered where transactions[index].postedAt >= start && transactions[index].postedAt < end {
                let row = transactions[index]
                guard row.accountID == Self.cardID, row.amount.isNegative,
                      ["travel", "dining", "transport"].contains(row.categorization?.categoryID ?? "") else { continue }
                tag(index, "Austin trip")
            }
        }
        if let dinner = transactions.firstIndex(where: { $0.id == "tx-hidden-1" }) { tag(dinner, "Reimbursable") }
        if let ride = transactions.firstIndex(where: { $0.merchant == "Uber" && !$0.isPending }) { tag(ride, "Reimbursable") }
    }

    private mutating func tag(_ index: Int, _ tag: String) {
        transactions[index].tags = TransactionTags.merged(transactions[index].tags, [tag])
    }
}
