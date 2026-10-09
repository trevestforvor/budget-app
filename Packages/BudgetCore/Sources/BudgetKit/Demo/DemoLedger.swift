import Foundation

/// SplitMix64 — deterministic fixtures from a seed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Stand-in for the Postgres ledger on the Olares: six months of plausible household data,
/// and the deterministic queries the agent tools would run against it.
/// Persisted ledger state: everything but the clock. The server loads it from Postgres,
/// runs `Ledger` over it, and writes back the diff.
public struct LedgerState: Hashable, Codable, Sendable {
    public var categories: [BudgetCategory]
    public var monthlyTargets: [String: Money]
    /// Oldest first; the newest matching rule wins.
    public var rules: [BudgetRule]
    public var decisionPolicy: DecisionPolicy
    public var merchantTargets: [String: Money]
    public var monthlySavings: Money?
    public var accounts: [Account]
    /// Balance before the first row, per account — derived so that replaying rows ends at the provider's balance.
    public var openingBalances: [String: Money]
    /// Newest first.
    public var transactions: [LedgerTransaction]
    public var suggestions: [String: [CategorySuggestion]]
    public var reviewReasons: [String: String]
    /// Merchant names the person gave a bank descriptor (normalized descriptor → name), applied to new rows.
    public var merchantAliases: [String: String]
    /// Normalized descriptors merchant memory was told to forget, sorted.
    public var forgottenMerchants: [String]
    /// The one-time upgrades loading has applied to this ledger, sorted (`Ledger.oneTimeUpgrades`). Empty for a ledger
    /// saved before any, so they run once on its next load.
    public var upgrades: [String]
    /// The person's say on which merchants recur, keyed by `RecurringChoice.key`.
    public var recurringChoices: [String: RecurringChoice]
    /// The person's answers to "Did this stop?", keyed by `RecurringChoice.key`.
    public var recurringReviews: [String: RecurringReviewMark]

    public init(categories: [BudgetCategory], monthlyTargets: [String: Money] = [:], rules: [BudgetRule] = [],
                decisionPolicy: DecisionPolicy = .default, merchantTargets: [String: Money] = [:], monthlySavings: Money? = nil,
                accounts: [Account] = [], openingBalances: [String: Money] = [:], transactions: [LedgerTransaction] = [],
                suggestions: [String: [CategorySuggestion]] = [:], reviewReasons: [String: String] = [:], merchantAliases: [String: String] = [:],
                forgottenMerchants: [String] = [], upgrades: [String] = [], recurringChoices: [String: RecurringChoice] = [:],
                recurringReviews: [String: RecurringReviewMark] = [:]) {
        self.categories = categories; self.monthlyTargets = monthlyTargets; self.rules = rules; self.decisionPolicy = decisionPolicy
        self.merchantTargets = merchantTargets; self.monthlySavings = monthlySavings; self.accounts = accounts
        self.openingBalances = openingBalances; self.transactions = transactions; self.suggestions = suggestions; self.reviewReasons = reviewReasons
        self.merchantAliases = merchantAliases; self.forgottenMerchants = forgottenMerchants; self.upgrades = upgrades
        self.recurringChoices = recurringChoices
        self.recurringReviews = recurringReviews
    }

    enum CodingKeys: String, CodingKey {
        case categories, monthlyTargets, rules, decisionPolicy, merchantTargets, monthlySavings, accounts, openingBalances, transactions
        case suggestions, reviewReasons, merchantAliases, forgottenMerchants, upgrades, recurringChoices
        case recurringReviews
    }

    /// Fields added after a ledger was first saved decode as empty; rules saved before they had ids get them.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(categories: try c.decode([BudgetCategory].self, forKey: .categories),
                  monthlyTargets: try c.decode([String: Money].self, forKey: .monthlyTargets),
                  rules: try BudgetRule.decodeStored(from: c.superDecoder(forKey: .rules)),
                  decisionPolicy: try c.decode(DecisionPolicy.self, forKey: .decisionPolicy),
                  merchantTargets: try c.decode([String: Money].self, forKey: .merchantTargets),
                  monthlySavings: try c.decodeIfPresent(Money.self, forKey: .monthlySavings),
                  accounts: try c.decode([Account].self, forKey: .accounts),
                  openingBalances: try c.decode([String: Money].self, forKey: .openingBalances),
                  transactions: try c.decode([LedgerTransaction].self, forKey: .transactions),
                  suggestions: try c.decode([String: [CategorySuggestion]].self, forKey: .suggestions),
                  reviewReasons: try c.decode([String: String].self, forKey: .reviewReasons),
                  merchantAliases: try c.decodeIfPresent([String: String].self, forKey: .merchantAliases) ?? [:],
                  forgottenMerchants: try c.decodeIfPresent([String].self, forKey: .forgottenMerchants) ?? [],
                  upgrades: try c.decodeIfPresent([String].self, forKey: .upgrades) ?? [],
                  recurringChoices: try c.decodeIfPresent([String: RecurringChoice].self, forKey: .recurringChoices) ?? [:],
                  recurringReviews: try c.decodeIfPresent([String: RecurringReviewMark].self, forKey: .recurringReviews) ?? [:])
    }

    /// A fresh ledger for a new install: the standard categories, no targets, no data. It lists no upgrades: the server
    /// loads stored documents over this one's, so a ledger stored before an upgrade must read as not having had it.
    public static var empty: LedgerState { LedgerState(categories: Ledger.categoryList) }
}

typealias DemoLedger = Ledger

/// The deterministic engine behind every number: balances, sums, projections, flex budget,
/// savings, review queue, proposals and actions. The demo builds one from fixtures; the server
/// from Postgres. The model never computes — it reads this engine's results through tools.
public struct Ledger: Sendable {
    static let historyDays = 180
    static let checkingID = "chk"
    static let savingsID = "sav"
    static let cardID = "card"

    public var now: Date
    public let calendar: Calendar
    // Mutable through `perform(_:)` in DemoLedger+Actions.swift.
    var categories: [BudgetCategory] { didSet { rowsToken = RowsToken.next() } }
    var monthlyTargets: [String: Money]
    /// Oldest first; the newest matching rule wins.
    var rules: [BudgetRule] = []
    var decisionPolicy = DecisionPolicy.default
    /// Monthly caps keyed by merchant name as shown ("DoorDash").
    var merchantTargets: [String: Money] = [:]
    /// Pay-yourself-first amount; nil means "what they already move to savings".
    var monthlySavings: Money?
    var accounts: [Account]
    /// Newest first.
    var transactions: [LedgerTransaction] { didSet { rowsToken = RowsToken.next() } }
    /// Changes whenever the rows, categories or recurring choices do, so what's worked out from them
    /// (`recurringIndex`) is worked out again.
    var rowsToken = RowsToken.next()
    /// Shared by copies of the ledger; keyed by `rowsToken`, so a copy that changed never reads another's answer.
    let recurringCache = RecurringCache()
    var suggestions: [String: [CategorySuggestion]] = [:]
    var reviewReasons: [String: String] = [:]
    var openingBalances: [String: Money]
    /// Normalized descriptor → the merchant name the person gave it ("rename all like it").
    var merchantAliases: [String: String] = [:]
    /// Normalized descriptors merchant memory leaves out until the person files one of their rows again.
    var forgottenMerchants: Set<String> = []
    /// One-time upgrades already applied (`LedgerState.upgrades`).
    var upgrades: Set<String> = []
    /// The person's say on which merchants recur (`LedgerState.recurringChoices`).
    var recurringChoices: [String: RecurringChoice] = [:] { didSet { rowsToken = RowsToken.next() } }
    /// The person's answers to "Did this stop?" (`LedgerState.recurringReviews`). An ended series leaves the usual month
    /// of bills and subscriptions, so a change is a change to what's worked out from the rows.
    var recurringReviews: [String: RecurringReviewMark] = [:] { didSet { rowsToken = RowsToken.next() } }

    public init(state: LedgerState, now: Date, calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
        categories = Self.withNewDefaults(state.categories)
        monthlyTargets = state.monthlyTargets
        rules = state.rules
        decisionPolicy = state.decisionPolicy
        merchantTargets = state.merchantTargets
        monthlySavings = state.monthlySavings
        accounts = state.accounts
        openingBalances = state.openingBalances
        transactions = state.transactions.sorted { $0.postedAt > $1.postedAt }
        suggestions = state.suggestions
        reviewReasons = state.reviewReasons
        merchantAliases = state.merchantAliases
        forgottenMerchants = Set(state.forgottenMerchants)
        upgrades = Set(state.upgrades)
        recurringChoices = state.recurringChoices
        recurringReviews = state.recurringReviews
        pairLegacyTransfers()
        upgradeLegacyProvenance()
        applyOneTimeUpgrades()
    }

    /// Upgrades that run once per ledger, on the first load after they ship, by name. Unlike the load-time repairs
    /// above, each changes what the ledger says about rows, so it must never run again over the person's later answers.
    static let oneTimeUpgrades = [cardIncomeUpgrade]
    static let cardIncomeUpgrade = "card-money-in-is-not-income"

    mutating func applyOneTimeUpgrades() {
        if upgrades.insert(Self.cardIncomeUpgrade).inserted { sendCardIncomeToReview() }
    }

    public var state: LedgerState {
        LedgerState(categories: categories, monthlyTargets: monthlyTargets, rules: rules, decisionPolicy: decisionPolicy,
                    merchantTargets: merchantTargets, monthlySavings: monthlySavings, accounts: accounts,
                    openingBalances: openingBalances, transactions: transactions, suggestions: suggestions, reviewReasons: reviewReasons,
                    merchantAliases: merchantAliases, forgottenMerchants: forgottenMerchants.sorted(), upgrades: upgrades.sorted(),
                    recurringChoices: recurringChoices, recurringReviews: recurringReviews)
    }

    /// Makes an account's replayed balance end at its reported balance (providers report the
    /// current balance; history is reconstructed backwards from it).
    mutating func reanchor(_ accountID: String) {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        let sum = transactions.lazy.filter { $0.accountID == accountID }.map(\.amount).sum(currencyCode: account.balance.currencyCode)
        openingBalances[accountID] = account.balance - sum
    }

    static let categoryList: [BudgetCategory] = [
        .init(id: "groceries", name: "Groceries", symbol: "cart"),
        .init(id: "dining", name: "Dining", symbol: "fork.knife"),
        .init(id: "transport", name: "Transport", symbol: "car"),
        .init(id: "housing", name: "Housing", symbol: "house", group: .bills),
        .init(id: "utilities", name: "Utilities", symbol: "bolt", group: .bills),
        .init(id: "subscriptions", name: "Subscriptions", symbol: "repeat", group: .subscriptions),
        .init(id: "shopping", name: "Shopping", symbol: "bag"),
        .init(id: "entertainment", name: "Entertainment", symbol: "ticket"),
        .init(id: "health", name: "Health", symbol: "heart"),
        .init(id: "travel", name: "Travel", symbol: "airplane"),
        .init(id: "fees", name: "Fees & interest", symbol: "percent", group: .bills),
        .init(id: "income", name: "Income", symbol: "arrow.down.circle", countsAsSpending: false, kind: .moneyIn),
        .init(id: "transfer", name: "Transfer", symbol: "arrow.left.arrow.right", countsAsSpending: false),
    ]

    init(now: Date, calendar: Calendar, seed: UInt64) {
        self.now = now
        self.calendar = calendar
        categories = Self.categoryList
        monthlyTargets = [
            "groceries": Money(650), "dining": Money(450), "transport": Money(250), "housing": Money(2400),
            "utilities": Money(300), "subscriptions": Money(60), "shopping": Money(300), "health": Money(250),
        ]
        openingBalances = [Self.checkingID: Money(6200), Self.savingsID: Money(18000), Self.cardID: .zero,
                           "meadow-inv": Money(32_418.77), "northwind": Money(48_210.10), "tidewater": Money(6_852.40)]

        var rng = SeededGenerator(seed: seed)
        var txs: [LedgerTransaction] = []
        var suggestionMap: [String: [CategorySuggestion]] = [:]
        var reasonMap: [String: String] = [:]
        var cardChargesByMonth: [String: Int64] = [:]
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -Self.historyDays, to: today)!
        let latestAllowed = now.addingTimeInterval(-120)

        func monthKey(_ date: Date) -> String {
            let c = calendar.dateComponents([.year, .month], from: date)
            return "\(c.year!)-\(c.month!)"
        }

        func add(_ day: Date, hour: Int, merchant: String, raw: String, amount: Decimal, category: String, account: String,
                 confidence: Double = 0.99, tier: CategorizationTier = .merchantMemory) {
            let minutes = hour * 60 + Int.random(in: 0..<60, using: &rng)
            let posted = min(calendar.date(byAdding: .minute, value: minutes, to: day)!, latestAllowed)
            let money = Money(amount)
            let id = "tx-\(txs.count + 1)"
            txs.append(LedgerTransaction(
                id: id, accountID: account, postedAt: posted, merchant: merchant, rawDescription: raw, amount: money,
                categorization: Categorization(categoryID: category, confidence: confidence, tier: tier, needsReview: false),
                isPending: now.timeIntervalSince(posted) < 36 * 3600,
                source: account == Self.checkingID ? .teller : .plaid))
            if account == Self.cardID, money.isNegative {
                cardChargesByMonth[monthKey(posted), default: 0] += -money.minorUnits
            }
        }

        func random(_ range: ClosedRange<Double>) -> Decimal {
            let value = Double.random(in: range, using: &rng)
            return Decimal((value * 100).rounded() / 100)
        }

        func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }

        // The last two rows added are the two sides of one move between accounts.
        func pairLastTwo() {
            txs[txs.count - 1].transferPeerID = txs[txs.count - 2].id
            txs[txs.count - 2].transferPeerID = txs[txs.count - 1].id
        }

        typealias Merchant = (name: String, raw: String, range: ClosedRange<Double>)
        let groceries: [Merchant] = [("Trader Joe's", "TRADER JOE S #236", 38...140), ("Whole Foods Market", "WHOLEFDS MKT 10238", 45...165),
                                     ("Safeway", "SAFEWAY #1507", 30...110), ("Green Valley Co-op", "GREEN VALLEY COOP", 25...90)]
        let dining: [Merchant] = [("Blue Bottle Coffee", "BLUE BOTTLE COFFEE", 5...9), ("Hearth Bakery", "HEARTH BAKERY", 12...28),
                                  ("Harvest Table", "HARVEST TABLE", 64...142), ("DoorDash", "DD *DOORDASH", 22...55), ("Olive Grill", "OLIVE GRILL MAIN", 18...40)]
        let transport: [Merchant] = [("Uber", "UBER *TRIP", 12...38), ("Shell", "SHELL OIL 5744", 45...72), ("Metro Transit", "METRO TRANSIT", 3...10)]
        let shopping: [Merchant] = [("Amazon", "AMAZON.COM*RT4", 15...120), ("Target", "TARGET 00027", 25...140), ("Uniqlo", "UNIQLO USA", 40...110)]

        for dayIndex in 0...Self.historyDays {
            let day = calendar.date(byAdding: .day, value: dayIndex, to: start)!
            let parts = calendar.dateComponents([.month, .day], from: day)
            let dom = parts.day!
            let month = parts.month!

            if dom == 1 {
                add(day, hour: 6, merchant: "Maple Court Apartments", raw: "MAPLE CT APTS ACH", amount: -2400, category: "housing", account: Self.checkingID)
            }
            if dom == 1 || dom == 15 {
                add(day, hour: 5, merchant: "Acme Corp", raw: "ACME CORP PAYROLL PPD", amount: 3850, category: "income", account: Self.checkingID)
            }
            if dom == 3 {
                add(day, hour: 9, merchant: "Transfer to Savings", raw: "ONLINE TRANSFER TO SAV", amount: -500, category: "transfer", account: Self.checkingID)
                add(day, hour: 9, merchant: "Transfer from Checking", raw: "ONLINE TRANSFER FROM CHK", amount: 500, category: "transfer", account: Self.savingsID)
                pairLastTwo()
            }
            if dom == 5 { add(day, hour: 3, merchant: "Netflix", raw: "NETFLIX.COM", amount: -15.49, category: "subscriptions", account: Self.cardID) }
            if dom == 8 { add(day, hour: 4, merchant: "Peak Fitness", raw: "PEAK FITNESS #144", amount: -185, category: "health", account: Self.cardID) }
            // A power bill that moves with the season, its highest month within 15% of its lowest: steady by the recurring
            // rule whichever month is the median, so it's on Recurring every day of the year.
            if dom == 10 { add(day, hour: 7, merchant: "City Power", raw: "CITYPOWER WEB ONLINE", amount: -random(136...156), category: "utilities", account: Self.checkingID) }
            if dom == 12 { add(day, hour: 3, merchant: "Spotify", raw: "SPOTIFY USA", amount: -11.99, category: "subscriptions", account: Self.cardID) }
            if dom == 18 { add(day, hour: 7, merchant: "Xfinity", raw: "COMCAST XFINITY", amount: -79.99, category: "utilities", account: Self.checkingID) }
            if dom == 20 { add(day, hour: 3, merchant: "iCloud+", raw: "APPLE.COM/BILL ICLOUD", amount: -2.99, category: "subscriptions", account: Self.cardID) }
            if dom == 22 { add(day, hour: 3, merchant: "The New York Times", raw: "NYTIMES DIGITAL", amount: -25, category: "subscriptions", account: Self.cardID) }
            if dom == 25 {
                let previous = calendar.date(byAdding: .month, value: -1, to: day)!
                if let owed = cardChargesByMonth[monthKey(previous)], owed > 0 {
                    let amount = Decimal(owed) / 100
                    add(day, hour: 8, merchant: "Summit Payment", raw: "SUMMIT EPAYMENT ACH PMT", amount: -amount, category: "transfer", account: Self.checkingID)
                    add(day, hour: 8, merchant: "Payment — Thank You", raw: "PAYMENT RECEIVED", amount: amount, category: "transfer", account: Self.cardID)
                    pairLastTwo()
                }
            }

            if chance(0.3), let m = groceries.randomElement(using: &rng) {
                add(day, hour: Int.random(in: 10...19, using: &rng), merchant: m.name, raw: m.raw, amount: -random(m.range), category: "groceries", account: Self.checkingID)
            }
            // Summer runs hotter on dining, so "Q3 vs Q2" has a real answer.
            if chance((7...9).contains(month) ? 0.62 : 0.45), let m = dining.randomElement(using: &rng) {
                add(day, hour: Int.random(in: 8...21, using: &rng), merchant: m.name, raw: m.raw, amount: -random(m.range), category: "dining", account: Self.cardID)
            }
            if chance(0.35), let m = transport.randomElement(using: &rng) {
                add(day, hour: Int.random(in: 7...22, using: &rng), merchant: m.name, raw: m.raw, amount: -random(m.range), category: "transport", account: Self.cardID)
            }
            if chance(0.14), let m = shopping.randomElement(using: &rng) {
                add(day, hour: Int.random(in: 11...21, using: &rng), merchant: m.name, raw: m.raw, amount: -random(m.range), category: "shopping", account: Self.cardID)
            }
            if dayIndex == 118 { add(day, hour: 14, merchant: "United Airlines", raw: "UNITED 0162348851", amount: -486.20, category: "travel", account: Self.cardID) }
            if dayIndex == 121 { add(day, hour: 16, merchant: "Riverside Hotel", raw: "RIVERSIDE HOTEL AUSTIN", amount: -612, category: "travel", account: Self.cardID) }
        }

        // Items the pipeline wasn't sure about — these land in the review queue.
        typealias Unsure = (daysAgo: Int, merchant: String, raw: String, amount: Decimal, account: String, tier: CategorizationTier, suggestions: [(String, Double)], reason: String)
        let unsure: [Unsure] = [
            (1, "Casa Taco", "SQ *CASA TACO 0423", -23.50, Self.cardID, .embedding, [("dining", 0.62), ("groceries", 0.21)],
             "New merchant behind a Square descriptor — no match in merchant memory yet."),
            (2, "PayPal", "PAYPAL *XJ29QK", -64.00, Self.cardID, .model, [("shopping", 0.41), ("subscriptions", 0.33)],
             "PayPal hides the real merchant, and the model split between two categories."),
            (3, "Amazon Marketplace", "AMZN MKTP US*2K4LL", -38.17, Self.cardID, .embedding, [("shopping", 0.58), ("groceries", 0.30)],
             "Marketplace orders span several categories."),
            (5, "Venmo", "VENMO *J. PARK", -45.00, Self.checkingID, .model, [("transfer", 0.44), ("dining", 0.31)],
             "Person-to-person payment: could be a transfer or a shared expense."),
            (6, "Local 123", "TST* LOCAL 123", -17.25, Self.cardID, .embedding, [("dining", 0.55), ("shopping", 0.18)],
             "Toast descriptor with no history."),
            (9, "Apple", "APPLE.COM/BILL 866-712", -9.99, Self.cardID, .embedding, [("subscriptions", 0.68), ("shopping", 0.20)],
             "Apple bills cover both apps and subscriptions."),
            (12, "CVS", "CHECKCARD 0917 CVS/PHARM", -31.84, Self.cardID, .model, [("health", 0.52), ("shopping", 0.38)],
             "Pharmacies sell both health and household items."),
        ]
        for item in unsure {
            let day = calendar.date(byAdding: .day, value: -item.daysAgo, to: today)!
            add(day, hour: 13, merchant: item.merchant, raw: item.raw, amount: item.amount, category: item.suggestions[0].0, account: item.account,
                confidence: item.suggestions[0].1, tier: item.tier)
            let id = txs[txs.count - 1].id
            txs[txs.count - 1].categorization?.needsReview = true
            suggestionMap[id] = item.suggestions.map { CategorySuggestion(categoryID: $0.0, confidence: $0.1) }
            reasonMap[id] = item.reason
        }

        transactions = txs.sorted { $0.postedAt > $1.postedAt }
        suggestions = suggestionMap
        reviewReasons = reasonMap
        accounts = [
            Account(id: Self.checkingID, name: "Total Checking", institution: "Harbor", kind: .checking, balance: .zero, source: .teller),
            Account(id: Self.savingsID, name: "Cash Account", institution: "Meadow", kind: .savings, balance: .zero, source: .plaid),
            Account(id: Self.cardID, name: "Gold Card", institution: "Summit Card", kind: .credit, balance: .zero, source: .plaid),
            // Balance-only investment accounts: shown, never counted as cash.
            Account(id: "meadow-inv", name: "Automated Investing", institution: "Meadow", kind: .investment, balance: .zero, source: .plaid),
            Account(id: "northwind", name: "Individual Brokerage", institution: "Northwind Brokerage", kind: .investment, balance: .zero, source: .plaid),
            Account(id: "tidewater", name: "Individual", institution: "Tidewater", kind: .investment, balance: .zero, source: .plaid),
        ]
        addShowcaseDetails()
        addCardRewards()
        for index in accounts.indices {
            accounts[index].balance = balance(of: accounts[index].id, through: now)
        }
        addActivityExamples(today: today)
        addRecurringExamples(today: today)
        // The demo's rows include answers the model filed, so its settings say the model is on (Qwen Decide at 80%).
        decisionPolicy = DecisionPolicy(provider: .localDecide, autoAcceptPercent: 80, kinds: [.category])
    }

    /// Where each of the demo household's institutions comes from.
    /// The demo's connections, as the server publishes real ones: four that sync, and Tidewater waiting for a sign-in.
    /// Keystone isn't here: its card only comes from statements, so the ledger lists it on its own (`institutionLinks`).
    static let institutionPlan: [InstitutionLink] = [
        InstitutionLink(id: "harbor", institution: "Harbor", primary: .teller, fallback: nil, accountKinds: [.checking], status: .demo,
                        note: "Demo data, as if connected through Teller."),
        InstitutionLink(id: "meadow", institution: "Meadow", primary: .plaid, fallback: nil, accountKinds: [.savings, .investment], status: .demo,
                        note: "Demo data, as if connected through Plaid."),
        InstitutionLink(id: "summit", institution: "Summit Card", primary: .plaid, fallback: nil, accountKinds: [.credit], status: .demo,
                        note: "Demo data, as if connected through Plaid."),
        InstitutionLink(id: "northwind", institution: "Northwind Brokerage", primary: .plaid, fallback: nil, accountKinds: [.investment], status: .demo,
                        note: "Demo data, as if connected through Plaid."),
        InstitutionLink(id: "tidewater", institution: "Tidewater", primary: .plaid, fallback: nil, accountKinds: [.investment], status: .needsReauth,
                        note: "Demo data: Tidewater ended the connection.",
                        lastError: "the login details of this item have changed (credentials, MFA, or required user action) and a user login is required to update this information"),
    ]

    // MARK: - Lookups

    /// Any category by id, merged-away ones included (old rows still name them).
    func category(_ id: String) -> BudgetCategory? { categories.first { $0.id == id } }

    /// Categories new rows can be filed under: everything not merged away. Pickers, tools and the decision
    /// model see only these.
    var activeCategories: [BudgetCategory] { categories.filter { !$0.isArchived } }

    private var spendingCategoryIDs: Set<String> { Set(categories.filter(\.countsAsSpending).map(\.id)) }

    // MARK: - Balances

    func balance(of accountID: String, through date: Date) -> Money {
        transactions.lazy.filter { $0.accountID == accountID && $0.postedAt <= date }.map(\.amount).sum() + (openingBalances[accountID] ?? .zero)
    }

    var cashAccountIDs: [String] { accounts.filter { $0.kind == .checking || $0.kind == .savings }.map(\.id) }
    var savingsAccountIDs: Set<String> { Set(accounts.filter { $0.kind == .savings }.map(\.id)) }

    /// Checking + savings. Card debt shows up when it's paid; investments never count as cash.
    func cash(through date: Date) -> Money {
        cashAccountIDs.map { balance(of: $0, through: date) }.sum()
    }

    /// Cash less what's owed on cards. A card charge lowers it the day it's made, so paying the card's bill moves money
    /// between accounts without moving this — the balance the projection starts from and charts.
    func cashAfterCards(through date: Date) -> Money {
        cash(through: date) + accounts.filter { $0.kind == .credit }.map { balance(of: $0.id, through: date) }.sum()
    }

    /// Cash at the end of each day, `days` back through today (every `strideDays`); or cash after cards.
    func cashTrend(days: Int, strideDays: Int = 1, afterCards: Bool = false) -> [BalancePoint] {
        let today = calendar.startOfDay(for: now)
        return stride(from: days, through: 0, by: -strideDays).map { back in
            let day = calendar.date(byAdding: .day, value: -back, to: today)!
            let endOfDay = back == 0 ? now : calendar.date(byAdding: .second, value: 86_399, to: day)!
            return BalancePoint(date: day, balance: afterCards ? cashAfterCards(through: endOfDay) : cash(through: endOfDay))
        }
    }

    // MARK: - sumByCategory

    /// The rows every total reads: posted in the window and not hidden. Balances read `transactions` directly,
    /// so a hidden row still moves them.
    func transactions(from start: Date, to end: Date) -> [LedgerTransaction] {
        transactions.filter { $0.postedAt >= start && $0.postedAt < end && !$0.isHidden }
    }

    func spent(from start: Date, to end: Date, categoryID: String? = nil) -> Money {
        netSpend(transactions(from: start, to: end), categoryIDs: categoryID.map { [$0] })
    }

    /// Money out across `rows` in spending categories (or just `categoryIDs`), hidden rows left out. Each category is
    /// net of the refunds and statement credits filed in it (a Tablesy credit offsets dining) and never below zero, so a
    /// category that took in more than it spent adds nothing — and never cancels another category's spending. Every
    /// spending figure uses this one rule, so the totals, the category rows, the budget groups and cash flow agree
    /// to the cent.
    func netSpend(_ rows: [LedgerTransaction], categoryIDs: Set<String>? = nil) -> Money {
        let ids = categoryIDs ?? spendingCategoryIDs
        var net: [String: Int64] = [:]
        for row in rows where !row.isHidden {
            guard let id = row.categorization?.categoryID, ids.contains(id) else { continue }
            net[id, default: 0] += row.amount.minorUnits
        }
        return Money(minorUnits: net.values.map { max(0, -$0) }.reduce(0, +))
    }

    /// Money filed under a money-in category (Income, and any the person made, like card rewards) across `rows`,
    /// hidden rows left out. Every income figure — income totals, expected income, cash flow — uses this one rule.
    func netIncome(_ rows: [LedgerTransaction]) -> Money {
        let ids = moneyInCategoryIDs
        return rows.filter { !$0.isHidden && ids.contains($0.categorization?.categoryID ?? "") }.map(\.amount).sum()
    }

    /// Whether a row counts toward spending and income (not hidden, not a transfer).
    func isCounted(_ row: LedgerTransaction) -> Bool {
        row.isCounted(category: row.categorization.flatMap { category($0.categoryID) })
    }

    /// Categories added to the defaults after a ledger was created show up in it (placed before the
    /// non-spending ones), without touching anything the person made or renamed. A standard category merged
    /// away is still there, archived, so it isn't added back.
    static func withNewDefaults(_ existing: [BudgetCategory]) -> [BudgetCategory] {
        guard !existing.isEmpty else { return existing }
        let have = Set(existing.map(\.id))
        let missing = categoryList.filter { !have.contains($0.id) && $0.countsAsSpending }
        guard !missing.isEmpty else { return existing }
        let firstNonSpending = existing.firstIndex { !$0.countsAsSpending } ?? existing.count
        var merged = existing
        merged.insert(contentsOf: missing, at: firstNonSpending)
        return merged
    }

    func income(from start: Date, to end: Date) -> Money {
        netIncome(transactions(from: start, to: end))
    }

    func sumByCategory(from start: Date, to end: Date, includeTargets: Bool) -> [CategoryTotal] {
        categoryTotals(transactions(from: start, to: end), includeTargets: includeTargets)
    }

    /// Each spending category's net spending across `window` (with its target when asked), most spent first.
    func categoryTotals(_ window: [LedgerTransaction], includeTargets: Bool) -> [CategoryTotal] {
        categories.filter(\.countsAsSpending).compactMap { category in
            let rows = window.filter { $0.categorization?.categoryID == category.id }
            guard !rows.isEmpty || (includeTargets && monthlyTargets[category.id] != nil) else { return nil }
            return CategoryTotal(category: category, spent: netSpend(rows, categoryIDs: [category.id]),
                                 target: includeTargets ? monthlyTargets[category.id] : nil, transactionCount: rows.count)
        }
        .sorted { $0.spent > $1.spent }
    }

    // MARK: - Ranges

    var startOfMonth: Date { calendar.dateInterval(of: .month, for: now)!.start }

    func interval(for range: SpendingRange) -> (start: Date, end: Date) {
        switch range {
        case .thisMonth: (startOfMonth, now)
        case .lastMonth: (calendar.date(byAdding: .month, value: -1, to: startOfMonth)!, startOfMonth)
        case .last90Days: (calendar.date(byAdding: .day, value: -90, to: now)!, now)
        case .yearToDate: (calendar.dateInterval(of: .year, for: now)!.start, now)
        }
    }

    /// The comparable earlier window, e.g. "the same point last month".
    func previousInterval(for range: SpendingRange) -> (start: Date, end: Date, label: String)? {
        switch range {
        case .thisMonth:
            // As far into last month as this one is, but never past its end (the 31st against a 30-day month).
            let start = calendar.date(byAdding: .month, value: -1, to: startOfMonth)!
            return (start, min(start.addingTimeInterval(now.timeIntervalSince(startOfMonth)), startOfMonth), "the same point last month")
        case .lastMonth:
            let end = calendar.date(byAdding: .month, value: -1, to: startOfMonth)!
            return (calendar.date(byAdding: .month, value: -1, to: end)!, end, "the month before")
        case .last90Days:
            let end = calendar.date(byAdding: .day, value: -90, to: now)!
            return (calendar.date(byAdding: .day, value: -90, to: end)!, end, "the 90 days before")
        case .yearToDate:
            return nil
        }
    }

    func quarter(_ q: Int, year: Int) -> (start: Date, end: Date) {
        let start = calendar.date(from: DateComponents(year: year, month: (q - 1) * 3 + 1, day: 1))!
        let end = min(calendar.date(byAdding: .month, value: 3, to: start)!, now)
        return (start, end)
    }

    func spendingSummary(_ range: SpendingRange) -> SpendingSummary {
        let window = interval(for: range)
        let total = spent(from: window.start, to: window.end)
        var previousTotal: Money?
        var comparison: String?
        if let previous = previousInterval(for: range) {
            let prior = spent(from: previous.start, to: previous.end)
            previousTotal = prior
            comparison = Self.comparisonLine(current: total, previous: prior, against: previous.label)
        }
        let monthly = range == .thisMonth || range == .lastMonth
        let caps = monthly ? merchantTargets.keys.sorted().map { merchant in
            MerchantCap(merchant: merchant, spent: merchantSpend(merchant, from: window.start, to: window.end).total, target: merchantTargets[merchant]!)
        } : []
        return SpendingSummary(range: range, start: window.start, end: window.end, total: total, previousTotal: previousTotal,
                               comparison: comparison, categories: sumByCategory(from: window.start, to: window.end, includeTargets: monthly),
                               merchantCaps: caps)
    }

    static func comparisonLine(current: Money, previous: Money, against label: String) -> String {
        guard previous.minorUnits > 0 else { return "Nothing to compare against yet" }
        let change = Double(current.minorUnits - previous.minorUnits) / Double(previous.minorUnits)
        let pct = Int((abs(change) * 100).rounded())
        if pct == 0 { return "About the same as \(label)" }
        return "\(pct)% \(change > 0 ? "more" : "less") than \(label)"
    }

    // MARK: - Periods ("this_month", "2026-Q3", "2026-09", …) as the tools and filters name them

    func interval(forPeriod period: String) -> (start: Date, end: Date, label: String)? {
        let p = period.lowercased()
        let startOfYear = calendar.dateInterval(of: .year, for: now)!.start
        switch p {
        case "this_month": return (startOfMonth, now, now.formatted(.dateTime.month(.wide).year()))
        case "last_month":
            let w = interval(for: .lastMonth)
            return (w.start, w.end, w.start.formatted(.dateTime.month(.wide).year()))
        case "last_7_days":
            // Today and the six days before it, from midnight — the days Home's week strip shows.
            return (calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))!, now, "the last 7 days")
        case "last_30_days": return (calendar.date(byAdding: .day, value: -30, to: now)!, now, "the last 30 days")
        case "last_90_days": let w = interval(for: .last90Days); return (w.start, w.end, "the last 90 days")
        case "last_6_months": return (calendar.date(byAdding: .month, value: -6, to: now)!, now, "the last 6 months")
        case "year_to_date": let w = interval(for: .yearToDate); return (w.start, w.end, "\(calendar.component(.year, from: now)) so far")
        case "last_year":
            let start = calendar.date(byAdding: .year, value: -1, to: startOfYear)!
            return (start, startOfYear, "\(calendar.component(.year, from: start))")
        case "all": return (.distantPast, now, "all time")
        default: break
        }
        if let m = p.wholeMatch(of: /(\d{4})-q([1-4])/), let year = Int(m.1), let q = Int(m.2) {
            let w = quarter(q, year: year)
            return (w.start, w.end, "Q\(q) \(year)")
        }
        if let start = monthStart(p) {
            let end = min(calendar.date(byAdding: .month, value: 1, to: start)!, now)
            return (start, end, start.formatted(.dateTime.month(.wide).year()))
        }
        return nil
    }

    /// The first instant of the month a key like "2026-09" names; nil for anything else.
    func monthStart(_ key: String) -> Date? {
        guard let m = key.wholeMatch(of: /(\d{4})-(\d{2})/), let year = Int(m.1), let month = Int(m.2), (1...12).contains(month) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: 1))
    }

    /// "2026-09" for the month holding `date`.
    func monthKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year!, parts.month!)
    }

    // MARK: - Merchants

    func merchantSpend(_ merchant: String, from start: Date, to end: Date) -> (total: Money, count: Int) {
        let rows = transactions(from: start, to: end).filter {
            $0.amount.isNegative && ($0.merchant.localizedCaseInsensitiveContains(merchant) || $0.rawDescription.localizedCaseInsensitiveContains(merchant))
                && ($0.categorization?.categoryID).map { category($0)?.countsAsSpending ?? true } ?? true
        }
        return (rows.map(\.amount.magnitude).sum(), rows.count)
    }

    /// A merchant named in free text: the whole name ("doordash", "blue bottle coffee") or its
    /// distinctive first word ("uniqlo"), never a common word like "the".
    func merchant(mentionedIn text: String) -> String? {
        let t = text.lowercased()
        let squashed = t.filter { $0.isLetter || $0.isNumber }
        let names = Set(transactions.map(\.merchant))
        func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        if let full = names.filter({ squash($0).count >= 4 && squashed.contains(squash($0)) }).max(by: { $0.count < $1.count }) { return full }
        let words = Set(t.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        return names.first { name in
            guard let first = name.lowercased().split(separator: " ").first.map(String.init), first.count >= 4 else { return false }
            return words.contains(first) && !["payment", "transfer", "apple", "local"].contains(first)
        }
    }

    /// Canonical merchant name as the ledger shows it ("doordash" → "DoorDash").
    func canonicalMerchant(_ query: String) -> String? {
        transactions.first { $0.merchant.localizedCaseInsensitiveContains(query) || $0.rawDescription.localizedCaseInsensitiveContains(query) }?.merchant
    }

    // MARK: - Savings capacity ("how much can I save")

    struct Capacity {
        var months: Int
        var income: Money
        /// A usual month of bills and of subscriptions (`budgetTotals`, spread charges at a twelfth).
        var bills: Money
        var subscriptions: Money
        /// A usual month of everyday spending.
        var everyday: Money
        /// Each month's income − spending as it actually went out (its `MonthFlow.net`), averaged, so it reconciles
        /// with Plan's cash flow. It differs from income − bills − subscriptions − everyday by how far charges spread
        /// over the year landed in these months rather than a twelfth in each.
        var typical: Money
        /// With everyday spending at its lowest recent month.
        var stretch: Money
        /// Money actually moved to savings per month.
        var alreadySaving: Money
        var emergencyMonths: Double
        var essentialMonthly: Money
        var cashOnHand: Money
    }

    func capacity(months count: Int = 3) -> Capacity {
        let windows = (1...count).map { back -> (Date, Date) in
            let start = calendar.date(byAdding: .month, value: -back, to: startOfMonth)!
            return (start, calendar.date(byAdding: .month, value: 1, to: start)!)
        }
        let flows = windows.map { flow(from: $0.0, to: $0.1) }
        // A series the person said they canceled is out of the usual month at once, not after it ages out.
        let ended = recurringIndex.endedIDs(asOf: now)
        let buckets = windows.map { budgetTotals(from: $0.0, to: $0.1, leavingOut: ended) }
        func usual(_ group: CategoryGroup) -> [Money] { buckets.map { ($0[group] ?? []).map(\.spent).sum() } }
        let income = Self.average(flows.map(\.income))
        let bills = Self.average(usual(.bills))
        let subscriptions = Self.average(usual(.subscriptions))
        let everyday = Self.average(usual(.everyday))
        // The average of the months' nets, so Plan's cash flow history reconciles with it to the cent.
        let typical = Self.average(flows.map(\.net))
        let stretch = typical + everyday - (usual(.everyday).min() ?? everyday)
        let saving = Self.average(windows.map { movedToSavings(from: $0.0, to: $0.1) })
        // Essentials: bills and subscriptions, plus everyday groceries and transport (a transit pass on the recurring list
        // is already a subscription).
        let essentials = bills + subscriptions
            + Self.average(buckets.map { ($0[.everyday] ?? []).filter { ["groceries", "transport"].contains($0.category.id) }.map(\.spent).sum() })
        let cash = cash(through: now)
        return Capacity(months: count, income: income, bills: bills, subscriptions: subscriptions, everyday: everyday, typical: typical,
                        stretch: stretch, alreadySaving: saving,
                        emergencyMonths: essentials.minorUnits > 0 ? Double(cash.minorUnits) / Double(essentials.minorUnits) : 0,
                        essentialMonthly: essentials, cashOnHand: cash)
    }

    /// The mean of `values`, to the cent (rounded toward zero); zero for none.
    static func average(_ values: [Money]) -> Money {
        Money(minorUnits: values.map(\.minorUnits).reduce(0, +) / Int64(max(values.count, 1)))
    }

    /// Income against spending over a window as it actually went, each category net of its refunds — what Plan's
    /// cash flow shows and savings capacity's `typical` averages. (The budget counts some charges spread over the year;
    /// cash flow doesn't.)
    struct Flow {
        var income: Money
        var spending: Money
        var net: Money { income - spending }
    }

    func flow(from start: Date, to end: Date) -> Flow {
        let window = transactions(from: start, to: end)
        return Flow(income: netIncome(window), spending: netSpend(window))
    }

    // MARK: - Flex budget

    /// Income − a usual month of bills and of subscriptions − saved first is the everyday budget; safe to spend is what
    /// this month's everyday spending (`budgetTotals`) leaves of it. Income is the lower of the last three months'
    /// average and a month of the latest paychecks (`expectedIncome(average:)`).
    func flexBudget() -> FlexBudget {
        let c = capacity()
        let income = expectedIncome(average: c.income)
        let planned = monthlySavings ?? c.alreadySaving
        let flexNumber = income.amount - c.bills - c.subscriptions - planned
        let month = interval(for: .thisMonth)
        let flexSpent = budgetSpent(.everyday, from: month.start, to: month.end)
        let safeToSpend = flexNumber - flexSpent
        let daysLeft = calendar.range(of: .day, in: .month, for: now)!.count - calendar.component(.day, from: now)
        return FlexBudget(expectedIncome: income.amount, bills: c.bills, subscriptions: c.subscriptions, plannedSavings: planned,
                          plannedSavingsIsSet: monthlySavings != nil, flexNumber: flexNumber, flexSpent: flexSpent,
                          safeToSpend: safeToSpend, daysLeft: daysLeft,
                          perDayLeft: Money(minorUnits: max(safeToSpend.minorUnits, 0) / Int64(daysLeft + 1)),
                          incomeSource: income.source, averageIncome: c.income, recentPaychecks: income.paychecks?.total,
                          paycheckCount: income.paychecks?.perMonth)
    }

    // MARK: - Review

    /// Whether a row is in the review queue: it needs a look, isn't hidden, and — with `holdPending` — has posted.
    /// The queue, the "needs review" filter and every review count use this one test.
    func isWaitingForReview(_ row: LedgerTransaction) -> Bool {
        row.categorization?.needsReview == true && !row.isHidden && !(decisionPolicy.holdPending && row.isPending)
    }

    /// Rows waiting for the person, newest first. With `holdPending`, pending charges wait until they post.
    var reviewItems: [ReviewItem] {
        transactions.filter(isWaitingForReview).map { tx in
            ReviewItem(transaction: tx, suggestions: suggestions[tx.id] ?? [], reason: reviewReasons[tx.id] ?? "Low confidence.",
                       isLarge: decisionPolicy.reviewAbove.map { tx.amount.magnitude.minorUnits > $0.minorUnits })
        }
    }

    /// Files a correction on the row and, like merchant memory would, on the rows still waiting for review that
    /// share its descriptor — never on a row the person filed or one that's settled. A generic descriptor
    /// ("Withdrawal") names no merchant, so it only reaches rows on the same account going the same way; money
    /// going out is never filed under a money-in category, nor money coming in on a card as Income; and a row over
    /// the review-above amount waits to be checked on its own. Returns how many rows changed, with an undo.
    @discardableResult
    mutating func confirm(transactionID: String, categoryID: String) throws -> ActionResult {
        guard let target = transactions.first(where: { $0.id == transactionID }) else { throw BudgetAPIError.notFound }
        guard let category = category(categoryID) else { throw BudgetAPIError.server(status: 422, message: "Unknown category") }
        guard !category.isArchived else { throw BudgetAPIError.rejected(Self.archivedMessage(category)) }
        let descriptor = Self.normalizedDescriptor(target.rawDescription)
        let generic = Descriptor.isGeneric(target.rawDescription)
        let indices = transactions.indices.filter { index in
            let row = transactions[index]
            if row.id == transactionID { return true }
            guard let c = row.categorization, c.needsReview, c.tier != .user, !row.isHidden,
                  Self.normalizedDescriptor(row.rawDescription) == descriptor,
                  !(category.isMoneyIn && row.amount.isNegative), !(categoryID == BudgetCategory.incomeID && isCardCredit(row)),
                  row.amount.magnitude.minorUnits <= decisionPolicy.reviewAbove?.minorUnits ?? .max else { return false }
            return !generic || (row.accountID == target.accountID && row.amount.isNegative == target.amount.isNegative)
        }
        let undo = restoring(indices)
        for index in indices { file(index, under: categoryID) }
        return ActionResult(message: indices.count == 1 ? "Filed under \(category.name)." : "Filed \(indices.count) transactions under \(category.name).",
                            affectedTransactions: indices.count, undo: undo)
    }

    static func normalizedDescriptor(_ raw: String) -> String { Descriptor.normalize(raw) }

    // MARK: - projectBalance

    /// Net cash change for each of the last `count` complete months — what cash actually did, beside income less
    /// spending on the Cash flow card. Hidden rows moved the balance but aren't part of the pace (a one-off the person
    /// set aside), so they're taken back out.
    func monthlyNets(count: Int) -> [Money] {
        let cashIDs = Set(cashAccountIDs)
        return (1...count).map { back in
            let start = calendar.date(byAdding: .month, value: -back, to: startOfMonth)!
            let end = calendar.date(byAdding: .month, value: 1, to: start)!
            let (from, through) = (start.addingTimeInterval(-1), end.addingTimeInterval(-1))
            let hidden = transactions.filter { $0.isHidden && cashIDs.contains($0.accountID) && $0.postedAt > from && $0.postedAt <= through }
                .map(\.amount).sum()
            return cash(through: through) - cash(through: from) - hidden
        }
    }

    /// The recent pace of cash: the last three complete months' net changes and their mean, in minor units.
    func cashPace() -> (nets: [Money], mean: Double) {
        let nets = monthlyNets(count: 3)
        return (nets, Double(nets.map(\.minorUnits).reduce(0, +)) / Double(nets.count))
    }

    /// How much cash grew a month, on average, over the last three complete months.
    var averageCashChange: Money { Money(minorUnits: Int64(cashPace().mean.rounded())) }

    /// Income less spending for each of the last `count` complete months, spending as the budget counts it (a charge
    /// spread over the year, a twelfth a month): the pace the projection runs at. Spending counts when it's made, not
    /// when the card is paid, so a month of big card payoffs doesn't read as a month of big spending.
    func spendingNets(count: Int) -> [Money] {
        (1...count).map { back in
            let start = calendar.date(byAdding: .month, value: -back, to: startOfMonth)!
            let end = calendar.date(byAdding: .month, value: 1, to: start)!
            let spending = budgetTotals(from: start, to: end).values.joined().map(\.spent).sum()
            return netIncome(transactions(from: start, to: end)) - spending
        }
    }

    /// The projection's pace: the last three complete months' income less spending, and their mean in minor units.
    func spendingPace() -> (nets: [Money], mean: Double) {
        let nets = spendingNets(count: 3)
        return (nets, Double(nets.map(\.minorUnits).reduce(0, +)) / Double(nets.count))
    }

    /// Cash after cards, charted back 120 days and carried forward at the recent pace of income less spending.
    func projection(horizonMonths: Int, goal: GoalQuery?) -> Projection {
        let horizon = max(1, min(horizonMonths, 36))
        let (nets, mean) = spendingPace()
        let variance = nets.map { pow(Double($0.minorUnits) - mean, 2) }.reduce(0, +) / Double(nets.count)
        let spread = max(sqrt(variance), 20_000) // at least $200/month of uncertainty
        let monthlyNet = Money(minorUnits: Int64(mean.rounded()))
        let current = cashAfterCards(through: now)
        let today = calendar.startOfDay(for: now)

        let projected = (0...horizon).map { m -> ProjectedPoint in
            let expected = Double(current.minorUnits) + mean * Double(m)
            let band = spread * sqrt(Double(m))
            return ProjectedPoint(date: calendar.date(byAdding: .month, value: m, to: today)!,
                                  expected: Money(minorUnits: Int64(expected.rounded())),
                                  low: Money(minorUnits: Int64((expected - band).rounded())),
                                  high: Money(minorUnits: Int64((expected + band).rounded())))
        }

        var check: GoalCheck?
        if let goal {
            let months = max(goal.targetDate.timeIntervalSince(now) / (30.436875 * 86_400), 0.5)
            let saved = Money(minorUnits: max(0, Int64((mean * months).rounded())))
            let shortfall = Money(minorUnits: max(0, goal.amount.minorUnits - saved.minorUnits))
            let needed = Money(minorUnits: Int64((Double(goal.amount.minorUnits) / months).rounded()))
            let onTrack = shortfall.minorUnits == 0
            let dateText = goal.targetDate.formatted(.dateTime.month(.wide).year())
            let summary = onTrack
                ? "At your recent pace you'd set aside \(saved.formatted(fractionDigits: 0)) by \(dateText) — enough for \(goal.amount.formatted(fractionDigits: 0))."
                : "At your recent pace you'd set aside \(saved.formatted(fractionDigits: 0)) by \(dateText), \(shortfall.formatted(fractionDigits: 0)) short. Setting aside \(needed.formatted(fractionDigits: 0)) a month closes the gap."
            check = GoalCheck(query: goal, projectedSavings: saved, isOnTrack: onTrack, shortfall: shortfall, monthlyNeeded: needed, summary: summary)
        }

        return Projection(accountID: nil, horizonMonths: horizon, history: cashTrend(days: 120, strideDays: 4, afterCards: true), projected: projected,
                          monthlyNet: monthlyNet, endBalance: projected.last!.expected, goal: check,
                          cardsOwed: Money(minorUnits: -(current - cash(through: now)).minorUnits))
    }

    // MARK: - Overview

    /// - Parameter institutions: the deployment's links, for the connections that need signing in again.
    func overview(institutions: [InstitutionLink] = []) -> Overview {
        let month = interval(for: .thisMonth)
        let cashNow = cash(through: now)
        let cash30 = cash(through: calendar.date(byAdding: .day, value: -30, to: now)!)
        let week = lastSevenDays()
        let waiting = reviewItems
        let decisions = ReviewGroup.groups(waiting).count
        return Overview(
            asOf: now, cashOnHand: cashNow, cashChange30Days: cashNow - cash30, cashTrend: cashTrend(days: 90),
            monthSpent: spent(from: month.start, to: month.end), monthIncome: income(from: month.start, to: month.end), monthTarget: nil,
            leftToBudget: nil, reviewCount: waiting.count, flex: flexBudget(), insights: insights(),
            recent: Array(transactions.prefix(8)), accounts: accounts,
            attention: dataHealth(institutions: institutions), balances: balances(), lastSevenDays: week,
            lastSevenDaysSpent: week.first.map { everydaySpent(from: $0.date, to: now) }, reviewDecisions: decisions,
            reviewHeadline: waiting.isEmpty ? nil : ReviewGroup.headline(decisions: decisions, transactions: waiting.count))
    }

    /// Everyday spending on each of the last seven days, oldest first, today so far last. Each day stands on its own
    /// (never below zero), so a refund offsets its day, not the day of the charge; the week's figure is
    /// `everydaySpent` over the whole window (`Overview.lastSevenDaysSpent`).
    func lastSevenDays() -> [DaySpend] {
        let today = calendar.startOfDay(for: now)
        return (0..<7).reversed().map { back in
            let day = calendar.date(byAdding: .day, value: -back, to: today)!
            let end = back == 0 ? now : calendar.date(byAdding: .day, value: 1, to: day)!
            return DaySpend(date: day, flexibleSpent: everydaySpent(from: day, to: end))
        }
    }

    func insights() -> [Insight] {
        var result: [Insight] = []
        let month = interval(for: .thisMonth)

        if let previous = previousInterval(for: .thisMonth) {
            let current = spent(from: month.start, to: month.end, categoryID: "dining")
            let before = spent(from: previous.start, to: previous.end, categoryID: "dining")
            if before.minorUnits > 0 {
                let change = Double(current.minorUnits - before.minorUnits) / Double(before.minorUnits)
                let pct = Int((abs(change) * 100).rounded())
                result.append(Insight(
                    id: "dining-pace", kind: .trend, eyebrow: "Dining",
                    title: change > 0 ? "Dining is running \(pct)% ahead of last month." : "Dining is \(pct)% below last month's pace.",
                    body: "\(current.formatted(fractionDigits: 0)) so far, against \(before.formatted(fractionDigits: 0)) at this point last month.",
                    computedBy: "sumByCategory",
                    askPrompt: change > 0 ? "Why is dining up this month?" : "Where did I spend less on dining this month?"))
            }
        }

        // The same repeat-charge detection as Recurring and the checkup, so every screen gives one figure.
        let found = subscriptions()
        let subs = found.items.filter { $0.status == .active && $0.kind == .subscription }
        if let largest = subs.max(by: { $0.monthlyCost < $1.monthlyCost }) {
            result.append(Insight(
                id: "subscriptions", kind: .subscription, eyebrow: "Subscriptions",
                title: "\(found.subscriptionsMonthly.formatted(fractionDigits: 0)) a month goes out on autopilot.",
                body: "\(subs.count) subscription\(subs.count == 1 ? "" : "s"), found from repeat charges. The largest is \(largest.merchant) at \(largest.monthlyCost.formatted()) a month.",
                computedBy: "subscriptions", askPrompt: "Which of my subscriptions could I cancel?"))
        }

        let totals = sumByCategory(from: month.start, to: month.end, includeTargets: true)
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)!.count
        let dayOfMonth = calendar.component(.day, from: now)
        if let hottest = totals.filter({ ($0.target?.minorUnits ?? 0) > 0 && $0.category.id != "housing" })
            .max(by: { Double($0.spent.minorUnits) / Double($0.target!.minorUnits) < Double($1.spent.minorUnits) / Double($1.target!.minorUnits) }),
            let target = hottest.target {
            let pct = Int((Double(hottest.spent.minorUnits) / Double(target.minorUnits) * 100).rounded())
            let left = daysInMonth - dayOfMonth + 1
            result.append(Insight(
                id: "budget-\(hottest.category.id)", kind: .budget, eyebrow: "Budget",
                title: "\(hottest.category.name) is at \(pct)% of its target.",
                body: "\(hottest.spent.formatted(fractionDigits: 0)) of \(target.formatted(fractionDigits: 0)), " + (left <= 1 ? "on the month's last day." : "with \(left) days left in the month."),
                computedBy: "sumByCategory", askPrompt: "How can I keep \(hottest.category.name.lowercased()) under its target this month?"))
        }

        let plan = projection(horizonMonths: 3, goal: nil)
        if plan.monthlyNet.minorUnits > 0 {
            result.append(Insight(
                id: "plan-pace", kind: .plan, eyebrow: "Forecast",
                title: "On pace to add \(plan.monthlyNet.formatted(fractionDigits: 0)) a month.",
                body: "Income less spending, the last three months. That puts cash after cards near \(plan.endBalance.formatted(fractionDigits: 0)) in three months if it holds.",
                computedBy: "projectBalance", askPrompt: "How much could I save by the end of the year?"))
        }

        // Idle cash: checking well past what the bills need, which could be earning something in savings.
        let checkingIDs = accounts.filter { $0.kind == .checking }.map(\.id)
        if historyMonths >= 3, !checkingIDs.isEmpty {
            let essentials = capacity().essentialMonthly
            let checking = checkingIDs.map { balance(of: $0, through: now) }.sum()
            let cushion = Money(minorUnits: essentials.minorUnits * 3 / 2)
            let extra = checking - cushion
            if essentials.minorUnits > 0, extra.minorUnits >= 50_000 {
                result.append(Insight(
                    id: "idle-cash", kind: .savings, eyebrow: "Cash",
                    title: "\(extra.formatted(fractionDigits: 0)) in checking is more than the bills need.",
                    body: "Checking holds \(checking.formatted(fractionDigits: 0)); a month and a half of essentials is about \(cushion.formatted(fractionDigits: 0)). The rest could earn interest in savings.",
                    computedBy: "savingsCapacity", askPrompt: "Where should the extra cash in checking go?"))
            }
        }
        return result
    }
}
