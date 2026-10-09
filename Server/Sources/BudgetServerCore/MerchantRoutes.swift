import BudgetKit
import Foundation
import Hummingbird

// MARK: - Merchants and store orders

struct OrderImportBody: Decodable {
    /// The order history file's text.
    let content: String
    /// Work out the matches without saving them.
    let preview: Bool?
}

/// Merchant pages and "Most frequent" lists, and Amazon order history matching. All static paths: nothing here sits
/// beside a parameter route (`/v1/imports/{batch}` is DELETE only, and a batch id is never "amazon").
func addMerchantRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService) {
    let api = service.api

    /// `?period=this_month` (the default; any period the ledger names: `2026-09`, `last_90_days`, `year_to_date`),
    /// `limit` (default 5, at most 50), `sort=visits|spent`.
    router.get("/v1/merchants") { request, _ in
        let query = request.uri.queryParameters
        let limit = try query.get("limit").map { raw in
            guard let n = Int(raw), n >= 1 else { throw BudgetAPIError.decoding("limit must be a whole number, 1 or more, got “\(raw)”") }
            return n
        } ?? 5
        let sort = try query.get("sort").map { raw in
            guard let sort = TopMerchants.Sort(rawValue: raw) else { throw BudgetAPIError.decoding("sort must be visits or spent, got “\(raw)”") }
            return sort
        } ?? .visits
        return try HTTP.json(try await api.topMerchants(period: query.get("period") ?? "this_month", limit: limit, sort: sort))
    }

    /// `?name=DoorDash`: one merchant, named as the ledger shows it (case doesn't matter). 404 when no row has it.
    router.get("/v1/merchants/summary") { request, _ in
        guard let name = request.uri.queryParameters.get("name")?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw BudgetAPIError.decoding("name is required, like ?name=DoorDash")
        }
        return try HTTP.json(try await api.merchantSummary(name))
    }

    /// Amazon's order history CSV (`Retail.OrderHistory.1.csv`) matched to the ledger's Amazon charges. `preview: true`
    /// saves nothing. Importing the same file again changes nothing.
    router.post("/v1/imports/amazon") { request, _ in
        let body = try await HTTP.body(OrderImportBody.self, request, limit: 32 * 1024 * 1024)
        return try HTTP.json(try await api.importAmazonOrders(body.content, preview: body.preview == true))
    }
}
