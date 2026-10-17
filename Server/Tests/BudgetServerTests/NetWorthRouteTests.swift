import BudgetKit
@testable import BudgetServerCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import NIOCore
import Testing

@Suite("Net worth over HTTP")
struct NetWorthRouteTests {
    static let dashboardWrite: HTTPFields = [HTTPField.Name("X-Budget-Dashboard")!: "1", .contentType: "application/json"]

    @Test("The app's client reads net worth and changes hand-kept items through actions, with undo")
    func parity() async throws {
        let (app, service) = try await TestServer.app()
        try await app.test(.live) { client in
            let port = try #require(client.port)
            let remote = RemoteBudgetAPI(baseURL: URL(string: "http://localhost:\(port)")!, token: TestServer.token)
            let worth = try await remote.netWorth(range: .threeMonths)
            let local = try await service.api.netWorth(range: .threeMonths)
            #expect(worth.points.map(\.netWorth) == local.points.map(\.netWorth) && worth.points.map(\.date) == local.points.map(\.date))
            #expect(worth.assetLines == local.assetLines && worth.liabilityLines == local.liabilityLines)
            #expect(worth.netWorth == (try await remote.overview().balances?.netWorth))
            #expect(worth.manualAssets.map(\.name) == ["Car", "Car loan"])
            #expect(worth.range == "3M")

            let added = try await remote.perform(.saveManualAsset(SaveManualAsset(name: "Savings bond", kind: .asset, category: .other,
                                                                                   value: DecimalAmount(string: "1000"))))
            #expect(added.message.hasPrefix("Added Savings bond."))
            let after = try await remote.netWorth(range: .oneMonth)
            #expect(after.netWorth == worth.netWorth + Money(1_000))
            #expect(after.assetLines.contains { $0.name == "Savings bond" && $0.isManual == true })
            let undo = try #require(added.undo)
            _ = try await remote.perform(undo)
            #expect(try await remote.netWorth(range: .oneMonth).netWorth == worth.netWorth)

            await #expect(throws: BudgetAPIError.notFound) {
                try await remote.perform(.removeManualAsset(RemoveManualAsset(id: "nope")))
            }
            await #expect(throws: BudgetAPIError.rejected("Give it a name.")) {
                try await remote.perform(.saveManualAsset(SaveManualAsset(name: " ", value: DecimalAmount(string: "5"))))
            }
        }
    }

    @Test("Ranges are checked; the hand-kept list has its own read")
    func routes() async throws {
        let (app, _) = try await TestServer.app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/networth?range=5Y", method: .get, headers: TestServer.auth) { response in
                #expect(response.status == .badRequest)
                #expect(String(buffer: response.body).contains("range must be one of 1M, 3M, YTD, 1Y, ALL"))
            }
            try await client.execute(uri: "/v1/networth?range=ytd", method: .get, headers: TestServer.auth) { response in
                #expect(response.status == .ok)
                let worth = try RemoteBudgetAPI.decoder.decode(NetWorth.self, from: Data(response.body.readableBytesView))
                #expect(worth.range == "YTD")
            }
            try await client.execute(uri: "/v1/assets", method: .get, headers: TestServer.auth) { response in
                let items = try RemoteBudgetAPI.decoder.decode([ManualAsset].self, from: Data(response.body.readableBytesView))
                #expect(items.map(\.id) == ["asset-car", "asset-car-loan"])
            }
            try await client.execute(uri: "/v1/networth", method: .get) { #expect($0.status == .unauthorized) }
        }
    }

    @Test("A bank sync records each account's balance for the day")
    func syncRecordsBalances() async throws {
        let plaid = FakeProvider([
            "/item/public_token/exchange": [#"{"access_token": "access-sandbox-9", "item_id": "item-1"}"#],
            "/transactions/sync": [#"{"added": [{"transaction_id": "t1", "account_id": "chk", "amount": 12.5, "date": "2026-09-20", "name": "BLUE BOTTLE", "pending": false}], "modified": [], "removed": [], "next_cursor": "c1", "has_more": false}"#],
            "/accounts/get": [#"{"accounts": [{"account_id": "chk", "balances": {"current": 50}, "name": "Checking", "type": "depository", "subtype": "checking"}]}"#], "/accounts/balance/get": [#"{"accounts": [{"account_id": "chk", "balances": {"current": 50}, "name": "Checking", "type": "depository", "subtype": "checking"}]}"#],
        ])
        let (dash, service) = try await TestServer.app(seedDemo: false, plaid: plaid, surface: .dashboard)
        try await dash.test(.router) { client in
            try await client.execute(uri: "/v1/links/plaid/exchange", method: .post, headers: Self.dashboardWrite,
                                     body: TestServer.body(#"{"publicToken":"p","institution":"Harbor"}"#)) { #expect($0.status == .created) }
        }
        let recorded = try await service.api.recordedBalances()
        #expect(recorded.map(\.accountID) == ["plaid:chk"])
        #expect(recorded.first?.balance == Money(50))
        let worth = try await service.api.netWorth(range: .oneMonth)
        #expect(worth.netWorth == Money(50) && worth.estimatedThrough == nil)
    }

    @Test("A reset clears the recorded balances, or records the demo's with the demo ledger")
    func resetHistory() async throws {
        let (dash, service) = try await TestServer.app(surface: .dashboard)
        try await dash.test(.router) { client in
            try await client.execute(uri: "/v1/admin/reset", method: .post, headers: Self.dashboardWrite,
                                     body: TestServer.body(#"{"confirm":"erase my ledger","seedDemo":true}"#)) { #expect($0.status == .ok) }
        }
        #expect(try await service.api.recordedBalances().count > 100)
        #expect(try await service.api.netWorth(range: .oneMonth).estimatedThrough == nil)
        try await dash.test(.router) { client in
            try await client.execute(uri: "/v1/admin/reset", method: .post, headers: Self.dashboardWrite,
                                     body: TestServer.body(#"{"confirm":"erase my ledger"}"#)) { #expect($0.status == .ok) }
        }
        #expect(try await service.api.recordedBalances().isEmpty)
    }
}
