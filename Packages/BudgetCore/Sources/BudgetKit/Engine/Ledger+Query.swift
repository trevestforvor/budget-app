import Foundation

extension Ledger {
    /// Every row `filter` matches, in its order, unpaged. The Activity list, its summary and the assistant's
    /// `queryTransactions` all read this, so they always agree. An unknown period matches nothing.
    func matching(_ filter: TransactionFilter) -> [LedgerTransaction] {
        var window: (start: Date, end: Date)?
        if let period = filter.period {
            guard let w = interval(forPeriod: period) else { return [] }
            window = (w.start, w.end)
        }
        let categoryIDs = filter.categoryIDs.flatMap { $0.isEmpty ? nil : Set($0) }
        let accountIDs = filter.accountIDs.flatMap { $0.isEmpty ? nil : Set($0) }
        let tagKeys = filter.tags.flatMap { $0.isEmpty ? nil : Set($0.map(TransactionTags.key)) }
        let search = filter.search.flatMap(SearchText.init)
        let rows = transactions.filter { row in
            if let window, row.postedAt < window.start || row.postedAt >= window.end { return false }
            if let since = filter.since, row.postedAt < since { return false }
            if let until = filter.until, row.postedAt >= until { return false }
            if let categoryIDs, !categoryIDs.contains(row.categorization?.categoryID ?? "") { return false }
            if let accountIDs, !accountIDs.contains(row.accountID) { return false }
            if let tagKeys, !(row.tags ?? []).contains(where: { tagKeys.contains($0.lowercased()) }) { return false }
            switch filter.direction {
            case .moneyOut?: if row.amount.minorUnits >= 0 { return false }
            case .moneyIn?: if row.amount.minorUnits <= 0 { return false }
            case nil: break
            }
            if let min = filter.minAmount, row.amount.magnitude < min.magnitude { return false }
            if let max = filter.maxAmount, row.amount.magnitude > max.magnitude { return false }
            if filter.needsReviewOnly, !isWaitingForReview(row) { return false }
            if filter.pendingOnly, !row.isPending { return false }
            if filter.modelFiledOnly, !(row.categorization.map { $0.tier == .decisionModel && !$0.needsReview } ?? false) { return false }
            switch filter.visibility {
            case .all: break
            case .counted: if !isCounted(row) { return false }
            case .notCounted: if isCounted(row) { return false }
            }
            if let search, !search.matches(row) { return false }
            return true
        }
        // Ties break on id, so pages don't overlap or skip when rows share a timestamp.
        func newer(_ a: LedgerTransaction, _ b: LedgerTransaction) -> Bool { a.postedAt != b.postedAt ? a.postedAt > b.postedAt : a.id > b.id }
        return switch filter.sort {
        case .newest: rows.sorted(by: newer)
        case .oldest: rows.sorted { newer($1, $0) }
        case .largest: rows.sorted { $0.amount.magnitude != $1.amount.magnitude ? $0.amount.magnitude > $1.amount.magnitude : newer($0, $1) }
        }
    }

    /// One page of `matching(filter)`: `offset` rows skipped, at most `limit` returned.
    func query(_ filter: TransactionFilter) -> [LedgerTransaction] {
        matching(filter).dropFirst(max(filter.offset, 0)).prefix(max(filter.limit, 0)).map(presented)
    }

    /// Totals over everything `filter` matches (paging and order don't matter), by the Spending tab's rules.
    func summary(_ filter: TransactionFilter) -> TransactionSummary {
        let rows = matching(filter)
        let notCounted = rows.filter { !isCounted($0) }
        return TransactionSummary(
            count: rows.count, earliest: rows.map(\.postedAt).min(), latest: rows.map(\.postedAt).max(),
            spent: netSpend(rows), income: netIncome(rows), notCountedCount: notCounted.count,
            notCountedTotal: notCounted.filter(\.amount.isNegative).map(\.amount.magnitude).sum(),
            hiddenCount: rows.filter(\.isHidden).count, needsReviewCount: rows.filter(isWaitingForReview).count,
            pendingCount: rows.filter(\.isPending).count)
    }
}

/// What a search box matches: the merchant, the bank descriptor, the note, a tag, or — when the text reads as an
/// amount — the amount. "42.50" (or "$42.50", "-42.50") is exact; "42" finds $42.00 up to $42.99.
struct SearchText {
    let text: String
    private let cents: Int64?
    private let dollars: Int64?

    init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        self.text = text
        let number = text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "+-− "))
        if number.contains("."), let amount = DecimalAmount(string: number) {
            (cents, dollars) = (amount.minorUnits, nil)
        } else if number.wholeMatch(of: /\d{1,9}/) != nil, let whole = Int64(number) {
            (cents, dollars) = (nil, whole)
        } else {
            (cents, dollars) = (nil, nil)
        }
    }

    func matches(_ row: LedgerTransaction) -> Bool {
        if row.merchant.localizedCaseInsensitiveContains(text) || row.rawDescription.localizedCaseInsensitiveContains(text)
            || (row.note?.localizedCaseInsensitiveContains(text) ?? false)
            || (row.tags ?? []).contains(where: { $0.localizedCaseInsensitiveContains(text) })
            || (row.orderMatch?.items.contains { $0.localizedCaseInsensitiveContains(text) } ?? false) { return true }
        let magnitude = row.amount.magnitude.minorUnits
        if let cents { return magnitude == cents }
        if let dollars { return magnitude / 100 == dollars }
        return false
    }
}
