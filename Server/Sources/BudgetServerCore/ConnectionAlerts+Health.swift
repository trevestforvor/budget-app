import BudgetKit
import Foundation

extension ConnectionAlerts {
    /// The pushes account health calls for now: an account gone quiet, one bank behind a link needing a sign-in. Pure,
    /// so it's tested directly; the sender calls it. None yet.
    static func healthAlerts(_ health: [AccountHealth], links: [StoredLink], now: Date) -> [ConnectionAlert] { [] }
}
