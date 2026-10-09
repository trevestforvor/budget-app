import Foundation

/// A finished month in review, shown in the first days of the next: what came in and went out, each bucket against
/// its budget, the categories that moved most, and how cash (and net worth, once it has a history) changed.
public struct MonthlyRecap: Hashable, Codable, Sendable {
    /// "2026-09".
    public var month: String
    public var asOf: Date
    /// Until when Home shows it as news: the end of the first week of the next month. Nil for a month further back.
    public var showsUntil: Date?
    /// Money in, every money-in category (Income, card rewards) — as Plan's cash flow counts it.
    public var income: Money
    /// Money out, every spending category net of its refunds — as Plan's cash flow counts it.
    public var spending: Money
    /// `income` − `spending`: what the month left over. Negative when spending ran past income.
    public var saved: Money
    /// What was moved into savings accounts during the month (the "saved first" the budget counts).
    public var movedToSavings: Money
    /// Bills, subscriptions and everyday, each as the budget counts it (a yearly charge a twelfth a month) against what
    /// the budget planned for it that month.
    public var buckets: [RecapBucket]
    /// Whether the budget behind `buckets` rested on full months of history; without it, the plans are left out.
    public var hasBudget: Bool
    /// The spending categories that moved most against the month before, biggest change first (up to three). Empty when
    /// the ledger doesn't cover the month before.
    public var categoryChanges: [RecapCategoryChange]
    /// Checking and savings at the end of the month less at its start.
    public var cashChange: Money
    /// Net worth at the end of the month less at its start, when the ledger has a net-worth history; nil otherwise (show
    /// `cashChange`).
    public var netWorthChange: Money?
    /// A sentence or two on the month, from these figures only.
    public var summary: String

    public init(month: String, asOf: Date, showsUntil: Date?, income: Money, spending: Money, saved: Money, movedToSavings: Money,
                buckets: [RecapBucket], hasBudget: Bool, categoryChanges: [RecapCategoryChange], cashChange: Money,
                netWorthChange: Money?, summary: String) {
        self.month = month; self.asOf = asOf; self.showsUntil = showsUntil; self.income = income; self.spending = spending
        self.saved = saved; self.movedToSavings = movedToSavings; self.buckets = buckets; self.hasBudget = hasBudget
        self.categoryChanges = categoryChanges; self.cashChange = cashChange; self.netWorthChange = netWorthChange; self.summary = summary
    }

    /// Whether Home shows it now.
    public var isFresh: Bool { showsUntil.map { asOf < $0 } ?? false }
}

/// One bucket's month.
public struct RecapBucket: Hashable, Codable, Sendable {
    public var group: CategoryGroup
    public var spent: Money
    /// What the budget planned for it; nil without a full-history budget.
    public var planned: Money?

    public init(group: CategoryGroup, spent: Money, planned: Money?) {
        self.group = group; self.spent = spent; self.planned = planned
    }

    /// `spent` − `planned`: positive when over. Nil without a plan.
    public var overBy: Money? { planned.map { spent - $0 } }
}

/// One spending category's month against the month before.
public struct RecapCategoryChange: Hashable, Codable, Sendable, Identifiable {
    public var categoryID: String
    public var name: String
    public var spent: Money
    public var previous: Money
    /// `spent` − `previous`.
    public var change: Money

    public init(categoryID: String, name: String, spent: Money, previous: Money, change: Money) {
        self.categoryID = categoryID; self.name = name; self.spent = spent; self.previous = previous; self.change = change
    }

    public var id: String { categoryID }
}

/// The monthly recap on clients that can ask for it (a server from 0.5.0 on, or the demo).
public protocol MonthlyRecapAPI: Sendable {
    /// The recap of `month` ("2026-09"); nil is last month.
    func monthlyRecap(month: String?) async throws -> MonthlyRecap
}

extension ServerStatus {
    /// The first server with the monthly recap (`GET /v1/recap/month`). An older one answers 404.
    public static let monthlyRecapSince = "0.5.0"
}

extension LedgerBudgetAPI: MonthlyRecapAPI {}
extension RemoteBudgetAPI: MonthlyRecapAPI {}
extension CachingBudgetAPI: MonthlyRecapAPI {}
