import Foundation

extension Ledger {
    /// Changes an account's kind, nickname or last digits.
    mutating func updateAccount(id: String, _ change: AccountChange) throws -> AccountChangeResult {
        throw BudgetAPIError.rejected("Editing accounts isn't built yet.")
    }
}
