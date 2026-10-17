import Foundation

extension LedgerBudgetAPI: HoldingsAPI {
    /// Stores each investment account's positions (`HoldingsSync`, after a holdings check). Returns how many accounts
    /// took them.
    @discardableResult
    public func applyHoldings(_ byExternal: [String: [SourceHolding]], source: SourceKind, at: Date) async throws -> Int {
        tick()
        return try await write { ledger.applyHoldings(byExternal, source: source, at: at) }
    }

    /// How many investment accounts the ledger holds from `source` at `institution`: none means a holdings check would
    /// only hear NO_INVESTMENT_ACCOUNTS, so it isn't made.
    public func investmentAccountCount(source: SourceKind, institution: String) -> Int {
        ledger.accounts.filter { $0.source == source && $0.institution == institution && $0.kind == .investment }.count
    }

    /// Positions in each investment account, as last checked, the largest account first. An account the ledger no
    /// longer holds as an investment is left out; one whose link was removed keeps its last positions, dated.
    public func holdings() async throws -> HoldingsReport {
        tick()
        let investments = Set(ledger.accounts.filter { $0.kind == .investment }.map(\.id))
        let accounts = ledger.holdings.values.filter { investments.contains($0.id) }.sorted { ($0.total, $1.id) > ($1.total, $0.id) }
        return HoldingsReport(accounts: accounts, asOf: accounts.map(\.fetchedAt).min())
    }
}
