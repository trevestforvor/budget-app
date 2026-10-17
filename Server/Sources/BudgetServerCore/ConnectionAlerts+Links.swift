import BudgetKit
import Foundation

extension ConnectionAlerts {
    /// How many days before consent runs out the phone hears about it (owner-approved: about two weeks, then one).
    static let expiryWarnDays = [14, 7]
    /// A PENDING_DISCONNECT is Plaid's week's notice.
    static let pendingDisconnectNotice: TimeInterval = 7 * 86_400

    /// The pushes the links call for now: a sign-in needed or access withdrawn (one per failure run), consent running out
    /// (about 14 and 7 days ahead), and the server's Plaid setup refused (one per run, however many links it stops).
    /// `timeZone` is the phone's, for the date in the copy. `reconnect` is how each link is repaired, the same answer
    /// `LinkSummary.reconnect` gives: only `.phone` makes a tap open signing in again. Never an amount, an account mask or a URL.
    static func linkAlerts(_ links: [StoredLink], now: Date, timeZone: TimeZone = utc,
                           reconnect: (StoredLink) -> ReconnectMethod = { ReconnectMethod.for($0, phoneCapable: false) }) -> [ConnectionAlert] {
        var alerts: [ConnectionAlert] = []
        for link in links where link.provider != .teller && link.provider != .fileImport {
            let fromPhone = reconnect(link) == .phone
            if LinkHealthBook.waitsForPerson(link) {
                // Only the sign-in push, never the consent one: renewing won't help until the person signs in. A link
                // parked before 0.6.0 gets neither until its next failed sync starts a run.
                if let alert = signInAlert(link, fromPhone: fromPhone) { alerts.append(alert) }
            } else if let alert = expiryAlert(link, now: now, timeZone: timeZone, fromPhone: fromPhone) {
                alerts.append(alert)
            }
        }
        if let alert = setupAlert(links) { alerts.append(alert) }
        return alerts
    }

    /// A link that waits for the person: the bank wants a sign-in, or access was withdrawn. A link parked before 0.6.0
    /// has no failure run to key on and waits for its next failed sync to start one.
    static func signInAlert(_ link: StoredLink, fromPhone: Bool) -> ConnectionAlert? {
        guard LinkHealthBook.waitsForPerson(link), let since = link.firstFailedAt else { return nil }
        let key = signInKey(linkID: link.id, firstFailedAt: since)
        if link.errorKind == .revoked {
            return ConnectionAlert(kind: .revoked, episodeKeys: [key], title: "\(link.institution) stopped sharing with Budget",
                                   body: "Link it again on the Budget dashboard. Its accounts come back as new ones; the old ones keep their history.",
                                   linkID: link.id)
        }
        return ConnectionAlert(kind: .needsSignIn, episodeKeys: [key], title: "\(link.institution) needs you to sign in again",
                               body: fromPhone ? "Syncing has stopped until you do. Tap to fix it."
                                   : "Syncing has stopped until you do. Sign in again on the Budget dashboard.",
                               linkID: link.id, opensReconnect: fromPhone)
    }

    /// When a Plaid Item's access ends (`PlaidLinkState.accessEnds`): the consent date, or a week after a
    /// PENDING_DISCONNECT, whichever comes first of those still ahead. Nil without a live Item.
    static func accessEnds(_ link: StoredLink, now: Date) -> Date? {
        guard link.hasLiveItem else { return nil }
        return link.plaid?.accessEnds(now: now)
    }

    /// The date the phone and Home show as when access ends: the push's `accessEnds` (so a PENDING_DISCONNECT with no
    /// consent date still reads as a week away), else a consent date that has passed, for "has ended". One answer for the
    /// push, Linked accounts' banner, `linkAttention` and the dashboard's `LinkSummary.consentExpiresAt`, so a tapped push
    /// always finds something to renew.
    static func shownAccessEnds(_ link: StoredLink, now: Date) -> Date? {
        guard link.hasLiveItem else { return nil }
        return link.plaid?.shownAccessEnds(now: now)
    }

    /// Consent running out within 14 days (or 7: that push also covers the 14-day one, so a first look inside a week
    /// sends one, not two). Nothing once the date has passed: Plaid then reports a sign-in error, which has its own push.
    static func expiryAlert(_ link: StoredLink, now: Date, timeZone: TimeZone, fromPhone: Bool) -> ConnectionAlert? {
        guard let ends = accessEnds(link, now: now) else { return nil }
        let left = ends.timeIntervalSince(now)
        guard let days = expiryWarnDays.sorted().first(where: { left <= Double($0) * 86_400 }) else { return nil }
        let keys = expiryWarnDays.sorted().filter { $0 >= days }.map { expiryKey(linkID: link.id, expiresAt: ends, daysBefore: $0) }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.timeZone = timeZone
        style.locale = Locale(identifier: "en_US")
        return ConnectionAlert(kind: .consentExpiring, episodeKeys: keys, title: "\(link.institution) access ends \(ends.formatted(style))",
                               body: fromPhone ? "Renew now so \(link.institution) keeps syncing. It takes a minute."
                                   : "Renew it on the Budget dashboard so \(link.institution) keeps syncing.",
                               linkID: link.id, opensReconnect: fromPhone)
    }

    /// The server's Plaid keys or setup refused: one push however many links it stops. Every stopped link's run is a key,
    /// the earliest first: links fail and heal one by one, and the sender carries the later ones with the first, so the
    /// earliest link healing first (or a link joining late) doesn't read as a new outage.
    static func setupAlert(_ links: [StoredLink]) -> ConnectionAlert? {
        let starts = links.filter { $0.provider == .plaid && $0.errorKind == .providerSetup }.compactMap(\.firstFailedAt).sorted()
        guard !starts.isEmpty else { return nil }
        var keys: [String] = []
        for key in starts.map({ setupKey(provider: .plaid, firstFailedAt: $0) }) where !keys.contains(key) { keys.append(key) }
        return ConnectionAlert(kind: .providerSetup, episodeKeys: keys, title: "Bank syncing through Plaid has stopped",
                               body: "The server's Plaid setup was refused. Check it on the Budget dashboard.")
    }
}
