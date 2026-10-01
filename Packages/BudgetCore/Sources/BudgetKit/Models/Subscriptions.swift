import Foundation

/// A charge that repeats on a schedule, found in the ledger — not declared by anyone.
public struct Subscription: Identifiable, Hashable, Codable, Sendable {
    public enum Cadence: String, Hashable, Codable, Sendable, CaseIterable {
        case weekly, monthly, quarterly, yearly
        var days: Double { switch self { case .weekly: 7; case .monthly: 30.4; case .quarterly: 91.3; case .yearly: 365.2 } }
        /// "every month", "every 3 months".
        public var every: String {
            switch self { case .weekly: "every week"; case .monthly: "every month"; case .quarterly: "every 3 months"; case .yearly: "every year" }
        }
        /// How long after its last charge a series is taken as over and leaves the list — about three missed charges
        /// for weekly and monthly ones, two for quarterly, half a year past a yearly one. Its charges keep their bucket.
        var staleAfter: Double { switch self { case .weekly: 28; case .monthly: 92; case .quarterly: 183; case .yearly: 548 } }
        /// How late a charge can be before it counts as missed.
        var grace: Double { switch self { case .weekly: 4; case .monthly: 10; case .quarterly: 21; case .yearly: 35 } }
    }
    /// Subscriptions are the ones you choose to keep; bills are rent, utilities and fees.
    public enum Kind: String, Hashable, Codable, Sendable, CaseIterable { case subscription, bill }
    public enum Status: String, Hashable, Codable, Sendable { case active, missed }

    public var id: String { merchant }
    public var merchant: String
    public var kind: Kind
    public var cadence: Cadence
    public var status: Status
    /// The latest charge.
    public var amount: Money
    /// The charge before it, when the price changed.
    public var previousAmount: Money?
    public var monthlyCost: Money
    public var yearlyCost: Money
    public var lastCharged: Date
    public var nextExpected: Date
    public var charges: Int
    public var categoryID: String?
    public var accountName: String?
    /// The person set how often it comes, or whether it's a subscription or a bill (`RecurringChoice`); nil when it's
    /// all what Budget found.
    public var setByPerson: Bool? = nil
    /// Every name its charges carry when the bank wrote the merchant more than one way; nil when it's just `merchant`.
    public var names: [String]? = nil

    /// Whether a charge from `merchant` is one of this series'.
    public func covers(_ merchant: String) -> Bool {
        merchant.caseInsensitiveCompare(self.merchant) == .orderedSame || (names ?? []).contains(merchant)
    }
}

/// The person's say on one merchant's recurring charges, which wins over what Budget finds in them: not recurring at
/// all (a restaurant visited every few months), or recurring on a cadence they give — even from a single charge, like a
/// first yearly one — and as a subscription or a bill.
public struct RecurringChoice: Hashable, Codable, Sendable {
    /// The merchant as shown ("Brenda's Meat").
    public var merchant: String
    /// False: never a subscription or a bill, whatever its charges look like.
    public var isRecurring: Bool
    /// How often it comes; nil keeps what Budget finds.
    public var cadence: Subscription.Cadence?
    /// Subscription or bill; nil keeps Budget's call (rent, utilities and fees are bills).
    public var kind: Subscription.Kind?
    /// The size of the charge that recurs, with a cadence the person gave: only the merchant's charges within a fifth of
    /// it are the series — Amazon Prime, not every Amazon order. Nil uses the latest charge.
    public var amount: Money?

    public init(merchant: String, isRecurring: Bool, cadence: Subscription.Cadence? = nil, kind: Subscription.Kind? = nil, amount: Money? = nil) {
        self.merchant = merchant; self.isRecurring = isRecurring; self.cadence = cadence; self.kind = kind; self.amount = amount
    }

    /// Whether a charge of `size` is the one that recurs at `anchor`: within a fifth of it (a dollar at least).
    static func matches(_ size: Money, _ anchor: Money) -> Bool {
        abs(size.minorUnits - anchor.minorUnits) <= max(anchor.minorUnits / 5, 100)
    }

    /// How choices are keyed: the merchant name, trimmed and lowercased.
    public static func key(_ merchant: String) -> String { merchant.trimmingCharacters(in: .whitespaces).lowercased() }
}

public struct SubscriptionSummary: Hashable, Codable, Sendable {
    public var asOf: Date
    /// Active and missed, most expensive (per month) first.
    public var items: [Subscription]
    public var subscriptionsMonthly: Money
    public var billsMonthly: Money
    public var subscriptionsYearly: Money
    /// Months of history the search had; annual charges need about a year to show up.
    public var monthsSearched: Int
    /// What the active charges are expected to take over the next 30 days: every expected charge in that window at
    /// its latest amount (a weekly one counts each week; one a few days late counts once). Nil from older servers.
    public var dueNext30Days: Money? = nil
    /// Merchants the person took off recurring, by name — so they can be put back. Nil from older servers.
    public var notRecurring: [String]? = nil
}
