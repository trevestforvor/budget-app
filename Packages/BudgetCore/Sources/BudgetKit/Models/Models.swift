import Foundation

// Wire models for the Budget API. They mirror docs/API.md; the server is the source of truth.

public enum SourceKind: String, Codable, Sendable, CaseIterable {
    case simplefin, financekit, plaid, teller, fileImport

    public var displayName: String {
        switch self {
        case .simplefin: "SimpleFIN Bridge"
        case .financekit: "FinanceKit"
        case .plaid: "Plaid"
        case .teller: "Teller"
        case .fileImport: "OFX / CSV import"
        }
    }
}

public enum AccountKind: String, Codable, Sendable, CaseIterable {
    case checking, savings, credit
    /// Balance-only (holdings), not part of cash on hand.
    case investment
}

public struct Account: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var institution: String
    public var kind: AccountKind
    public var balance: Money
    public var source: SourceKind
    /// Last digits of the account number as the bank shows them ("0909"), for matching statement files.
    public var mask: String?

    public init(id: String, name: String, institution: String, kind: AccountKind, balance: Money, source: SourceKind, mask: String? = nil) {
        self.id = id; self.name = name; self.institution = institution; self.kind = kind; self.balance = balance; self.source = source; self.mask = mask
    }

    /// "Gold Card ••1008", or just the name when the bank gave no digits. The one way the app, the dashboard and the
    /// engine's own sentences (rule descriptions) name an account.
    public var shortLabel: String { mask.map { "\(name) ••\($0)" } ?? name }
}

/// How a category behaves month to month — the basis of "how much can I save".
public enum CategoryGroup: String, Hashable, Codable, Sendable, CaseIterable {
    /// What's owed each month: rent, utilities, insurance, fees.
    case bills
    /// What's paid for on a schedule and chosen: streaming, apps, memberships.
    case subscriptions
    /// Everything else, day to day: groceries, dining, shopping, transport, trips. Safe to spend is this part.
    case everyday

    public var label: String {
        switch self {
        case .bills: "Bills"
        case .subscriptions: "Subscriptions"
        case .everyday: "Everyday"
        }
    }

    /// A group as stored. Categories saved before these groups (fixed, flexible, non-monthly) read as the nearest one:
    /// fixed as Bills — Subscriptions as Subscriptions, and Health as Everyday (its memberships are on the recurring list,
    /// so they count as subscriptions; the rest varies) — and flexible and non-monthly as Everyday.
    public static func stored(_ raw: String, categoryID: String? = nil) -> CategoryGroup {
        if let group = CategoryGroup(rawValue: raw) { return group }
        switch (raw, categoryID) {
        case ("fixed", "subscriptions"): return .subscriptions
        case ("fixed", "health"): return .everyday
        case ("fixed", _): return .bills
        default: return .everyday
        }
    }

    /// Reads the groups of older ledgers and apps too (`stored`).
    public init(from decoder: any Decoder) throws {
        self = Self.stored(try decoder.singleValueContainer().decode(String.self))
    }
}

/// Which way a category's money counts.
public enum CategoryKind: String, Hashable, Codable, Sendable, CaseIterable {
    /// Money going out: groceries, rent, travel. Transfer is the one category of this kind that counts as neither
    /// spending nor money in (`countsAsSpending` is false): money moving between the person's own accounts.
    case spending
    /// Money coming in that counts like income: Income itself, and categories the person makes for it, such as
    /// "Card rewards" for statement credits and points back. Never spending, never budgeted.
    case moneyIn

    public var label: String {
        switch self {
        case .spending: "Spending"
        case .moneyIn: "Money in"
        }
    }

    /// What a category of this id is when nothing says otherwise: Income is money in, everything else spending.
    public static func standard(forCategoryID id: String) -> CategoryKind { id == BudgetCategory.incomeID ? .moneyIn : .spending }
}

public struct BudgetCategory: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    /// SF Symbol name.
    public var symbol: String
    /// Money-in categories and transfers are not spending. Always false for money in.
    public var countsAsSpending: Bool
    /// Only means something for spending categories: money in is never budgeted.
    public var group: CategoryGroup
    /// A `CategoryColor` token name ("teal"); nil wears the standard color for the id (`effectiveColor`).
    public var color: String?
    /// Merged into another category. Kept so old rows and undo still resolve the id, but nothing new is filed
    /// under it, and pickers, tools and the decision model leave it out.
    public var isArchived: Bool
    /// The category an archived one was merged into, so an undo made before the merge files its rows there. Nil for
    /// categories archived before this was recorded.
    public var mergedInto: String?
    /// Spending or money in. Set when the category is made and never changed.
    public var kind: CategoryKind

    /// - Parameter kind: nil takes the standard kind for the id (Income is money in). Money in never counts as spending.
    public init(id: String, name: String, symbol: String, countsAsSpending: Bool = true, group: CategoryGroup = .everyday,
                color: String? = nil, isArchived: Bool = false, mergedInto: String? = nil, kind: CategoryKind? = nil) {
        let kind = kind ?? CategoryKind.standard(forCategoryID: id)
        self.id = id
        self.name = name
        self.symbol = symbol
        self.countsAsSpending = kind == .moneyIn ? false : countsAsSpending
        self.group = group
        self.color = color
        self.isArchived = isArchived
        self.mergedInto = mergedInto
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case id, name, symbol, countsAsSpending, group, color, isArchived, mergedInto, kind }

    /// Categories stored and cached before colors, archiving and kinds decode without them: Income as money in,
    /// everything else as spending.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        symbol = try c.decode(String.self, forKey: .symbol)
        group = CategoryGroup.stored(try c.decode(String.self, forKey: .group), categoryID: id)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        mergedInto = try c.decodeIfPresent(String.self, forKey: .mergedInto)
        kind = try c.decodeIfPresent(CategoryKind.self, forKey: .kind) ?? CategoryKind.standard(forCategoryID: id)
        let spends = try c.decode(Bool.self, forKey: .countsAsSpending)
        countsAsSpending = kind == .moneyIn ? false : spends
    }

    /// The built-in money-in category: pay, interest and other money received.
    public static let incomeID = "income"
    /// The built-in category for money moving between the person's own accounts: neither spending nor money in.
    public static let transferID = "transfer"

    /// Counts as money coming in, like income.
    public var isMoneyIn: Bool { kind == .moneyIn }

    /// Income and Transfer: built in, they keep their names, aren't budgeted and can't be merged away.
    public var isSystem: Bool { id == Self.incomeID || id == Self.transferID }
}

/// The budget in one number to watch: income − bills − subscriptions − saved first is what's left for everyday
/// spending (`flexNumber`); safe to spend is what's left of it this month. Income is the lower of the last three
/// months' average and a month of the latest paychecks; bills and subscriptions are a usual month: the last three
/// months' average, a charge spread over the year counting a twelfth each month.
public struct FlexBudget: Hashable, Sendable {
    /// Where `expectedIncome` comes from.
    public enum IncomeSource: String, Codable, Sendable {
        case threeMonthAverage, recentPaychecks
    }

    public var expectedIncome: Money
    public var bills: Money
    public var subscriptions: Money
    /// Paid first. The person's setting, or what they already move to savings.
    public var plannedSavings: Money
    public var plannedSavingsIsSet: Bool
    /// The everyday budget.
    public var flexNumber: Money
    /// Everyday spending this month.
    public var flexSpent: Money
    public var safeToSpend: Money
    /// Days after today left in the month.
    public var daysLeft: Int
    /// Safe to spend spread over the rest of the month, today included (`daysLeft + 1` days); zero once nothing is
    /// left. Nil for a month that's over, and from servers before it existed.
    public var perDayLeft: Money? = nil
    /// Which of the two `expectedIncome` is, and both: the last three months' average income, and a month of the latest
    /// paychecks (`paycheckCount` of them) when regular pay shows. Nil from servers before 0.3.3, whose income was
    /// always the average.
    public var incomeSource: IncomeSource? = nil
    public var averageIncome: Money? = nil
    public var recentPaychecks: Money? = nil
    public var paycheckCount: Int? = nil

    /// The days safe to spend still has to cover, today included — how every screen counts "days left", so Home,
    /// Spending, the checkup and Ask agree ("5 days left" on the 26th of a 30-day month).
    public var daysLeftIncludingToday: Int { daysLeft + 1 }

    /// "Last day", "2 days left" for a count of days, today included.
    public static func daysLeftPhrase(_ days: Int) -> String {
        days <= 1 ? "Last day" : "\(days) days left"
    }

    public init(expectedIncome: Money, bills: Money, subscriptions: Money, plannedSavings: Money, plannedSavingsIsSet: Bool,
                flexNumber: Money, flexSpent: Money, safeToSpend: Money, daysLeft: Int, perDayLeft: Money? = nil,
                incomeSource: IncomeSource? = nil, averageIncome: Money? = nil, recentPaychecks: Money? = nil, paycheckCount: Int? = nil) {
        self.expectedIncome = expectedIncome; self.bills = bills; self.subscriptions = subscriptions
        self.plannedSavings = plannedSavings; self.plannedSavingsIsSet = plannedSavingsIsSet
        self.flexNumber = flexNumber; self.flexSpent = flexSpent; self.safeToSpend = safeToSpend
        self.daysLeft = daysLeft; self.perDayLeft = perDayLeft
        self.incomeSource = incomeSource; self.averageIncome = averageIncome; self.recentPaychecks = recentPaychecks; self.paycheckCount = paycheckCount
    }

    /// "your last 2 paychecks" or "the last 3 months' average", for saying where expected income came from.
    public var incomeSourcePhrase: String {
        switch incomeSource {
        case .recentPaychecks?: "your last \(paycheckCount ?? 2) paycheck\(paycheckCount == 1 ? "" : "s")"
        default: "the last 3 months' average"
        }
    }
}

extension FlexBudget: Codable {
    enum CodingKeys: String, CodingKey {
        case expectedIncome, bills, subscriptions, plannedSavings, plannedSavingsIsSet, flexNumber, flexSpent, safeToSpend, daysLeft, perDayLeft
        case incomeSource, averageIncome, recentPaychecks, paycheckCount
        /// Older servers and cached copies: fixed costs and a non-monthly set-aside instead of bills and subscriptions.
        case fixed, nonMonthly
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        expectedIncome = try c.decode(Money.self, forKey: .expectedIncome)
        let fixed = try c.decodeIfPresent(Money.self, forKey: .fixed) ?? .zero
        let nonMonthly = try c.decodeIfPresent(Money.self, forKey: .nonMonthly) ?? .zero
        bills = try c.decodeIfPresent(Money.self, forKey: .bills) ?? fixed + nonMonthly
        subscriptions = try c.decodeIfPresent(Money.self, forKey: .subscriptions) ?? .zero
        plannedSavings = try c.decode(Money.self, forKey: .plannedSavings)
        plannedSavingsIsSet = try c.decode(Bool.self, forKey: .plannedSavingsIsSet)
        flexNumber = try c.decode(Money.self, forKey: .flexNumber)
        flexSpent = try c.decode(Money.self, forKey: .flexSpent)
        safeToSpend = try c.decode(Money.self, forKey: .safeToSpend)
        daysLeft = try c.decode(Int.self, forKey: .daysLeft)
        perDayLeft = try c.decodeIfPresent(Money.self, forKey: .perDayLeft)
        incomeSource = try? c.decodeIfPresent(IncomeSource.self, forKey: .incomeSource)
        averageIncome = try c.decodeIfPresent(Money.self, forKey: .averageIncome)
        recentPaychecks = try c.decodeIfPresent(Money.self, forKey: .recentPaychecks)
        paycheckCount = try c.decodeIfPresent(Int.self, forKey: .paycheckCount)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(expectedIncome, forKey: .expectedIncome)
        try c.encode(bills, forKey: .bills)
        try c.encode(subscriptions, forKey: .subscriptions)
        try c.encode(plannedSavings, forKey: .plannedSavings)
        try c.encode(plannedSavingsIsSet, forKey: .plannedSavingsIsSet)
        try c.encode(flexNumber, forKey: .flexNumber)
        try c.encode(flexSpent, forKey: .flexSpent)
        try c.encode(safeToSpend, forKey: .safeToSpend)
        try c.encode(daysLeft, forKey: .daysLeft)
        try c.encodeIfPresent(perDayLeft, forKey: .perDayLeft)
        try c.encodeIfPresent(incomeSource, forKey: .incomeSource)
        try c.encodeIfPresent(averageIncome, forKey: .averageIncome)
        try c.encodeIfPresent(recentPaychecks, forKey: .recentPaychecks)
        try c.encodeIfPresent(paycheckCount, forKey: .paycheckCount)
    }
}

/// "How much can I save / should I save", computed by the ledger. Rules: docs/BUDGETING.md.
public struct SavingsPlan: Hashable, Codable, Sendable {
    public var monthsAveraged: Int
    public var averageIncome: Money
    public var canSaveTypical: Money
    public var canSaveStretch: Money
    public var alreadySaving: Money
    public var plannedSavings: Money
    public var plannedSavingsIsSet: Bool
    public var essentialMonthly: Money
    public var cashOnHand: Money
    public var monthsCovered: Double
    public var emergencyTargetLow: Money
    public var emergencyTargetHigh: Money
    public var twentyPercentOfIncome: Money
    /// Income and spending by month, oldest first: up to six complete months, then this month so far. The last three
    /// complete months' `net` average to `canSaveTypical` exactly. Nil from servers before it existed.
    public var history: [MonthFlow]? = nil
    /// How much cash (checking and savings) actually grew a month over the last three complete months — the pace the
    /// projection runs at. It differs from `canSaveTypical` by what went to investments or card balances.
    public var averageCashChange: Money? = nil
}

/// A monthly cap on one merchant ("DoorDash: $150").
public struct MerchantCap: Identifiable, Hashable, Codable, Sendable {
    public var merchant: String
    public var spent: Money
    public var target: Money
    public var id: String { merchant }
}

/// Which tier of the categorization pipeline produced the label.
public enum CategorizationTier: String, Codable, Sendable, CaseIterable {
    case merchantMemory, embedding, model, decisionModel, rule, user
    /// One side of a move between the person's own accounts: the opposite amount turned up on another of
    /// them within days. (Rows filed this way before the tier existed said `.rule`; loading a ledger fixes them.)
    case transferMatch
    /// The statement file said what the row is: interest, a transfer, a card payment.
    case statement

    public var displayName: String {
        switch self {
        case .merchantMemory: "Merchant memory"
        case .embedding: "Local classifier"
        case .model: "Model fallback"
        case .decisionModel: "The model"
        case .rule: "Your rule"
        case .user: "You"
        case .transferMatch: "Matched transfer"
        case .statement: "Your statement"
        }
    }

    /// Filed by the person or by facts in the bank data — nothing a model re-check may move.
    var isSettledByPersonOrData: Bool { [.user, .rule, .transferMatch, .statement].contains(self) }

    /// A tier a later version wrote (a server rolled back to this one reads it) decodes as `.model` — a model's
    /// guess, the least a row can claim — instead of failing the whole ledger's load. The row keeps the later tier in
    /// storage until it's next changed.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CategorizationTier(rawValue: raw) ?? .model
    }
}

public struct Categorization: Hashable, Codable, Sendable {
    public var categoryID: String
    /// 0...1
    public var confidence: Double
    public var tier: CategorizationTier
    /// Decided by the server's threshold, not the client.
    public var needsReview: Bool
    /// Which model made the call, when a model did (e.g. "jev-1.13").
    public var decidedBy: String?

    public init(categoryID: String, confidence: Double, tier: CategorizationTier, needsReview: Bool, decidedBy: String? = nil) {
        self.categoryID = categoryID
        self.confidence = confidence
        self.tier = tier
        self.needsReview = needsReview
        self.decidedBy = decidedBy
    }

    /// How the model's call came about, in words, when it's more than the model's own answer: "Agreed with your bank's
    /// category", "Checked again", "Asked Jev". `decidedBy` itself is a model's id, never shown.
    public var modelNote: String? {
        guard tier == .decisionModel || tier == .model, let decidedBy else { return nil }
        if decidedBy.hasSuffix("agrees with the bank") { return "Agreed with your bank's category" }
        if decidedBy.hasSuffix("re-checked") { return "Checked again" }
        if decidedBy.hasSuffix("escalated") { return "Asked Jev" }
        return nil
    }

    /// The rule that filed the row, when one did (`decidedBy` is then "rule:<id>", not something to show).
    public var ruleID: String? {
        guard tier == .rule, let decidedBy, decidedBy.hasPrefix(BudgetRule.stampPrefix) else { return nil }
        return String(decidedBy.dropFirst(BudgetRule.stampPrefix.count))
    }
}

public struct LedgerTransaction: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var accountID: String
    public var postedAt: Date
    /// Normalized merchant name.
    public var merchant: String
    /// Bank descriptor as received.
    public var rawDescription: String
    /// Negative is money out.
    public var amount: Money
    public var categorization: Categorization?
    public var isPending: Bool
    public var source: SourceKind
    /// The import or sync batch that added this row — rolling a batch back removes exactly these.
    public var batchID: String?
    /// The provider's own category, kept as a hint (Plaid personal_finance_category, Teller details.category).
    public var providerCategory: String?
    /// Left out of every spending, income and budget total; balances still include it. Hiding takes a row out of review.
    public var isHidden: Bool
    /// The person's own note. Search matches it.
    public var note: String?
    /// The other side of a move between the person's own accounts (a card payment, a transfer to savings), once matched.
    public var transferPeerID: String?
    /// The name the bank data gave, kept when the merchant was renamed; nil when it never was.
    public var originalMerchant: String?
    /// The person's say on whether this is a yearly charge — one the budget sets aside a twelfth a month (in
    /// Non-monthly) instead of counting whole in its month. Nil leaves it to Budget: a charge in a yearly series, or
    /// one whose description says it's annual.
    public var isYearly: Bool?
    /// Whether the budget treats the row as yearly: the person's say, or what Budget found. Filled in on rows the API
    /// hands out; never stored.
    public var countsAsYearly: Bool?
    /// The store order this charge paid for, matched from an imported order history (Amazon's). Nil for most rows,
    /// and on rows from servers before 0.5.0.
    public var orderMatch: OrderMatch?

    public init(id: String, accountID: String, postedAt: Date, merchant: String, rawDescription: String, amount: Money,
                categorization: Categorization?, isPending: Bool, source: SourceKind, batchID: String? = nil, providerCategory: String? = nil,
                isHidden: Bool = false, note: String? = nil, transferPeerID: String? = nil, originalMerchant: String? = nil,
                isYearly: Bool? = nil, orderMatch: OrderMatch? = nil) {
        self.id = id; self.accountID = accountID; self.postedAt = postedAt; self.merchant = merchant; self.rawDescription = rawDescription
        self.amount = amount; self.categorization = categorization; self.isPending = isPending; self.source = source
        self.batchID = batchID; self.providerCategory = providerCategory
        self.isHidden = isHidden; self.note = note; self.transferPeerID = transferPeerID; self.originalMerchant = originalMerchant
        self.isYearly = isYearly
        self.orderMatch = orderMatch
    }

    enum CodingKeys: String, CodingKey {
        case id, accountID, postedAt, merchant, rawDescription, amount, categorization, isPending, source, batchID, providerCategory
        case isHidden, note, transferPeerID, originalMerchant, isYearly, countsAsYearly
        case orderMatch
    }

    /// Rows stored and cached before hiding, notes, transfer pairs and yearly charges existed decode with those unset.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        accountID = try c.decode(String.self, forKey: .accountID)
        postedAt = try c.decode(Date.self, forKey: .postedAt)
        merchant = try c.decode(String.self, forKey: .merchant)
        rawDescription = try c.decode(String.self, forKey: .rawDescription)
        amount = try c.decode(Money.self, forKey: .amount)
        categorization = try c.decodeIfPresent(Categorization.self, forKey: .categorization)
        isPending = try c.decode(Bool.self, forKey: .isPending)
        source = try c.decode(SourceKind.self, forKey: .source)
        batchID = try c.decodeIfPresent(String.self, forKey: .batchID)
        providerCategory = try c.decodeIfPresent(String.self, forKey: .providerCategory)
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note)
        transferPeerID = try c.decodeIfPresent(String.self, forKey: .transferPeerID)
        originalMerchant = try c.decodeIfPresent(String.self, forKey: .originalMerchant)
        isYearly = try c.decodeIfPresent(Bool.self, forKey: .isYearly)
        countsAsYearly = try c.decodeIfPresent(Bool.self, forKey: .countsAsYearly)
        orderMatch = try c.decodeIfPresent(OrderMatch.self, forKey: .orderMatch)
    }

    /// Whether the row counts toward spending and income. Hidden rows don't, and neither does money moving
    /// between the person's own accounts (a category that is neither spending nor money in: Transfer). Every
    /// ledger total already leaves them out; the app uses this to dim them the same way everywhere.
    /// - Parameter category: the row's category as the ledger defines it (nil when uncategorized).
    public func isCounted(category: BudgetCategory?) -> Bool {
        guard !isHidden else { return false }
        guard let category else { return true }
        return category.countsAsSpending || category.isMoneyIn
    }
}

public struct BalancePoint: Hashable, Codable, Sendable {
    public var date: Date
    public var balance: Money

    public init(date: Date, balance: Money) {
        self.date = date
        self.balance = balance
    }
}

public enum SpendingRange: String, Codable, Sendable, CaseIterable, Identifiable {
    case thisMonth, lastMonth, last90Days, yearToDate

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .thisMonth: "This month"
        case .lastMonth: "Last month"
        case .last90Days: "90 days"
        case .yearToDate: "Year to date"
        }
    }
}

public struct CategoryTotal: Identifiable, Hashable, Codable, Sendable {
    public var category: BudgetCategory
    public var spent: Money
    /// Present only for ranges that map onto the budget period.
    public var target: Money?
    public var transactionCount: Int
    /// Only the category's charges spread over the year, at this month's share: how a budget month lists them
    /// ("Subscriptions · yearly"). Nil everywhere else.
    public var isYearly: Bool? = nil
    public var id: String { isYearly == true ? "\(category.id)-yearly" : category.id }
}

public struct SpendingSummary: Hashable, Codable, Sendable {
    public var range: SpendingRange
    public var start: Date
    public var end: Date
    public var total: Money
    public var previousTotal: Money?
    /// Server-written comparison line, e.g. "12% less than last month".
    public var comparison: String?
    public var categories: [CategoryTotal]
    /// Merchant caps with this range's spend (monthly ranges only).
    public var merchantCaps: [MerchantCap]
}

public enum InsightKind: String, Codable, Sendable { case savings, subscription, anomaly, budget, trend, plan }

public struct Insight: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var kind: InsightKind
    public var eyebrow: String
    public var title: String
    public var body: String
    /// Name of the ledger tool that computed the figures in the text.
    public var computedBy: String
    /// A question for Ask that follows up on this insight ("Why is dining up this month?").
    public var askPrompt: String? = nil
}

public struct Overview: Hashable, Codable, Sendable {
    public var asOf: Date
    public var cashOnHand: Money
    public var cashChange30Days: Money
    public var cashTrend: [BalancePoint]
    public var monthSpent: Money
    public var monthIncome: Money
    /// No longer sent: a sum of category targets competed with the flex budget, which is the budget. Kept so older
    /// payloads still decode.
    public var monthTarget: Money?
    /// No longer sent (see `monthTarget`).
    public var leftToBudget: Money?
    public var reviewCount: Int
    public var flex: FlexBudget
    public var insights: [Insight]
    public var recent: [LedgerTransaction]
    public var accounts: [Account]
    /// What's keeping the numbers from being current, worst first: connections to sign in to again, cash and card
    /// accounts that stopped getting transactions, an empty ledger. The checkup's data section says the same.
    public var attention: [DataAttention]? = nil
    /// Every account's balance by kind, as of the last sync or import.
    public var balances: Balances? = nil
    /// Everyday spending on each of the last seven days, oldest first; the last is today so far. The same rows and
    /// rules as `flex.flexSpent`. Each day is its own net, so a refund on a later day lowers that day, not the charge's.
    public var lastSevenDays: [DaySpend]? = nil
    /// Everyday spending over those seven days as one window, refunds netted across the days — the week's figure, by
    /// the same rule as safe to spend. Nil from servers before it existed (sum the days then).
    public var lastSevenDaysSpent: Money? = nil
    /// `reviewCount` rows as decisions: the review groups one answer each files (`ReviewGroup.groups`), what the
    /// phone's badge counts. Nil from servers before it existed.
    public var reviewDecisions: Int? = nil
    /// The queue in a sentence (`ReviewGroup.headline`), for the dashboard. Nil when nothing waits.
    public var reviewHeadline: String? = nil
}

/// Something that keeps the ledger from being current, and what to do about it.
public struct DataAttention: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable {
        /// The bank ended a connection; the person signs in again on the dashboard.
        case needsReauth
        /// A checking, savings or card account whose newest transaction is older than its rhythm allows: past
        /// max(10 days, 3× the median gap between its days with transactions).
        case stale
        /// No transactions at all yet.
        case emptyLedger
    }

    /// Stable across calls: "reauth-<link id>", "stale-<account id>", "no-data" (the checkup's finding ids).
    public var id: String
    public var kind: Kind
    public var title: String
    public var detail: String
    public var institution: String?
    /// The account, for `stale`.
    public var accountID: String?

    public init(id: String, kind: Kind, title: String, detail: String, institution: String? = nil, accountID: String? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.institution = institution; self.accountID = accountID
    }
}

/// Balances by account kind. Card balances are negative in the ledger; `cardsOwed` is what they owe together, as a
/// positive amount. `netWorth` = cash − cardsOwed + investments; `cashAfterCards` = cash − cardsOwed.
public struct Balances: Hashable, Codable, Sendable {
    /// Checking and savings: `Overview.cashOnHand`.
    public var cash: Money
    public var cardsOwed: Money
    /// Balance-only accounts, never cash.
    public var investments: Money
    public var netWorth: Money
    public var cashAfterCards: Money
}

/// One day's everyday spending.
public struct DaySpend: Hashable, Codable, Sendable {
    /// Start of the day in the ledger's time zone.
    public var date: Date
    public var flexibleSpent: Money
}

public struct CategorySuggestion: Hashable, Codable, Sendable {
    public var categoryID: String
    public var confidence: Double
}

public struct ReviewItem: Identifiable, Hashable, Codable, Sendable {
    public var transaction: LedgerTransaction
    /// Ranked, best first.
    public var suggestions: [CategorySuggestion]
    /// Why this came to you, in plain language.
    public var reason: String
    /// Over the amount the person checks one by one ("check anything above"), so it's answered on its own, never in a
    /// group. Nil from servers before it existed.
    public var isLarge: Bool? = nil
    public var id: String { transaction.id }
}

public struct ToolCall: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    /// JSON arguments, as the model emitted them.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct Figure: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var label: String
    public var detail: String?
    public var value: Money
}

public struct AskReply: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var conversationID: String
    public var text: String
    public var figures: [Figure]
    public var toolCalls: [ToolCall]
    /// The model assigned to the `chat` role that wrote the prose.
    public var model: String
    public var followUps: [String]
    /// Changes the assistant proposes. Each is applied only if the person taps Apply.
    public var proposedActions: [ProposedAction]
}

public struct GoalQuery: Hashable, Codable, Sendable {
    public var amount: Money
    public var targetDate: Date

    public init(amount: Money, targetDate: Date) {
        self.amount = amount
        self.targetDate = targetDate
    }
}

public struct GoalCheck: Hashable, Codable, Sendable {
    public var query: GoalQuery
    public var projectedSavings: Money
    public var isOnTrack: Bool
    public var shortfall: Money
    public var monthlyNeeded: Money
    public var summary: String
}

public struct ProjectedPoint: Hashable, Codable, Sendable {
    public var date: Date
    public var expected: Money
    public var low: Money
    public var high: Money
}

/// Cash after cards (cash less what's owed on cards) over the last 120 days, carried forward at the recent pace:
/// the last three complete months' income less spending, a yearly charge counted a twelfth a month.
public struct Projection: Hashable, Codable, Sendable {
    public var accountID: String?
    public var horizonMonths: Int
    public var history: [BalancePoint]
    public var projected: [ProjectedPoint]
    /// The pace: average income less spending a month.
    public var monthlyNet: Money
    public var endBalance: Money
    public var goal: GoalCheck?
    /// What's owed on cards now, which the balances above are net of. Nil from servers before 0.3.1, whose
    /// projection was cash alone at the pace cash itself moved.
    public var cardsOwed: Money? = nil
}

public enum ModelRole: String, Codable, Sendable, CaseIterable {
    case chat, categorize, plan, vision

    public var purpose: String {
        switch self {
        case .chat: "Questions and explanations"
        case .categorize: "Low-confidence categorization"
        case .plan: "Multi-month scenarios"
        case .vision: "Receipt photos"
        }
    }
}

public struct RoleAssignment: Hashable, Codable, Sendable, Identifiable {
    public var role: ModelRole
    public var model: String?
    public var evalsPassed: Bool
    public var evalScore: Double?
    public var id: ModelRole { role }
}

public struct ServerStatus: Hashable, Codable, Sendable {
    public var endpoint: String
    public var version: String
    public var roles: [RoleAssignment]
    public var discoveredModels: [String]
    public var sources: [SourceKind]
    public var rawDataStaysLocal: Bool
    /// The most recent successful sync of any linked institution; nil when nothing has synced yet.
    public var lastSync: Date?
    public var decisionPolicy: DecisionPolicy
    /// The model behind the current provider, when one is set.
    public var decisionModel: String?
    /// The exact state a decision model receives for a sample transaction (pretty JSON).
    public var decisionSample: String?
    /// The person's institutions: each linked one, then any whose accounts only come from imported statements.
    public var institutions: [InstitutionLink]
    /// Decision providers the server can actually use (so clients can disable the rest). Nil from older servers.
    public var availableDecisionProviders: [DecisionProvider]?
    /// The Budget dashboard on the Olares, where banks are linked and reconnected and statements imported — for the
    /// phone's "Open dashboard". Nil until it's set in the dashboard's settings (or `BUDGET_DASHBOARD_URL`).
    public var dashboardURL: String? = nil
}

extension ServerStatus {
    /// The first server that keeps a rule's account, direction and amount conditions. An older one silently drops them
    /// and saves a much broader rule, so the app doesn't send such a rule to it.
    public static let rulesWithConditionsSince = "0.2.0"
    /// The first server that keeps a yearly-charge mark on a transaction and the person's say on recurring charges. An
    /// older one drops the mark (or refuses the edit as empty) and doesn't know the recurring action.
    public static let yearlyAndRecurringSince = "0.3.0"

    /// Whether `version` ("0.2.0") is `minimum` or later, compared number by number; anything unreadable is older.
    public static func version(_ version: String, isAtLeast minimum: String) -> Bool {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let (a, b) = (parts(version), parts(minimum))
        for i in 0..<max(a.count, b.count) {
            let (x, y) = (i < a.count ? a[i] : 0, i < b.count ? b[i] : 0)
            if x != y { return x > y }
        }
        return true
    }
}

public enum ConnectionStatus: String, Hashable, Sendable, Codable {
    case connected
    /// Demo ledger stand-in for an institution that would be connected.
    case demo
    case planned
    /// Coverage couldn't be confirmed; check the provider's institution search when connecting.
    case verifyAtConnect
    /// Not a custodian — connect whoever holds the account.
    case viaCustodian
    case needsReauth

    public var label: String {
        switch self {
        case .connected: "Connected"
        case .demo: "Demo data"
        case .planned: "Planned"
        case .verifyAtConnect: "Verify at connect"
        case .viaCustodian: "Via custodian"
        case .needsReauth: "Sign in again"
        }
    }
}

public enum InstitutionPriority: String, Hashable, Sendable, Codable {
    case core, niceToHave, stretch, maybe

    public var label: String {
        switch self {
        case .core: "Core"
        case .niceToHave: "Nice to have"
        case .stretch: "Stretch"
        case .maybe: "Maybe"
        }
    }
}

/// One of the person's institutions and how its data arrives. A linked institution is one provider connection; one
/// whose accounts only come from imported statements has `primary: fileImport`, status `connected` (there's nothing
/// to sign in to), and no `lastSync`.
public struct InstitutionLink: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var institution: String
    /// How much the institution mattered in the coverage research (the demo plan). Real links don't have one;
    /// older servers sent "core" for every link.
    public var priority: InstitutionPriority?
    public var primary: SourceKind?
    public var fallback: SourceKind?
    public var accountKinds: [AccountKind]
    public var status: ConnectionStatus
    public var note: String
    /// When the provider last synced successfully.
    public var lastSync: Date?
    /// Why the latest sync failed, in the provider's words; nil once one succeeds.
    public var lastError: String?
    /// The ledger accounts this institution holds (`Overview.accounts` ids), so clients join them without matching names.
    public var accountIDs: [String]?
    /// The newest transaction on those accounts — how far the data reaches.
    public var coversThrough: Date?

    public init(id: String, institution: String, priority: InstitutionPriority? = nil, primary: SourceKind?, fallback: SourceKind?,
                accountKinds: [AccountKind], status: ConnectionStatus, note: String, lastSync: Date? = nil, lastError: String? = nil,
                accountIDs: [String]? = nil, coversThrough: Date? = nil) {
        self.id = id; self.institution = institution; self.priority = priority; self.primary = primary
        self.fallback = fallback; self.accountKinds = accountKinds; self.status = status; self.note = note
        self.lastSync = lastSync; self.lastError = lastError; self.accountIDs = accountIDs; self.coversThrough = coversThrough
    }
}

/// What syncing one link did.
public struct LinkSyncResult: Codable, Hashable, Sendable {
    public var linkID: String
    public var institution: String
    public var ok: Bool
    /// What the sync added, updated and filed; nil when it failed.
    public var report: IngestReport?
    /// Rows the provider deleted and the ledger dropped.
    public var removed: Int
    /// Why it failed, in the provider's words.
    public var error: String?

    public init(linkID: String, institution: String, ok: Bool, report: IngestReport? = nil, removed: Int = 0, error: String? = nil) {
        self.linkID = linkID; self.institution = institution; self.ok = ok; self.report = report; self.removed = removed; self.error = error
    }
}
