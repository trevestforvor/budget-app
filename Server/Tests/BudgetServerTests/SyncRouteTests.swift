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

/// A provider that answers each path from a script of (status, body) replies — the last one repeats — and can take its
/// time, to see whether two syncs ever overlap.
final class ScriptedProvider: HTTPTransport, @unchecked Sendable {
    struct Request { var path: String; var body: String; var authorization: String? }
    private let lock = NSLock()
    private var script: [String: [(status: Int, body: String)]]
    private let delay: Duration
    private var inFlight = 0
    private(set) var requests: [Request] = []
    private(set) var mostAtOnce = 0

    init(_ script: [String: [(status: Int, body: String)]], delay: Duration = .zero) {
        self.script = script
        self.delay = delay
    }

    func count(_ path: String) -> Int { lock.withLock { requests.filter { $0.path == path }.count } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        let reply = lock.withLock { () -> (status: Int, body: String) in
            requests.append(Request(path: path, body: String(decoding: request.httpBody ?? Data(), as: UTF8.self),
                                    authorization: request.value(forHTTPHeaderField: "Authorization")))
            inFlight += 1
            mostAtOnce = max(mostAtOnce, inFlight)
            guard var replies = script[path], !replies.isEmpty else { return (404, #"{"error_code":"NOT_FOUND"}"#) }
            let first = replies.removeFirst()
            script[path] = replies.isEmpty ? [first] : replies
            return first
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        lock.withLock { inFlight -= 1 }
        return (Data(reply.body.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!)
    }
}

enum PlaidScript {
    static let exchange = (200, #"{"access_token": "access-sandbox-9", "item_id": "item-1"}"#)
    static func page(_ cursor: String, _ rows: String = "") -> (Int, String) {
        (200, #"{"added": [\#(rows)], "modified": [], "removed": [], "next_cursor": "\#(cursor)", "has_more": false}"#)
    }
    static let loginRequired = (400, #"{"error_type": "ITEM_ERROR", "error_code": "ITEM_LOGIN_REQUIRED", "error_message": "the login details of this item have changed"}"#)
    static let balances = (200, #"{"accounts": [{"account_id": "chk", "balances": {"current": 5000, "iso_currency_code": "USD"}, "name": "Checking", "type": "depository", "subtype": "checking"}]}"#)
    static let row = #"{"transaction_id": "t1", "account_id": "chk", "amount": 12.5, "iso_currency_code": "USD", "date": "2026-09-20", "name": "BLUE BOTTLE COFFEE", "pending": false}"#
}

@Suite("Syncing and reconnecting")
struct SyncRouteTests {
    static let write: HTTPFields = [HTTPField.Name("X-Budget-Dashboard")!: "1", .contentType: "application/json"]

    static func decode<T: Decodable>(_ type: T.Type, _ response: TestResponse) throws -> T {
        try RemoteBudgetAPI.decoder.decode(T.self, from: Data(response.body.readableBytesView))
    }

    @Test("Plaid: a refused sign-in parks the link until it's reconnected in update mode — no second Item, no exchange")
    func plaidReconnect() async throws {
        let plaid = ScriptedProvider([
            "/item/public_token/exchange": [PlaidScript.exchange],
            "/transactions/sync": [PlaidScript.page("cursor-1", PlaidScript.row), PlaidScript.loginRequired, PlaidScript.page("cursor-2")],
            "/accounts/get": [PlaidScript.balances], "/accounts/balance/get": [PlaidScript.balances],
            "/link/token/create": [(200, #"{"link_token": "link-update-1"}"#)],
        ])
        let (dash, service) = try await TestServer.app(seedDemo: false, plaid: plaid, surface: .dashboard)
        try await dash.test(.router) { client in
            try await client.execute(uri: "/v1/links/plaid/exchange", method: .post, headers: Self.write,
                                     body: TestServer.body(#"{"publicToken":"public-1","institution":"Harbor"}"#)) { #expect($0.status == .created) }
            // The bank ends the connection: the scheduled sync marks it and says why, in Plaid's words.
            try await client.execute(uri: "/v1/sync", method: .post, headers: Self.write) { response in
                let results = try Self.decode([LinkSyncResult].self, response)
                #expect(results.count == 1 && !results[0].ok)
                #expect(results[0].error == "Plaid: the login details of this item have changed (ITEM_LOGIN_REQUIRED)")
            }
            try await client.execute(uri: "/v1/status", method: .get) { response in
                let status = try Self.decode(ServerStatus.self, response)
                let chase = try #require(status.institutions.first)
                #expect(chase.status == .needsReauth && chase.priority == .core) // .core only for apps before 0.2.0
                #expect(chase.lastError?.contains("ITEM_LOGIN_REQUIRED") == true && chase.lastSync != nil)
                #expect(chase.accountIDs?.isEmpty == false && chase.accountKinds == [.checking])
                #expect(status.lastSync == chase.lastSync)
            }
            try await client.execute(uri: "/v1/overview", method: .get) { response in
                let decoded = try Self.decode(Overview.self, response)
                #expect(decoded.attention?.first?.id == "reauth-plaid-item-1")
            }
            // Sync-all leaves it alone: asking again would only be refused again.
            try await client.execute(uri: "/v1/sync", method: .post, headers: Self.write) { response in
                let decoded = try Self.decode([LinkSyncResult].self, response)
                #expect(decoded.isEmpty)
            }
            #expect(plaid.count("/transactions/sync") == 2)

            // Update mode: a Link token for the existing Item. An unknown link is refused rather than starting a new Item.
            try await client.execute(uri: "/v1/links/plaid/token", method: .post, headers: Self.write,
                                     body: TestServer.body(#"{"linkID":"plaid-item-1"}"#)) { #expect(String(buffer: $0.body).contains("link-update-1")) }
            let tokenRequest = try #require(plaid.requests.last { $0.path == "/link/token/create" })
            #expect(tokenRequest.body.contains("access-sandbox-9") && !tokenRequest.body.contains("products"))
            try await client.execute(uri: "/v1/links/plaid/token", method: .post, headers: Self.write,
                                     body: TestServer.body(#"{"linkID":"plaid-nope"}"#)) { #expect($0.status == .notFound) }

            // Link finished: one sync of that link, nothing exchanged.
            try await client.execute(uri: "/v1/links/plaid-item-1/sync", method: .post, headers: Self.write) { response in
                #expect(response.status == .ok)
                let decoded = try Self.decode(LinkSyncResult.self, response)
                #expect(decoded.ok)
            }
            #expect(plaid.count("/item/public_token/exchange") == 1)
            try await client.execute(uri: "/v1/links", method: .get) { response in
                let links = try Self.decode([LinkSummary].self, response)
                #expect(links.map(\.status) == [.connected] && links[0].lastError == nil && links[0].externalID == "item-1")
            }
            // And sync-all takes it again.
            try await client.execute(uri: "/v1/sync", method: .post, headers: Self.write) { response in
                let decoded = try Self.decode([LinkSyncResult].self, response)
                #expect(decoded.count == 1)
            }
            try await client.execute(uri: "/v1/links/nope/sync", method: .post, headers: Self.write) { #expect($0.status == .notFound) }
            try await client.execute(uri: "/v1/links/plaid-item-1", method: .delete, headers: Self.write) { #expect($0.status == .noContent) }
        }
        #expect(try await service.store.links().isEmpty)
    }

    @Test("A sync that fails for another reason after a reconnect leaves the link for the schedule, not for another sign-in")
    func retryAfterTransientFailure() async throws {
        let plaid = ScriptedProvider([
            "/item/public_token/exchange": [PlaidScript.exchange],
            "/transactions/sync": [PlaidScript.page("cursor-1"), PlaidScript.loginRequired, (500, #"{"error_code": "INTERNAL_SERVER_ERROR", "error_message": "try again"}"#),
                                   PlaidScript.page("cursor-2")],
            "/accounts/get": [PlaidScript.balances], "/accounts/balance/get": [PlaidScript.balances],
        ])
        let (app, service) = try await TestServer.app(seedDemo: false, plaid: plaid, surface: .dashboard)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/links/plaid/exchange", method: .post, headers: TestServer.dash,
                                     body: TestServer.body(#"{"publicToken":"public-1","institution":"Harbor"}"#)) { #expect($0.status == .created) }
        }
        _ = await service.sync.syncAll()
        #expect(try await service.store.links().first?.status == .needsReauth)
        let retried = try await service.sync.sync(linkID: "plaid-item-1")
        #expect(!retried.ok && retried.error?.contains("try again") == true)
        #expect(try await service.store.links().first?.status == .connected)
        // 0.6.0: the schedule first waits out the failure's backoff, then takes the link.
        #expect(await service.sync.syncAll().isEmpty)
        try await service.sync.updateLink("plaid-item-1") { $0.nextAttemptAt = nil }
        #expect(await service.sync.syncAll().map(\.ok) == [true])
    }

    @Test("Syncs never overlap: a second sync-all joins the one under way, and one bank's sync waits its turn")
    func serialized() async throws {
        let plaid = ScriptedProvider([
            "/item/public_token/exchange": [PlaidScript.exchange],
            "/transactions/sync": [PlaidScript.page("cursor-1")],
            "/accounts/get": [PlaidScript.balances], "/accounts/balance/get": [PlaidScript.balances],
        ], delay: .milliseconds(150))
        let (app, service) = try await TestServer.app(seedDemo: false, plaid: plaid, surface: .dashboard)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/links/plaid/exchange", method: .post, headers: TestServer.dash,
                                     body: TestServer.body(#"{"publicToken":"public-1","institution":"Harbor"}"#)) { #expect($0.status == .created) }
        }
        let before = plaid.count("/transactions/sync")
        async let first = service.sync.syncAll()
        async let second = service.sync.syncAll()
        async let one = service.sync.sync(linkID: "plaid-item-1")
        let (a, b, c) = try await (first, second, one)
        #expect(a.count == 1 && b.count == 1 && c.ok)
        #expect(plaid.count("/transactions/sync") == before + 2)  // one sync-all, one bank
        #expect(plaid.mostAtOnce == 1)
    }

    @Test("The budget month, a category's history and Sync now over HTTP, with the app's own client")
    func readsOverHTTP() async throws {
        let (app, service) = try await TestServer.app()
        try await app.test(.live) { client in
            let port = try #require(client.port)
            let remote = RemoteBudgetAPI(baseURL: URL(string: "http://localhost:\(port)")!, token: TestServer.token)
            let month = try await remote.budget(month: nil)
            #expect(month.isCurrent && month.groups.count == 3)
            #expect(month.month == (try await service.api.budget(month: nil)).month)
            let past = try await remote.budget(month: "2026-08")
            #expect(!past.isCurrent && past.month == "2026-08")
            await #expect(throws: BudgetAPIError.rejected("A month is written like 2026-09.")) { try await remote.budget(month: "2026-13") }
            let history = try await remote.categoryHistory(id: "dining", months: 6)
            #expect(!history.months.isEmpty && history.months.count <= 6 && history.months.last?.month == month.month)
            #expect(history.months.allSatisfy { $0.target == Money(450) })
            await #expect(throws: BudgetAPIError.notFound) { try await remote.categoryHistory(id: "pets", months: 6) }
            #expect(try await remote.syncNow().isEmpty)  // no links on this server
            let plan = try await remote.savingsPlan()
            #expect(plan.history?.last?.isPartial == true && plan.averageCashChange != nil)
            let overview = try await remote.overview()
            #expect(overview.balances?.cash == overview.cashOnHand && overview.lastSevenDays?.count == 7 && overview.attention != nil)
            #expect(try await remote.subscriptions().dueNext30Days != nil)
        }
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/categories/dining/history?months=0", method: .get, headers: TestServer.auth) { #expect($0.status == .badRequest) }
            try await client.execute(uri: "/v1/categories/dining/history", method: .get, headers: TestServer.auth) { response in
                #expect(response.status == .ok)
                let decoded = try Self.decode(CategoryHistory.self, response)
                #expect(decoded.categoryID == "dining")
            }
        }
    }

    @Test("The dashboard URL is a server setting beside the phone's server URL, and the phone reads it from status")
    func dashboardURL() async throws {
        let (dash, _) = try await TestServer.app(surface: .dashboard)
        try await dash.test(.router) { client in
            try await client.execute(uri: "/v1/status", method: .get) { response in
                let decoded = try Self.decode(ServerStatus.self, response)
                #expect(decoded.dashboardURL == nil)
            }
            try await client.execute(uri: "/dash/settings", method: .patch, headers: Self.write,
                                     body: TestServer.body(#"{"changes":{"dashboardURL":"https://budget.example/"}}"#)) { response in
                #expect(response.status == .ok)
                let fields = try JSONDecoder().decode([SettingField].self, from: Data(response.body.readableBytesView))
                let field = try #require(fields.first { $0.key == "dashboardURL" })
                #expect(field.group == "Phone" && field.value == "https://budget.example" && field.origin == .dashboard)
            }
            try await client.execute(uri: "/v1/status", method: .get) { response in
                let decoded = try Self.decode(ServerStatus.self, response)
                #expect(decoded.dashboardURL == "https://budget.example")
            }
            try await client.execute(uri: "/dash/settings", method: .patch, headers: Self.write,
                                     body: TestServer.body(#"{"changes":{"dashboardURL":"budget.example"}}"#)) { #expect($0.status == .unprocessableContent) }
        }
        #expect(try ServerConfig.fromEnvironment(["BUDGET_DASHBOARD_URL": "https://dash.example"]).dashboardURL == "https://dash.example")
    }

    @Test("A link's failure reads in the provider's words, and only a refused sign-in needs one")
    func errors() {
        let plaid = SourceHTTPError(status: 400, body: #"{"error_code": "ITEM_LOGIN_REQUIRED", "error_message": "login required"}"#)
        #expect(SyncService.describe(plaid) == "Plaid: login required (ITEM_LOGIN_REQUIRED)")
        #expect(SyncService.needsSignIn(plaid))
        #expect(SyncService.needsSignIn(SourceHTTPError(status: 403, body: "")))
        #expect(!SyncService.needsSignIn(SourceHTTPError(status: 500, body: #"{"error_code": "INTERNAL_SERVER_ERROR"}"#)))
        #expect(!SyncService.needsSignIn(BudgetAPIError.rejected("Plaid isn't set up on the server.")))
        #expect(SyncService.describe(BudgetAPIError.rejected("Plaid isn't set up on the server.")) == "Plaid isn't set up on the server.")
    }

    @Test("A restart doesn't put the next sync a whole interval off: the first wait counts from the last sync")
    func firstSyncAfterRestart() {
        let now = Date(timeIntervalSince1970: 1_800_000_000), hour = 3600.0, six = 6 * hour
        // Synced 13 hours ago (deploys kept restarting the old six-hour countdown): due, so in a minute.
        #expect(SyncService.firstWait(interval: six, lastSync: now.addingTimeInterval(-13 * hour), linked: true, now: now) == 60)
        // Synced two hours ago: the four hours left.
        #expect(SyncService.firstWait(interval: six, lastSync: now.addingTimeInterval(-2 * hour), linked: true, now: now) == 4 * hour)
        // Never synced: soon. Nothing linked: the whole interval, as before.
        #expect(SyncService.firstWait(interval: six, lastSync: nil, linked: true, now: now) == 60)
        #expect(SyncService.firstWait(interval: six, lastSync: nil, linked: false, now: now) == six)
        // A clock that says the last sync is in the future never waits past one interval.
        #expect(SyncService.firstWait(interval: six, lastSync: now.addingTimeInterval(3 * hour), linked: true, now: now) == six)
    }
}
