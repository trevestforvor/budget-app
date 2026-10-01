import Foundation

// Month-by-month views of the ledger: the budget for one month, a category's history, and cash flow.
// Months are named like "2026-09", in the ledger's time zone.

/// One month of the budget, worked out as of the end of that month (or now, for this one): the flex budget,
/// each budget type's plan against what it spent, and the lines the Spending tab explains the plan with.
public struct BudgetMonth: Hashable, Codable, Sendable {
    /// "2026-09".
    public var month: String
    public var isCurrent: Bool
    /// The flex budget as it stood at the end of the month (this month: now). A past month has no `perDayLeft`.
    public var flex: FlexBudget
    /// One or two plain sentences on the month — for this month, the checkup's own. Never a model's words.
    public var summary: String
    /// Bills, subscriptions and everyday, in that order, each with its categories.
    public var groups: [BudgetGroup]
    /// The everyday budget no everyday target claims: `flex.flexNumber` − the everyday categories' targets. Negative
    /// when the targets promise more than the budget has.
    public var unallocatedFlex: Money
    /// Everyday spending in categories with no target — the "everything else" row.
    public var everythingElseSpent: Money
    /// What bills and subscriptions usually come to that hasn't been paid yet this month (`flex.bills` +
    /// `flex.subscriptions` less their spending so far, never below zero). Zero for a past month.
    public var stillToCome: Money
    /// Whether the three months the flex budget averages are all in the ledger. False for the first months of a
    /// ledger: their "budget" counts months with no data as zero, so it isn't one — show what was spent, not a
    /// budget. Nil from servers before it existed.
    public var hasFullHistory: Bool? = nil

    /// Whether to show this month as a budget: this month always is (it's what Home shows), and a past month is when
    /// its flex budget rests on full months.
    public var hasBudget: Bool { isCurrent || hasFullHistory != false }
}

extension BudgetMonth {
    enum CodingKeys: String, CodingKey {
        case month, isCurrent, flex, summary, groups, unallocatedFlex, everythingElseSpent, stillToCome, hasFullHistory
        /// Servers before 0.3.0 (and copies cached from them): fixed costs still to come.
        case fixedStillToCome
    }

    /// Reads budget months from servers before 0.3.0 too: their fixed costs still to come, and their flexible and
    /// non-monthly groups (which both read as everyday) as one everyday group.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        month = try c.decode(String.self, forKey: .month)
        isCurrent = try c.decode(Bool.self, forKey: .isCurrent)
        flex = try c.decode(FlexBudget.self, forKey: .flex)
        summary = try c.decode(String.self, forKey: .summary)
        var merged: [BudgetGroup] = []
        for group in try c.decode([BudgetGroup].self, forKey: .groups) {
            if let i = merged.firstIndex(where: { $0.group == group.group }) {
                merged[i].planned = merged[i].planned + group.planned
                merged[i].spent = merged[i].spent + group.spent
                merged[i].categories += group.categories
            } else {
                merged.append(group)
            }
        }
        groups = merged
        unallocatedFlex = try c.decode(Money.self, forKey: .unallocatedFlex)
        everythingElseSpent = try c.decode(Money.self, forKey: .everythingElseSpent)
        stillToCome = try c.decodeIfPresent(Money.self, forKey: .stillToCome) ?? c.decodeIfPresent(Money.self, forKey: .fixedStillToCome) ?? .zero
        hasFullHistory = try c.decodeIfPresent(Bool.self, forKey: .hasFullHistory)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(month, forKey: .month)
        try c.encode(isCurrent, forKey: .isCurrent)
        try c.encode(flex, forKey: .flex)
        try c.encode(summary, forKey: .summary)
        try c.encode(groups, forKey: .groups)
        try c.encode(unallocatedFlex, forKey: .unallocatedFlex)
        try c.encode(everythingElseSpent, forKey: .everythingElseSpent)
        try c.encode(stillToCome, forKey: .stillToCome)
        try c.encodeIfPresent(hasFullHistory, forKey: .hasFullHistory)
    }
}

/// One budget type within a month.
public struct BudgetGroup: Hashable, Codable, Sendable {
    public var group: CategoryGroup
    /// What the budget sets aside for it: a usual month of bills or of subscriptions, and the flex number for everyday.
    public var planned: Money
    public var spent: Money
    /// Its categories with spending or a target this month, most spent first, each with its target.
    public var categories: [CategoryTotal]
}

/// A category's spending month by month, for its detail screen.
public struct CategoryHistory: Hashable, Codable, Sendable {
    public var categoryID: String
    /// Oldest first; the last is this month so far. Months before the ledger's first transaction are left out.
    public var months: [MonthSpend]
    /// The average over the complete months the ledger fully covers (not this month, not a first partial month).
    public var averageMonthly: Money
    public var monthsAveraged: Int
}

public struct MonthSpend: Hashable, Codable, Sendable {
    /// "2026-09".
    public var month: String
    public var spent: Money
    /// Today's target: targets have no history, so every month is measured against the current one.
    public var target: Money?
}

/// A month's income against its spending.
public struct MonthFlow: Hashable, Codable, Sendable {
    /// "2026-09".
    public var month: String
    public var income: Money
    /// Spending in every category, each net of its refunds: what actually went out.
    public var spending: Money
    /// income − spending.
    public var net: Money
    /// This month, still under way.
    public var isPartial: Bool
}
