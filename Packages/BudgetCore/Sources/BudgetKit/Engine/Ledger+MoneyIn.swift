import Foundation

/// Money in: which categories count as money coming in (Income and any the person makes, like card rewards), and the
/// guard that keeps money coming in on a credit card out of Income — pay never lands on a card; what does is a
/// payment to the card, a refund or a statement credit.
extension Ledger {
    /// Every money-in category, merged-away ones included (old rows still name them).
    var moneyInCategoryIDs: Set<String> { Set(categories.filter(\.isMoneyIn).map(\.id)) }

    /// Whether rows filed under `categoryID` count as money in.
    func isMoneyIn(_ categoryID: String?) -> Bool { categoryID.flatMap(category)?.isMoneyIn ?? false }

    /// What money-in categories received between two instants — one category's, or every one's (the income figure) —
    /// hidden rows left out.
    func received(from start: Date, to end: Date, categoryID: String? = nil) -> Money {
        let rows = transactions(from: start, to: end)
        return netIncome(categoryID.map { id in rows.filter { $0.categorization?.categoryID == id } } ?? rows)
    }

    /// Each money-in category that received something between two instants, most first.
    func receivedByCategory(from start: Date, to end: Date) -> [(category: BudgetCategory, received: Money)] {
        let window = transactions(from: start, to: end)
        return categories.filter(\.isMoneyIn).compactMap { category in
            let rows = window.filter { $0.categorization?.categoryID == category.id }
            return rows.isEmpty ? nil : (category, netIncome(rows))
        }
        .sorted { $0.received > $1.received }
    }

    /// Money coming in on a credit card: never pay, so never Income unless the person or their rule says so.
    func isCardCredit(_ row: LedgerTransaction) -> Bool {
        row.amount.minorUnits > 0 && accountKind(row.accountID) == .credit
    }

    /// One decision per descriptor and direction, and money coming in on a card apart from money coming in anywhere
    /// else (the guard below treats them differently): `Categorizer.decisionKey` with the row's account.
    func decisionKey(_ row: LedgerTransaction) -> String {
        Categorizer.decisionKey(row, accountKind: accountKind(row.accountID))
    }

    /// Honest review suggestions for money coming in on a credit card, which is never pay: Transfer first when it reads
    /// as a payment to the card; then the spending categories it most likely refunds (how earlier charges from the
    /// same merchant were filed) and the bank's own label for it; then `ranked` (the model's). Income is always left
    /// out; a money-in category the person made (card rewards) may stay. At most three, and Transfer alone when there's
    /// nothing else to go on.
    func cardCreditSuggestions(for row: LedgerTransaction, ranked: [CategorySuggestion] = [], known: Set<String>) -> [CategorySuggestion] {
        var out: [CategorySuggestion] = []
        func add(_ id: String, _ confidence: Double) {
            guard id != BudgetCategory.incomeID, known.contains(id), !out.contains(where: { $0.categoryID == id }) else { return }
            out.append(CategorySuggestion(categoryID: id, confidence: confidence))
        }
        if Categorizer.looksLikePayment(row) { add(BudgetCategory.transferID, 0.6) }
        // A share of earlier charges, scaled so a guess from history never reads as surer than 60%.
        for (id, share) in refundedCategories(of: row) { add(id, (60 * share).rounded() / 100) }
        if let hint = row.providerCategory.flatMap(ProviderCategories.map), category(hint)?.countsAsSpending == true { add(hint, 0.4) }
        for suggestion in ranked { add(suggestion.categoryID, suggestion.confidence) }
        if out.isEmpty { add(BudgetCategory.transferID, 0.3) }
        return Array(out.prefix(3))
    }

    /// The spending categories earlier charges from the same merchant (or with the same bank description) are filed
    /// under, with each one's share of those charges, most first — what a refund most likely reverses. A description
    /// that names no merchant ("Credit") has nothing to go on.
    func refundedCategories(of row: LedgerTransaction) -> [(categoryID: String, share: Double)] {
        guard !Descriptor.isGeneric(row.rawDescription) else { return [] }
        let merchant = row.merchant.lowercased(), descriptor = Descriptor.normalize(row.rawDescription)
        var counts: [String: Int] = [:]
        for other in transactions where other.amount.isNegative && !other.isHidden && other.id != row.id {
            guard let c = other.categorization, !c.needsReview, category(c.categoryID)?.countsAsSpending == true,
                  other.merchant.lowercased() == merchant || Descriptor.normalize(other.rawDescription) == descriptor else { continue }
            counts[c.categoryID, default: 0] += 1
        }
        let total = Double(counts.values.reduce(0, +))
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { ($0.key, Double($0.value) / total) }
    }

    /// Money coming in on a credit card is never pay, but before that was guarded the model, merchant memory or a
    /// statement could file a card payment or a refund as Income. This sends each such row back to review with honest
    /// suggestions (`cardCreditSuggestions`) and says why. The person's own answers and their rules keep Income, and a
    /// row they hid stays as it is. A one-time upgrade (`Ledger.cardIncomeUpgrade`): it runs on the first load after it
    /// ships, which the server writes back once (`persistUpgrades`), and never again — so card credits the person later
    /// merges into Income stay there. Running it twice changes nothing anyway: the rows aren't Income any more.
    /// With `accountID`, only that card's rows (an account the person just made a card); returns how many went.
    @discardableResult
    mutating func sendCardIncomeToReview(onlyOn accountID: String? = nil) -> Int {
        let cards = Set(accounts.filter { $0.kind == .credit && (accountID == nil || $0.id == accountID) }.map(\.id))
        guard !cards.isEmpty else { return 0 }
        let known = Set(activeCategories.map(\.id))
        var sent = 0
        for index in transactions.indices {
            let row = transactions[index]
            guard cards.contains(row.accountID), row.amount.minorUnits > 0, !row.isHidden, var c = row.categorization,
                  c.categoryID == BudgetCategory.incomeID, c.tier != .user, c.tier != .rule else { continue }
            let ranked = cardCreditSuggestions(for: row, ranked: suggestions[row.id] ?? [], known: known)
            guard let best = ranked.first else { continue } // no Transfer to offer either: nothing honest to suggest
            c.categoryID = best.categoryID
            c.confidence = best.confidence
            c.needsReview = true
            transactions[index].categorization = c
            suggestions[row.id] = ranked
            reviewReasons[row.id] = Categorizer.cardIncomeReason("It was filed as Income")
            sent += 1
        }
        return sent
    }
}

extension Categorizer {
    /// Why an answer can't be filed as given, however sure the model is.
    enum Held: Hashable, Sendable {
        /// Money going out called Income or another money-in category: money going out is never money in.
        case moneyOut(categoryID: String, name: String)
        /// Money coming in on a credit card called Income: pay never lands on a card.
        case cardIncome

        /// Why the row came to the person, in plain words.
        var reason: String {
            switch self {
            case let .moneyOut(id, name):
                id == BudgetCategory.incomeID ? "The decision model called this income, but money going out is never income."
                    : "The decision model filed this under \(name), but money going out never counts as money in."
            case .cardIncome: Categorizer.cardIncomeReason("The decision model called this income")
            }
        }
    }

    /// "<source>, but money coming in on a credit card isn't pay: …" — the review reason whenever the card guard holds
    /// a row back.
    static func cardIncomeReason(_ source: String) -> String {
        "\(source), but money coming in on a credit card isn't pay: it's a payment to the card, a refund or a statement credit."
    }

    /// Money going out is never money in, and money coming in on a credit card is never Income, however sure the model
    /// is: such an answer counts as unsure (confidence 0), so the row goes to review. Returns the answer to act on, and
    /// what was held back.
    static func guarded(_ answer: DecisionAnswer?, for row: LedgerTransaction, in ledger: Ledger) -> (answer: DecisionAnswer?, held: Held?) {
        guard var answer else { return (nil, nil) }
        let held: Held
        if row.amount.isNegative, let category = ledger.category(answer.value), category.isMoneyIn {
            held = .moneyOut(categoryID: category.id, name: category.name)
        } else if answer.value == BudgetCategory.incomeID, ledger.isCardCredit(row) {
            held = .cardIncome
        } else {
            return (answer, nil)
        }
        answer.confidence = 0
        return (answer, held)
    }

    /// Review suggestions for a row the guard held back: for money going out, every money-in category dropped and
    /// Transfer first; for money coming in on a card, the card's honest options (`Ledger.cardCreditSuggestions`).
    static func guardSuggestions(_ ranked: inout [CategorySuggestion], held: Held, for row: LedgerTransaction, in ledger: Ledger, known: Set<String>) {
        switch held {
        case .moneyOut:
            ranked.removeAll { ledger.isMoneyIn($0.categoryID) }
            if known.contains(BudgetCategory.transferID), !ranked.contains(where: { $0.categoryID == BudgetCategory.transferID }) {
                ranked.insert(CategorySuggestion(categoryID: BudgetCategory.transferID, confidence: 0.5), at: 0)
            }
        case .cardIncome:
            ranked = ledger.cardCreditSuggestions(for: row, ranked: ranked, known: known)
        }
    }

    /// `ranked` without what the guards never file on their own: a money-in category for money going out, Income for
    /// money coming in on a card (even as the bank's hint). The person can still pick either from the full list.
    static func offerable(_ ranked: [CategorySuggestion], for row: LedgerTransaction, in ledger: Ledger) -> [CategorySuggestion] {
        let cardCredit = ledger.isCardCredit(row)
        return ranked.filter { !(row.amount.isNegative && ledger.isMoneyIn($0.categoryID)) && !(cardCredit && $0.categoryID == BudgetCategory.incomeID) }
    }

    /// Reads as a payment to a card: filed or labeled as a transfer, or its description says payment, autopay, thank
    /// you or transfer.
    static func looksLikePayment(_ row: LedgerTransaction) -> Bool {
        row.categorization?.categoryID == BudgetCategory.transferID || row.providerCategory.flatMap(ProviderCategories.map) == BudgetCategory.transferID
            || row.rawDescription.range(of: #"PAYMENT|THANK YOU|AUTOPAY|EPAY|TRANSFER"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
