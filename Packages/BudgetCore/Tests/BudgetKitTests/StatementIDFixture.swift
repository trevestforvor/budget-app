import Foundation
@testable import BudgetKit

extension StatementIDs {
    /// A keyed stand-in for the server's HMAC-SHA256, for tests: FNV-1a under a fixed key, 32 hex digits.
    static let test = keyed("test-key")

    /// The same stand-in under another key (BUDGET_TOKEN_KEY replaced).
    static func keyed(_ key: String) -> StatementIDs {
        StatementIDs(digest: { StableHash.hex128(key + "|" + $0) })
    }
}
