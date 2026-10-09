import Foundation

// Tags: the person's own labels on transactions (a trip, a project, what work pays back), and spending by tag.

/// How tags are written and compared. A tag is trimmed, its inner spaces collapsed and a leading "#" dropped; tags
/// compare without case, so "austin trip" and "Austin trip" are one tag (the spelling already in the ledger wins).
public enum TransactionTags {
    /// The longest tag, in characters.
    public static let maxLength = 32
    /// The most tags one transaction carries.
    public static let maxPerTransaction = 10

    /// "  #Austin   trip " → "Austin trip"; nil when nothing is left.
    public static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("#") { text.removeFirst() }
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// The key two tags are compared by.
    public static func key(_ tag: String) -> String { (normalize(tag) ?? tag).lowercased() }

    /// Normalized, each once (the first spelling kept), in the order given.
    public static func cleaned(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap(normalize).filter { seen.insert($0.lowercased()).inserted }
    }

    /// Whether `tags` holds `tag`, ignoring case.
    public static func contains(_ tags: [String]?, _ tag: String) -> Bool {
        let k = key(tag)
        return (tags ?? []).contains { $0.lowercased() == k }
    }

    /// `old` then whatever of `new` it lacks; nil when that's nothing.
    public static func merged(_ old: [String]?, _ new: [String]?) -> [String]? {
        let all = cleaned((old ?? []) + (new ?? []))
        return all.isEmpty ? nil : all
    }
}

/// One tag across the ledger (or a period of it): how many rows carry it and what they add up to by the Spending tab's
/// rules — hidden rows and transfers left out, each category net of its refunds and never below zero, money-in
/// categories as income.
public struct TagSummary: Identifiable, Hashable, Codable, Sendable {
    /// One spending category's share of a tag.
    public struct CategorySpend: Hashable, Codable, Sendable {
        public var categoryID: String
        public var spent: Money
        public init(categoryID: String, spent: Money) { self.categoryID = categoryID; self.spent = spent }
    }

    public var tag: String
    /// Every row with the tag, hidden ones and transfers included.
    public var count: Int
    /// Spending net of refunds.
    public var spent: Money
    /// Money filed under a money-in category.
    public var income: Money
    public var earliest: Date?
    public var latest: Date?
    /// Spending by category, most first; categories with nothing spent are left out. Nil from a list that leaves it out.
    public var byCategory: [CategorySpend]?

    public var id: String { tag.lowercased() }

    public init(tag: String, count: Int, spent: Money, income: Money, earliest: Date?, latest: Date?, byCategory: [CategorySpend]? = nil) {
        self.tag = tag; self.count = count; self.spent = spent; self.income = income
        self.earliest = earliest; self.latest = latest; self.byCategory = byCategory
    }
}

extension ServerStatus {
    /// The first server that keeps tags on transactions and answers `GET /v1/tags`. An older one drops `addTags` and
    /// `removeTags` without a word (or refuses the edit as empty).
    public static let tagsSince = "0.5.0"
    /// The first server that files similar transactions with a re-file (`EditTransactions.fileSimilar`). An older one
    /// files only the rows named.
    public static let fileSimilarSince = "0.5.0"
    /// The first server with `GET /v1/transactions/export.csv`.
    public static let transactionExportSince = "0.5.0"
}

/// Tags and the CSV export, on clients whose ledger can answer them (the server, the demo). Reached as
/// `api as? any TransactionToolsAPI`, so the other `BudgetAPI` conformers don't need them.
public protocol TransactionToolsAPI: Sendable {
    /// Every tag in use, most recently used first; with `period` (as `TransactionFilter.period` names them) only rows in it
    /// count, and tags with none are left out.
    func tags(period: String?) async throws -> [TagSummary]
    /// One tag in full, with spending by category; `notFound` when no row carries it.
    func tag(_ name: String, period: String?) async throws -> TagSummary
    /// Every row the filter matches (paging ignored) as RFC 4180 CSV, in the filter's order.
    func exportCSV(_ filter: TransactionFilter) async throws -> Data
}
