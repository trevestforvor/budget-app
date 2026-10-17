import Foundation

extension LedgerBudgetAPI: HoldingsAPI {
    /// Stores each investment account's positions (`HoldingsSync`, after a holdings check). Returns how many accounts
    /// took them.
    @discardableResult
    public func applyHoldings(_ byExternal: [String: [SourceHolding]], source: SourceKind, at: Date) async throws -> Int { 0 }

    /// Positions in each investment account, as last checked.
    public func holdings() async throws -> HoldingsReport { .empty }
}
