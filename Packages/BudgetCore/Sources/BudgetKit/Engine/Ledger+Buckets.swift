import Foundation
import Synchronization

// The budget's three buckets and how a charge lands in one.
//
// Every counted charge is a bill, a subscription or everyday spending. A charge in a recurring series counts as the
// series' kind — a bill or a subscription, the person's say first (`RecurringChoice`) — whatever its category, so a gym
// in Health or an app filed under Shopping is a subscription; anything else, the merchant's other charges included,
// counts as its category's group. A charge
// spread over the year (`yearlyIDs`: the person's say, a yearly series, a description that says annual) counts a
// twelfth in each of the twelve months from its own, in its bucket, so an annual fee or a trip the person spreads
// doesn't land whole in one month or swell the usual month after it. It keeps its category.

extension Ledger {
    /// What the recurring search says about the rows, worked out once per change to them.
    struct RecurringIndex {
        var yearlyIDs: Set<String>
        /// Rows in a recurring series, by id, and the kind each counts as.
        var kinds: [String: Subscription.Kind]
    }

    var recurringIndex: RecurringIndex { recurringCache.index(for: rowsToken) { computeRecurringIndex() } }

    /// Rows spread over the year: the person's say (`isYearly`) where they've given it; otherwise a charge in a yearly
    /// series (found, or one the person said repeats yearly) or one whose description says it's annual.
    var yearlyIDs: Set<String> { recurringIndex.yearlyIDs }

    func computeRecurringIndex() -> RecurringIndex {
        let series = recurringSeries()
        let yearlySeries = Set(series.filter { $0.cadence == .yearly }.flatMap(\.rowIDs))
        var ids: Set<String> = []
        for row in transactions {
            switch row.isYearly {
            case true?: ids.insert(row.id)
            case false?: continue
            case nil: if yearlySeries.contains(row.id) || Self.saysAnnual(row) { ids.insert(row.id) }
            }
        }
        var kinds: [String: Subscription.Kind] = [:]
        for item in series {
            let kind = recurringKind(item)
            for id in item.rowIDs { kinds[id] = kind }
        }
        return RecurringIndex(yearlyIDs: ids, kinds: kinds)
    }

    /// A recurring series' kind: the person's say, else a bill when its category is a bill, else a subscription.
    func recurringKind(_ series: RecurringSeries) -> Subscription.Kind {
        if let kind = recurringChoices[RecurringChoice.key(series.merchant)]?.kind { return kind }
        let categoryID = series.billings.last?.rows.first?.categorization?.categoryID
        return categoryID.flatMap(category)?.group == .bills ? .bill : .subscription
    }

    /// "ANNUAL MEMBERSHIP FEE", "Yearly plan", "billed annually" — but not "semi-annual" or "bi-annual", which come
    /// twice a year.
    static func saysAnnual(_ row: LedgerTransaction) -> Bool {
        [row.merchant, row.rawDescription].contains { text in
            let words = text.lowercased().split { !$0.isLetter }.map(String.init)
            return words.indices.contains { i in
                ["annual", "annually", "yearly"].contains(words[i]) && (i == 0 || !["semi", "bi"].contains(words[i - 1]))
            }
        }
    }

    /// The row as the API hands it out: `countsAsYearly` set when the budget spreads it over the year (left nil
    /// otherwise, so every other row goes out exactly as stored).
    func presented(_ row: LedgerTransaction) -> LedgerTransaction {
        guard yearlyIDs.contains(row.id) else { return row }
        var row = row
        row.countsAsYearly = true
        return row
    }

    // MARK: Buckets

    /// The bucket a spending row lands in: its recurring series' kind, else its category's group. Nil for a row that
    /// isn't spending (money in, a transfer, not filed).
    func bucket(of row: LedgerTransaction, categories byID: [String: BudgetCategory]? = nil,
                kinds: [String: Subscription.Kind]? = nil) -> CategoryGroup? {
        guard let id = row.categorization?.categoryID,
              let category = byID?[id] ?? (byID == nil ? category(id) : nil), category.countsAsSpending else { return nil }
        switch (kinds ?? recurringIndex.kinds)[row.id] {
        case .bill?: return .bills
        case .subscription?: return .subscriptions
        case nil: return category.group
        }
    }

    /// A month's spending as the budget counts it, by bucket, each bucket's categories most spent first: each charge
    /// in its own month, except one spread over the year, which counts a twelfth in each of the twelve months from its
    /// own (listed apart, `isYearly`). Each category is net of its refunds and never below zero.
    /// - Parameters:
    ///   - start: the month's first instant.
    ///   - end: its end, or now for this month.
    ///   - includeTargets: attach each category's target, and list a targeted category with nothing spent yet.
    func budgetTotals(from start: Date, to end: Date, includeTargets: Bool = false) -> [CategoryGroup: [CategoryTotal]] {
        let index = recurringIndex
        let yearly = index.yearlyIDs
        let byID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let spreadFrom = calendar.date(byAdding: .month, value: -11, to: start)!
        var regular: [CategoryGroup: [String: [LedgerTransaction]]] = [:]
        var spread: [CategoryGroup: [String: [LedgerTransaction]]] = [:]
        for row in transactions where row.postedAt < end && row.postedAt >= spreadFrom && !row.isHidden {
            guard let bucket = bucket(of: row, categories: byID, kinds: index.kinds), let id = row.categorization?.categoryID else { continue }
            if yearly.contains(row.id) {
                spread[bucket, default: [:]][id, default: []].append(row)
            } else if row.postedAt >= start {
                regular[bucket, default: [:]][id, default: []].append(row)
            }
        }
        var totals: [CategoryGroup: [CategoryTotal]] = [:]
        for group in CategoryGroup.allCases {
            var list: [CategoryTotal] = []
            // A category's target sits with its own group's entry, even when a recurring merchant took some of it elsewhere.
            var ids = Set(regular[group]?.keys.map { $0 } ?? [])
            if includeTargets {
                ids.formUnion(monthlyTargets.keys.filter { byID[$0]?.group == group && byID[$0]?.countsAsSpending == true && byID[$0]?.isArchived == false })
            }
            for id in ids {
                guard let category = byID[id] else { continue }
                let rows = regular[group]?[id] ?? []
                list.append(CategoryTotal(category: category, spent: netSpend(rows, categoryIDs: [id]),
                                          target: includeTargets && category.group == group ? monthlyTargets[id] : nil,
                                          transactionCount: rows.count))
            }
            for (id, rows) in spread[group] ?? [:] {
                guard let category = byID[id] else { continue }
                let share = Money(minorUnits: netSpend(rows, categoryIDs: [id]).minorUnits / 12)
                guard share.minorUnits > 0 else { continue }
                list.append(CategoryTotal(category: category, spent: share, target: nil, transactionCount: rows.count, isYearly: true))
            }
            totals[group] = list.sorted { $0.spent != $1.spent ? $0.spent > $1.spent : $0.id < $1.id }
        }
        return totals
    }

    /// One bucket's spending over a month, as the budget counts it (`budgetTotals`).
    func budgetSpent(_ group: CategoryGroup, from start: Date, to end: Date) -> Money {
        (budgetTotals(from: start, to: end)[group] ?? []).map(\.spent).sum()
    }

    /// Everyday charges between two instants, each in full, spread ones left out — the days the week strip shows.
    func everydaySpent(from start: Date, to end: Date) -> Money {
        let index = recurringIndex
        let byID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return netSpend(transactions(from: start, to: end).filter {
            !index.yearlyIDs.contains($0.id) && bucket(of: $0, categories: byID, kinds: index.kinds) == .everyday
        })
    }
}

/// A number no ledger has had before: `Ledger.rowsToken`. Every change to the rows takes one, so it has to be cheap —
/// seeding a ledger changes them thousands of times.
enum RowsToken {
    private static let counter = Atomic<UInt64>(0)
    static func next() -> UInt64 { counter.add(1, ordering: .relaxed).newValue }
}

/// `Ledger.recurringIndex`, kept between reads until the rows change. A class, so the ledger (a value) can fill it in
/// from a non-mutating read; copies share it, keyed by their `rowsToken`.
final class RecurringCache: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UInt64?
    private var value: Ledger.RecurringIndex?

    func index(for token: UInt64, compute: () -> Ledger.RecurringIndex) -> Ledger.RecurringIndex {
        lock.lock()
        defer { lock.unlock() }
        if self.token != token || value == nil {
            value = compute()
            self.token = token
        }
        return value!
    }
}
