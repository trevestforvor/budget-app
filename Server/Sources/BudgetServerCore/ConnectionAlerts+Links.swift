import BudgetKit
import Foundation

extension ConnectionAlerts {
    /// How many days before consent runs out the phone hears about it (owner-approved: about two weeks, then one).
    static let expiryWarnDays = [14, 7]
    /// A PENDING_DISCONNECT is Plaid's week's notice.
    static let pendingDisconnectNotice: TimeInterval = 7 * 86_400

    /// The pushes the links call for now: a sign-in needed or access withdrawn (one per failure run), consent running out
    /// (about 14 and 7 days ahead), and the server's Plaid setup refused (one per run, however many links it stops).
    /// `timeZone` is the phone's, for the date in the copy. Never an amount, an account mask or a URL.
    static func linkAlerts(_ links: [StoredLink], now: Date, timeZone: TimeZone = utc) -> [ConnectionAlert] {
        var alerts: [ConnectionAlert] = []
        for link in links where link.provider != .teller && link.provider != .fileImport {
            if let alert = signInAlert(link) {
                alerts.append(alert)
            } else if let alert = expiryAlert(link, now: now, timeZone: timeZone) {
                alerts.append(alert)
            }
        }
        if let alert = setupAlert(links) { alerts.append(alert) }
        return alerts
    }

    /// A link that waits for the person: the bank wants a sign-in, or access was withdrawn. A link parked before 0.6.0
    /// has no failure run to key on and waits for its next failed sync to start one.
    static func signInAlert(_ link: StoredLink) -> ConnectionAlert? {
        guard LinkHealthBook.waitsForPerson(link), let since = link.firstFailedAt else { return nil }
        let key = signInKey(linkID: link.id, firstFailedAt: since)
        if link.errorKind == .revoked {
            return ConnectionAlert(kind: .revoked, episodeKeys: [key], title: "\(link.institution) stopped sharing with Budget",
                                   body: "Link it again on the Budget dashboard to keep its accounts up to date. Its history stays.",
                                   linkID: link.id)
        }
        return ConnectionAlert(kind: .needsSignIn, episodeKeys: [key], title: "\(link.institution) needs you to sign in again",
                               body: "Syncing has stopped until you do. Tap to fix it.", linkID: link.id,
                               opensReconnect: link.hasLiveItem)
    }

    /// When a Plaid Item's access ends: the consent date, or a week after a PENDING_DISCONNECT, whichever comes first.
    static func accessEnds(_ link: StoredLink) -> Date? {
        guard link.hasLiveItem, let plaid = link.plaid else { return nil }
        return [plaid.consentExpiresAt, plaid.pendingDisconnectAt.map { $0.addingTimeInterval(pendingDisconnectNotice) }].compactMap { $0 }.min()
    }

    /// Consent running out within 14 days (or 7: that push also covers the 14-day one, so a first look inside a week
    /// sends one, not two). Nothing once the date has passed: Plaid then reports a sign-in error, which has its own push.
    static func expiryAlert(_ link: StoredLink, now: Date, timeZone: TimeZone) -> ConnectionAlert? {
        guard let ends = accessEnds(link), ends > now else { return nil }
        let left = ends.timeIntervalSince(now)
        guard let days = expiryWarnDays.sorted().first(where: { left <= Double($0) * 86_400 }) else { return nil }
        let keys = expiryWarnDays.sorted().filter { $0 >= days }.map { expiryKey(linkID: link.id, expiresAt: ends, daysBefore: $0) }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.timeZone = timeZone
        style.locale = Locale(identifier: "en_US")
        return ConnectionAlert(kind: .consentExpiring, episodeKeys: keys, title: "\(link.institution) access ends \(ends.formatted(style))",
                               body: "Renew now so \(link.institution) keeps syncing. It takes a minute.", linkID: link.id, opensReconnect: true)
    }

    /// The server's Plaid keys or setup refused: one push for the earliest run among the links it stops.
    static func setupAlert(_ links: [StoredLink]) -> ConnectionAlert? {
        guard let since = links.filter({ $0.provider == .plaid && $0.errorKind == .providerSetup }).compactMap(\.firstFailedAt).min() else { return nil }
        return ConnectionAlert(kind: .providerSetup, episodeKeys: [setupKey(provider: .plaid, firstFailedAt: since)],
                               title: "Bank syncing through Plaid has stopped",
                               body: "The server's Plaid setup was refused. Check it on the Budget dashboard.")
    }
}
