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

/// Positions in investment accounts from Plaid Investments: once a day per Item, on a HOLDINGS webhook, or when a caller
/// says the person asked after a failure (one link's sync or a reconnect, `SyncService.syncPlaid`) — never on every sync.
/// Best effort, like card bills: it never fails anything. It only reads: it never removes, replaces or re-links an Item,
/// and never starts Link.
enum HoldingsSync {
    /// The least time between two checks of one Item. Plaid refreshes holdings about daily, mostly overnight, and the
    /// daily Item check that asks comes every 24 h give or take an hour, so this sits below that: a check that comes an
    /// hour early still asks, rather than waiting for the next one, two days on.
    static let interval: TimeInterval = 20 * 3600

    /// Whether to ask Plaid about an Item now: the first time; when a webhook said there's news (now, or marked on the
    /// last check); when the person asks again after Plaid wasn't ready, wanted consent or failed; otherwise once a day.
    static func isDue(_ last: HoldingsCheck?, now: Date, requestedByPerson: Bool, webhookDue: Bool) -> Bool {
        guard let last else { return true }
        if webhookDue || last.due == true { return true }
        if requestedByPerson, [.notReady, .needsConsent, .failed].contains(last.access) { return true }
        return now.timeIntervalSince(last.checkedAt) >= interval
    }

    /// The check after this one. This signature is the contract between the Item check and webhooks (which call it)
    /// and holdings (which fill it in). Unchanged when it's off or not due; `noInvestmentAccounts` without asking when
    /// the ledger holds no investment account from this Item's bank; otherwise Plaid's answer — positions stored in the
    /// ledger, or why not. Never throws, and never logs a token or a position.
    static func refresh(enabled: Bool, source: PlaidSource, previous: HoldingsCheck?, requestedByPerson: Bool, webhookDue: Bool,
                        api: LedgerBudgetAPI, now: Date, institution: String, logger: Logger) async -> HoldingsCheck? {
        guard enabled else { return previous }
        guard await api.investmentAccountCount(source: .plaid, institution: source.institution) > 0 else {
            return previous?.access == .noInvestmentAccounts && previous?.due != true
                ? previous : HoldingsCheck(access: .noInvestmentAccounts, checkedAt: now)
        }
        // "No investment accounts" said here, without asking Plaid (no request id), before the ledger held any: the
        // first check came before the first sync, or the person has since marked an account as an investment. This is
        // the first real check, so it's due now. Plaid's own NO_INVESTMENT_ACCOUNTS waits like any other answer.
        let last = previous?.access == .noInvestmentAccounts && previous?.requestID == nil ? nil : previous
        guard isDue(last, now: now, requestedByPerson: requestedByPerson, webhookDue: webhookDue) else { return previous }
        do {
            let (positions, requestID) = try await source.holdingsReport()
            let stored = try await api.applyHoldings(positions, source: .plaid, at: now)
            logger.info("holdings for \(institution): \(stored) account\(stored == 1 ? "" : "s") (request_id \(requestID ?? "none"))")
            return HoldingsCheck(access: .ok, checkedAt: now, accounts: stored, requestID: requestID)
        } catch let error as PlaidAPIError {
            let access = HoldingsAccess.from(errorCode: error.errorCode)
            logger.notice("holdings not available for \(institution): \(error.errorType ?? "?")/\(error.errorCode ?? "?") (request_id \(error.requestID ?? "none"))")
            return HoldingsCheck(access: access, checkedAt: now, requestID: error.requestID, message: access == .failed ? error.errorMessage : nil)
        } catch {
            // The log names only the kind of failure: a provider's error page can echo what it was sent. The check keeps
            // the full text for the dashboard.
            logger.warning("holdings check failed for \(institution): \(Self.kind(of: error))")
            return HoldingsCheck(access: .failed, checkedAt: now, message: SyncService.describe(error))
        }
    }

    /// A failure as a log may name it: an HTTP status, or the error's type. Never a response body.
    static func kind(of error: any Error) -> String {
        if let e = error as? SourceHTTPError { return "HTTP \(e.status)" }
        return String(describing: type(of: error))
    }
}
