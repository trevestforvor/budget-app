import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Testing

/// P0.2 (SPEC §10, Q1): the phone's token can't add or remove bank links or erase data. Those routes are on the dashboard's
/// listener only, and the API answers 404 for them even with the right token. The phone keeps syncing, signing in again
/// and file imports.
@Suite("The phone's token: no linking, unlinking or erasing (P0.2)")
struct PhoneTokenScopeTests {
    static let dash: HTTPFields = [HTTPField.Name("X-Budget-Dashboard")!: "1", .contentType: "application/json"]
    static let syncBatch = "plaid-\(ReconnectRouteTests.id)-1"

    /// Each route the phone lost, as (method, path, body).
    static let moved: [(HTTPRequest.Method, String, String?)] = [
        (.post, "/v1/links/plaid/token", "{}"),
        (.post, "/v1/links/plaid/token", #"{"linkID": "\#(ReconnectRouteTests.id)"}"#),
        (.post, "/v1/links/plaid/exchange", #"{"publicToken": "public-1", "institution": "Harbor"}"#),
        (.post, "/v1/links/simplefin", #"{"setupToken": "aHR0cHM6Ly9leGFtcGxlLmNvbQ=="}"#),
        (.put, "/v1/links/\(ReconnectRouteTests.id)/token", #"{"setupToken": "aHR0cHM6Ly9leGFtcGxlLmNvbQ=="}"#),
        (.delete, "/v1/links/\(ReconnectRouteTests.id)", nil),
        (.get, "/v1/imports", nil),
        (.post, "/v1/imports/duplicates", #"{"apply": true}"#),
        (.delete, "/v1/imports/\(syncBatch)?acknowledge=returning", nil),
        // Last, so a reset that did run can't hide what the others did.
        (.post, "/v1/admin/reset", #"{"confirm": "erase my ledger", "removeLinks": true, "clearImports": true, "removeProviderKeys": true}"#),
    ]

    /// One Plaid link (waiting for a sign-in), a ledger with a row, and a sync batch on record.
    static func fixture() async throws -> ReconnectRouteTests.Fixture {
        let f = try await ReconnectRouteTests.fixture()
        try await f.service.store.upsertImport(ImportRecord(batchID: syncBatch, kind: .sync, linkID: ReconnectRouteTests.id, label: "Harbor",
                                                            report: IngestReport(batchID: syncBatch, source: .plaid), createdAt: Date(), rolledBack: false))
        return f
    }

    @Test("Every moved route is a 404 to the phone's token, changes nothing, and still needs the token first")
    func phoneRefused() async throws {
        let f = try await Self.fixture()
        let before = await f.service.api.state.transactions.count
        try await f.app.test(.router) { client in
            for (method, path, body) in Self.moved {
                try await client.execute(uri: path, method: method, headers: TestServer.auth, body: body.map(TestServer.body)) { response in
                    #expect(response.status == .notFound, "\(method) \(path) answered \(response.status) to the phone's token")
                }
                // Without the token it's still 401: the refusal says nothing about which routes exist.
                try await client.execute(uri: path, method: method, headers: [.contentType: "application/json"], body: body.map(TestServer.body)) { response in
                    #expect(response.status == .unauthorized, "\(method) \(path) answered \(response.status) with no token")
                }
            }
        }
        #expect(try await f.service.store.links().map(\.id) == [ReconnectRouteTests.id])
        #expect(try await f.service.store.imports().map(\.batchID) == [Self.syncBatch])
        #expect(try await f.service.providers.plaid() != nil)
        #expect(await f.service.api.state.transactions.count == before)
        #expect(f.plaid.count("/item/remove") == 0 && f.plaid.count("/link/token/create") == 0)
    }

    @Test("The phone keeps syncing, signing in again, and its file imports (with their undo)")
    func phoneKeeps() async throws {
        let f = try await Self.fixture()
        try await f.app.test(.router) { client in
            try await client.execute(uri: "/v1/links", method: .get, headers: TestServer.auth) { #expect($0.status == .ok) }
            try await client.execute(uri: "/v1/links/\(ReconnectRouteTests.id)/reconnect", method: .post, headers: TestServer.auth) { response in
                #expect(response.status == .created)
                let session = try ReconnectRouteTests.decode(response)
                try await client.execute(uri: "/v1/links/\(ReconnectRouteTests.id)/reconnect/\(session.id)", method: .get, headers: TestServer.auth) {
                    #expect($0.status == .ok)
                }
            }
            try await client.execute(uri: "/v1/links/\(ReconnectRouteTests.id)/sync", method: .post, headers: TestServer.auth) { #expect($0.status == .ok) }
            try await client.execute(uri: "/v1/sync", method: .post, headers: TestServer.auth,
                                     body: TestServer.body(#"{"requestedByPerson": true}"#)) { #expect($0.status == .ok) }

            let csv = "Date,Description,Amount\\n2026-09-02,HOTEL NIKKO,-312.00\\n"
            let account = try #require(try await f.service.api.overview().accounts.first?.id)
            let body = #"{"content": "\#(csv)", "accountID": "\#(account)", "label": "September.csv"}"#
            try await client.execute(uri: "/v1/imports/preview", method: .post, headers: TestServer.auth,
                                     body: TestServer.body(#"{"files": [\#(body)]}"#)) { #expect($0.status == .ok) }
            var batch = ""
            try await client.execute(uri: "/v1/imports", method: .post, headers: TestServer.auth, body: TestServer.body(body)) { response in
                #expect(response.status == .created)
                batch = try RemoteBudgetAPI.decoder.decode(ImportRecord.self, from: Data(response.body.readableBytesView)).batchID
            }
            try await client.execute(uri: "/v1/imports/\(batch)/undo", method: .get, headers: TestServer.auth) { #expect($0.status == .ok) }
            // A file's batch is the phone's to undo; a sync's isn't (above).
            try await client.execute(uri: "/v1/imports/\(batch)", method: .delete, headers: TestServer.auth) { #expect($0.status == .ok) }
        }
    }

    @Test("The dashboard still has every one of them")
    func dashboardKeeps() async throws {
        let f = try await Self.fixture()
        let dash = Application(router: buildRouter(f.service, surface: .dashboard))
        try await dash.test(.router) { client in
            try await client.execute(uri: "/v1/imports", method: .get) { response in
                #expect(response.status == .ok)
                let records = try RemoteBudgetAPI.decoder.decode([ImportRecord].self, from: Data(response.body.readableBytesView))
                #expect(records.map(\.batchID) == [Self.syncBatch])
            }
            try await client.execute(uri: "/v1/imports/duplicates", method: .post, headers: Self.dash, body: TestServer.body(#"{"apply": false}"#)) {
                #expect($0.status == .ok)
            }
            // A Plaid sync's batch: the dashboard gets Undo's own answer (409, hide instead), not a 404.
            try await client.execute(uri: "/v1/imports/\(Self.syncBatch)", method: .delete, headers: Self.dash) { #expect($0.status == .conflict) }
            try await client.execute(uri: "/v1/links/plaid/token", method: .post, headers: Self.dash,
                                     body: TestServer.body(#"{"linkID": "\#(ReconnectRouteTests.id)"}"#)) { #expect($0.status == .ok) }
            // Only a SimpleFIN link takes a new setup token: the route is there, and says so.
            try await client.execute(uri: "/v1/links/\(ReconnectRouteTests.id)/token", method: .put, headers: Self.dash,
                                     body: TestServer.body(#"{"setupToken": "aHR0cHM6Ly9leGFtcGxlLmNvbQ=="}"#)) { #expect($0.status == .unprocessableContent) }
            try await client.execute(uri: "/v1/links/\(ReconnectRouteTests.id)", method: .delete, headers: Self.dash) { #expect($0.status == .noContent) }
            try await client.execute(uri: "/v1/admin/reset", method: .post, headers: Self.dash,
                                     body: TestServer.body(#"{"confirm": "erase my ledger", "clearImports": true}"#)) { #expect($0.status == .ok) }
        }
        #expect(try await f.service.store.links().isEmpty)
        #expect(try await f.service.store.imports().isEmpty)
    }

    @Test("The dashboard says what the phone can't do")
    func dashboardCopy() throws {
        let settings = String(decoding: try #require(DashboardAssets.files["settings.js"]).bytes, as: UTF8.self)
        #expect(settings.contains("the phone can't add or remove bank links or erase data"))
    }
}
