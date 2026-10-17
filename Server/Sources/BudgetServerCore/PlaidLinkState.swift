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
    // Retries.
    /// Refused sign-ins in a row, counted apart from other failures: a webhook stops retrying after three of them, and a
    /// bank that was down first doesn't use them up. Nil after any other outcome.
    public var signInFailures: Int? = nil

    public init() {}

    /// Copies what the dashboard shows about this Item onto its summary. The access-ends date is the one the phone and
    /// the pushes show (`ConnectionAlerts.shownAccessEnds`): the consent date, or a week after a PENDING_DISCONNECT when
    /// that comes first, so the dashboard's "access ends" banner agrees with them.
    func summaryFields(into summary: inout LinkSummary, now: Date = Date()) {
        summary.institutionID = institutionID
        let warned = pendingDisconnectAt.map { $0.addingTimeInterval(ConnectionAlerts.pendingDisconnectNotice) }
        summary.consentExpiresAt = [consentExpiresAt, warned].compactMap { $0 }.filter { $0 > now }.min() ?? consentExpiresAt
        summary.lastItemCheckAt = lastItemCheckAt
        if webhookURL != nil || webhookAcknowledgedAt != nil || lastWebhookAt != nil || lastWebhookCode != nil {
            summary.webhook = LinkWebhookStatus(url: webhookURL, acknowledgedAt: webhookAcknowledgedAt, lastReceivedAt: lastWebhookAt,
                                                lastCode: lastWebhookCode)
        }
    }

    // MARK: Balance only on request

    /// The server's own cap on live balance reads per Item, well under Plaid's (5 a minute, 30 an hour).
    static let balanceReadsPerHour = 1
    static let balanceReadsPerDay = 6

    /// Whether the person's refresh may read balances live now: under the hourly and daily caps.
    func mayReadLiveBalance(now: Date) -> Bool {
        let day = (balanceRequests ?? []).filter { now.timeIntervalSince($0) < 86_400 }
        let hour = day.filter { now.timeIntervalSince($0) < 3_600 }
        return day.count < Self.balanceReadsPerDay && hour.count < Self.balanceReadsPerHour
    }

    /// Counts a live read, keeping only the last day's.
    mutating func recordBalanceRead(now: Date) {
        balanceRequests = ((balanceRequests ?? []) + [now]).filter { now.timeIntervalSince($0) < 86_400 }
    }

    /// The newest time Plaid's cached balances are known to be from: the last live read (which refreshes them) or Plaid's
    /// last transactions update (which a Transactions Item's balances follow). Nil when neither is known. A live read more
    /// than two days old says little: Plaid refreshes the cache about daily, so dating by it would make a healthy account
    /// look days stale. Without a transactions update to go by, it's left out and the read time dates the balance.
    func cachedBalanceAsOf(now: Date) -> Date? {
        let live = balanceAsOf.flatMap { now.timeIntervalSince($0) <= Self.liveReadDatesCacheFor ? $0 : nil }
        return [live, lastTransactionsUpdate].compactMap { $0 }.filter { $0 <= now }.max()
    }

    /// How long a live read still dates the cached balances that follow it.
    static let liveReadDatesCacheFor: TimeInterval = 48 * 3_600
}

extension StoredLink {
    /// A Plaid link whose Item still exists: it has an access token. After ITEM_NOT_FOUND (confirmed by /item/get) the
    /// token is dropped and the link kept for its history; such a link opens nothing, so nothing may call Plaid with it
    /// (no sync, balance, /item/get, /item/remove or update mode), and it never counts as a live Item at its institution.
    /// Linking the bank again is the only way back.
    public var hasLiveItem: Bool { provider == .plaid && !sealedToken.isEmpty }
}

// MARK: One Item per bank

extension StoredLink {
    /// A link that already holds a working Plaid Item at the bank Link just signed in to: linking it again would make a
    /// second Item (on the Trial plan, one of ten lifetime slots) and bring the same accounts in twice under new ids.
    /// Matched by Plaid's `institution_id` when both sides have it (the daily Item check reads the link's); otherwise by
    /// the bank's name, which came from the same Link metadata when the link was made. A link whose Item is gone or whose access was withdrawn
    /// doesn't count: linking again is the only way back for those.
    static func duplicateItem(in links: [StoredLink], institutionID: String?, institution: String) -> StoredLink? {
        let name = institution.trimmingCharacters(in: .whitespaces).lowercased()
        return links.first { link in
            guard link.hasLiveItem, link.errorKind != .revoked else { return false }
            if let known = link.plaid?.institutionID, let institutionID { return known == institutionID }
            // "Plaid" is what the dashboard sends when Link names no bank; it says nothing about which one.
            return !name.isEmpty && name != "plaid" && link.institution.trimmingCharacters(in: .whitespaces).lowercased() == name
        }
    }

    /// What the dashboard says when it refuses a second Item at a bank.
    static func duplicateItemMessage(_ existing: StoredLink) -> String {
        "\(existing.institution) is already linked. Use Reconnect on it instead, so you keep its history and don't use up a Plaid Item."
    }

    /// Plaid's `institution_id` as Link reported it, when it looks like one (`ins_…`); anything else isn't stored.
    static func institutionID(_ raw: String?) -> String? {
        guard let raw, (1...64).contains(raw.count), raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        return raw
    }
}
