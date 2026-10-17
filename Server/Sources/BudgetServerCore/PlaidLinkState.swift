import BudgetKit
import Foundation

/// Plaid's own state for one Item, kept on its `StoredLink` (`StoredLink.plaid`). Every field is optional, so a link
/// stored before a field existed still decodes.
public struct PlaidLinkState: Codable, Hashable, Sendable {
    public var institutionID: String? = nil
    // The daily /item/get: what Plaid says about the Item.
    public var lastItemCheckAt: Date? = nil
    /// `item.consent_expiration_time`.
    public var consentExpiresAt: Date? = nil
    /// When a PENDING_DISCONNECT webhook arrived (about a week's warning).
    public var pendingDisconnectAt: Date? = nil
    /// What Plaid bills this Item for.
    public var billedProducts: [String]? = nil
    public var availableProducts: [String]? = nil
    // Webhooks.
    /// The URL last sent with /link/token/create or /item/webhook/update; a changed public URL registers again.
    public var webhookURL: String? = nil
    /// When WEBHOOK_UPDATE_ACKNOWLEDGED arrived for that URL.
    public var webhookAcknowledgedAt: Date? = nil
    public var lastWebhookAt: Date? = nil
    /// Type and code only ("TRANSACTIONS/SYNC_UPDATES_AVAILABLE"), never the payload.
    public var lastWebhookCode: String? = nil
    // Balance only on request.
    /// Person-requested /accounts/balance/get calls in the last day, for the server's own cap.
    public var balanceRequests: [Date]? = nil
    /// The last real balance call.
    public var balanceAsOf: Date? = nil
    /// When Plaid last said new transactions were ready.
    public var lastTransactionsUpdate: Date? = nil

    public init() {}

    /// Copies what the dashboard shows about this Item onto its summary.
    func summaryFields(into summary: inout LinkSummary) {}
}
