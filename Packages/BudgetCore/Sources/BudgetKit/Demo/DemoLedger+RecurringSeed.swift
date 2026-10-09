import Foundation

/// Two series that give the recurring review something to ask about. Pocket Yoga has charged twice, a month apart — too
/// few for the recurring list, so it's an "Is this recurring?". StreamBox charged monthly for months, then stopped a
/// month and a half ago — a "Did this stop?". Nothing here draws from the seeded generator, so the rest of the demo stays
/// as it was.
extension Ledger {
    mutating func addRecurringExamples(today: Date) {
        func row(_ id: String, _ daysAgo: Int, merchant: String, raw: String, amount: Decimal) -> LedgerTransaction {
            let start = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
            let posted = min(calendar.date(byAdding: .minute, value: 4 * 60 + 11, to: start)!, now.addingTimeInterval(-120))
            return LedgerTransaction(id: id, accountID: Self.cardID, postedAt: posted, merchant: merchant, rawDescription: raw, amount: Money(amount),
                                     categorization: Categorization(categoryID: "subscriptions", confidence: 0.99, tier: .merchantMemory, needsReview: false),
                                     isPending: now.timeIntervalSince(posted) < 36 * 3600, source: .plaid)
        }
        var added = [41, 11].enumerated().map { n, daysAgo in
            row("tx-yoga-\(n + 1)", daysAgo, merchant: "Pocket Yoga", raw: "POCKETYOGA.APP", amount: -12.99)
        }
        added += [170, 140, 109, 79, 48].enumerated().map { n, daysAgo in
            row("tx-streambox-\(n + 1)", daysAgo, merchant: "StreamBox", raw: "STREAMBOX* MONTHLY", amount: -9.99)
        }
        transactions = (transactions + added).sorted { $0.postedAt > $1.postedAt }
        for index in accounts.indices {
            accounts[index].balance = balance(of: accounts[index].id, through: now)
        }
    }
}
