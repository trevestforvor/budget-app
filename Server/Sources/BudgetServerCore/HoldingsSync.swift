import BudgetKit
import Foundation
import Logging

/// The last holdings check on one Plaid Item (kept on its `StoredLink`): what Plaid said and when.
public struct HoldingsCheck: Codable, Hashable, Sendable {
    public var access: HoldingsAccess
    public var checkedAt: Date
    /// Accounts whose positions came back and were stored.
    public var accounts: Int?
    /// Plaid's request id, for support. Never a token.
    public var requestID: String?
    public var message: String?
    /// A webhook said there's news, so the next chance checks again.
    public var due: Bool?

    public init(access: HoldingsAccess, checkedAt: Date, accounts: Int? = nil, requestID: String? = nil, message: String? = nil, due: Bool? = nil) {
        self.access = access; self.checkedAt = checkedAt; self.accounts = accounts; self.requestID = requestID; self.message = message; self.due = due
    }
}

/// What Plaid said about holdings on an Item. Separate from `CardBillAccess`, whose stored raw values can't change.
/// Tolerant: unknown reads as `.failed`.
public enum HoldingsAccess: String, Codable, Hashable, Sendable {
    case ok, needsConsent, notSupported, noInvestmentAccounts, notReady, failed

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .failed
    }

    static func from(errorCode: String?) -> Self {
        switch errorCode {
        case "ADDITIONAL_CONSENT_REQUIRED": .needsConsent
        case "PRODUCTS_NOT_SUPPORTED", "INVALID_PRODUCT": .notSupported
        case "NO_INVESTMENT_ACCOUNTS": .noInvestmentAccounts
        case "PRODUCT_NOT_READY": .notReady
        default: .failed
        }
    }
}

/// Positions in investment accounts from Plaid Investments: once a day per Item, on a HOLDINGS webhook, or when the
/// person asks after a failure — never on every sync. Best effort, like card bills: it never fails anything.
enum HoldingsSync {
    /// The check after this one. This signature is the contract between the Item check and webhooks (which call it)
    /// and holdings (which fill it in); until then it changes nothing.
    static func refresh(enabled: Bool, source: PlaidSource, previous: HoldingsCheck?, requestedByPerson: Bool, webhookDue: Bool,
                        api: LedgerBudgetAPI, now: Date, institution: String, logger: Logger) async -> HoldingsCheck? {
        previous
    }
}
