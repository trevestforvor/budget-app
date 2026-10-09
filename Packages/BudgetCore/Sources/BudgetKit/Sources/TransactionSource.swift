import Foundation

// Every bank-data provider implements one interface and writes into the ledger (intent:
// "All sources implement one TransactionSource interface"). These types are server-side;
// they live in BudgetKit so the Swift server and tests share them.

public struct SourceTransaction: Hashable, Sendable {
    public var externalID: String
    public var posted: Date
    /// Negative is money out.
    public var amount: Money
    public var description: String
    public var payee: String?
    public var isPending: Bool
    /// The provider's own category (Plaid personal_finance_category, Teller details.category) —
    /// a hint for the categorization pipeline, never the final answer.
    public var providerCategory: String?
    /// The provider's id for the pending row this posted row replaces (Plaid `pending_transaction_id`), so
    /// what the person did to the pending row carries over.
    public var replacesExternalID: String?

    public init(externalID: String, posted: Date, amount: Money, description: String, payee: String? = nil, isPending: Bool = false,
                providerCategory: String? = nil, replacesExternalID: String? = nil) {
        self.externalID = externalID
        self.posted = posted
        self.amount = amount
        self.description = description
        self.payee = payee
        self.isPending = isPending
        self.providerCategory = providerCategory
        self.replacesExternalID = replacesExternalID
    }
}

public struct SourceHolding: Hashable, Sendable {
    public var symbol: String?
    public var description: String
    public var marketValue: Money
}

public struct SourceAccount: Hashable, Sendable {
    public var externalID: String
    public var institution: String
    public var institutionDomain: String?
    public var name: String
    public var kind: AccountKind
    public var balance: Money
    public var availableBalance: Money?
    public var balanceDate: Date
    public var transactions: [SourceTransaction]
    public var holdings: [SourceHolding]
    /// Last digits of the account number, when the provider gives them.
    public var mask: String? = nil
    /// The provider's own account type, when it gives one (Plaid: "credit" for cards, "loan" for loans — both `.credit`
    /// here). Card bills are asked for only on Items with a "credit" one.
    public var providerType: String? = nil
}

public struct SourceSnapshot: Hashable, Sendable {
    public var source: SourceKind
    public var accounts: [SourceAccount]
    /// Provider messages worth showing (e.g. "Chase needs re-authentication").
    public var warnings: [String]
}

public protocol TransactionSource: Sendable {
    var kind: SourceKind { get }
    /// Accounts with balances and transactions posted on or after `since`.
    func fetch(since: Date, includePending: Bool) async throws -> SourceSnapshot
}

extension AccountKind {
    /// Best guess from a provider's account name; the person can correct it.
    public static func infer(fromName name: String) -> AccountKind {
        let n = name.lowercased()
        if ["brokerage", "invest", "ira", "401", "roth", "individual", "portfolio", "automated"].contains(where: n.contains) { return .investment }
        if ["card", "credit", "amex", "platinum", "gold", "sapphire", "freedom"].contains(where: n.contains) { return .credit }
        if ["saving", "cash account", "high yield", "money market"].contains(where: n.contains) { return .savings }
        return .checking
    }
}

// MARK: - Deduplication

/// Deduplicates rows across sources "on account + date + amount + fuzzy description" (intent).
/// The same card purchase can arrive from SimpleFIN and Plaid with different descriptors and
/// a day or two apart (pending vs posted), so dates get a window and descriptions a similarity.
public enum Deduplicator {
    public struct Key: Hashable, Sendable {
        public var account: String
        public var date: Date
        public var amount: Money
        public var description: String

        public init(account: String, date: Date, amount: Money, description: String) {
            self.account = account
            self.date = date
            self.amount = amount
            self.description = description
        }
    }

    public static let dateWindow: TimeInterval = 3 * 86_400
    public static let similarityThreshold = 0.5

    public static func isDuplicate(_ a: Key, _ b: Key) -> Bool {
        a.account == b.account && a.amount == b.amount && abs(a.date.timeIntervalSince(b.date)) <= dateWindow
            && similarity(a.description, b.description) >= similarityThreshold
    }

    /// The ledger row an incoming row duplicates, if any: same account and amount within the date window,
    /// most similar description first, then nearest date. Every wording of each side is compared — a
    /// provider's short name ("AMC Theatres") and its bank descriptor ("AplPay AMC 0001 EXAMPLE") — and
    /// a same-amount row a day or less away counts whatever the wording. A near-identical description
    /// stretches the window to five days: card credits can post days after the statement dates them.
    /// `similarOnly` drops the any-wording day-apart rule: an after-the-fact sweep can't tell whether that
    /// synced row already stands for a different imported row, so it needs the descriptions to agree.
    public static func bestMatch(account: String, date: Date, amount: Money, descriptions: [String], in rows: [LedgerTransaction],
                                 similarOnly: Bool = false) -> Int? {
        var best: (index: Int, score: Double, gap: TimeInterval)?
        for (index, row) in rows.enumerated() where row.accountID == account && row.amount == amount {
            let gap = abs(row.postedAt.timeIntervalSince(date))
            guard gap <= wideWindow else { continue }
            let score = descriptions.flatMap { d in [similarity(row.merchant, d), similarity(row.rawDescription, d)] }.max() ?? 0
            let matches = (!similarOnly && gap <= 86_400) || (gap <= dateWindow && score >= similarityThreshold) || score >= 0.8
            guard matches else { continue }
            if best == nil || score > best!.score || (score == best!.score && gap < best!.gap) { best = (index, score, gap) }
        }
        return best?.index
    }

    public static let wideWindow: TimeInterval = 5 * 86_400

    /// Elements of `incoming` that don't duplicate anything in `existing` (or each other).
    public static func unique<T>(_ incoming: [T], against existing: [T], key: (T) -> Key) -> [T] {
        var seen = existing.map(key)
        var out: [T] = []
        for item in incoming {
            let k = key(item)
            guard !seen.contains(where: { isDuplicate($0, k) }) else { continue }
            seen.append(k)
            out.append(item)
        }
        return out
    }

    /// Token-set similarity of normalized descriptors; containment counts as a match.
    static func similarity(_ a: String, _ b: String) -> Double {
        func tokens(_ s: String) -> Set<String> {
            Set(Descriptor.normalize(s).lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 1 })
        }
        let ta = tokens(a), tb = tokens(b)
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        if ta.isSubset(of: tb) || tb.isSubset(of: ta) { return 1 }
        return Double(ta.intersection(tb).count) / Double(ta.union(tb).count)
    }
}
