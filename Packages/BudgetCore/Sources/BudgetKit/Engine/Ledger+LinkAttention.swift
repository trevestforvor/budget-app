import Foundation

extension Ledger {
    /// How far ahead a bank's consent running out shows in Home's attention and Linked accounts (and when its first
    /// push goes out).
    static let consentWarningDays: Double = 14

    /// One item per connection the bank ended (sign in again), then one per connection whose consent runs out within
    /// `consentWarningDays` (renew access): first in `dataHealth`. Both keep `kind: .needsReauth`, which every app
    /// knows; `reason` and `linkID` tell a 0.6.0 phone which repair to open.
    func linkAttention(_ institutions: [InstitutionLink]) -> [DataAttention] {
        let reauth = institutions.filter { $0.status == .needsReauth }
        let ended = reauth.map { link in
            DataAttention(id: "reauth-\(link.id)", kind: .needsReauth, title: "\(link.institution) needs you to sign in again.",
                          detail: reauthDetail(link), institution: link.institution,
                          reason: link.errorKind == .revoked || link.reconnect == .newLink ? .revoked : .needsSignIn, linkID: link.id)
        }
        var dayStyle = Date.FormatStyle.dateTime.month(.abbreviated).day()
        dayStyle.timeZone = calendar.timeZone
        let expiring = institutions.compactMap { link -> DataAttention? in
            guard link.status != .needsReauth, let ends = link.consentExpiresAt,
                  ends.timeIntervalSince(now) <= Self.consentWarningDays * 86_400 else { return nil }
            let when = ends > now ? "ends \(ends.formatted(dayStyle))" : "has ended"
            return DataAttention(id: "expiring-\(link.id)", kind: .needsReauth, title: "\(link.institution) access \(when).",
                                 detail: link.reconnect == .phone
                                    ? "Banks ask you to renew access now and then. Renew it from Linked accounts so new transactions keep coming in."
                                    : "Banks ask you to renew access now and then. Reconnect it on the Budget dashboard so new transactions keep coming in.",
                                 institution: link.institution, reason: .consentExpiring, linkID: link.id, dueBy: ends)
        }
        return ended + expiring
    }

    /// Where the person repairs `link`: on the phone when the server says it can, else the dashboard; a fresh link when
    /// access was withdrawn.
    private func reauthDetail(_ link: InstitutionLink) -> String {
        switch link.reconnect {
        case .phone?:
            "The bank ended the connection, so nothing new is coming in. Sign in again from Linked accounts — your accounts and history stay as they are."
        case .newLink?:
            "Access to it was withdrawn, so nothing new is coming in. Link it again on the Budget dashboard — your accounts and history stay as they are."
        default:
            "The bank ended the connection, so nothing new is coming in. Reconnect it on the Budget dashboard — your accounts and history stay as they are."
        }
    }
}
