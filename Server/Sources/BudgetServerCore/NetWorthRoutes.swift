import BudgetKit
import Foundation
import Hummingbird

/// Net worth (server 0.5.0): its history, and the hand-kept assets and debts in it. Those are changed through
/// `POST /v1/actions` (`saveManualAsset`, `removeManualAsset`), like rules and targets. Investment holdings (0.6.0) are read
/// here too.
func addNetWorthRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService) {
    let api = service.api

    /// `?range=1M|3M|YTD|1Y|ALL` (default 3M).
    router.get("/v1/networth") { request, _ in
        let raw = request.uri.queryParameters.get("range") ?? NetWorthRange.threeMonths.rawValue
        guard let range = NetWorthRange(rawValue: raw.uppercased()) else {
            throw BudgetAPIError.decoding("range must be one of \(NetWorthRange.allCases.map(\.rawValue).joined(separator: ", ")), got “\(raw)”")
        }
        return try HTTP.json(try await api.netWorth(range: range))
    }

    router.get("/v1/assets") { _, _ in try HTTP.json(await api.manualAssets()) }

    /// Positions in each investment account, as last checked (server 0.6.0). Read-only, so the phone has it too.
    router.get("/v1/holdings") { _, _ in try HTTP.json(try await api.holdings()) }
}
