import Foundation

/// Details the demo ledger carries so Settings has something real to show: the last digits of each account
/// number, a card whose transactions only come from imported statements, three rules — one that has filed
/// every paycheck, and two that disagree about the longer Uber rides — and where merchant memory's answers came
/// from (a few merchants the person filed once, a couple the model filed). None of it moves a spending total.
extension Ledger {
    static let keystoneCardID = "keystone"
    /// Who "the model" is on every demo row it filed — the same name the demo's decision model gives new answers.
    static let demoDecisionModelLabel = DemoDecisionModel(provider: .localDecide).label

    mutating func addShowcaseDetails() {
        let masks = [Self.checkingID: "0909", Self.savingsID: "3321", Self.cardID: "1008",
                     "meadow-inv": "7740", "northwind": "2215", "tidewater": "8903"]
        for index in accounts.indices { accounts[index].mask = masks[accounts[index].id] }

        addStatementOnlyCard()
        addRules()
        addFirstAnswers()
    }

    /// Merchant memory repeats an answer; the first row of each merchant is where it came from. The person filed
    /// three merchants themselves, and the model filed two on its own; memory has filed the rest since.
    private mutating func addFirstAnswers() {
        let byPerson: Set = ["DD *DOORDASH", "TRADER JOE S #236", "TARGET 00027"]
        let byModel = ["OLIVE GRILL MAIN": 0.93, "UNIQLO USA": 0.88]
        var answered: Set<String> = []
        for index in transactions.indices.reversed() { // oldest first
            let raw = transactions[index].rawDescription
            guard !answered.contains(raw), let categorization = transactions[index].categorization, categorization.tier == .merchantMemory else { continue }
            if byPerson.contains(raw) {
                transactions[index].categorization = Categorization(categoryID: categorization.categoryID, confidence: 1, tier: .user, needsReview: false)
                answered.insert(raw)
            } else if let confidence = byModel[raw] {
                transactions[index].categorization = Categorization(categoryID: categorization.categoryID, confidence: confidence, tier: .decisionModel,
                                                                    needsReview: false, decidedBy: Self.demoDecisionModelLabel)
                answered.insert(raw)
            }
        }
    }

    /// A Keystone card with nothing to sign in to: its rows come from a statement imported a couple of weeks ago, and the
    /// only one is a payment from an account the ledger doesn't hold, so it's a transfer and counts nowhere.
    private mutating func addStatementOnlyCard() {
        accounts.append(Account(id: Self.keystoneCardID, name: "Keystone Mastercard", institution: "Keystone", kind: .credit, balance: .zero,
                                source: .fileImport, mask: "4417"))
        let day = calendar.date(byAdding: .day, value: -13, to: calendar.startOfDay(for: now))!
        let posted = calendar.date(byAdding: .hour, value: 9, to: day)!
        transactions.append(LedgerTransaction(
            id: "tx-keystone-1", accountID: Self.keystoneCardID, postedAt: posted, merchant: "Payment — Thank You", rawDescription: "PAYMENT RECEIVED THANK YOU",
            amount: Money(318.42), categorization: Categorization(categoryID: "transfer", confidence: 1, tier: .statement, needsReview: false),
            isPending: false, source: .fileImport, batchID: "demo-statement-keystone"))
        transactions.sort { $0.postedAt > $1.postedAt }
        // What the statement said was owed before that payment.
        openingBalances[Self.keystoneCardID] = Money(-530.82)
    }

    static let cardRewardsID = "card-rewards"

    /// A money-in category the person made for what the Gold Card gives back — the monthly dining credit, a Tablesy credit,
    /// a Summit Offer and points taken as a statement credit — so money in beyond pay shows on every screen. It adds to
    /// income (and so to the flex budget), never to spending. Nothing here draws from the seeded generator, so the rest
    /// of the demo stays as it was. The person filed the first dining credit; merchant memory has filed it since.
    mutating func addCardRewards() {
        let place = categories.lastIndex(where: \.isMoneyIn).map { $0 + 1 } ?? categories.endIndex
        categories.insert(BudgetCategory(id: Self.cardRewardsID, name: "Card rewards", symbol: "gift", color: CategoryColor.amber.rawValue, kind: .moneyIn),
                          at: place)
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -Self.historyDays, to: today)!
        var credits: [(day: Date, merchant: String, raw: String, amount: Decimal)] = (0...6).reversed().map { back in
            let month = calendar.date(byAdding: .month, value: -back, to: startOfMonth)!
            return (calendar.date(byAdding: .day, value: 2, to: month)!, "Dining credit", "SUMMIT DINING CREDIT", 10)
        }
        let oneOffs: [(daysAgo: Int, merchant: String, raw: String, amount: Decimal)] = [
            (74, "Tablesy credit", "SUMMIT TABLESY CREDIT", 50), (47, "Summit Rewards", "SUMMIT REWARDS CREDIT", 25),
            (33, "Summit Offer", "SUMMIT OFFER CREDIT SWEETGREEN", 15),
        ]
        credits += oneOffs.map { (calendar.date(byAdding: .day, value: -$0.daysAgo, to: today)!, $0.merchant, $0.raw, $0.amount) }
        var filedByPerson = false
        for (n, credit) in credits.enumerated() {
            let posted = calendar.date(byAdding: .hour, value: 7, to: credit.day)!
            guard credit.day >= first, posted < now else { continue }
            let byPerson = !filedByPerson && credit.raw == "SUMMIT DINING CREDIT"
            filedByPerson = filedByPerson || byPerson
            transactions.append(LedgerTransaction(
                id: "tx-reward-\(n + 1)", accountID: Self.cardID, postedAt: posted, merchant: credit.merchant, rawDescription: credit.raw,
                amount: Money(credit.amount),
                categorization: Categorization(categoryID: Self.cardRewardsID, confidence: byPerson ? 1 : 0.99, tier: byPerson ? .user : .merchantMemory,
                                               needsReview: false),
                isPending: now.timeIntervalSince(posted) < 36 * 3600, source: .plaid))
        }
        transactions.sort { $0.postedAt > $1.postedAt }
    }

    /// Rules as a person using the app for a while would have them. The paycheck rule and the assistant's Uber rule
    /// filed the rows they match; the newer "longer rides are travel" rule was added today and hasn't filed anything,
    /// but it disagrees with the Uber rule on every ride over $30 already in the ledger.
    private mutating func addRules() {
        let start = calendar.date(byAdding: .day, value: -Self.historyDays, to: calendar.startOfDay(for: now))!
        rules = [
            BudgetRule(id: "rule-1", match: RuleMatch(descriptorContains: "ACME CORP PAYROLL", direction: .moneyIn), categoryID: "income",
                       createdAt: start, createdBy: .person),
            BudgetRule(id: "rule-2", match: RuleMatch(descriptorContains: "UBER"), categoryID: "transport",
                       createdAt: calendar.date(byAdding: .day, value: 12, to: start), createdBy: .assistant),
            BudgetRule(id: "rule-3", match: RuleMatch(merchantContains: "Uber", minAmount: DecimalAmount(minorUnits: 3000)), categoryID: "travel",
                       createdAt: now.addingTimeInterval(-3 * 3600), createdBy: .person),
        ]
        let stamps = ["ACME CORP PAYROLL PPD": rules[0], "UBER *TRIP": rules[1]]
        for index in transactions.indices {
            guard let rule = stamps[transactions[index].rawDescription], transactions[index].postedAt >= rule.createdAt ?? .distantPast,
                  transactions[index].categorization?.categoryID == rule.categoryID else { continue }
            transactions[index].categorization = Categorization(categoryID: rule.categoryID, confidence: 1, tier: .rule, needsReview: false,
                                                                decidedBy: rule.stamp)
        }
    }
}
