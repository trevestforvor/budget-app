import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLRequest on Linux
#endif

/// Tags and the CSV export over HTTP (docs/API.md §Transactions). A server older than 0.5.0 answers 404, which reads as
/// `BudgetAPIError.notFound`.
extension RemoteBudgetAPI: TransactionToolsAPI {
    public func tags(period: String?) async throws -> [TagSummary] {
        try await get("v1/tags", query: period.map { [URLQueryItem(name: "period", value: $0)] } ?? [])
    }

    public func tag(_ name: String, period: String?) async throws -> TagSummary {
        try await get("v1/tags", id: name, query: period.map { [URLQueryItem(name: "period", value: $0)] } ?? [])
    }

    public func exportCSV(_ filter: TransactionFilter) async throws -> Data {
        var components = URLComponents(url: endpoint("v1/transactions/export.csv", id: nil), resolvingAgainstBaseURL: false)!
        components.queryItems = filter.queryItems
        // Writing a long history out takes the server a moment longer than a page.
        return try await load(URLRequest(url: components.url!), timeout: 60)
    }
}

/// Tags and exports are worked out on the ledger as it is now, so they always go upstream; offline they fail like any
/// other read without a saved copy.
extension CachingBudgetAPI: TransactionToolsAPI {
    public func tags(period: String?) async throws -> [TagSummary] { try await tools().tags(period: period) }
    public func tag(_ name: String, period: String?) async throws -> TagSummary { try await tools().tag(name, period: period) }
    public func exportCSV(_ filter: TransactionFilter) async throws -> Data { try await tools().exportCSV(filter) }

    private func tools() throws -> any TransactionToolsAPI {
        guard let api = upstream as? any TransactionToolsAPI else { throw BudgetAPIError.rejected("This connection can't list tags or export.") }
        return api
    }
}
