import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Testing

/// B3 over HTTP: `PATCH /v1/accounts/:id` on both surfaces, the phone with its token and the dashboard with its header.
@Suite("Account edit routes")
struct AccountEditRouteTests {
    static func decode<T: Decodable>(_ type: T.Type, _ response: TestResponse) throws -> T {
        try RemoteBudgetAPI.decoder.decode(T.self, from: Data(response.body.readableBytesView))
    }

    /// One SimpleFIN account whose name says nothing of a card, so it comes in as checking: id `simplefin:acct-1`.
    static func seed(_ service: BudgetService) async throws -> String {
        let json = #"{"errors": [], "accounts": [{"id": "acct-1", "name": "Everyday Rewards", "org": {"name": "Harbor Bank"}, "currency": "USD", "balance": "-500.00", "balance-date": \#(Int(Date().timeIntervalSince1970)), "transactions": []}]}"#
        _ = try await service.api.ingest(try SimpleFINSource.parse(Data(json.utf8)), batchID: "simplefin-link-1-1")
        let id = try #require(try await service.api.overview().accounts.first?.id)
        #expect(id.contains(":"))   // sent as one percent-encoded segment, as the app does
        return id
    }

    static func path(_ id: String) -> String { "/v1/accounts/" + id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }

    @Test("PATCH /v1/accounts/:id works with the phone's token and from the dashboard; a bad mask is 422")
    func patchBothSurfaces() async throws {
        let (app, service) = try await TestServer.app(seedDemo: false)
        let id = try await Self.seed(service)
        try await app.test(.router) { client in
            try await client.execute(uri: Self.path(id), method: .patch, headers: TestServer.auth,
                                     body: TestServer.body(#"{"kind": "credit", "nickname": "Rewards card", "mask": "4321"}"#)) { response in
                #expect(response.status == .ok)
                let result = try Self.decode(AccountChangeResult.self, response)
                #expect(result.account.kind == .credit && result.account.kindSetByPerson == true)
                #expect(result.account.displayName == "Rewards card" && result.account.mask == "4321")
                #expect(result.warning == nil && result.sentToReview == 0)
            }
            try await client.execute(uri: Self.path(id), method: .patch, headers: TestServer.auth, body: TestServer.body(#"{"mask": "12345678"}"#)) { response in
                #expect(response.status == .unprocessableContent)
                #expect(String(buffer: response.body).contains("2 to 5 numbers"))
            }
            try await client.execute(uri: Self.path("simplefin:nope"), method: .patch, headers: TestServer.auth, body: TestServer.body(#"{"nickname": "x"}"#)) { response in
                #expect(response.status == .notFound)
            }
            // The phone's token is required.
            try await client.execute(uri: Self.path(id), method: .patch, headers: [.contentType: "application/json"], body: TestServer.body(#"{"nickname": "x"}"#)) { response in
                #expect(response.status == .unauthorized)
            }
        }
        let overview = try await service.api.overview()
        #expect(overview.accounts.first?.nickname == "Rewards card")   // the refusals changed nothing
        #expect(overview.balances?.cardsOwed == Money(500))

        let (dash, dashService) = try await TestServer.app(seedDemo: false, surface: .dashboard)
        let dashID = try await Self.seed(dashService)
        let write: HTTPFields = [HTTPField.Name("X-Budget-Dashboard")!: "1", .contentType: "application/json"]
        try await dash.test(.router) { client in
            try await client.execute(uri: Self.path(dashID), method: .patch, headers: write, body: TestServer.body(#"{"nickname": "Bills"}"#)) { response in
                #expect(response.status == .ok)
                let result = try Self.decode(AccountChangeResult.self, response)
                #expect(result.account.nickname == "Bills")
            }
            // The dashboard's write guard: no header, and nothing changes.
            try await client.execute(uri: Self.path(dashID), method: .patch, headers: [.contentType: "application/json"],
                                     body: TestServer.body(#"{"nickname": "Other"}"#)) { response in
                #expect(response.status == .forbidden)
            }
            try await client.execute(uri: Self.path(dashID), method: .patch, headers: write, body: TestServer.body(#"{"mask": "ab"}"#)) { response in
                #expect(response.status == .unprocessableContent)
            }
        }
        #expect(try await dashService.api.overview().accounts.first?.nickname == "Bills")
    }

    @Test("Making a card of an account with a positive balance warns, and the balance keeps its sign")
    func remoteClient() async throws {
        let (app, service) = try await TestServer.app(seedDemo: false)
        let id = try await Self.seed(service)
        try await app.test(.router) { client in
            // A positive balance on a card: warned, not flipped.
            let json = #"{"errors": [], "accounts": [{"id": "acct-1", "name": "Everyday Rewards", "org": {"name": "Harbor Bank"}, "currency": "USD", "balance": "25.00", "balance-date": \#(Int(Date().timeIntervalSince1970)), "transactions": []}]}"#
            _ = try await service.api.ingest(try SimpleFINSource.parse(Data(json.utf8)), batchID: "simplefin-link-1-2")
            // As `RemoteBudgetAPI` sends it: `appending(component:)` leaves the colon as it is.
            try await client.execute(uri: "/v1/accounts/\(id)", method: .patch, headers: TestServer.auth, body: TestServer.body(#"{"kind": "credit"}"#)) { response in
                #expect(response.status == .ok)
                let result = try Self.decode(AccountChangeResult.self, response)
                #expect(result.warning?.contains("positive") == true)
                #expect(result.account.balance == Money(25))
            }
        }
    }
}
