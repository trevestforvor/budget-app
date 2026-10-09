import Foundation

extension LedgerBudgetAPI: TransactionToolsAPI {
    public func tags(period: String?) async throws -> [TagSummary] {
        tick(); await pause(0.3)
        return try ledger.tagSummaries(period: period)
    }

    public func tag(_ name: String, period: String?) async throws -> TagSummary {
        tick(); await pause(0.4)
        return try ledger.tagSummary(name, period: period)
    }

    public func exportCSV(_ filter: TransactionFilter) async throws -> Data {
        tick(); await pause(0.6)
        try validate(filter)
        return Data(ledger.exportCSV(filter).utf8)
    }
}
