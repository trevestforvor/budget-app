import Foundation

extension Ledger {
    // MARK: Which rows are a merchant's

    /// Whether `row` is one of `merchant`'s: its name as the ledger shows it, compared without case or surrounding space.
    static func isMerchant(_ row: LedgerTransaction, _ merchant: String) -> Bool {
        row.merchant.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(merchant.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// A charge that counts as spending — money out, not hidden, filed under a spending category: what a visit is, and
    /// what an average charge averages. (`netSpend` reads the same rows, with refunds netted against them.)
    func isSpendingCharge(_ row: LedgerTransaction) -> Bool {
        guard row.amount.isNegative, !row.isHidden, let id = row.categorization?.categoryID else { return false }
        return category(id)?.countsAsSpending == true
    }

    /// The category most of `rows` are filed under; a tie goes to the one filed most recently.
    static func usualCategory(_ rows: [LedgerTransaction]) -> String? {
        categoriesByUse(rows).first
    }

    /// Every category `rows` are filed under, most rows first, ties to the most recent.
    static func categoriesByUse(_ rows: [LedgerTransaction]) -> [String] {
        var count: [String: Int] = [:]
        var latest: [String: Date] = [:]
        for row in rows {
            guard let id = row.categorization?.categoryID else { continue }
            count[id, default: 0] += 1
            latest[id] = max(latest[id] ?? .distantPast, row.postedAt)
        }
        return count.keys.sorted { (count[$0]!, latest[$0]!, $1) > (count[$1]!, latest[$1]!, $0) }
    }

    // MARK: One merchant

    /// Everything about one merchant (`MerchantSummary`). Totals use the Spending tab's rule — each category net of its
    /// refunds, never below zero, hidden rows and transfers left out — so the page agrees with Spending and Activity.
    /// Throws `notFound` when the ledger has no row from it.
    func merchantSummary(_ name: String) throws -> MerchantSummary {
        let rows = transactions.filter { Self.isMerchant($0, name) }
        guard let newest = rows.first else { throw BudgetAPIError.notFound }
        let merchant = newest.merchant
        let yearStart = calendar.date(byAdding: .month, value: -11, to: startOfMonth)!
        let charges = rows.filter(isSpendingCharge)
        let yearCharges = charges.filter { $0.postedAt >= yearStart }
        func spent(from start: Date, to end: Date) -> Money {
            netSpend(rows.filter { $0.postedAt >= start && $0.postedAt < end })
        }
        let cap = merchantCap(for: merchant)
        let months = recentMonths(12).map { month in
            MonthSpend(month: month.key, spent: spent(from: month.start, to: month.end), target: cap?.target)
        }
        let rate = visitsPerMonth(yearCharges.count, since: yearStart)
        return MerchantSummary(
            merchant: merchant, thisMonth: spent(from: startOfMonth, to: now), lastTwelveMonths: spent(from: yearStart, to: now),
            lifetime: netSpend(rows), months: months,
            averageCharge: charges.isEmpty ? nil : Money(minorUnits: charges.map(\.amount.magnitude.minorUnits).reduce(0, +) / Int64(charges.count)),
            charges: charges.count, chargesLastTwelveMonths: yearCharges.count, visitsPerMonth: rate,
            frequency: Self.frequencyPhrase(visits: yearCharges.count, perMonth: rate),
            firstCharge: charges.last?.postedAt, lastCharge: charges.first?.postedAt,
            categoryID: Self.usualCategory(charges.isEmpty ? rows : charges), categoryIDs: Self.categoriesByUse(rows),
            recurring: subscriptions().items.first { $0.covers(merchant) }, cap: cap,
            transactions: rows.prefix(MerchantSummary.transactionLimit).map(presented), transactionCount: rows.count)
    }

    /// The cap that counts `merchant`'s charges, with this month's spend against it (`merchantSpend`, as Spending's caps
    /// read it): one named for exactly this merchant, else one whose name the merchant's contains ("Amazon" counts
    /// "Amazon Marketplace" too).
    func merchantCap(for merchant: String) -> MerchantCap? {
        let names = merchantTargets.keys.sorted()
        guard let name = names.first(where: { $0.caseInsensitiveCompare(merchant) == .orderedSame })
                ?? names.first(where: { merchant.localizedCaseInsensitiveContains($0) }),
              let target = merchantTargets[name] else { return nil }
        return MerchantCap(merchant: name, spent: merchantSpend(name, from: startOfMonth, to: now).total, target: target)
    }

    /// Charges a month over the window from `start` (or the ledger's first day, when that's later) to now — at least a
    /// month, so two charges in a new ledger's first week don't read as eight a month. Nil with no charges.
    func visitsPerMonth(_ visits: Int, since start: Date) -> Double? {
        guard visits > 0 else { return nil }
        let from = max(start, transactions.last.map { calendar.startOfDay(for: $0.postedAt) } ?? start)
        let months = max(now.timeIntervalSince(from) / (30.4 * 86_400), 1)
        return Double(visits) / months
    }

    /// "About 6 times a month", "About twice a week", "About once every 3 months".
    static func frequencyPhrase(visits: Int, perMonth: Double?) -> String {
        guard let rate = perMonth, visits > 0 else { return "No charges in the last 12 months" }
        if visits == 1 { return "One charge in the last 12 months" }
        func times(_ n: Int) -> String { n == 1 ? "once" : n == 2 ? "twice" : "\(n) times" }
        if rate >= 6.5 { return "About \(times(max(Int((rate / 4.33).rounded()), 2))) a week" }
        if rate >= 0.75 { return "About \(times(max(Int(rate.rounded()), 1))) a month" }
        let every = Int((1 / rate).rounded())
        return every <= 1 ? "About once a month" : "About once every \(every) months"
    }

    // MARK: Many merchants

    /// The merchants of `period` (`interval(forPeriod:)`'s names), most visited or most spent first, at most `limit`.
    /// Only charges that count as spending make a merchant a visit; its spend is net of its refunds in the period.
    func topMerchants(period: String, limit: Int = 5, sort: TopMerchants.Sort = .visits) throws -> TopMerchants {
        guard let window = interval(forPeriod: period) else { throw BudgetAPIError.rejected("Unknown period “\(period)”.") }
        let rows = transactions(from: window.start, to: window.end)
        let charges = rows.filter(isSpendingCharge)
        // One name per merchant, however its rows capitalize it: the newest row's.
        var names: [String: String] = [:]
        for row in rows.reversed() { names[row.merchant.lowercased()] = row.merchant }
        let byMerchant = Dictionary(grouping: charges) { $0.merchant.lowercased() }
        let rowsByMerchant = Dictionary(grouping: rows) { $0.merchant.lowercased() }
        var totals = byMerchant.map { key, visits in
            MerchantTotal(merchant: names[key] ?? visits[0].merchant, spent: netSpend(rowsByMerchant[key] ?? visits), visits: visits.count,
                          categoryID: Self.usualCategory(visits), lastVisit: visits.map(\.postedAt).max())
        }
        switch sort {
        case .visits: totals.sort { ($0.visits, $0.spent.minorUnits, $1.merchant) > ($1.visits, $1.spent.minorUnits, $0.merchant) }
        case .spent: totals.sort { ($0.spent.minorUnits, $0.visits, $1.merchant) > ($1.spent.minorUnits, $1.visits, $0.merchant) }
        }
        return TopMerchants(period: period, label: window.label, start: window.start, end: window.end, sort: sort,
                            merchants: Array(totals.prefix(max(limit, 0))), merchantCount: totals.count)
    }
}
