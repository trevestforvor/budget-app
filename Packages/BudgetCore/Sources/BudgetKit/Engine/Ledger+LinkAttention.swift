import Foundation

extension Ledger {
    /// One item per connection the bank ended (sign in again), first in `dataHealth`.
    func linkAttention(_ institutions: [InstitutionLink]) -> [DataAttention] {
        let reauth = institutions.filter { $0.status == .needsReauth }
        return reauth.map { link in
            DataAttention(id: "reauth-\(link.id)", kind: .needsReauth, title: "\(link.institution) needs you to sign in again.",
                          detail: "The bank ended the connection, so nothing new is coming in. Reconnect it on the Budget dashboard — your accounts and history stay as they are.",
                          institution: link.institution)
        }
    }
}
