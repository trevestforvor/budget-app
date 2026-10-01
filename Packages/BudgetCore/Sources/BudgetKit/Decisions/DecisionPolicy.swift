import Foundation

public enum DecisionProvider: String, Hashable, Sendable, Codable, CaseIterable {
    case off
    /// Qwen3.8-27B Decide on the llama.cpp fork's /v1/decision, on the Olares.
    case localDecide
    /// Laya on the Olares, /v1/systemone. Weak past ~20 options (see decision-bench).
    case laya
    /// Jev 1.13 via OpenRouter or TypeSafe. Cloud: descriptors leave the Olares.
    case jev

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .localDecide: "Qwen Decide · on your Olares"
        case .laya: "Laya · on your Olares"
        case .jev: "Jev · TypeSafe"
        }
    }

    public var runsLocally: Bool { self != .jev }
}

/// Which decisions the model may make. Anything with enumerable options qualifies;
/// subscriptions and transfers are categories, so `category` covers them.
public enum DecisionKind: String, Hashable, Sendable, Codable, CaseIterable {
    case category

    public var displayName: String {
        switch self {
        case .category: "Categories (incl. subscriptions and transfers)"
        }
    }
}

/// How the decision model is used. Stored on the server; changed only via `updateDecisionPolicy`.
public struct DecisionPolicy: Hashable, Sendable, Codable {
    public var provider: DecisionProvider
    /// Decisions at or above this percent are accepted automatically. 50...99.
    public var autoAcceptPercent: Int
    public var kinds: [DecisionKind]
    /// With a local provider: re-ask Jev about anything below the threshold, and accept
    /// Jev's answer if it clears the threshold.
    public var escalateToJev: Bool
    /// Send every merchant the model hasn't seen before to review, however sure it is. (The model is only
    /// asked about descriptors with no memory, so this covers everything it would file on its own.)
    public var reviewNewMerchants: Bool
    /// Leave pending charges out of the review queue until they post.
    public var holdPending: Bool
    /// Send anything bigger than this to review when the model or merchant memory would file it. Rules, matched
    /// transfers and your own answers still file on their own. Nil is off.
    public var reviewAbove: DecimalAmount?

    public init(provider: DecisionProvider, autoAcceptPercent: Int, kinds: [DecisionKind], escalateToJev: Bool = false,
                reviewNewMerchants: Bool = false, holdPending: Bool = false, reviewAbove: DecimalAmount? = nil) {
        self.provider = provider
        self.autoAcceptPercent = autoAcceptPercent
        self.kinds = kinds
        self.escalateToJev = escalateToJev
        self.reviewNewMerchants = reviewNewMerchants
        self.holdPending = holdPending
        self.reviewAbove = reviewAbove
    }

    enum CodingKeys: String, CodingKey { case provider, autoAcceptPercent, kinds, escalateToJev, reviewNewMerchants, holdPending, reviewAbove }

    /// Policies saved before the review toggles decode with them off.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decode(DecisionProvider.self, forKey: .provider)
        autoAcceptPercent = try c.decode(Int.self, forKey: .autoAcceptPercent)
        kinds = try c.decode([DecisionKind].self, forKey: .kinds)
        escalateToJev = try c.decodeIfPresent(Bool.self, forKey: .escalateToJev) ?? false
        reviewNewMerchants = try c.decodeIfPresent(Bool.self, forKey: .reviewNewMerchants) ?? false
        holdPending = try c.decodeIfPresent(Bool.self, forKey: .holdPending) ?? false
        reviewAbove = try c.decodeIfPresent(DecimalAmount.self, forKey: .reviewAbove)
    }

    public static let `default` = DecisionPolicy(provider: .off, autoAcceptPercent: 80, kinds: [.category])

    /// Whether Jev sees anything under this policy.
    public var usesJev: Bool { isActive && (provider == .jev || (provider.runsLocally && escalateToJev)) }
    public static let allowedPercents = 50...99

    public var isActive: Bool { provider != .off && !kinds.isEmpty }
    public var threshold: Double { Double(autoAcceptPercent) / 100 }

    /// Why a row the model (for a new merchant) or merchant memory would file on its own comes to the person
    /// instead, when the review toggles say so; nil when it may be filed.
    public func reviewReason(for row: LedgerTransaction, newMerchant: Bool) -> String? {
        if newMerchant, reviewNewMerchants { return "New merchant. You asked to check new merchants before they're filed." }
        if let reviewAbove, row.amount.magnitude.minorUnits > reviewAbove.minorUnits {
            return "More than \(reviewAbove.money(row.amount.currencyCode).formatted(fractionDigits: 0)). You asked to check big amounts before they're filed."
        }
        return nil
    }
}

/// Partial update. Tool: `updateDecisionPolicy`.
public struct UpdateDecisionPolicy: Hashable, Sendable, Codable {
    public var provider: DecisionProvider?
    public var autoAcceptPercent: Int?
    public var escalateToJev: Bool?
    /// Re-run the decision model on everything waiting for review (default true).
    public var rerunPending: Bool?
    public var reviewNewMerchants: Bool?
    public var holdPending: Bool?
    /// A new review-above amount; "0" turns it off.
    public var reviewAbove: DecimalAmount?

    public init(provider: DecisionProvider? = nil, autoAcceptPercent: Int? = nil, escalateToJev: Bool? = nil, rerunPending: Bool? = nil,
                reviewNewMerchants: Bool? = nil, holdPending: Bool? = nil, reviewAbove: DecimalAmount? = nil) {
        self.provider = provider
        self.autoAcceptPercent = autoAcceptPercent
        self.escalateToJev = escalateToJev
        self.rerunPending = rerunPending
        self.reviewNewMerchants = reviewNewMerchants
        self.holdPending = holdPending
        self.reviewAbove = reviewAbove
    }

    /// Whether this changes anything at all (re-running the queue counts).
    var isEmpty: Bool {
        provider == nil && autoAcceptPercent == nil && escalateToJev == nil && rerunPending == nil
            && reviewNewMerchants == nil && holdPending == nil && reviewAbove == nil
    }

    /// Whether this changes the model or how sure it must be (not just the review toggles).
    var changesModel: Bool { provider != nil || autoAcceptPercent != nil || escalateToJev != nil }

    /// Whether the model re-decides the review queue afterwards: when asked, else when the model changed.
    var reruns: Bool { rerunPending ?? changesModel }

    public func applied(to policy: DecisionPolicy) -> DecisionPolicy {
        var next = policy
        if let provider { next.provider = provider }
        if let autoAcceptPercent { next.autoAcceptPercent = autoAcceptPercent }
        if let escalateToJev { next.escalateToJev = escalateToJev }
        if let reviewNewMerchants { next.reviewNewMerchants = reviewNewMerchants }
        if let holdPending { next.holdPending = holdPending }
        if let reviewAbove { next.reviewAbove = reviewAbove.minorUnits > 0 ? reviewAbove : nil }
        return next
    }
}

/// Normalizes bank descriptors: "SQ *CASA TACO 0423" → "CASA TACO".
public enum Descriptor {
    public static func normalize(_ raw: String) -> String {
        var s = raw.uppercased()
        for prefix in ["SQ *", "TST* ", "DD *", "PAYPAL *", "CHECKCARD "] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
        }
        return s.split(separator: " ").filter { !$0.contains(where: \.isNumber) }.joined(separator: " ")
    }

    /// Descriptors that name no merchant ("Deposit", "Withdrawal" — all some brokerages' Quicken exports
    /// give). Nothing is remembered from them: one answer can't be right for every such row.
    public static func isGeneric(_ raw: String) -> Bool {
        ["", "TRANSACTION", "DEPOSIT", "WITHDRAWAL", "TRANSFER", "DEBIT", "CREDIT", "PAYMENT", "INTEREST", "CHECK", "ATM", "OTHER", "FEE", "DIVIDEND"]
            .contains(normalize(raw).trimmingCharacters(in: .whitespaces))
    }
}

/// Category decisions: what's sent to the decision model and how its answer is used.
public enum CategoryDecisions {
    public static let questionID = "category"

    public enum Outcome: Hashable, Sendable {
        case accept(categoryID: String, confidence: Double)
        case review(suggestions: [CategorySuggestion])
    }

    /// The state sent to the model — deliberately minimal, because a cloud provider sees it:
    /// processor-stripped descriptor, merchant name, direction and a coarse amount band.
    /// No account, date, exact amount, or transaction id.
    public static func request(for row: LedgerTransaction, categories: [BudgetCategory], accountKind: AccountKind? = nil) -> DecisionRequest {
        request(merchant: row.merchant, rawDescription: row.rawDescription, amount: row.amount, categories: categories,
                bankCategory: row.providerCategory, accountKind: accountKind)
    }

    /// Same as `request(for:)` from raw provider fields — for sync jobs and evals.
    /// `bankCategory` is the provider's own label (Plaid personal_finance_category, Teller details.category):
    /// a strong hint, not ground truth. It's a category name, so it's safe to send to Jev too.
    public static func request(merchant: String, rawDescription: String, amount: Money, categories: [BudgetCategory],
                               bankCategory: String? = nil, accountKind: AccountKind? = nil) -> DecisionRequest {
        let descriptor = redacted(Descriptor.normalize(rawDescription))
        let isPeerToPeer = peerToPeer.contains { descriptor.hasPrefix($0) }
        var fields: [String: JSONValue] = [
            // For person-to-person payments the "merchant" is a person; send the service instead.
            "merchant": .string(isPeerToPeer ? descriptor.capitalized : merchant),
            "descriptor": .string(descriptor),
            "direction": .string(amount.isNegative ? "money out" : "money in"),
            "amountBand": .string(amountBand(amount)),
        ]
        if let hint = processorHint(rawDescription) { fields["processor"] = .string(hint) }
        if let bank = bankCategory.map(readableBankCategory), !bank.isEmpty { fields["bankCategory"] = .string(bank) }
        if let accountKind { fields["account"] = .string(accountKind == .credit ? "credit card" : accountKind.rawValue) }
        let state: JSONValue = .object(fields)
        let options = categories.map { c in (id: c.id, description: hint(for: c)) }
        return DecisionRequest(
            state: (try? String(decoding: state.data(), as: UTF8.self)) ?? merchant,
            questions: [questionID: .choice(instructions: "Which category does this bank transaction belong to?", options: options)],
            instructions: "You categorize personal bank transactions. Answer using only the evidence given. When bankCategory is present it is the bank's own label for the transaction: usually right, sometimes too broad. Money in on a credit card that isn't a payment is a refund or statement credit: choose the category it refunds, not Income.")
    }

    /// "RENT_AND_UTILITIES_INTERNET_AND_CABLE" → "rent and utilities: internet and cable".
    static func readableBankCategory(_ raw: String) -> String {
        let primaries = ["RENT_AND_UTILITIES", "FOOD_AND_DRINK", "GENERAL_MERCHANDISE", "GENERAL_SERVICES", "LOAN_PAYMENTS", "BANK_FEES",
                         "HOME_IMPROVEMENT", "PERSONAL_CARE", "TRANSFER_IN", "TRANSFER_OUT", "GOVERNMENT_AND_NON_PROFIT",
                         "ENTERTAINMENT", "TRANSPORTATION", "TRAVEL", "MEDICAL", "INCOME"]
        let upper = raw.uppercased()
        func words(_ s: Substring) -> String { s.replacingOccurrences(of: "_", with: " ").lowercased() }
        if let primary = primaries.first(where: { upper.hasPrefix($0 + "_") }) {
            return words(Substring(primary)) + ": " + words(upper.dropFirst(primary.count + 1))
        }
        return words(Substring(upper))
    }

    static let peerToPeer = ["VENMO", "ZELLE", "CASH APP", "SQC"]

    /// Normalization strips processor prefixes, but the processor is often the best clue:
    /// Toast means a restaurant, PayPal means the real merchant is hidden.
    public static func processorHint(_ raw: String) -> String? {
        let s = raw.uppercased()
        let hints: [(prefix: String, hint: String)] = [
            ("TST*", "Toast — restaurant point of sale"), ("SQ *", "Square — small-business point of sale"),
            ("DD *", "DoorDash — food delivery"), ("PAYPAL *", "PayPal — the real merchant isn't shown"),
            ("AMZN MKTP", "Amazon Marketplace — mixed goods"), ("APPLE.COM/BILL", "Apple — App Store or subscription billing"),
            ("VENMO", "Venmo — person-to-person payment"), ("ZELLE", "Zelle — person-to-person payment"),
            ("CHECKCARD", "debit card purchase"),
        ]
        return hints.first { s.hasPrefix($0.prefix) }?.hint
    }

    /// Strips people from descriptors (Jev's own guidance: send less, strip names, emails and
    /// account numbers). Digit runs are already gone after `Descriptor.normalize`.
    ///   "VENMO *J. PARK" → "VENMO", "ZELLE TO JOHN SMITH" → "ZELLE TO", emails → removed.
    public static func redacted(_ descriptor: String) -> String {
        var s = descriptor.replacing(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/, with: "")
        if let star = s.firstIndex(of: "*") {
            let head = s[..<star].trimmingCharacters(in: .whitespaces)
            if peerToPeer.contains(where: head.hasPrefix) { s = head }
        }
        if let m = s.firstMatch(of: /^(ZELLE|VENMO|CASH APP)(\s+(PAYMENT\s+)?(TO|FROM))?/) { s = String(m.0) }
        return s.split(separator: " ").joined(separator: " ")
    }

    static func hint(for category: BudgetCategory) -> String {
        switch category.id {
        case "transfer": "Transfer — money moved between the user's own accounts, payments to a credit card, or paying a person back"
        case "income": "Income — pay, salary, interest earned and other money received. Never a refund or statement credit: those go to the category they refund"
        case "subscriptions": "Subscriptions — recurring charges for software, streaming, media and memberships"
        case "dining": "Dining — restaurants, bars, cafes, food delivery, and dining credits (e.g. a Resy credit)"
        case "entertainment": "Entertainment — movies and theaters (AMC), concerts, shows, events, games, museums; not recurring subscriptions, not restaurants"
        case "fees": "Fees & interest — credit card annual and plan fees (e.g. an Amex Plan It fee), interest charges, bank, ATM, late and foreign transaction fees"
        case "housing": "Housing — rent, mortgage, HOA, renters or home insurance; not card fees"
        case "shopping": "Shopping — retail, online stores, clothing, electronics, household goods"
        default: category.isMoneyIn ? "\(category.name) — money coming in that the user counts like income, never spending" : category.name
        }
    }

    public static func amountBand(_ money: Money) -> String {
        let dollars = money.magnitude.minorUnits / 100
        switch dollars {
        case ..<10: return "under $10"
        case ..<50: return "$10–50"
        case ..<200: return "$50–200"
        case ..<1000: return "$200–1,000"
        default: return "over $1,000"
        }
    }

    /// Accept at or above the threshold; otherwise send to review with the model's ranking.
    public static func outcome(_ answer: DecisionAnswer?, policy: DecisionPolicy, knownCategoryIDs: Set<String>) -> Outcome {
        guard let answer else { return .review(suggestions: []) }
        if let confidence = answer.confidence, confidence >= policy.threshold, knownCategoryIDs.contains(answer.value) {
            return .accept(categoryID: answer.value, confidence: confidence)
        }
        return .review(suggestions: suggestions(answer, knownCategoryIDs: knownCategoryIDs))
    }

    /// The model's top three known categories, best first — what review shows as suggestions.
    static func suggestions(_ answer: DecisionAnswer?, knownCategoryIDs: Set<String>) -> [CategorySuggestion] {
        guard let answer else { return [] }
        return answer.ranked.filter { knownCategoryIDs.contains($0.id) }.prefix(3).map { CategorySuggestion(categoryID: $0.id, confidence: $0.probability) }
    }

    /// Review suggestions for a pick the model would have filed but a review toggle held back: the pick first,
    /// then the rest of the model's ranking.
    static func suggestions(leadingWith pick: CategorySuggestion, _ answer: DecisionAnswer?, knownCategoryIDs: Set<String>) -> [CategorySuggestion] {
        [pick] + suggestions(answer, knownCategoryIDs: knownCategoryIDs).filter { $0.categoryID != pick.categoryID }.prefix(2)
    }
}
