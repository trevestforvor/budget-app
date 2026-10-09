import Foundation

// What's coming up: expected paychecks, bills and subscriptions from the recurring list, and card bills from the card
// issuer (Plaid Liabilities), day by day. All of it is worked out by the ledger (`Ledger.upcoming(days:)`).

/// A credit card's latest statement as the card issuer reports it (Plaid Liabilities), kept per ledger account. Every
/// field the issuer may leave out is optional; the ledger works with what's there. `paidSinceStatement`, `remaining`
/// and `status` are the ledger's reading of it against the card's own rows, set when it's presented.
public struct CardBill: Identifiable, Hashable, Codable, Sendable {
    public var id: String { accountID }
    /// The ledger account (`Account.id`) of the card.
    public var accountID: String
    /// What the latest statement said was owed.
    public var statementBalance: Money?
    /// When the latest statement was issued.
    public var statementDate: Date?
    public var minimumPayment: Money?
    /// When the next payment is due.
    public var dueDate: Date?
    /// The issuer says a payment is past due.
    public var isOverdue: Bool?
    public var lastPaymentAmount: Money?
    public var lastPaymentDate: Date?
    /// The purchase APR, percent, when the issuer gives one.
    public var purchaseAPR: Double?
    /// When the issuer's figures were fetched.
    public var updatedAt: Date
    /// Days after `updatedAt` a statement is no longer shown: a statement cycle and a few days.
    static let staleAfter: Double = 35

    // The ledger's reading, set when presented (nil in storage).
    /// "Gold Card ••1008".
    public var accountName: String?
    /// Payments into the card the ledger has seen since the statement date.
    public var paidSinceStatement: Money?
    /// What's left of the statement balance after those payments, never below zero.
    public var remaining: Money?
    public var status: Status?

    public enum Status: String, Hashable, Codable, Sendable, CaseIterable {
        /// Something's owed and the due date is ahead.
        case due
        /// The statement balance is paid.
        case paid
        /// The issuer says it's past due, or the due date passed with a balance left.
        case overdue
        /// No balance on the statement (or no statement yet).
        case nothingDue

        /// A status a later version adds decodes as `.due`, instead of failing the whole response.
        public init(from decoder: any Decoder) throws {
            self = Status(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .due
        }
    }

    public init(accountID: String, statementBalance: Money? = nil, statementDate: Date? = nil, minimumPayment: Money? = nil,
                dueDate: Date? = nil, isOverdue: Bool? = nil, lastPaymentAmount: Money? = nil, lastPaymentDate: Date? = nil,
                purchaseAPR: Double? = nil, updatedAt: Date) {
        self.accountID = accountID; self.statementBalance = statementBalance; self.statementDate = statementDate
        self.minimumPayment = minimumPayment; self.dueDate = dueDate; self.isOverdue = isOverdue
        self.lastPaymentAmount = lastPaymentAmount; self.lastPaymentDate = lastPaymentDate; self.purchaseAPR = purchaseAPR
        self.updatedAt = updatedAt
    }
}

/// One thing expected on a day: a paycheck, a bill, a subscription or a card bill.
public struct UpcomingItem: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable, CaseIterable {
        case income, bill, subscription, cardBill

        public var label: String {
            switch self {
            case .income: "Income"
            case .bill: "Bill"
            case .subscription: "Subscription"
            case .cardBill: "Card bill"
            }
        }

        /// A kind a later version adds decodes as `.bill` (money going out), instead of failing the whole response.
        public init(from decoder: any Decoder) throws {
            self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .bill
        }
    }

    /// Stable across loads: kind, who, and the day.
    public var id: String
    public var kind: Kind
    /// The day it's expected, at the start of that day in the ledger's calendar.
    public var date: Date
    /// "Acme Corp", "Netflix", "Gold Card ••1008".
    public var title: String
    /// Signed the ledger's way: money in positive, money out negative. A card bill is what's left of its statement balance.
    public var amount: Money
    public var categoryID: String?
    public var accountID: String?
    /// For income, bills and subscriptions: how often it comes.
    public var cadence: Subscription.Cadence?
    /// A prediction from past charges or paychecks (true), or a date the issuer gave (false, card bills).
    public var isEstimate: Bool
    /// Late: expected earlier and not seen yet (shown on today), or a card bill the issuer says is past due.
    public var isLate: Bool?
    /// A card bill's minimum payment.
    public var minimumPayment: Money?

    public init(id: String, kind: Kind, date: Date, title: String, amount: Money, categoryID: String? = nil, accountID: String? = nil,
                cadence: Subscription.Cadence? = nil, isEstimate: Bool, isLate: Bool? = nil, minimumPayment: Money? = nil) {
        self.id = id; self.kind = kind; self.date = date; self.title = title; self.amount = amount; self.categoryID = categoryID
        self.accountID = accountID; self.cadence = cadence; self.isEstimate = isEstimate; self.isLate = isLate; self.minimumPayment = minimumPayment
    }
}

/// What a stretch of days holds, by kind. Every amount is a magnitude.
public struct UpcomingTotals: Hashable, Codable, Sendable {
    public var income: Money
    public var bills: Money
    public var subscriptions: Money
    /// Card bills pay for spending already made on the cards (a subscription charged to a card is counted on its own
    /// day, and again inside a later card bill), so they're kept apart from new charges.
    public var cardBills: Money

    public init(income: Money = .zero, bills: Money = .zero, subscriptions: Money = .zero, cardBills: Money = .zero) {
        self.income = income; self.bills = bills; self.subscriptions = subscriptions; self.cardBills = cardBills
    }

    /// Bills and subscriptions: new charges, card bills aside.
    public var charges: Money { bills + subscriptions }
}

/// One day with something expected.
public struct UpcomingDay: Identifiable, Hashable, Codable, Sendable {
    public var id: Date { date }
    /// The start of the day in the ledger's calendar.
    public var date: Date
    public var totals: UpcomingTotals
    /// The ids of its items (`Upcoming.items`), in order.
    public var itemIDs: [String]

    public init(date: Date, totals: UpcomingTotals, itemIDs: [String]) {
        self.date = date; self.totals = totals; self.itemIDs = itemIDs
    }
}

/// `GET /v1/upcoming?days=N`: what's expected from today through `days` ahead.
public struct Upcoming: Hashable, Codable, Sendable {
    public var asOf: Date
    /// How many days ahead, today included.
    public var days: Int
    /// Soonest first; on one day, income first, then card bills, bills and subscriptions, each by size.
    public var items: [UpcomingItem]
    /// Only days with something on them, soonest first.
    public var byDay: [UpcomingDay]
    /// Everything in the window.
    public var totals: UpcomingTotals
    /// The next seven days, today included: what the weekly recap tells.
    public var nextSevenDays: UpcomingTotals
    /// The next expected paycheck, even when it's past the window. Nil when no regular pay shows.
    public var nextPaycheck: UpcomingItem?
    /// How often pay comes ("every 2 weeks", "twice a month"); nil when no regular pay shows.
    public var payCadence: String?
    /// Every card with a statement from its issuer, whatever its due date, paid ones included. Empty when card bills
    /// aren't turned on (or no card has one yet).
    public var cardBills: [CardBill]

    public init(asOf: Date, days: Int, items: [UpcomingItem], byDay: [UpcomingDay], totals: UpcomingTotals, nextSevenDays: UpcomingTotals,
                nextPaycheck: UpcomingItem?, payCadence: String?, cardBills: [CardBill]) {
        self.asOf = asOf; self.days = days; self.items = items; self.byDay = byDay; self.totals = totals
        self.nextSevenDays = nextSevenDays; self.nextPaycheck = nextPaycheck; self.payCadence = payCadence; self.cardBills = cardBills
    }

    /// The items on `day` (a `byDay` entry), in order.
    public func items(on day: UpcomingDay) -> [UpcomingItem] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return day.itemIDs.compactMap { byID[$0] }
    }

    /// Items from the start of `asOf`'s day through `days` days, today included.
    public func items(within days: Int, calendar: Calendar) -> [UpcomingItem] {
        let start = calendar.startOfDay(for: asOf)
        guard let end = calendar.date(byAdding: .day, value: days, to: start) else { return items }
        return items.filter { $0.date < end }
    }
}

extension ServerStatus {
    /// The first server with `GET /v1/upcoming` (expected paychecks, bills and card bills by day) and card bills from
    /// Plaid Liabilities. An older one answers 404, which the app shows as nothing coming up rather than an error.
    public static let upcomingSince = "0.5.0"
}
