import BudgetKit
import Foundation

// Read models the dashboard needs and the phone doesn't: which months each account has rows for, and the review
// queue grouped so one answer files a whole group. Both are worked out from the ledger as it stands; neither
// changes anything. Filing a group goes through `POST /v1/actions` with the group's exact transaction ids.

/// Accounts × calendar months (the ledger's time zone): how many rows each account has in each of the last
/// `months` months, so the dashboard can show which statements are missing.
struct DashboardCoverage: Encodable, Sendable {
    struct Account: Encodable, Sendable {
        var id: String
        var name: String
        /// The person's name for it (L3), shown over the bank's `name`; omitted when unset.
        var nickname: String?
        var institution: String
        var mask: String?
        var kind: AccountKind
        var source: SourceKind
        /// Rows in each month of `months`, oldest first. Hidden and pending rows count: they came in with the data.
        var counts: [Int]
        var firstRow: Date?
        var lastRow: Date?
        /// The month of `firstRow` ("2025-03"), in the ledger's time zone.
        var firstMonth: String?
        /// Months ("2026-08") in the window with no rows, from the account's first row through last month.
        /// This month is still under way, so it's never a gap.
        var gaps: [String]
    }

    /// "2024-10" … "2026-09": oldest first, this month last.
    var months: [String]
    /// Accounts with rows, and statement accounts even before their first file. Balance-only accounts with no
    /// rows (an investment account synced for its balance) are left out: there's nothing to cover.
    var accounts: [Account]

    static func build(state: LedgerState, now: Date, calendar: Calendar, months count: Int = 24) -> DashboardCoverage {
        let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        let starts = (0..<count).reversed().compactMap { calendar.date(byAdding: .month, value: -$0, to: thisMonth) }
        let keys = starts.map { key($0, calendar) }
        let index = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
        var counts: [String: [Int]] = [:], first: [String: Date] = [:], last: [String: Date] = [:]
        for row in state.transactions {
            if first[row.accountID].map({ row.postedAt < $0 }) ?? true { first[row.accountID] = row.postedAt }
            if last[row.accountID].map({ row.postedAt > $0 }) ?? true { last[row.accountID] = row.postedAt }
            guard let i = index[key(row.postedAt, calendar)] else { continue }
            counts[row.accountID, default: Array(repeating: 0, count: keys.count)][i] += 1
        }
        let accounts = state.accounts
            .filter { first[$0.id] != nil || $0.source == .fileImport }
            .sorted { ($0.institution.lowercased(), $0.name.lowercased()) < ($1.institution.lowercased(), $1.name.lowercased()) }
            .map { account -> Account in
                let row = counts[account.id] ?? Array(repeating: 0, count: keys.count)
                let opened = first[account.id].map { key($0, calendar) }
                // "2025-03" sorts like the month it names, so string order is month order.
                let gaps = opened.map { opened in keys.indices.filter { $0 < keys.count - 1 && keys[$0] >= opened && row[$0] == 0 }.map { keys[$0] } } ?? []
                return Account(id: account.id, name: account.name, nickname: account.nickname, institution: account.institution, mask: account.mask, kind: account.kind,
                               source: account.source, counts: row, firstRow: first[account.id], lastRow: last[account.id], firstMonth: opened, gaps: gaps)
            }
        return DashboardCoverage(months: keys, accounts: accounts)
    }

    static func key(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }
}

/// The review queue in groups a person can answer at once — BudgetKit's `ReviewGroup`, the grouping the phone uses, so
/// the dashboard and the phone count the same decisions: rows on the same account, going the same way, whose bank
/// descriptors are the same once numbers and processor prefixes are stripped, and for a descriptor that names no
/// merchant the same merchant name; a row over the "check anything above" amount is its own group. Filing a group
/// sends exactly its `transactionIDs`, so nothing outside the group changes.
struct DashboardReviewGroups: Encodable, Sendable {
    struct Suggestion: Encodable, Sendable {
        var categoryID: String
        /// The model's confidence averaged over the group's rows (a row without this suggestion counts as 0).
        var confidence: Double
    }

    struct Row: Encodable, Sendable {
        var id: String
        var postedAt: Date
        var amount: Money
        var rawDescription: String
        var isPending: Bool
    }

    struct Group: Encodable, Sendable {
        /// Stable while the group's rows wait (`ReviewGroup.id`).
        var id: String
        /// The newest row's merchant name.
        var merchant: String
        var descriptor: String
        var accountID: String
        var direction: TransactionFilter.Direction
        var transactionIDs: [String]
        var total: Money
        var earliest: Date
        var latest: Date
        /// At most three, best first. Money going out is never offered a money-in category (Income, card rewards), and a
        /// merged-away category is never offered.
        var suggestions: [Suggestion]
        /// The reason most of its rows give.
        var reason: String
        /// A descriptor that names no merchant ("Withdrawal"): only grouped within one account and direction anyway.
        var isGeneric: Bool
        /// Over the "check anything above" amount, so it's answered on its own.
        var isLarge: Bool
        /// The rule "Make a rule" starts from — the phone's "always file these this way" (`ReviewGroup.scopedRule`).
        var rule: RuleMatch
        /// The newest few rows, for the dates and amounts.
        var rows: [Row]
    }

    var groups: [Group]
    /// Rows waiting, over all groups.
    var transactions: Int

    static let rowsShown = 5

    static func build(queue: [ReviewItem], categories: [BudgetCategory]) -> DashboardReviewGroups {
        let offered = Set(categories.filter { !$0.isArchived }.map(\.id))
        let moneyIn = Set(categories.filter(\.isMoneyIn).map(\.id))
        let groups = ReviewGroup.groups(queue).map { group -> Group in
            let rows = group.items.map(\.transaction)
            let newest = rows[0]
            let direction: TransactionFilter.Direction = group.key.isOutflow ? .moneyOut : .moneyIn
            var totals: [String: Double] = [:]
            for item in group.items { for s in item.suggestions { totals[s.categoryID, default: 0] += s.confidence } }
            let suggestions = totals
                .filter { offered.contains($0.key) && !(direction == .moneyOut && moneyIn.contains($0.key)) }
                .map { Suggestion(categoryID: $0.key, confidence: $0.value / Double(group.count)) }
                .sorted { ($0.confidence, $1.categoryID) > ($1.confidence, $0.categoryID) }
            var reasons: [String: Int] = [:]
            for item in group.items { reasons[item.reason, default: 0] += 1 }
            let reason = group.items.map(\.reason).first { reasons[$0] == reasons.values.max() } ?? ""
            return Group(id: group.id, merchant: newest.merchant, descriptor: group.key.descriptor, accountID: newest.accountID,
                         direction: direction, transactionIDs: group.transactionIDs, total: group.total,
                         earliest: rows.map(\.postedAt).min()!, latest: newest.postedAt, suggestions: Array(suggestions.prefix(3)), reason: reason,
                         isGeneric: group.isGeneric, isLarge: group.isLarge, rule: group.scopedRule,
                         rows: rows.prefix(rowsShown).map { Row(id: $0.id, postedAt: $0.postedAt, amount: $0.amount, rawDescription: $0.rawDescription, isPending: $0.isPending) })
        }
        return DashboardReviewGroups(groups: groups, transactions: queue.count)
    }
}

/// A category as the dashboard draws it: `color` is always the one it wears (`effectiveColor`), so the page
/// never keeps its own copy of the standard colors.
struct DashboardCategory: Encodable, Sendable {
    var id: String
    var name: String
    var group: CategoryGroup
    var countsAsSpending: Bool
    /// Spending or money in (`moneyIn`: Income and the ones like it, never offered for money going out).
    var kind: CategoryKind
    var isArchived: Bool
    /// A `CategoryColor` name; the page draws it with the design-system tone of the same name.
    var color: String
    /// Its SF Symbol on the phone, named on Categories & rules (the page can't draw it).
    var symbol: String

    init(_ category: BudgetCategory) {
        id = category.id
        name = category.name
        group = category.group
        countsAsSpending = category.countsAsSpending
        kind = category.kind
        isArchived = category.isArchived
        color = category.effectiveColor.rawValue
        symbol = category.symbol
    }
}
