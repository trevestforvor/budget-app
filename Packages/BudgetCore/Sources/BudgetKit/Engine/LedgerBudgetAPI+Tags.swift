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
        // A UTF-8 byte order mark first: Excel reads a CSV without one in the system's legacy encoding, which garbles
        // "Café" or "••1008". Numbers, Sheets and LibreOffice skip it.
        return Data(CSV.byteOrderMark.utf8) + Data(ledger.exportCSV(filter).utf8)
    }
}
