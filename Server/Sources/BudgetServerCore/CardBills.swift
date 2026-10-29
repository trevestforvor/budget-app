import BudgetKit
import Foundation
import Logging

/// The last card-bill check on one Plaid Item (kept on its `StoredLink`): what Plaid said and when. The dashboard shows
/// it per link, and offers "Grant card-bill access" only for `needsConsent` with confirmed product support.
public struct CardBillCheck: Codable, Hashable, Sendable {
    public var access: CardBillAccess
    public var checkedAt: Date
    /// Cards whose statement came back and was stored.
    public var cards: Int?
    /// Plaid's request id, for support. Never a token.
    public var requestID: String?
    /// Why the check could not complete, when the dashboard has no more specific status to show.
    public var message: String?
    /// Consent is offered only after Plaid confirmed product support. Missing on checks saved before that verification.
    public var supportConfirmed: Bool?

    public init(access: CardBillAccess, checkedAt: Date, cards: Int? = nil, requestID: String? = nil, message: String? = nil,
                supportConfirmed: Bool? = nil) {
        self.access = access; self.checkedAt = checkedAt; self.cards = cards; self.requestID = requestID; self.message = message
        self.supportConfirmed = supportConfirmed
    }
}

/// Card bills from Plaid Liabilities, read after a Plaid Item's transactions sync. Plaid bills Liabilities per Item once
/// it's used, so this runs only with the "Card bills" setting on, only for Items with a credit card, and at most once a
/// day per Item (Plaid refreshes about that often). It's best effort: whatever Plaid answers, the transactions sync
/// stands. It only reads: it never removes, replaces or re-links an Item, and never starts Link.
enum CardBillSync {
    /// The least time between two checks of one Item.
    static let interval: TimeInterval = 24 * 3600

    /// Whether to ask Plaid about an Item now. A person asking for that link's sync (after granting access in update
    /// mode, say) asks again at once when it was waiting for consent, Plaid or a failed check; otherwise once a day.
    static func isDue(_ last: CardBillCheck?, now: Date, requestedByPerson: Bool) -> Bool {
        guard let last else { return true }
        // Old consent errors did not establish eligibility. Verify those on the next sync, even within today's window.
        if last.access == .needsConsent, last.supportConfirmed != true { return true }
        if requestedByPerson, [.needsConsent, .notReady, .failed].contains(last.access) { return true }
        return now.timeIntervalSince(last.checkedAt) >= interval
    }

    /// The check after this sync: unchanged when it's off or not due, `noCreditAccounts` without asking when the Item
    /// has no card, otherwise Plaid's answer — card bills stored in the ledger, or why not. Never throws.
    static func refresh(enabled: Bool, source: PlaidSource, snapshot: SourceSnapshot, previous: CardBillCheck?, requestedByPerson: Bool,
                        api: LedgerBudgetAPI, now: Date, institution: String, logger: Logger, institutionID: String? = nil,
                        force: Bool = false) async -> CardBillCheck? {
        guard enabled else { return previous }
        let cards = PlaidSource.cardAccountIDs(snapshot)
        guard !cards.isEmpty else {
            return previous?.access == .noCreditAccounts ? previous : CardBillCheck(access: .noCreditAccounts, checkedAt: now)
        }
        guard force || isDue(previous, now: now, requestedByPerson: requestedByPerson) else { return previous }
        do {
            let (bills, requestID) = try await source.liabilities(accountIDs: cards)
            let stored = try await api.applyCardBills(bills, source: .plaid)
            logger.info("card bills for \(institution): \(stored) card\(stored == 1 ? "" : "s") (request_id \(requestID ?? "none"))")
            return CardBillCheck(access: .ok, checkedAt: now, cards: stored, requestID: requestID)
        } catch let error as PlaidAPIError {
            let access = CardBillAccess.from(errorCode: error.errorCode)
            logger.notice("card bills not available for \(institution): \(error.errorType ?? "?")/\(error.errorCode ?? "?") (request_id \(error.requestID ?? "none"))")
            if access == .needsConsent {
                return await consentCheck(source: source, institutionID: institutionID, previous: previous,
                                          now: now, requestID: error.requestID, logger: logger)
            }
            return CardBillCheck(access: access, checkedAt: now, requestID: error.requestID, message: access == .failed ? error.errorMessage : nil)
        } catch {
            logger.warning("card bills check failed for \(institution): \(SyncService.describe(error))")
            return CardBillCheck(access: .failed, checkedAt: now, message: SyncService.describe(error))
        }
    }

    /// ADDITIONAL_CONSENT_REQUIRED says nothing about whether the bank offers Liabilities. Ask for product metadata
    /// before inviting the person into Link. This read never grants a product or changes the Item's permissions.
    static func consentCheck(source: PlaidSource, institutionID: String?, previous: CardBillCheck?, now: Date,
                             requestID: String? = nil, logger: Logger) async -> CardBillCheck {
        do {
            if let supported = try await source.supportsLiabilities(institutionID: institutionID) {
                return CardBillCheck(access: supported ? .needsConsent : .notSupported, checkedAt: now,
                                     requestID: requestID, supportConfirmed: supported)
            }
        } catch {
            logger.notice("card-bill support check failed: \(SyncService.describe(error))")
        }
        // A missing product list or failed lookup is unknown. It cannot revoke a known denial or offer consent.
        return CardBillCheck(access: previous?.access == .notSupported ? .notSupported : .failed, checkedAt: now,
                             requestID: requestID, message: supportUnavailableMessage)
    }

    static let supportUnavailableMessage = "Couldn't confirm whether this bank offers card bills through Plaid. Try syncing this bank again."
}
