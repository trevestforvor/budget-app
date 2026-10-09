import BudgetKit
@testable import BudgetServerCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Testing

@Suite("Merchants and order matching over HTTP")
struct MerchantRouteTests {
    /// The app's own client against the running server.
    @Test("The app's client reads a merchant page and the most frequent merchants; an unknown merchant is a 404")
    func parity() async throws {
        let (app, _) = try await TestServer.app()
        try await app.test(.live) { client in
            let port = try #require(client.port)
            let remote = RemoteBudgetAPI(baseURL: URL(string: "http://localhost:\(port)")!, token: TestServer.token)
            let top = try await remote.topMerchants(period: "last_90_days", limit: 3, sort: .visits)
            #expect(top.merchants.count == 3 && top.label == "the last 90 days")
            #expect(top.merchants.map(\.visits) == top.merchants.map(\.visits).sorted(by: >))
            let bySpend = try await remote.topMerchants(period: "last_90_days", limit: 50, sort: .spent)
            #expect(bySpend.merchants.map(\.spent) == bySpend.merchants.map(\.spent).sorted(by: >))
            // A name with a space and an apostrophe travels as one query value.
            let joes = try await remote.merchantSummary("trader joe's")
            #expect(joes.merchant == "Trader Joe's" && joes.categoryID == "groceries")
            #expect(joes.transactions.allSatisfy { $0.merchant == "Trader Joe's" })
            #expect(joes.months.last?.spent == joes.thisMonth)
            let netflix = try await remote.merchantSummary("Netflix")
            #expect(netflix.recurring?.cadence == .monthly)
            await #expect(throws: BudgetAPIError.notFound) { try await remote.merchantSummary("Nowhere Diner") }
            await #expect(throws: BudgetAPIError.self) { try await remote.topMerchants(period: "someday", limit: 3, sort: .visits) }
        }
    }

    @Test("An Amazon order history matches the demo's charges; a preview saves nothing; the same file again changes nothing")
    func amazon() async throws {
        let (app, service) = try await TestServer.app()
        // One of the demo's Amazon charges that no order has claimed yet, as its order history would list it.
        let charge = try #require(await service.api.state.transactions.first {
            $0.merchant == "Amazon" && $0.orderMatch == nil && !$0.isPending && $0.amount.isNegative
        })
        let amount = DecimalAmount(charge.amount.magnitude).description
        let ordered = charge.postedAt.addingTimeInterval(-86_400).formatted(.iso8601)
        let csv = "Order ID,Order Date,Total Owed,Product Name,Order Status\n"
            + "112-7000000-0000001,\(ordered),\(amount),\"Bamboo cutting board, large\",Closed\n"
            + "112-7000000-0000002,\(ordered),1.23,Sticker,Closed\n"
        let bodies = try [true, false].map { ByteBuffer(bytes: try JSONSerialization.data(withJSONObject: ["content": csv, "preview": $0])) }
        let (previewBody, importBody) = (bodies[0], bodies[1])
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/imports/amazon", method: .post, headers: TestServer.auth, body: previewBody) { response in
                #expect(response.status == .ok)
                let report = try RemoteBudgetAPI.decoder.decode(OrderImportReport.self, from: Data(response.body.readableBytesView))
                #expect(!report.applied && report.orders == 2 && report.matched == 1 && report.unmatched == 1)
            }
            #expect(await service.api.state.transactions.first { $0.id == charge.id }?.orderMatch == nil)
            try await client.execute(uri: "/v1/imports/amazon", method: .post, headers: TestServer.auth, body: importBody) { response in
                let report = try RemoteBudgetAPI.decoder.decode(OrderImportReport.self, from: Data(response.body.readableBytesView))
                #expect(report.applied && report.matched == 1 && report.matches.first?.transactionID == charge.id)
            }
            try await client.execute(uri: "/v1/transactions/\(charge.id)", method: .get, headers: TestServer.auth) { response in
                let row = try RemoteBudgetAPI.decoder.decode(LedgerTransaction.self, from: Data(response.body.readableBytesView))
                #expect(row.orderMatch?.items == ["Bamboo cutting board, large"])
            }
            try await client.execute(uri: "/v1/imports/amazon", method: .post, headers: TestServer.auth, body: importBody) { response in
                let report = try RemoteBudgetAPI.decoder.decode(OrderImportReport.self, from: Data(response.body.readableBytesView))
                #expect(report.matched == 0 && report.alreadyMatched == 1)
            }
            try await client.execute(uri: "/v1/imports/amazon", method: .post, headers: TestServer.auth,
                                     body: TestServer.body(#"{"content":"Date,Amount\n2026-09-01,4.50"}"#)) { response in
                #expect(response.status == .unprocessableContent)
                #expect(String(buffer: response.body).contains("Order ID"))
            }
            try await client.execute(uri: "/v1/merchants/summary", method: .get, headers: TestServer.auth) { #expect($0.status == .badRequest) }
            try await client.execute(uri: "/v1/merchants?sort=loudest", method: .get, headers: TestServer.auth) { #expect($0.status == .badRequest) }
        }
    }

    @Test("The dashboard reads merchants and imports orders without the token")
    func dashboard() async throws {
        let (dash, _) = try await TestServer.app(surface: .dashboard)
        let write: HTTPFields = [HTTPField.Name("X-Budget-Dashboard")!: "1", .contentType: "application/json"]
        try await dash.test(.router) { client in
            try await client.execute(uri: "/v1/merchants?period=year_to_date&limit=2", method: .get) { response in
                #expect(response.status == .ok)
                let top = try RemoteBudgetAPI.decoder.decode(TopMerchants.self, from: Data(response.body.readableBytesView))
                #expect(top.merchants.count == 2)
            }
            try await client.execute(uri: "/v1/imports/amazon", method: .post, headers: write,
                                     body: TestServer.body(#"{"content":"Order ID,Order Date,Total Owed\n112-1,2020-01-02,5.00","preview":true}"#)) { response in
                #expect(response.status == .ok)
                let report = try RemoteBudgetAPI.decoder.decode(OrderImportReport.self, from: Data(response.body.readableBytesView))
                #expect(report.beforeLedger == 1 && report.matched == 0)
            }
            // The dashboard's write guard holds here too: no header, or another site's origin, and nothing runs.
            try await client.execute(uri: "/v1/imports/amazon", method: .post, headers: [.contentType: "application/json"],
                                     body: TestServer.body(#"{"content":"Order ID,Order Date,Total Owed\n112-1,2020-01-02,5.00"}"#)) { response in
                #expect(response.status == .forbidden)
            }
            var crossSite = write
            crossSite[.origin] = "https://elsewhere.example"
            try await client.execute(uri: "/v1/imports/amazon", method: .post, headers: crossSite,
                                     body: TestServer.body(#"{"content":"Order ID,Order Date,Total Owed\n112-1,2020-01-02,5.00"}"#)) { response in
                #expect(response.status == .forbidden)
            }
        }
    }
}
