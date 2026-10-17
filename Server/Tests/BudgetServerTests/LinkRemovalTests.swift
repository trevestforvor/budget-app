import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import Testing

/// Removing a Plaid Item (ITEM-005): a link's token goes only once Plaid confirms `/item/remove`, linking a bank again
/// after its access was withdrawn removes the old Item, and no Item is made that this server couldn't keep.
@Suite("Plaid Item removal")
struct LinkRemovalTests {
    static let removed = (200, #"{"request_id": "req-rm"}"#)
    static let down = PlaidErrorKindTests.plaidError("INTERNAL_SERVER_ERROR", type: "API_ERROR", status: 500)

    /// A dashboard server in `environment` with one live Plaid link, `plaid-item-0` at "Harbor Bank" (ins_1).
    static func server(_ plaid: ScriptedProvider, environment: PlaidSource.Environment = .production, tokenKey: Bool = true,
                       change: (inout StoredLink) -> Void = { _ in }) async throws -> (Application<RouterResponder<BasicRequestContext>>, BudgetService) {
        var config = TestServer.config()
        config.plaid?.environment = environment
        if !tokenKey { config.tokenKey = nil }
        let (service, _) = try await BudgetServerApp.makeService(config: config, store: MemoryStore(), logger: Logger(label: "test"), plaidTransport: plaid)
        try await BudgetServerApp.prepare(service)
        if tokenKey {
            var link = StoredLink(id: "plaid-item-0", provider: .plaid, institution: "Harbor Bank", externalID: "item-0",
                                  sealedToken: try #require(try service.sealer?.seal("access-sandbox-0")), cursor: "c0", status: .connected,
                                  lastSync: nil, lastError: nil, createdAt: Date())
            var state = PlaidLinkState()
            state.institutionID = "ins_1"
            link.plaid = state
            change(&link)
            try await service.store.upsertLink(link)
        }
        return (Application(router: buildRouter(service, surface: .dashboard)), service)
    }

    static func delete(_ app: some ApplicationProtocol) async throws -> (HTTPResponse.Status, String) {
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/links/plaid-item-0", method: .delete, headers: PlaidDashboardTests.write) { ($0.status, String(buffer: $0.body)) }
        }
    }

    @Test("Plaid not confirming /item/remove keeps the link (502, the token kept); confirming then removes it")
    func deleteFailsClosed() async throws {
        let plaid = ScriptedProvider(["/item/remove": [Self.down, Self.removed]])
        let (app, service) = try await Self.server(plaid)
        let (status, body) = try await Self.delete(app)
        #expect(status == .badGateway)
        #expect(body.contains("Harbor Bank") && body.contains("kept"))
        let kept = try #require(try await service.store.links().first)
        #expect(kept.hasLiveItem)
        #expect(try await Self.delete(app).0 == .noContent)
        #expect(try await service.store.links().isEmpty)
        #expect(plaid.count("/item/remove") == 2)
    }

    @Test("ITEM_NOT_FOUND from /item/remove means it's already gone: the link is removed")
    func alreadyGoneRemoves() async throws {
        let plaid = ScriptedProvider(["/item/remove": [PlaidErrorKindTests.plaidError("ITEM_NOT_FOUND", type: "ITEM_ERROR")]])
        let (app, service) = try await Self.server(plaid)
        #expect(try await Self.delete(app).0 == .noContent)
        #expect(try await service.store.links().isEmpty)
    }

    @Test("A sandbox Item (never billed) is removed here even when Plaid doesn't answer")
    func sandboxRemovesAnyway() async throws {
        let plaid = ScriptedProvider(["/item/remove": [Self.down]])
        let (app, service) = try await Self.server(plaid, environment: .sandbox)
        #expect(try await Self.delete(app).0 == .noContent)
        #expect(try await service.store.links().isEmpty)
    }

    @Test("Reset with removeLinks keeps a link Plaid didn't confirm removing, and resets nothing else")
    func resetFailsClosed() async throws {
        let plaid = ScriptedProvider(["/item/remove": [Self.down]])
        let (app, service) = try await Self.server(plaid)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/admin/reset", method: .post, headers: PlaidDashboardTests.write,
                                     body: TestServer.body(#"{"confirm":"erase my ledger","removeLinks":true,"clearImports":true}"#)) { response in
                #expect(response.status == .badGateway)
                #expect(String(buffer: response.body).contains("Nothing else was reset"))
            }
        }
        #expect(try await service.store.links().count == 1)
    }

    @Test("Linking a bank again after its access was withdrawn removes the old Item and drops its token; its rows stay")
    func relinkRemovesWithdrawnItem() async throws {
        let plaid = ScriptedProvider([
            PlaidDashboardTests.exchangePath: [PlaidScript.exchange],
            "/transactions/sync": [PlaidScript.page("c1")],
            "/accounts/get": [PlaidScript.balances],
            "/item/remove": [Self.removed],
        ])
        let (app, service) = try await Self.server(plaid) { link in
            LinkHealthBook.recordFailure(&link, LinkFailure(kind: .revoked, code: "USER_PERMISSION_REVOKED", message: "withdrawn"), now: Date())
        }
        let (status, _) = try await PlaidDashboardTests.exchange(app, #"{"publicToken":"public-2","institution":"Harbor Bank","institutionID":"ins_1"}"#)
        #expect(status == .created)
        #expect(plaid.count("/item/remove") == 1)
        #expect(plaid.requests.first { $0.path == "/item/remove" }?.body.contains("access-sandbox-0") == true)
        let links = try await service.store.links()
        #expect(Set(links.map(\.id)) == ["plaid-item-0", "plaid-item-1"])
        let old = try #require(links.first { $0.id == "plaid-item-0" })
        #expect(!old.hasLiveItem)
        #expect(links.first { $0.id == "plaid-item-1" }?.hasLiveItem == true)
    }

    @Test("Without BUDGET_TOKEN_KEY no Item is ever made: no new-link token, no exchange, no Plaid call")
    func noSealerNoItem() async throws {
        let plaid = PlaidDashboardTests.provider()
        let (app, _) = try await Self.server(plaid, environment: .sandbox, tokenKey: false)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/links/plaid/token", method: .post, headers: PlaidDashboardTests.write, body: TestServer.body("{}")) {
                #expect($0.status == .unprocessableContent)
            }
            try await client.execute(uri: "/v1/links/plaid/exchange", method: .post, headers: PlaidDashboardTests.write,
                                     body: TestServer.body(#"{"publicToken":"public-2","institution":"Harbor Bank"}"#)) {
                #expect($0.status == .unprocessableContent)
            }
        }
        #expect(plaid.requests.isEmpty)
    }
}
