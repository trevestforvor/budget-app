import Foundation

// Tags across the ledger, and the rows "like" a re-filed one.

extension Ledger {
    // MARK: Tags

    /// `tags` written the way the ledger already writes them: "austin trip" becomes "Austin trip" when a row carries that.
    func canonicalTags(_ tags: [String]) -> [String] {
        var known: [String: String] = [:]
        for row in transactions {
            for tag in row.tags ?? [] where known[tag.lowercased()] == nil { known[tag.lowercased()] = tag }
        }
        return TransactionTags.cleaned(tags).map { known[$0.lowercased()] ?? $0 }
    }

    /// Every tag on the rows in `period` (all of them when nil), most recently used first; without spending by category.
    func tagSummaries(period: String? = nil) throws -> [TagSummary] {
        let rows = try rows(in: period)
        var groups: [String: (tag: String, rows: [LedgerTransaction])] = [:]
        for row in rows {
            for tag in row.tags ?? [] {
                groups[tag.lowercased(), default: (tag, [])].rows.append(row)
            }
        }
        return groups.values.map { summary($0.tag, $0.rows, byCategory: false) }
            .sorted { ($0.latest ?? .distantPast, $1.tag.lowercased()) > ($1.latest ?? .distantPast, $0.tag.lowercased()) }
    }

    /// One tag over `period`, with spending by category. `notFound` when no row in it carries the tag.
    func tagSummary(_ name: String, period: String? = nil) throws -> TagSummary {
        let rows = try rows(in: period).filter { TransactionTags.contains($0.tags, name) }
        guard let first = rows.first else { throw BudgetAPIError.notFound }
        let spelling = first.tags?.first { $0.lowercased() == TransactionTags.key(name) } ?? name
        return summary(spelling, rows, byCategory: true)
    }

    private func rows(in period: String?) throws -> [LedgerTransaction] {
        guard let period else { return transactions }
        guard let window = interval(forPeriod: period) else { throw BudgetAPIError.rejected("Unknown period “\(period)”.") }
        return transactions.filter { $0.postedAt >= window.start && $0.postedAt < window.end }
    }

    /// Totals by the Spending tab's rules: `netSpend` (hidden rows and transfers out, each category net of refunds and
    /// floored at zero) and `netIncome`.
    private func summary(_ tag: String, _ rows: [LedgerTransaction], byCategory: Bool) -> TagSummary {
        var categories: [TagSummary.CategorySpend]?
        if byCategory {
            let ids = Set(rows.compactMap { $0.categorization?.categoryID }).intersection(self.categories.filter(\.countsAsSpending).map(\.id))
            categories = ids.map { TagSummary.CategorySpend(categoryID: $0, spent: netSpend(rows, categoryIDs: [$0])) }
                .filter { $0.spent.minorUnits > 0 }
                .sorted { ($0.spent.minorUnits, $1.categoryID) > ($1.spent.minorUnits, $0.categoryID) }
        }
        let dates = rows.map(\.postedAt)
        return TagSummary(tag: tag, count: rows.count, spent: netSpend(rows), income: netIncome(rows),
                          earliest: dates.min(), latest: dates.max(), byCategory: categories)
    }

    // MARK: Similar rows

    /// Rows like `chosen` that filing them under `categoryID` would also reach (`EditTransactions.fileSimilar`): the same
    /// merchant or the same bank descriptor, money going the same way. A descriptor that names no merchant ("Withdrawal")
    /// and a payment app ("Venmo", "PayPal", where the merchant is a person or hidden) reach nothing; a matched transfer
    /// stays one unless it's being filed as a transfer; rows already filed there and settled are left alone, and rows the
    /// person filed themselves keep their category (`yours` counts those that would otherwise move).
    func similarRows(to chosen: [Int], under categoryID: String) -> (rows: [Int], yours: Int) {
        struct Key: Hashable { var text: String; var isOutflow: Bool }
        var descriptors = Set<Key>(), merchants = Set<Key>()
        for index in chosen {
            let row = transactions[index]
            guard !Descriptor.isGeneric(row.rawDescription), !Self.isPaymentApp(row) else { continue }
            let out = row.amount.isNegative
            let descriptor = Descriptor.normalize(row.rawDescription).trimmingCharacters(in: .whitespaces)
            if !descriptor.isEmpty { descriptors.insert(Key(text: descriptor, isOutflow: out)) }
            let merchant = RecurringChoice.key(row.merchant)
            if !merchant.isEmpty { merchants.insert(Key(text: merchant, isOutflow: out)) }
        }
        guard !descriptors.isEmpty || !merchants.isEmpty else { return ([], 0) }
        let skip = Set(chosen)
        var reached: [Int] = [], yours = 0
        for index in transactions.indices where !skip.contains(index) {
            let row = transactions[index], out = row.amount.isNegative
            guard row.amount.minorUnits != 0, !Self.isPaymentApp(row),
                  merchants.contains(Key(text: RecurringChoice.key(row.merchant), isOutflow: out))
                    || (!Descriptor.isGeneric(row.rawDescription)
                        && descriptors.contains(Key(text: Descriptor.normalize(row.rawDescription).trimmingCharacters(in: .whitespaces), isOutflow: out)))
            else { continue }
            if row.transferPeerID != nil, categoryID != "transfer" { continue }
            switch Self.refiling(row, under: categoryID) {
            case .moves?, .leavesReview?: reached.append(index)
            case .yours?: if row.categorization?.categoryID != categoryID { yours += 1 }
            case nil: continue
            }
        }
        return (reached, yours)
    }

    /// A payment app's row: the merchant is a person, or hidden behind the app, so its name says nothing about the next one.
    static func isPaymentApp(_ row: LedgerTransaction) -> Bool {
        let raw = row.rawDescription.uppercased().trimmingCharacters(in: .whitespaces)
        let apps = CategoryDecisions.peerToPeer + ["PAYPAL", "APPLE CASH"]
        return apps.contains { raw.hasPrefix($0) } || apps.contains { RecurringChoice.key(row.merchant) == $0.lowercased() }
    }
}
