import Foundation

extension Ledger {
    /// The demo's Activity examples, added after the six months of household rows so every Activity state has
    /// something real to show:
    /// - Meadow withdrawals with no merchant and no matching deposit (money going to an account that isn't
    ///   linked): one review group that a single answer, and an account-scoped rule, settles;
    /// - a work dinner the person hid (work paid them back), with a note;
    /// - a few recent rows the decision model filed on its own, for the "Filed by the model" filter (with the two
    ///   first answers merchant memory learned from the model in `addShowcaseDetails`, five in all).
    /// Account digits come from `addShowcaseDetails`.
    mutating func addActivityExamples(today: Date) {
        func day(_ daysAgo: Int, hour: Int) -> Date {
            let start = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
            return min(calendar.date(byAdding: .minute, value: hour * 60 + 17, to: start)!, now.addingTimeInterval(-120))
        }
        func row(_ id: String, _ daysAgo: Int, hour: Int, merchant: String, raw: String, amount: Decimal, account: String,
                 categorization: Categorization, isHidden: Bool = false, note: String? = nil) -> LedgerTransaction {
            let posted = day(daysAgo, hour: hour)
            return LedgerTransaction(id: id, accountID: account, postedAt: posted, merchant: merchant, rawDescription: raw, amount: Money(amount),
                                     categorization: categorization, isPending: now.timeIntervalSince(posted) < 36 * 3600,
                                     source: account == Self.checkingID ? .simplefin : .plaid, isHidden: isHidden, note: note)
        }

        var added: [LedgerTransaction] = []
        // Money moved out of the Meadow cash account to somewhere that isn't linked.
        for (n, withdrawal) in [(4, Decimal(-1200)), (18, -450), (33, -2000), (47, -600)].enumerated() {
            var item = row("tx-wf-\(n + 1)", withdrawal.0, hour: 10, merchant: "Withdrawal", raw: "Withdrawal", amount: withdrawal.1,
                           account: Self.savingsID, categorization: Categorization(categoryID: "transfer", confidence: 0.47, tier: .model, needsReview: true))
            item.isPending = false
            added.append(item)
            suggestions[item.id] = [CategorySuggestion(categoryID: "transfer", confidence: 0.47), CategorySuggestion(categoryID: "housing", confidence: 0.14)]
            reviewReasons[item.id] = Categorizer.reviewReason(for: item, modelIsOn: false)
        }
        added.append(row("tx-hidden-1", 34, hour: 20, merchant: "Linden Café", raw: "LINDEN CAFE", amount: -186.40, account: Self.cardID,
                         categorization: Categorization(categoryID: "dining", confidence: 1, tier: .user, needsReview: false),
                         isHidden: true, note: "Team dinner. Work paid me back."))
        let model = Self.demoDecisionModelLabel
        added.append(row("tx-model-1", 2, hour: 8, merchant: "Bluebird Coffee", raw: "BLUEBIRD COFFEE #12", amount: -6.25, account: Self.cardID,
                         categorization: Categorization(categoryID: "dining", confidence: 0.88, tier: .decisionModel, needsReview: false, decidedBy: model)))
        added.append(row("tx-model-2", 7, hour: 18, merchant: "Walgreens", raw: "WALGREENS #4412", amount: -23.10, account: Self.cardID,
                         categorization: Categorization(categoryID: "health", confidence: 0.83, tier: .decisionModel, needsReview: false, decidedBy: model)))
        added.append(row("tx-model-3", 13, hour: 22, merchant: "Lyft", raw: "LYFT *RIDE SUN 8PM", amount: -18.40, account: Self.cardID,
                         categorization: Categorization(categoryID: "transport", confidence: 0.9, tier: .decisionModel, needsReview: false, decidedBy: model)))

        transactions = (transactions + added).sorted { $0.postedAt > $1.postedAt }
        for index in accounts.indices {
            accounts[index].balance = balance(of: accounts[index].id, through: now)
        }
    }
}
