import Foundation

/// The demo's card bill: the Gold Card's latest statement as Plaid Liabilities would report it. The statement closes on
/// the last day of each month for that month's charges and is due on the 25th of the next, which is when the demo's
/// checking account pays it, so before the 25th it's due and from then on it's paid. Nothing here moves a spending total.
extension Ledger {
    /// - Parameter owedByMonth: the card's charges per month as the seed made them ("2026-8" → minor units), which is
    ///   also what the 25th's payment pays.
    mutating func addDemoCardBill(owedByMonth: [String: Int64]) {
        let today = calendar.startOfDay(for: now)
        let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
        let statementDate = calendar.date(byAdding: .day, value: -1, to: thisMonth)!
        func key(_ date: Date) -> String {
            let c = calendar.dateComponents([.year, .month], from: date)
            return "\(c.year!)-\(c.month!)"
        }
        guard let owed = owedByMonth[key(statementDate)], owed > 0 else { return }
        let lastMonth = calendar.date(byAdding: .month, value: -1, to: thisMonth)!
        let previous = owedByMonth[key(calendar.date(byAdding: .day, value: -1, to: lastMonth)!)]
        let balance = Money(minorUnits: owed)
        cardBills[Self.cardID] = CardBill(
            accountID: Self.cardID, statementBalance: balance, statementDate: statementDate,
            minimumPayment: Money(minorUnits: max(4_000, owed / 50)),
            dueDate: calendar.date(byAdding: .day, value: 24, to: thisMonth)!, isOverdue: false,
            lastPaymentAmount: previous.map { Money(minorUnits: $0) }, lastPaymentDate: previous.map { _ in calendar.date(byAdding: .day, value: 24, to: lastMonth)! },
            purchaseAPR: 24.99, updatedAt: now.addingTimeInterval(-3 * 3600))
    }
}
