import Foundation

/// Which rows a list, its summary, or the assistant's `queryTransactions` wants. Every field narrows; the
/// defaults match every row, newest first. On the wire it travels as query items (`queryItems` and
/// `init(queryItems:)`), the one coding the app's client and the server share.
public struct TransactionFilter: Hashable, Codable, Sendable {
    public enum Direction: String, Hashable, Codable, Sendable, CaseIterable {
        /// Money out (negative amounts).
        case moneyOut = "out"
        /// Money in (positive amounts).
        case moneyIn = "in"
    }

    public enum Visibility: String, Hashable, Codable, Sendable, CaseIterable {
        case all
        /// Rows that count toward spending and income.
        case counted
        /// Hidden rows and transfers between the person's own accounts.
        case notCounted
    }

    public enum Sort: String, Hashable, Codable, Sendable, CaseIterable {
        case newest, oldest
        /// Biggest amount first, money in or out.
        case largest
    }

    /// Matches the merchant, the bank descriptor, the note, or an amount ("42.50", "$1,250"; "42" finds $42.00–42.99).
    public var search: String?
    /// Any of these categories. Empty means any category.
    public var categoryIDs: [String]?
    /// Any of these accounts. Empty means any account.
    public var accountIDs: [String]?
    /// A period as the ledger names them: this_month, last_month, last_30_days, last_90_days, last_6_months,
    /// year_to_date, last_year, all, a month like 2026-09, or a quarter like 2026-Q3.
    public var period: String?
    /// Posted on or after.
    public var since: Date?
    /// Posted before.
    public var until: Date?
    public var direction: Direction?
    /// Bounds on the size of the amount, whichever way it goes.
    public var minAmount: Money?
    public var maxAmount: Money?
    public var needsReviewOnly: Bool
    public var pendingOnly: Bool
    /// Rows the decision model filed on its own, to check or overrule.
    public var modelFiledOnly: Bool
    public var visibility: Visibility
    public var sort: Sort
    /// Page size.
    public var limit: Int
    /// Rows to skip, for the next page.
    public var offset: Int

    public init(search: String? = nil, categoryIDs: [String]? = nil, accountIDs: [String]? = nil, period: String? = nil,
                since: Date? = nil, until: Date? = nil, direction: Direction? = nil, minAmount: Money? = nil, maxAmount: Money? = nil,
                needsReviewOnly: Bool = false, pendingOnly: Bool = false, modelFiledOnly: Bool = false,
                visibility: Visibility = .all, sort: Sort = .newest, limit: Int = 200, offset: Int = 0) {
        self.search = search; self.categoryIDs = categoryIDs; self.accountIDs = accountIDs; self.period = period
        self.since = since; self.until = until; self.direction = direction; self.minAmount = minAmount; self.maxAmount = maxAmount
        self.needsReviewOnly = needsReviewOnly; self.pendingOnly = pendingOnly; self.modelFiledOnly = modelFiledOnly
        self.visibility = visibility; self.sort = sort; self.limit = limit; self.offset = offset
    }

    /// One category's rows (a category detail screen).
    public init(categoryID: String?, limit: Int = 200) {
        self.init(categoryIDs: categoryID.map { [$0] }, limit: limit)
    }

    /// The single category, when the filter names exactly one.
    public var categoryID: String? {
        get { categoryIDs?.count == 1 ? categoryIDs?.first : nil }
        set { categoryIDs = newValue.map { [$0] } }
    }

    /// Nothing narrowed and the first page, newest first: the list worth keeping offline.
    public var isDefault: Bool {
        var plain = self
        if plain.search?.trimmingCharacters(in: .whitespaces).isEmpty == true { plain.search = nil }
        if plain.categoryIDs?.isEmpty == true { plain.categoryIDs = nil }
        if plain.accountIDs?.isEmpty == true { plain.accountIDs = nil }
        return plain == TransactionFilter(limit: limit)
    }

    enum CodingKeys: String, CodingKey {
        case search, categoryIDs, accountIDs, period, since, until, direction, minAmount, maxAmount
        case needsReviewOnly, pendingOnly, modelFiledOnly, visibility, sort, limit, offset
    }

    /// Every field is optional in JSON: a missing one is its default.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(search: try c.decodeIfPresent(String.self, forKey: .search),
                  categoryIDs: try c.decodeIfPresent([String].self, forKey: .categoryIDs),
                  accountIDs: try c.decodeIfPresent([String].self, forKey: .accountIDs),
                  period: try c.decodeIfPresent(String.self, forKey: .period),
                  since: try c.decodeIfPresent(Date.self, forKey: .since),
                  until: try c.decodeIfPresent(Date.self, forKey: .until),
                  direction: try c.decodeIfPresent(Direction.self, forKey: .direction),
                  minAmount: try c.decodeIfPresent(Money.self, forKey: .minAmount),
                  maxAmount: try c.decodeIfPresent(Money.self, forKey: .maxAmount),
                  needsReviewOnly: try c.decodeIfPresent(Bool.self, forKey: .needsReviewOnly) ?? false,
                  pendingOnly: try c.decodeIfPresent(Bool.self, forKey: .pendingOnly) ?? false,
                  modelFiledOnly: try c.decodeIfPresent(Bool.self, forKey: .modelFiledOnly) ?? false,
                  visibility: try c.decodeIfPresent(Visibility.self, forKey: .visibility) ?? .all,
                  sort: try c.decodeIfPresent(Sort.self, forKey: .sort) ?? .newest,
                  limit: try c.decodeIfPresent(Int.self, forKey: .limit) ?? 200,
                  offset: try c.decodeIfPresent(Int.self, forKey: .offset) ?? 0)
    }
}

// MARK: - Query items (GET /v1/transactions and /v1/transactions/summary)

extension TransactionFilter {
    /// The filter as URL query items; only what differs from the defaults is sent (plus the page size).
    /// Categories and accounts repeat their name (`category=dining&category=travel`).
    public var queryItems: [URLQueryItem] {
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if offset > 0 { items.append(URLQueryItem(name: "offset", value: String(offset))) }
        if let search = search?.trimmingCharacters(in: .whitespaces), !search.isEmpty { items.append(URLQueryItem(name: "q", value: search)) }
        items += (categoryIDs ?? []).map { URLQueryItem(name: "category", value: $0) }
        items += (accountIDs ?? []).map { URLQueryItem(name: "account", value: $0) }
        if let period { items.append(URLQueryItem(name: "period", value: period)) }
        if let since { items.append(URLQueryItem(name: "since", value: since.formatted(.iso8601))) }
        if let until { items.append(URLQueryItem(name: "until", value: until.formatted(.iso8601))) }
        if let direction { items.append(URLQueryItem(name: "direction", value: direction.rawValue)) }
        if let minAmount { items.append(URLQueryItem(name: "min", value: DecimalAmount(minAmount.magnitude).description)) }
        if let maxAmount { items.append(URLQueryItem(name: "max", value: DecimalAmount(maxAmount.magnitude).description)) }
        if needsReviewOnly { items.append(URLQueryItem(name: "needsReview", value: "true")) }
        if pendingOnly { items.append(URLQueryItem(name: "pending", value: "true")) }
        if modelFiledOnly { items.append(URLQueryItem(name: "modelFiled", value: "true")) }
        if visibility != .all { items.append(URLQueryItem(name: "visibility", value: visibility.rawValue)) }
        if sort != .newest { items.append(URLQueryItem(name: "sort", value: sort.rawValue)) }
        return items
    }

    /// Reads `queryItems` back. Unknown names are ignored; a value that can't be read is refused with a
    /// message saying which (`BudgetAPIError.decoding`, a 400 on the server).
    /// - Parameters:
    ///   - calendar: reads a bare `since`/`until` day (2026-09-01) as the start of that day.
    ///   - maxLimit: the largest page served.
    public init(queryItems: [URLQueryItem], calendar: Calendar = .current, maxLimit: Int = 5000) throws {
        func values(_ name: String) -> [String] {
            queryItems.filter { $0.name == name }.compactMap { $0.value?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        func value(_ name: String) -> String? { values(name).first }
        func flag(_ name: String) -> Bool { value(name).map { ["true", "1", "yes"].contains($0.lowercased()) } ?? false }
        func count(_ name: String, default fallback: Int) throws -> Int {
            guard let raw = value(name) else { return fallback }
            guard let n = Int(raw), n >= 0 else { throw BudgetAPIError.decoding("\(name) must be a whole number, got “\(raw)”") }
            return n
        }
        func date(_ name: String) throws -> Date? {
            guard let raw = value(name) else { return nil }
            if let instant = try? Date(raw, strategy: .iso8601) { return instant }
            if let m = raw.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})/),
               let day = calendar.date(from: DateComponents(year: Int(m.1), month: Int(m.2), day: Int(m.3))) { return day }
            throw BudgetAPIError.decoding("\(name) must be a date like 2026-09-01, got “\(raw)”")
        }
        func amount(_ name: String) throws -> Money? {
            guard let raw = value(name) else { return nil }
            guard let parsed = DecimalAmount(string: raw.replacingOccurrences(of: ",", with: "")) else {
                throw BudgetAPIError.decoding("\(name) must be an amount like 25 or 25.50, got “\(raw)”")
            }
            return parsed.money().magnitude
        }
        func option<T: RawRepresentable>(_ name: String, _ type: T.Type) throws -> T? where T.RawValue == String, T: CaseIterable {
            guard let raw = value(name) else { return nil }
            guard let parsed = T(rawValue: raw) else {
                throw BudgetAPIError.decoding("\(name) must be \(T.allCases.map(\.rawValue).spokenList.replacingOccurrences(of: " and ", with: " or ")), got “\(raw)”")
            }
            return parsed
        }
        let categories = values("category"), accounts = values("account")
        self.init(search: value("q"), categoryIDs: categories.isEmpty ? nil : categories, accountIDs: accounts.isEmpty ? nil : accounts,
                  period: value("period"), since: try date("since"), until: try date("until"),
                  direction: try option("direction", Direction.self), minAmount: try amount("min"), maxAmount: try amount("max"),
                  needsReviewOnly: flag("needsReview"), pendingOnly: flag("pending"), modelFiledOnly: flag("modelFiled"),
                  visibility: try option("visibility", Visibility.self) ?? .all, sort: try option("sort", Sort.self) ?? .newest,
                  limit: min(try count("limit", default: 200), maxLimit), offset: try count("offset", default: 0))
    }
}

// MARK: - Summary

/// Totals over every row a filter matches, worked out by the ledger with the Spending tab's rules, so a
/// filtered list's summary and the budget always agree.
public struct TransactionSummary: Hashable, Codable, Sendable {
    public var count: Int
    /// Posting dates of the oldest and newest match.
    public var earliest: Date?
    public var latest: Date?
    /// Money out in spending categories net of refunds in them, hidden rows left out: the same figure the
    /// Spending tab shows for the same rows.
    public var spent: Money
    /// Money filed as income, hidden rows left out.
    public var income: Money
    /// Matches that don't count toward spending or income: transfers between the person's accounts, plus
    /// hidden rows (`hiddenCount` of them).
    public var notCountedCount: Int
    /// Money out among those, as a positive amount.
    public var notCountedTotal: Money
    public var hiddenCount: Int
    public var needsReviewCount: Int
    public var pendingCount: Int

    public init(count: Int, earliest: Date?, latest: Date?, spent: Money, income: Money, notCountedCount: Int, notCountedTotal: Money,
                hiddenCount: Int, needsReviewCount: Int, pendingCount: Int) {
        self.count = count; self.earliest = earliest; self.latest = latest; self.spent = spent; self.income = income
        self.notCountedCount = notCountedCount; self.notCountedTotal = notCountedTotal; self.hiddenCount = hiddenCount
        self.needsReviewCount = needsReviewCount; self.pendingCount = pendingCount
    }
}
