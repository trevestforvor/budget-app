import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLQueryItem on Linux
#endif

// Merchant pages, "Most frequent" lists and store order matching, on the ledger (server and demo), over HTTP, and
// through the phone's offline cache.

extension LedgerBudgetAPI: MerchantAPI {
    public func merchantSummary(_ merchant: String) async throws -> MerchantSummary {
        tick(); await pause(0.5)
        return try ledger.merchantSummary(merchant)
    }

    public func topMerchants(period: String, limit: Int, sort: TopMerchants.Sort) async throws -> TopMerchants {
        tick(); await pause(0.4)
        return try ledger.topMerchants(period: period, limit: min(max(limit, 1), 50), sort: sort)
    }

    /// Matches an Amazon order history file (`OrderHistory.parseAmazon`) to the ledger's Amazon charges
    /// (`Ledger.matchOrders`). A preview works it out on a copy and saves nothing; importing the same file again
    /// changes nothing.
    public func importAmazonOrders(_ csv: String, preview: Bool) async throws -> OrderImportReport {
        tick()
        let parsed = try OrderHistory.parseAmazon(csv)
        if preview {
            var copy = ledger
            return copy.matchOrders(parsed.orders, skippedLines: parsed.skippedLines, apply: false)
        }
        return try await write { ledger.matchOrders(parsed.orders, skippedLines: parsed.skippedLines, apply: true) }
    }
}

extension RemoteBudgetAPI: MerchantAPI {
    public func merchantSummary(_ merchant: String) async throws -> MerchantSummary {
        try await get("v1/merchants/summary", query: [URLQueryItem(name: "name", value: merchant)])
    }

    public func topMerchants(period: String, limit: Int, sort: TopMerchants.Sort) async throws -> TopMerchants {
        try await get("v1/merchants", query: [URLQueryItem(name: "period", value: period), URLQueryItem(name: "limit", value: String(limit)),
                                              URLQueryItem(name: "sort", value: sort.rawValue)])
    }
}

/// Merchant reads go to the server; with no answer they're unavailable rather than served from an older copy.
extension CachingBudgetAPI: MerchantAPI {
    public func merchantSummary(_ merchant: String) async throws -> MerchantSummary {
        try await merchants().merchantSummary(merchant)
    }

    public func topMerchants(period: String, limit: Int, sort: TopMerchants.Sort) async throws -> TopMerchants {
        try await merchants().topMerchants(period: period, limit: limit, sort: sort)
    }

    private func merchants() throws -> any MerchantAPI {
        guard let api = upstream as? any MerchantAPI else { throw BudgetAPIError.notFound }
        return api
    }
}
