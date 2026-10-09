import Foundation

// One merchant at a time: what the ledger knows about everywhere the person spends, and which store orders a card
// charge paid for. Merchants are named as the ledger shows them ("DoorDash"), compared without case.

/// One merchant's spending in a period, for "Most frequent" lists.
public struct MerchantTotal: Identifiable, Hashable, Codable, Sendable {
    public var merchant: String
    /// Spending there, net of its refunds (each category on its own, never below zero): the Spending tab's rule.
    public var spent: Money
    /// Charges there that count as spending: money out, not hidden, filed under a spending category.
    public var visits: Int
    /// The category most of its charges are filed under.
    public var categoryID: String?
    /// The newest of those charges.
    public var lastVisit: Date?
    public var id: String { merchant }

    public init(merchant: String, spent: Money, visits: Int, categoryID: String? = nil, lastVisit: Date? = nil) {
        self.merchant = merchant; self.spent = spent; self.visits = visits; self.categoryID = categoryID; self.lastVisit = lastVisit
    }
}

/// The merchants of one period, most visited (or most spent) first.
public struct TopMerchants: Hashable, Codable, Sendable {
    public enum Sort: String, Hashable, Codable, Sendable, CaseIterable {
        /// Most charges first: the places the person goes most.
        case visits
        /// Most money first.
        case spent
    }

    /// The period as asked ("this_month", "2026-09", "last_90_days").
    public var period: String
    /// "September 2026", "the last 90 days".
    public var label: String
    public var start: Date
    public var end: Date
    public var sort: Sort
    public var merchants: [MerchantTotal]
    /// How many merchants had a charge in the period, listed or not.
    public var merchantCount: Int
}

/// Everything the ledger knows about one merchant: what's gone there this month, over the last year and ever, how
/// often and how much at a time, whether it recurs, its category and cap, and its transactions.
public struct MerchantSummary: Hashable, Codable, Sendable {
    /// The name as the ledger shows it.
    public var merchant: String
    /// Spending there this month so far, net of refunds (the Spending tab's rule).
    public var thisMonth: Money
    /// This month and the eleven before it.
    public var lastTwelveMonths: Money
    /// Everything in the ledger.
    public var lifetime: Money
    /// Up to twelve months, oldest first, this one last; none from before the ledger's first row. `target` is the
    /// merchant's cap, when it has one.
    public var months: [MonthSpend]
    /// The mean of its charges (money out that counts as spending), over the whole ledger. Nil with none.
    public var averageCharge: Money?
    /// Its charges, over the whole ledger and in the last twelve months.
    public var charges: Int
    public var chargesLastTwelveMonths: Int
    /// Charges a month over the last twelve months, or as much of them as the ledger covers. Nil with no charges.
    public var visitsPerMonth: Double?
    /// The same in words: "About 6 times a month", "About once every 3 months".
    public var frequency: String
    public var firstCharge: Date?
    public var lastCharge: Date?
    /// The category most of its charges are filed under; nil when nothing is filed.
    public var categoryID: String?
    /// Every category its rows are filed under, most rows first.
    public var categoryIDs: [String]
    /// The recurring series its charges make, when they recur (`findSubscriptions`'s own).
    public var recurring: Subscription?
    /// The monthly cap that counts its charges, with this month's spend against it.
    public var cap: MerchantCap?
    /// Its rows, newest first: hidden ones and money in included, at most `transactionLimit`.
    public var transactions: [LedgerTransaction]
    /// All its rows, however many `transactions` holds.
    public var transactionCount: Int

    public static let transactionLimit = 100
}

/// What a store's order history says a card charge paid for: an Amazon order, or one shipment of it.
public struct OrderMatch: Hashable, Codable, Sendable {
    /// "Amazon".
    public var store: String
    public var orderID: String
    /// The shipment the charge paid for ("2026-09-14"), when the order was charged a shipment at a time; nil when the
    /// charge was the whole order.
    public var shipment: String?
    /// What it bought, as the store names it ("Pour-over coffee filters ×2").
    public var items: [String]
    public var orderedAt: Date?

    public init(store: String, orderID: String, shipment: String? = nil, items: [String], orderedAt: Date? = nil) {
        self.store = store; self.orderID = orderID; self.shipment = shipment; self.items = items; self.orderedAt = orderedAt
    }

    /// "Coffee filters, Desk lamp and 2 more".
    public var itemsLine: String {
        guard items.count > 2 else { return items.joined(separator: ", ") }
        return "\(items.prefix(2).joined(separator: ", ")) and \(items.count - 2) more"
    }
}

/// What matching an order history file did (or, previewed, would do).
public struct OrderImportReport: Hashable, Codable, Sendable {
    /// One charge matched to an order, or one shipment of it.
    public struct Match: Hashable, Codable, Sendable {
        public var transactionID: String
        public var orderID: String
        public var postedAt: Date
        public var amount: Money
        public var items: [String]
        /// The category its items read as, when that differs from the charge's and it went to review.
        public var suggestedCategoryID: String?
    }

    /// An order no charge was found for.
    public struct Unmatched: Hashable, Codable, Sendable {
        public var orderID: String
        public var orderedAt: Date
        public var total: Money
        public var items: [String]
    }

    public var store: String
    /// False for a preview: nothing changed.
    public var applied: Bool
    /// Orders read from the file: cancelled lines and orders that owed nothing left out.
    public var orders: Int
    /// Charges matched to an order (or a shipment of one) by this import.
    public var matched: Int
    /// Orders an earlier import already matched; they're left as they are.
    public var alreadyMatched: Int
    /// Orders within the ledger's dates that no charge matched.
    public var unmatched: Int
    /// Orders from before the ledger's first transaction, which can't have a charge in it.
    public var beforeLedger: Int
    /// Matched charges whose items read as another category than the charge's: sent to review with that suggestion.
    /// Nothing is re-filed without the person.
    public var suggested: Int
    /// Lines that couldn't be read, were cancelled, or belong to an order that owed nothing.
    public var skippedLines: Int
    /// The matches made, newest first (at most `sampleSize`).
    public var matches: [Match]
    /// The newest orders left unmatched (at most `sampleSize`).
    public var unmatchedOrders: [Unmatched]

    public static let sampleSize = 20
}

/// The merchant views and order matching, on clients that talk to a server new enough (`ServerStatus.merchantsSince`)
/// or to the demo ledger. A side protocol so `BudgetAPI` keeps its shape for older conformers.
public protocol MerchantAPI: Sendable {
    /// One merchant (`GET /v1/merchants/summary?name=`). Unknown merchants are `BudgetAPIError.notFound`.
    func merchantSummary(_ merchant: String) async throws -> MerchantSummary
    /// The merchants of a period (`GET /v1/merchants`), most visited first unless `sort` says otherwise.
    func topMerchants(period: String, limit: Int, sort: TopMerchants.Sort) async throws -> TopMerchants
}

extension ServerStatus {
    /// The first server with merchant pages (`/v1/merchants`, `/v1/merchants/summary`), Amazon order matching
    /// (`/v1/imports/amazon`) and a charge's `orderMatch`. Older ones answer those routes with 404.
    public static let merchantsSince = "0.5.0"
}
