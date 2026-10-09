import BudgetKit
import Foundation
import Logging

/// The last card-bill check on one Plaid Item (kept on its `StoredLink`): what Plaid said and when. The dashboard shows
/// it per link, and offers "Grant card-bill access" when it says `needsConsent`.
public struct CardBillCheck: Codable, Hashable, Sendable {
    public var access: CardBillAccess
    public var checkedAt: Date
    /// Cards whose statement came back and was stored.
    public var cards: Int?
    /// Plaid's request id, for support. Never a token.
    public var requestID: String?
    /// Plaid's words, when it said no for a reason the dashboard doesn't name.
    public var message: String?

    public init(access: CardBillAccess, checkedAt: Date, cards: Int? = nil, requestID: String? = nil, message: String? = nil) {
        self.access = access; self.checkedAt = checkedAt; self.cards = cards; self.requestID = requestID; self.message = message
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
    /// mode, say) asks again at once when it was waiting for their consent or for Plaid; otherwise once a day.
    static func isDue(_ last: CardBillCheck?, now: Date, requestedByPerson: Bool) -> Bool {
        guard let last else { return true }
        if requestedByPerson, [.needsConsent, .notReady].contains(last.access) { return true }
        return now.timeIntervalSince(last.checkedAt) >= interval
    }

    /// The check after this sync: unchanged when it's off or not due, `noCreditAccounts` without asking when the Item
    /// has no card, otherwise Plaid's answer — card bills stored in the ledger, or why not. Never throws.
    static func refresh(enabled: Bool, source: PlaidSource, snapshot: SourceSnapshot, previous: CardBillCheck?, requestedByPerson: Bool,
                        api: LedgerBudgetAPI, now: Date, institution: String, logger: Logger) async -> CardBillCheck? {
        guard enabled else { return previous }
        let cards = PlaidSource.cardAccountIDs(snapshot)
        guard !cards.isEmpty else {
            return previous?.access == .noCreditAccounts ? previous : CardBillCheck(access: .noCreditAccounts, checkedAt: now)
        }
        guard isDue(previous, now: now, requestedByPerson: requestedByPerson) else { return previous }
        do {
            let (bills, requestID) = try await source.liabilities(accountIDs: cards)
            let stored = try await api.applyCardBills(bills, source: .plaid)
            logger.info("card bills for \(institution): \(stored) card\(stored == 1 ? "" : "s") (request_id \(requestID ?? "none"))")
            return CardBillCheck(access: .ok, checkedAt: now, cards: stored, requestID: requestID)
        } catch let error as PlaidAPIError {
            let access = CardBillAccess.from(errorCode: error.errorCode)
            logger.notice("card bills not available for \(institution): \(error.errorType ?? "?")/\(error.errorCode ?? "?") (request_id \(error.requestID ?? "none"))")
            return CardBillCheck(access: access, checkedAt: now, requestID: error.requestID, message: access == .failed ? error.errorMessage : nil)
        } catch {
            logger.warning("card bills check failed for \(institution): \(SyncService.describe(error))")
            return CardBillCheck(access: .failed, checkedAt: now, message: SyncService.describe(error))
        }
    }
}
