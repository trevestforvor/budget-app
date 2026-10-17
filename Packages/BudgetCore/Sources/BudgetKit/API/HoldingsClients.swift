import Foundation

extension RemoteBudgetAPI: HoldingsAPI {
    /// A server before 0.6.0 answers 404 (`BudgetAPIError.notFound`).
    public func holdings() async throws -> HoldingsReport { try await get("v1/holdings") }
}

/// Holdings are a read like any other: the last good answer is kept on the phone for offline.
extension CachingBudgetAPI: HoldingsAPI {
    public func holdings() async throws -> HoldingsReport {
        try await read(.holdings) {
            guard let api = upstream as? any HoldingsAPI else { throw BudgetAPIError.notFound }
            return try await api.holdings()
        }
    }
}
