import Foundation

/// Rows waiting for review that one answer settles: the same account, the same bank descriptor (as merchant
/// memory reads it, numbers and processor prefixes dropped), and the same direction. Grouping by merchant
/// name would lump a Meadow "Withdrawal" with a Harbor one; by account and direction it never does.
/// A descriptor that names no merchant ("WITHDRAWAL", or "PAYPAL *XJ29QK" once its code is stripped) is also told
/// apart by the merchant name the bank gave, so PayPal and a Square stall never share a group; and a row over the
/// "check anything above" amount is answered on its own. The phone and the dashboard both group with this, so
/// their counts of decisions agree. Filing a group sends its exact row ids, so nothing outside it moves.
public struct ReviewGroup: Identifiable, Hashable, Sendable {
    public struct Key: Hashable, Sendable {
        public let accountID: String
        public let descriptor: String
        public let isOutflow: Bool
        /// The bank's merchant name, upper-cased, for a descriptor that names no merchant; nil otherwise.
        public let merchant: String?
        /// A row over the check-above amount, answered on its own; nil otherwise.
        public let rowID: String?

        public init(accountID: String, descriptor: String, isOutflow: Bool, merchant: String? = nil, rowID: String? = nil) {
            self.accountID = accountID; self.descriptor = descriptor; self.isOutflow = isOutflow; self.merchant = merchant; self.rowID = rowID
        }
    }

    public let key: Key
    /// Newest first; never empty.
    public let items: [ReviewItem]

    public var id: String {
        if let rowID = key.rowID { return "row|\(rowID)" }
        return "\(key.accountID)|\(key.isOutflow ? "out" : "in")|\(key.descriptor)" + (key.merchant.map { "|\($0)" } ?? "")
    }
    public var first: ReviewItem { items[0] }
    public var count: Int { items.count }
    public var transactionIDs: [String] { items.map(\.id) }
    public var merchant: String { first.transaction.merchant }
    public var total: Money { items.map(\.transaction.amount).sum(currencyCode: first.transaction.amount.currencyCode) }
    /// Descriptors like "Withdrawal" name no merchant, so memory can't learn from them; a rule scoped to the
    /// account and direction (`scopedRule`) is what files the next one.
    public var isGeneric: Bool { Descriptor.isGeneric(first.transaction.rawDescription) }
    /// Over the check-above amount, so it's answered on its own.
    public var isLarge: Bool { key.rowID != nil }
    /// What the pipeline would file the first row under: its current category, else the top suggestion.
    public var bestGuess: String? { first.transaction.categorization?.categoryID ?? first.suggestions.first?.categoryID }

    public func contains(_ transactionID: String) -> Bool { items.contains { $0.id == transactionID } }

    /// "Always file these this way", as both the phone and the dashboard offer it: the descriptor as merchant memory
    /// reads it ("CASA TACO", so next month's "SQ *CASA TACO 0611" is caught too), going this way. A descriptor
    /// that names no merchant keeps its exact text ("PAYPAL *XJ29QK", never an empty condition that would catch
    /// everything) and is scoped to its account, which is what tells those rows apart.
    public var scopedRule: RuleMatch {
        let raw = first.transaction.rawDescription.trimmingCharacters(in: .whitespaces)
        let cleaned = Descriptor.normalize(raw)
        let text = isGeneric || cleaned.count < 2 ? raw : cleaned
        return RuleMatch(descriptorContains: String(text.prefix(60)), direction: key.isOutflow ? .moneyOut : .moneyIn,
                         accountID: isGeneric ? key.accountID : nil)
    }

    public static func key(for item: ReviewItem) -> Key {
        let row = item.transaction
        return Key(accountID: row.accountID, descriptor: Descriptor.normalize(row.rawDescription), isOutflow: row.amount.isNegative,
                   merchant: Descriptor.isGeneric(row.rawDescription) ? row.merchant.uppercased() : nil,
                   rowID: item.isLarge == true ? row.id : nil)
    }

    /// The queue in a sentence, counted in decisions as the tab badge counts it: "3 transactions need a quick look." or
    /// "8 quick answers file 11 transactions." The phone, the checkup and the dashboard all say it this way.
    public static func headline(decisions: Int, transactions: Int) -> String {
        if transactions <= decisions {
            return "\(decisions) transaction\(decisions == 1 ? "" : "s") need\(decisions == 1 ? "s" : "") a quick look."
        }
        return "\(decisions) quick answer\(decisions == 1 ? "" : "s") file\(decisions == 1 ? "s" : "") \(transactions) transactions."
    }

    /// The answers that file the most rows first, then the most money, then the most recent.
    public static func groups(_ items: [ReviewItem]) -> [ReviewGroup] {
        var order: [Key] = []
        var byKey: [Key: [ReviewItem]] = [:]
        for item in items {
            let key = key(for: item)
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(item)
        }
        return order
            .map { ReviewGroup(key: $0, items: byKey[$0]!.sorted { $0.transaction.postedAt > $1.transaction.postedAt }) }
            .sorted { a, b in
                (a.count, a.total.magnitude.minorUnits, a.first.transaction.postedAt) > (b.count, b.total.magnitude.minorUnits, b.first.transaction.postedAt)
            }
    }
}
