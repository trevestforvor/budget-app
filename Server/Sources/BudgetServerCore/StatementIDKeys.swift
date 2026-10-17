import BudgetKit
import Foundation

/// The key that makes statement ids unreadable (account numbers never in an id), derived from `BUDGET_TOKEN_KEY`.
enum StatementIDKeys {
    /// Nil until statement ids are hashed.
    static func make(sealer: TokenSealer?, persistent: Bool) -> StatementIDs? { nil }
}
