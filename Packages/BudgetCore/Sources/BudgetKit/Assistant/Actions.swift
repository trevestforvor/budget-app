import Foundation

/// An amount as a model or a person types it: a decimal string like "500" or "-42.50".
/// Tools take amounts this way so the model never converts units — the server parses it.
public struct DecimalAmount: Hashable, Sendable, Codable, CustomStringConvertible {
    // Digits are [0-9], never \d: llama.cpp's JSON-schema-to-grammar converter rejects \d, and
    // one bad pattern anywhere in the tool catalog fails the whole request ("failed to parse grammar").
    public static let unsignedPattern = #"^[0-9]{1,9}(\.[0-9]{1,2})?$"#
    public static let signedPattern = #"^[+-]?[0-9]{1,9}(\.[0-9]{1,2})?$"#

    public var minorUnits: Int64

    public init(minorUnits: Int64) { self.minorUnits = minorUnits }
    public init(_ money: Money) { minorUnits = money.minorUnits }

    public init?(string raw: String) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard s.wholeMatch(of: /[+-]?\d{1,9}(\.\d{1,2})?/) != nil else { return nil }
        let negative = s.hasPrefix("-")
        let digits = s.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
        let whole = Int64(parts[0])!
        let cents = parts.count > 1 ? Int64(parts[1].padding(toLength: 2, withPad: "0", startingAt: 0))! : 0
        minorUnits = (whole * 100 + cents) * (negative ? -1 : 1)
    }

    public func money(_ currencyCode: String = "USD") -> Money { Money(minorUnits: minorUnits, currencyCode: currencyCode) }

    public var description: String {
        let sign = minorUnits < 0 ? "-" : ""
        let magnitude = Swift.abs(minorUnits)
        return "\(sign)\(magnitude / 100).\(String(format: "%02lld", magnitude % 100))"
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = DecimalAmount(string: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a decimal amount: \(raw)"))
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

// MARK: - Action payloads (one per write/client tool)

public struct SetCategoryTarget: Hashable, Sendable, Codable {
    public var categoryID: String
    public var monthlyAmount: DecimalAmount
    public init(categoryID: String, monthlyAmount: DecimalAmount) { self.categoryID = categoryID; self.monthlyAmount = monthlyAmount }
}

public struct AdjustCategoryTarget: Hashable, Sendable, Codable {
    public var categoryID: String
    /// Signed change; the ledger computes the new target.
    public var change: DecimalAmount
    public init(categoryID: String, change: DecimalAmount) { self.categoryID = categoryID; self.change = change }
}

public struct RemoveCategoryTarget: Hashable, Sendable, Codable {
    public var categoryID: String
    public init(categoryID: String) { self.categoryID = categoryID }
}

/// Pay yourself first: the amount set aside each month before anything else.
public struct SetMonthlySavings: Hashable, Sendable, Codable {
    public var monthlyAmount: DecimalAmount
    public init(monthlyAmount: DecimalAmount) { self.monthlyAmount = monthlyAmount }
}

/// A monthly cap on one merchant, e.g. DoorDash.
public struct SetMerchantTarget: Hashable, Sendable, Codable {
    public var merchant: String
    public var monthlyAmount: DecimalAmount
    public init(merchant: String, monthlyAmount: DecimalAmount) { self.merchant = merchant; self.monthlyAmount = monthlyAmount }
}

public struct RemoveMerchantTarget: Hashable, Sendable, Codable {
    public var merchant: String
    public init(merchant: String) { self.merchant = merchant }
}

public struct CreateCategory: Hashable, Sendable, Codable {
    public var name: String
    public var symbol: String?
    /// Spending only: money in has no target.
    public var monthlyTarget: DecimalAmount?
    /// How it behaves month to month; flexible when not given. Money in isn't budgeted, so it leaves this out.
    public var group: CategoryGroup?
    /// A `CategoryColor` name; when not given, the color the other categories use least.
    public var color: String?
    /// Spending when not given; `moneyIn` makes one that counts as money coming in, like income (card rewards). Set
    /// once: `updateCategory` never changes it.
    public var kind: CategoryKind?
    public init(name: String, symbol: String? = nil, monthlyTarget: DecimalAmount? = nil, group: CategoryGroup? = nil, color: String? = nil,
                kind: CategoryKind? = nil) {
        self.name = name; self.symbol = symbol; self.monthlyTarget = monthlyTarget; self.group = group; self.color = color; self.kind = kind
    }
}

/// Changes a category's name, icon, color or budget type; the id and the kind stay. Income and Transfer take only an
/// icon and a color; a money-in category has no budget type.
public struct UpdateCategory: Hashable, Sendable, Codable {
    public var categoryID: String
    public var name: String?
    /// SF Symbol name.
    public var symbol: String?
    /// A `CategoryColor` name.
    public var color: String?
    public var group: CategoryGroup?
    public init(categoryID: String, name: String? = nil, symbol: String? = nil, color: String? = nil, group: CategoryGroup? = nil) {
        self.categoryID = categoryID; self.name = name; self.symbol = symbol; self.color = color; self.group = group
    }
}

/// Folds one category into another of the same kind (spending into spending, money in into money in): its rows move
/// (each keeps how it was filed), and so do its rules, review suggestions and, with `combineTargets`, its monthly
/// target. A standard category is archived (so it isn't added back); one the person made is removed. Income and
/// Transfer are never merged away.
public struct MergeCategory: Hashable, Sendable, Codable {
    public var from: String
    public var into: String
    /// Add `from`'s monthly target to `into`'s; otherwise it's dropped and `into` keeps its own.
    public var combineTargets: Bool?
    public init(from: String, into: String, combineTargets: Bool? = nil) { self.from = from; self.into = into; self.combineTargets = combineTargets }
}

/// A categorization rule: rows matching `match` are filed under `categoryID`.
public struct CreateBudgetRule: Hashable, Sendable, Codable {
    public typealias Match = RuleMatch

    public var match: RuleMatch
    public var categoryID: String
    public var applyToExisting: Bool
    /// Who asked for it. The server stamps `.assistant` on rules the assistant proposes; nil is the person.
    public var createdBy: RuleAuthor?
    public init(match: RuleMatch, categoryID: String, applyToExisting: Bool, createdBy: RuleAuthor? = nil) {
        self.match = match; self.categoryID = categoryID; self.applyToExisting = applyToExisting; self.createdBy = createdBy
    }
}

/// Changes a rule. Each field given replaces what the rule has (`match` as a whole).
public struct UpdateBudgetRule: Hashable, Sendable, Codable {
    public var ruleID: String
    public var match: RuleMatch?
    public var categoryID: String?
    public var isEnabled: Bool?
    /// Also re-file the existing rows the changed rule matches.
    public var applyToExisting: Bool?
    public init(ruleID: String, match: RuleMatch? = nil, categoryID: String? = nil, isEnabled: Bool? = nil, applyToExisting: Bool? = nil) {
        self.ruleID = ruleID; self.match = match; self.categoryID = categoryID; self.isEnabled = isEnabled; self.applyToExisting = applyToExisting
    }
}

/// Removes a rule. The rows it filed keep their category.
public struct DeleteBudgetRule: Hashable, Sendable, Codable {
    public var ruleID: String
    public init(ruleID: String) { self.ruleID = ruleID }
}

/// Makes merchant memory forget a descriptor: new rows with it are decided afresh (by rules, the model or the
/// person), until the person files one of its rows themselves. Past rows keep their category.
public struct ForgetMerchant: Hashable, Sendable, Codable {
    /// `RememberedMerchant.descriptor` (a raw bank descriptor works too; it's normalized the same way).
    public var descriptor: String
    public init(descriptor: String) { self.descriptor = descriptor }
}

/// The person's say on one merchant's recurring charges, from the recurring list or a transaction's details. Not a
/// tool the assistant can call.
public struct SetRecurring: Hashable, Sendable, Codable {
    /// The merchant as shown.
    public var merchant: String
    /// False: not recurring — off the recurring list, never expected, never a yearly charge. True: recurring, on
    /// `cadence` (nil keeps the cadence Budget found) and as `kind`. Nil: back to what Budget finds.
    public var isRecurring: Bool?
    public var cadence: Subscription.Cadence?
    public var kind: Subscription.Kind?
    /// With a cadence: the size of the charge that recurs (`RecurringChoice.amount`). Nil keeps the one it has, or
    /// uses the latest charge.
    public var amount: DecimalAmount?
    /// An undo: sets the choice exactly as given — a field left out is cleared — with no checks.
    public var restores: Bool?

    public init(merchant: String, isRecurring: Bool?, cadence: Subscription.Cadence? = nil, kind: Subscription.Kind? = nil,
                amount: DecimalAmount? = nil, restores: Bool? = nil) {
        self.merchant = merchant; self.isRecurring = isRecurring; self.cadence = cadence; self.kind = kind
        self.amount = amount; self.restores = restores
    }
}

public struct Recategorize: Hashable, Sendable, Codable {
    public var transactionIDs: [String]
    public var categoryID: String
    public init(transactionIDs: [String], categoryID: String) { self.transactionIDs = transactionIDs; self.categoryID = categoryID }
}

/// Changes to specific rows, each field optional: file them (or keep what they're filed as), hide them from
/// totals or count them again, add a note, rename the merchant, tag them. Everything given applies to every row.
public struct EditTransactions: Hashable, Sendable, Codable {
    public var transactionIDs: [String]
    /// File under this category, as the person's choice.
    public var categoryID: String?
    /// Keep the category each row already has (the best guess), as the person's choice.
    public var acceptGuess: Bool?
    /// True leaves the rows out of every spending, income and budget total (balances keep them) and takes them
    /// out of review; false counts them again.
    public var isHidden: Bool?
    /// A note; an empty one removes it.
    public var note: String?
    /// A new merchant name for these rows.
    public var merchant: String?
    /// With `merchant`: also rename every row sharing these rows' bank descriptor, and new ones as they arrive.
    /// A generic descriptor ("Withdrawal") names no merchant, so those rows are renamed one by one.
    public var renameSimilar: Bool?
    /// True: spread over the year — the budget counts a twelfth a month for twelve months instead of all of it in
    /// its month (it keeps its category). False: not yearly, even where Budget took it for one.
    public var isYearly: Bool?
    /// Tags to put on every row (one already there is kept). Server 0.5.0.
    public var addTags: [String]?
    /// Tags to take off every row that has them. Server 0.5.0.
    public var removeTags: [String]?
    /// With `categoryID`: also file every other row like these — the same merchant or the same bank descriptor, money
    /// going the same way (and a purchase's refunds, when it goes to a spending category) — under it. Rows the person
    /// filed themselves keep their category, a matched transfer stays one unless it's being filed as a transfer, and a
    /// generic descriptor ("Withdrawal") or a payment app's name ("Venmo") reaches nothing on its own. Server 0.5.0.
    public var fileSimilar: Bool?

    public init(transactionIDs: [String], categoryID: String? = nil, acceptGuess: Bool? = nil, isHidden: Bool? = nil,
                note: String? = nil, merchant: String? = nil, renameSimilar: Bool? = nil, isYearly: Bool? = nil,
                addTags: [String]? = nil, removeTags: [String]? = nil, fileSimilar: Bool? = nil) {
        self.transactionIDs = transactionIDs; self.categoryID = categoryID; self.acceptGuess = acceptGuess; self.isHidden = isHidden
        self.note = note; self.merchant = merchant; self.renameSimilar = renameSimilar; self.isYearly = isYearly
        self.addTags = addTags; self.removeTags = removeTags; self.fileSimilar = fileSimilar
    }
}

/// Puts rows back exactly as they were before a re-file or an edit: the `ActionResult.undo` the ledger
/// returns. Built by the server from the rows it changed; not a tool the assistant can call.
public struct RestoreTransactions: Hashable, Sendable, Codable {
    public struct Row: Hashable, Sendable, Codable {
        public var transactionID: String
        public var merchant: String
        public var originalMerchant: String?
        public var categorization: Categorization?
        public var suggestions: [CategorySuggestion]?
        public var isHidden: Bool
        public var note: String?
        public var transferPeerID: String?
        public var isYearly: Bool?
        /// The row's tags, empty for none. Nil in an undo made before tags existed: the row keeps the tags it has.
        public var tags: [String]?

        public init(_ row: LedgerTransaction, suggestions: [CategorySuggestion]?) {
            transactionID = row.id; merchant = row.merchant; originalMerchant = row.originalMerchant; categorization = row.categorization
            self.suggestions = suggestions; isHidden = row.isHidden; note = row.note; transferPeerID = row.transferPeerID
            isYearly = row.isYearly; tags = row.tags ?? []
        }
    }

    /// A descriptor's merchant name to put back; nil removes the name.
    public struct Alias: Hashable, Sendable, Codable {
        public var descriptor: String
        public var merchant: String?
        public init(descriptor: String, merchant: String?) { self.descriptor = descriptor; self.merchant = merchant }
    }

    /// A merchant cap to put back (a rename moves caps with it), applied in order; nil removes the cap.
    public struct Cap: Hashable, Sendable, Codable {
        public var merchant: String
        public var monthlyAmount: DecimalAmount?
        public init(merchant: String, monthlyAmount: DecimalAmount?) { self.merchant = merchant; self.monthlyAmount = monthlyAmount }
    }

    /// A merchant's recurring choice to put back (nil removes it), keyed by `RecurringChoice.key`.
    public struct Recurring: Hashable, Sendable, Codable {
        public var key: String
        public var choice: RecurringChoice?
        public init(key: String, choice: RecurringChoice?) { self.key = key; self.choice = choice }
    }

    public var rows: [Row]
    public var aliases: [Alias]?
    public var caps: [Cap]?
    public var recurring: [Recurring]?
    /// Descriptors merchant memory had been told to forget when the change was made (filing one of their rows
    /// remembers it again); undoing the change forgets them again.
    public var forgotten: [String]?

    public init(rows: [Row], aliases: [Alias]? = nil, caps: [Cap]? = nil, forgotten: [String]? = nil, recurring: [Recurring]? = nil) {
        self.rows = rows; self.aliases = aliases; self.caps = caps; self.forgotten = forgotten; self.recurring = recurring
    }
}

public enum AppScreen: String, Hashable, Sendable, Codable, CaseIterable {
    case home, spending, ask, plan, activity, settings
    /// Recurring charges: subscriptions and bills.
    case recurring
}

/// Client-only: moves the app to a screen. Never reaches the server.
public struct Navigate: Hashable, Sendable, Codable {
    public var screen: AppScreen
    public var categoryID: String?
    public var range: SpendingRange?
    public var search: String?
    public var horizonMonths: Int?
    /// A budget month for Spending, like "2026-09".
    public var month: String?
    public init(screen: AppScreen, categoryID: String? = nil, range: SpendingRange? = nil, search: String? = nil, horizonMonths: Int? = nil,
                month: String? = nil) {
        self.screen = screen; self.categoryID = categoryID; self.range = range; self.search = search; self.horizonMonths = horizonMonths
        self.month = month
    }
}

// MARK: - AppAction

/// Every change the app can make. The UI, the assistant, and the server all speak this type.
/// On the wire: `{"type": "<toolName>", ...payload}`.
public enum AppAction: Hashable, Sendable {
    case setCategoryTarget(SetCategoryTarget)
    case adjustCategoryTarget(AdjustCategoryTarget)
    case removeCategoryTarget(RemoveCategoryTarget)
    case setMerchantTarget(SetMerchantTarget)
    case setMonthlySavings(SetMonthlySavings)
    case removeMerchantTarget(RemoveMerchantTarget)
    case createCategory(CreateCategory)
    case updateCategory(UpdateCategory)
    case mergeCategory(MergeCategory)
    case createBudgetRule(CreateBudgetRule)
    case updateBudgetRule(UpdateBudgetRule)
    case deleteBudgetRule(DeleteBudgetRule)
    case recategorize(Recategorize)
    case editTransactions(EditTransactions)
    /// An undo. The server builds it; the assistant never proposes it.
    case restoreTransactions(RestoreTransactions)
    case updateDecisionPolicy(UpdateDecisionPolicy)
    /// From the memory viewer; not a tool the assistant can call.
    case forgetMerchant(ForgetMerchant)
    /// From the recurring list and a transaction's details; not a tool the assistant can call.
    case setRecurring(SetRecurring)
    /// Keeps a fact in assistant memory (server 0.5.0).
    case rememberFact(RememberFact)
    case navigate(Navigate)

    public var toolName: String {
        switch self {
        case .setCategoryTarget: "setCategoryTarget"
        case .adjustCategoryTarget: "adjustCategoryTarget"
        case .removeCategoryTarget: "removeCategoryTarget"
        case .setMerchantTarget: "setMerchantTarget"
        case .setMonthlySavings: "setMonthlySavings"
        case .removeMerchantTarget: "removeMerchantTarget"
        case .createCategory: "createCategory"
        case .updateCategory: "updateCategory"
        case .mergeCategory: "mergeCategory"
        case .createBudgetRule: "createBudgetRule"
        case .updateBudgetRule: "updateBudgetRule"
        case .deleteBudgetRule: "deleteBudgetRule"
        case .recategorize: "recategorize"
        case .editTransactions: "editTransactions"
        case .restoreTransactions: "restoreTransactions"
        case .updateDecisionPolicy: "updateDecisionPolicy"
        case .forgetMerchant: "forgetMerchant"
        case .setRecurring: "setRecurring"
        case .rememberFact: "rememberFact"
        case .navigate: "navigate"
        }
    }

    /// Handled on the device; `BudgetAPI.perform` rejects these.
    public var isClientOnly: Bool {
        if case .navigate = self { return true }
        return false
    }

    /// The action as the assistant proposes it: a rule it suggests is credited to it.
    func proposedByAssistant() -> AppAction {
        guard case var .createBudgetRule(p) = self else { return self }
        p.createdBy = .assistant
        return .createBudgetRule(p)
    }

    /// Decodes a model's tool call, validating arguments against the tool's schema first.
    /// - Parameter categoryIDs: When given, `categoryID` fields must be one of these.
    public init(toolName: String, arguments: Data, categoryIDs: [String]? = nil) throws {
        _ = try ToolCatalog.validateArguments(tool: toolName, json: arguments, categoryIDs: categoryIDs)
        let d = JSONDecoder()
        switch toolName {
        case "setCategoryTarget": self = .setCategoryTarget(try d.decode(SetCategoryTarget.self, from: arguments))
        case "adjustCategoryTarget": self = .adjustCategoryTarget(try d.decode(AdjustCategoryTarget.self, from: arguments))
        case "removeCategoryTarget": self = .removeCategoryTarget(try d.decode(RemoveCategoryTarget.self, from: arguments))
        case "setMerchantTarget": self = .setMerchantTarget(try d.decode(SetMerchantTarget.self, from: arguments))
        case "setMonthlySavings": self = .setMonthlySavings(try d.decode(SetMonthlySavings.self, from: arguments))
        case "removeMerchantTarget": self = .removeMerchantTarget(try d.decode(RemoveMerchantTarget.self, from: arguments))
        case "createCategory": self = .createCategory(try d.decode(CreateCategory.self, from: arguments))
        case "updateCategory": self = .updateCategory(try d.decode(UpdateCategory.self, from: arguments))
        case "mergeCategory": self = .mergeCategory(try d.decode(MergeCategory.self, from: arguments))
        case "createBudgetRule": self = .createBudgetRule(try d.decode(CreateBudgetRule.self, from: arguments))
        case "updateBudgetRule": self = .updateBudgetRule(try d.decode(UpdateBudgetRule.self, from: arguments))
        case "deleteBudgetRule": self = .deleteBudgetRule(try d.decode(DeleteBudgetRule.self, from: arguments))
        case "recategorize": self = .recategorize(try d.decode(Recategorize.self, from: arguments))
        case "editTransactions": self = .editTransactions(try d.decode(EditTransactions.self, from: arguments))
        case "updateDecisionPolicy": self = .updateDecisionPolicy(try d.decode(UpdateDecisionPolicy.self, from: arguments))
        case "rememberFact": self = .rememberFact(try d.decode(RememberFact.self, from: arguments))
        case "navigate": self = .navigate(try d.decode(Navigate.self, from: arguments))
        default: throw ToolArgumentError(tool: toolName, problems: ["\(toolName) is not a write or client tool"])
        }
    }

    /// The tool-call arguments for this action (payload without the `type` discriminator).
    public func argumentsJSON() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        switch self {
        case let .setCategoryTarget(p): return try e.encode(p)
        case let .adjustCategoryTarget(p): return try e.encode(p)
        case let .removeCategoryTarget(p): return try e.encode(p)
        case let .setMerchantTarget(p): return try e.encode(p)
        case let .setMonthlySavings(p): return try e.encode(p)
        case let .removeMerchantTarget(p): return try e.encode(p)
        case let .createCategory(p): return try e.encode(p)
        case let .updateCategory(p): return try e.encode(p)
        case let .mergeCategory(p): return try e.encode(p)
        case let .createBudgetRule(p): return try e.encode(p)
        case let .updateBudgetRule(p): return try e.encode(p)
        case let .deleteBudgetRule(p): return try e.encode(p)
        case let .recategorize(p): return try e.encode(p)
        case let .editTransactions(p): return try e.encode(p)
        case let .restoreTransactions(p): return try e.encode(p)
        case let .updateDecisionPolicy(p): return try e.encode(p)
        case let .forgetMerchant(p): return try e.encode(p)
        case let .setRecurring(p): return try e.encode(p)
        case let .rememberFact(p): return try e.encode(p)
        case let .navigate(p): return try e.encode(p)
        }
    }
}

extension AppAction: Codable {
    private enum Keys: String, CodingKey { case type }

    public init(from decoder: any Decoder) throws {
        let type = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .type)
        switch type {
        case "setCategoryTarget": self = .setCategoryTarget(try SetCategoryTarget(from: decoder))
        case "adjustCategoryTarget": self = .adjustCategoryTarget(try AdjustCategoryTarget(from: decoder))
        case "removeCategoryTarget": self = .removeCategoryTarget(try RemoveCategoryTarget(from: decoder))
        case "setMerchantTarget": self = .setMerchantTarget(try SetMerchantTarget(from: decoder))
        case "setMonthlySavings": self = .setMonthlySavings(try SetMonthlySavings(from: decoder))
        case "removeMerchantTarget": self = .removeMerchantTarget(try RemoveMerchantTarget(from: decoder))
        case "createCategory": self = .createCategory(try CreateCategory(from: decoder))
        case "updateCategory": self = .updateCategory(try UpdateCategory(from: decoder))
        case "mergeCategory": self = .mergeCategory(try MergeCategory(from: decoder))
        case "createBudgetRule": self = .createBudgetRule(try CreateBudgetRule(from: decoder))
        case "updateBudgetRule": self = .updateBudgetRule(try UpdateBudgetRule(from: decoder))
        case "deleteBudgetRule": self = .deleteBudgetRule(try DeleteBudgetRule(from: decoder))
        case "recategorize": self = .recategorize(try Recategorize(from: decoder))
        case "editTransactions": self = .editTransactions(try EditTransactions(from: decoder))
        case "restoreTransactions": self = .restoreTransactions(try RestoreTransactions(from: decoder))
        case "updateDecisionPolicy": self = .updateDecisionPolicy(try UpdateDecisionPolicy(from: decoder))
        case "forgetMerchant": self = .forgetMerchant(try ForgetMerchant(from: decoder))
        case "setRecurring": self = .setRecurring(try SetRecurring(from: decoder))
        case "rememberFact": self = .rememberFact(try RememberFact(from: decoder))
        case "navigate": self = .navigate(try Navigate(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: try decoder.container(keyedBy: Keys.self), debugDescription: "Unknown action \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(toolName, forKey: .type)
        switch self {
        case let .setCategoryTarget(p): try p.encode(to: encoder)
        case let .adjustCategoryTarget(p): try p.encode(to: encoder)
        case let .removeCategoryTarget(p): try p.encode(to: encoder)
        case let .setMerchantTarget(p): try p.encode(to: encoder)
        case let .setMonthlySavings(p): try p.encode(to: encoder)
        case let .removeMerchantTarget(p): try p.encode(to: encoder)
        case let .createCategory(p): try p.encode(to: encoder)
        case let .updateCategory(p): try p.encode(to: encoder)
        case let .mergeCategory(p): try p.encode(to: encoder)
        case let .createBudgetRule(p): try p.encode(to: encoder)
        case let .updateBudgetRule(p): try p.encode(to: encoder)
        case let .deleteBudgetRule(p): try p.encode(to: encoder)
        case let .recategorize(p): try p.encode(to: encoder)
        case let .editTransactions(p): try p.encode(to: encoder)
        case let .restoreTransactions(p): try p.encode(to: encoder)
        case let .updateDecisionPolicy(p): try p.encode(to: encoder)
        case let .forgetMerchant(p): try p.encode(to: encoder)
        case let .setRecurring(p): try p.encode(to: encoder)
        case let .rememberFact(p): try p.encode(to: encoder)
        case let .navigate(p): try p.encode(to: encoder)
        }
    }
}

/// A change the assistant wants to make. Nothing happens until the person applies it.
public struct ProposedAction: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var action: AppAction
    /// "Set Dining target to $500 a month"
    public var title: String
    public var detail: String?
    /// Before/after figures computed by the ledger for the preview.
    public var effects: [Figure]

    public init(id: String, action: AppAction, title: String, detail: String? = nil, effects: [Figure] = []) {
        self.id = id; self.action = action; self.title = title; self.detail = detail; self.effects = effects
    }
}

public struct ActionResult: Hashable, Sendable, Codable {
    public var message: String
    public var affectedTransactions: Int
    /// Reverses this change (re-filing, confirming and editing rows), for an Undo button: send it to `perform`.
    public var undo: AppAction?

    public init(message: String, affectedTransactions: Int = 0, undo: AppAction? = nil) {
        self.message = message; self.affectedTransactions = affectedTransactions; self.undo = undo
    }
}

/// What an action would do, worked out by the ledger without changing anything — the same preview a proposal
/// card shows, plus the rows it reaches, so an editor can show a live "41 match · 3 move".
public struct ActionPreview: Hashable, Sendable, Codable {
    public var title: String
    public var detail: String?
    /// Before/after figures.
    public var effects: [Figure]
    /// Some of the rows it reaches, newest first (at most `sampleSize`).
    public var sample: [LedgerTransaction]
    /// How many rows it reaches: a rule's matches, the rows re-filed or edited, a merged category's rows.
    /// Nil for actions that don't touch rows.
    public var matchCount: Int?
    /// Of those, the rows whose category would change (for a rule: if it re-filed what it matches).
    public var changeCount: Int?
    /// For a rule being made or changed: the rules that would disagree with it (ids, as `rules()` lists them).
    public var conflicts: [String]

    public static let sampleSize = 8

    public init(title: String, detail: String? = nil, effects: [Figure] = [], sample: [LedgerTransaction] = [],
                matchCount: Int? = nil, changeCount: Int? = nil, conflicts: [String] = []) {
        self.title = title; self.detail = detail; self.effects = effects; self.sample = sample
        self.matchCount = matchCount; self.changeCount = changeCount; self.conflicts = conflicts
    }
}

/// What the chat model is told and what it can call — exposed so the person can inspect it.
public struct AssistantConfig: Hashable, Sendable, Codable {
    public var promptVersion: String
    public var systemPrompt: String
    public var tools: [ToolDefinition]
}
