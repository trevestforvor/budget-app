import BudgetKit
import Foundation

extension ConnectionAlerts {
    /// The pushes the links call for now: a sign-in needed, access withdrawn, consent running out. None yet.
    static func linkAlerts(_ links: [StoredLink], now: Date) -> [ConnectionAlert] { [] }
}
