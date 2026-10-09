import Foundation

extension RemoteBudgetAPI: NetWorthAPI {
    /// A server before 0.5.0 answers 404 (`BudgetAPIError.notFound`).
    public func netWorth(range: NetWorthRange) async throws -> NetWorth {
        try await get("v1/networth", query: [URLQueryItem(name: "range", value: range.rawValue)])
    }
}

/// Net worth is a read like any other: the last good answer for each range is kept on the phone for offline.
extension CachingBudgetAPI: NetWorthAPI {
    public func netWorth(range: NetWorthRange) async throws -> NetWorth {
        try await read(.netWorth(range: range.rawValue)) {
            guard let networth = upstream as? any NetWorthAPI else { throw BudgetAPIError.notFound }
            return try await networth.netWorth(range: range)
        }
    }
}
