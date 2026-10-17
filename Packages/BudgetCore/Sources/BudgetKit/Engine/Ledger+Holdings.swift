import Foundation

extension Ledger {
    /// Stores each investment account's positions from its provider, keyed by the provider's account id. Returns how
    /// many accounts took them (none yet).
    mutating func applyHoldings(_ byExternal: [String: [SourceHolding]], source: SourceKind, at: Date) -> Int { 0 }
}
