import BudgetKit
import Foundation

extension ConnectionAlerts {
    /// The pushes account health calls for now: one bank behind a SimpleFIN link needing a sign-in (once per episode,
    /// keyed by when it began). Accounts gone quiet come later. Pure, so it's tested directly; the sender calls it.
    static func healthAlerts(_ health: [AccountHealth], links: [StoredLink], now: Date) -> [ConnectionAlert] {
        links.filter { $0.provider == .simplefin && $0.status != .needsReauth }.flatMap { link -> [ConnectionAlert] in
            (link.simplefin?.sortedConnections ?? []).compactMap { id, bank in
                guard bank.status == .needsReauth, let since = bank.firstFailedAt else { return nil }
                let bankID = SimpleFINLinkState.bankID(id)
                return ConnectionAlert(kind: .bankNeedsSignIn, episodeKeys: [bankKey(linkID: link.id, connectionID: bankID, firstFailedAt: since)],
                                       title: "\(bank.name) needs you to sign in",
                                       body: "Sign in again on SimpleFIN Bridge. Nothing new comes in from \(bank.name) until then; your other banks keep syncing.",
                                       linkID: link.id, bankID: SimpleFINLinkState.rowID(linkID: link.id, connectionID: id))
            }
        }
    }
}
