import Foundation

// How rows get filed on their own: the person's rules, and what merchant memory learned from their answers.

/// What a categorization rule matches. Every condition given must hold. Text ignores case and numbers, like
/// merchant memory: "PARAMOUNT PAYROLL 0923" is caught by "Paramount payroll", and so is next month's.
public struct RuleMatch: Hashable, Sendable, Codable {
    /// Text in the merchant name.
    public var merchantContains: String?
    /// Text in the bank descriptor.
    public var descriptorContains: String?
    /// Only money going out, or only money coming in.
    public var direction: TransactionFilter.Direction?
    /// Bounds on the size of the amount, whichever way it goes. Both are inclusive.
    public var minAmount: DecimalAmount?
    public var maxAmount: DecimalAmount?
    /// Only rows on this account (a generic descriptor like "Withdrawal" means one thing on one account).
    public var accountID: String?

    public init(merchantContains: String? = nil, descriptorContains: String? = nil, direction: TransactionFilter.Direction? = nil,
                minAmount: DecimalAmount? = nil, maxAmount: DecimalAmount? = nil, accountID: String? = nil) {
        self.merchantContains = merchantContains; self.descriptorContains = descriptorContains; self.direction = direction
        self.minAmount = minAmount; self.maxAmount = maxAmount; self.accountID = accountID
    }

    /// The same match as it's stored and compared: text trimmed, blank conditions dropped.
    public var normalized: RuleMatch {
        func clean(_ s: String?) -> String? { s.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } }
        return RuleMatch(merchantContains: clean(merchantContains), descriptorContains: clean(descriptorContains), direction: direction,
                         minAmount: minAmount, maxAmount: maxAmount, accountID: clean(accountID))
    }

    /// Whether two matches state the same conditions (text compared without case), so they pick out the same
    /// rows whatever the ledger holds.
    func isSame(as other: RuleMatch) -> Bool {
        let (a, b) = (normalized, other.normalized)
        return a.merchantContains?.uppercased() == b.merchantContains?.uppercased() && a.descriptorContains?.uppercased() == b.descriptorContains?.uppercased()
            && a.direction == b.direction && a.minAmount == b.minAmount && a.maxAmount == b.maxAmount && a.accountID == b.accountID
    }
}

/// Who made a rule.
public enum RuleAuthor: String, Hashable, Sendable, Codable {
    /// Made by the person, in the app or on the dashboard.
    case person
    /// Proposed by the assistant and applied by the person.
    case assistant
}

/// "Always file rows matching this under that category." Rules run first, before merchant memory and the
/// model; when several match a row, the newest wins.
public struct BudgetRule: Identifiable, Hashable, Sendable, Codable {
    /// "rule-3". Rows it files carry `decidedBy` "rule:<id>", which is how its hits are counted.
    public var id: String
    public var match: RuleMatch
    public var categoryID: String
    /// Nil for rules saved before this was recorded.
    public var createdAt: Date?
    public var createdBy: RuleAuthor
    /// A rule that's off files nothing; it's kept so it can be turned back on.
    public var isEnabled: Bool

    public init(id: String, match: RuleMatch, categoryID: String, createdAt: Date? = nil, createdBy: RuleAuthor = .person, isEnabled: Bool = true) {
        self.id = id; self.match = match; self.categoryID = categoryID; self.createdAt = createdAt; self.createdBy = createdBy; self.isEnabled = isEnabled
    }

    enum CodingKeys: String, CodingKey { case id, match, categoryID, createdAt, createdBy, isEnabled }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        match = try c.decode(RuleMatch.self, forKey: .match)
        categoryID = try c.decode(String.self, forKey: .categoryID)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        createdBy = try c.decodeIfPresent(RuleAuthor.self, forKey: .createdBy) ?? .person
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    /// `decidedBy` on the rows this rule files.
    public var stamp: String { Self.stampPrefix + id }
    static let stampPrefix = "rule:"

    /// The id a new rule gets: one past the highest "rule-<n>" in use by a rule or still stamped on a row. A deleted
    /// rule's rows keep its stamp, so its id is never handed out again (the new rule would inherit its hits).
    static func nextID(after rules: [BudgetRule], stampedOn transactions: [LedgerTransaction]) -> String {
        let ids = rules.map(\.id) + transactions.compactMap { row in
            row.categorization?.decidedBy.flatMap { $0.hasPrefix(stampPrefix) ? String($0.dropFirst(stampPrefix.count)) : nil }
        }
        let used = ids.compactMap { $0.hasPrefix("rule-") ? Int($0.dropFirst(5)) : nil }
        return "rule-\((used.max() ?? 0) + 1)"
    }

    /// Stored rules, current or saved before rules had ids (a bare `CreateBudgetRule`). An old one gets the id
    /// "rule-<n>" from its place in the list (the n-th rule is "rule-n"), so the same ledger always gives the
    /// same ids; it's credited to the assistant, since applying an Ask proposal was the only way to make one.
    static func decodeStored(from decoder: any Decoder) throws -> [BudgetRule] {
        struct Stored: Decodable {
            var rule: BudgetRule?
            var legacy: CreateBudgetRule?
            init(from decoder: any Decoder) throws {
                if try decoder.container(keyedBy: BudgetRule.CodingKeys.self).contains(.id) { rule = try BudgetRule(from: decoder) }
                else { legacy = try CreateBudgetRule(from: decoder) }
            }
        }
        let stored = try [Stored](from: decoder)
        var taken = Set(stored.compactMap(\.rule?.id))
        return stored.enumerated().map { index, entry in
            if let rule = entry.rule { return rule }
            var n = index + 1
            while taken.contains("rule-\(n)") { n += 1 }
            taken.insert("rule-\(n)")
            let old = entry.legacy!
            return BudgetRule(id: "rule-\(n)", match: old.match, categoryID: old.categoryID, createdBy: .assistant)
        }
    }
}

/// A rule as the rules list shows it: what it matches in words, what it has done, and what's wrong with it.
public struct RuleSummary: Identifiable, Hashable, Sendable, Codable {
    public var rule: BudgetRule
    /// "Bank description contains “PARAMOUNT PAYROLL” · money in · $1,000 or more · Total Checking"
    public var matchDescription: String
    /// Rows this rule filed that are still filed that way.
    public var hitCount: Int
    /// Rows it matches now, however they're filed — what re-filing with it would reach.
    public var matchCount: Int
    /// Other rules that disagree with this one: both on, both match some row now (or match exactly the same
    /// rows), different categories. The newer of the two wins those rows.
    public var conflicts: [String]
    /// Its category is gone or was merged away, so it files nothing.
    public var isDead: Bool
    public var id: String { rule.id }

    public init(rule: BudgetRule, matchDescription: String, hitCount: Int, matchCount: Int, conflicts: [String], isDead: Bool) {
        self.rule = rule; self.matchDescription = matchDescription; self.hitCount = hitCount; self.matchCount = matchCount
        self.conflicts = conflicts; self.isDead = isDead
    }
}

/// One thing merchant memory knows: rows with this bank descriptor file themselves under this category.
public struct RememberedMerchant: Identifiable, Hashable, Sendable, Codable {
    /// The descriptor as memory keys it, numbers and processor prefixes stripped ("CASA TACO"). `forgetMerchant` takes this.
    public var descriptor: String
    /// The merchant name on its newest row.
    public var merchant: String
    public var categoryID: String
    /// Where the remembered answer came from: `.user` (you), `.rule` (your rule), `.statement`, `.decisionModel`,
    /// or `.merchantMemory` when every row was itself filed from memory (demo data, very old rows).
    public var source: CategorizationTier
    /// The decision model's confidence, when the model made the call.
    public var confidence: Double?
    /// Rows with this descriptor (hidden ones aside).
    public var rowCount: Int
    public var lastSeen: Date
    public var id: String { descriptor }

    public init(descriptor: String, merchant: String, categoryID: String, source: CategorizationTier, confidence: Double?, rowCount: Int, lastSeen: Date) {
        self.descriptor = descriptor; self.merchant = merchant; self.categoryID = categoryID; self.source = source
        self.confidence = confidence; self.rowCount = rowCount; self.lastSeen = lastSeen
    }
}
