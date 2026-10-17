import BudgetKit
@testable import BudgetServerCore
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

/// Teller withdrew its API in July 2026, and 0.6.0 removes it (SPEC §10): no routes, no dashboard pane, nothing in the
/// CSP. A Teller link stored before then still loads, and says to remove it.
@Suite("Teller removed")
struct TellerRemovalTests {
    static let write: HTTPFields = [HTTPField.Name("X-Budget-Dashboard")!: "1", .contentType: "application/json"]

    static func asset(_ name: String) throws -> String {
        String(decoding: try #require(DashboardAssets.files[name]).bytes, as: UTF8.self)
    }

    @Test("The Connect drawer offers Plaid and SimpleFIN only, and Settings has no Teller keys")
    func noTellerPane() throws {
        let providers = try Self.asset("providers.js")
        let panes = try #require(providers.firstMatch(of: #/const PANES = \[(?<body>[\s\S]*?)\n\];/#)).output.body
        let ids = panes.matches(of: #/\[\s*"(\w+)",/#).map { String($0.output.1) }
        #expect(ids == ["plaid", "simplefin"])
        #expect(!providers.contains("teller.io") && !providers.contains("TellerConnect") && !providers.contains("tellerForm"))
        // Only the stubs accounts.js still imports remain.
        let tellerLines = providers.split(separator: "\n").filter { $0.lowercased().contains("teller") }
        #expect(tellerLines.count == 4)
        #expect(!(try Self.asset("settings.js")).lowercased().contains("teller"))
    }

    @Test("The comparison is in the Connect drawer, with no recommended badge")
    func fairChoice() throws {
        let providers = try Self.asset("providers.js")
        #expect(providers.contains("root.append(compareTable(), tabs)"))
        for row in ["Cost", "Setup", "Card bills (statement, minimum, due date)", "Merchant names and bank categories", "History", "Freshness", "Investments"] {
            #expect(providers.contains("[\"\(row)\""))
        }
        #expect(!providers.lowercased().contains("recommended\""))
        #expect(!providers.contains("the easiest"))
    }

    @Test("The CSP names Plaid for script, connect and frame only, and no Teller")
    func csp() {
        let csp = DashboardAssets.contentSecurityPolicy
        #expect(!csp.contains("teller"))
        #expect(csp.contains("script-src 'self' https://cdn.plaid.com https://*.plaid.com"))
        #expect(csp.contains("connect-src 'self' https://*.plaid.com"))
        #expect(csp.contains("frame-src https://*.plaid.com"))
        #expect(csp.contains("img-src 'self' data:;"))
    }

    @Test("Teller's routes are gone: keys and linking answer 404, and the token swap takes no Teller token")
    func routesGone() async throws {
        let (dash, _) = try await TestServer.app(surface: .dashboard)
        try await dash.test(.router) { client in
            try await client.execute(uri: "/dash/providers/teller", method: .put, headers: Self.write,
                                     body: TestServer.body(#"{"applicationID":"app_1","environment":"sandbox"}"#)) { #expect($0.status == .notFound) }
            try await client.execute(uri: "/dash/providers/teller", method: .delete, headers: Self.write) { #expect($0.status == .notFound) }
            try await client.execute(uri: "/v1/links/teller", method: .post, headers: Self.write,
                                     body: TestServer.body(#"{"accessToken":"t","institution":"Harbor"}"#)) { #expect($0.status == .notFound) }
            // The token swap is SimpleFIN's only now: a Teller {accessToken} body is refused (SimpleFINSyncTests has the rest).
            try await client.execute(uri: "/v1/links/teller-enr_1/token", method: .put, headers: Self.write,
                                     body: TestServer.body(#"{"accessToken":"t","enrollmentID":"enr_1"}"#)) { #expect($0.status == .badRequest) }
            try await client.execute(uri: "/dash/summary", method: .get) { response in
                #expect(response.status == .ok)
                let body = try #require(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
                let settings = try #require(body["settings"] as? [String: Any])
                #expect(settings["plaid"] != nil && settings["teller"] == nil)
            }
        }
    }

    @Test("A stored Teller link still loads, lists, syncs to the shut-down note, and can be removed")
    func storedLinkDecodes() async throws {
        let (dash, service) = try await TestServer.app(seedDemo: false, surface: .dashboard)
        let sealed = try #require(try service.sealer?.seal("tok-1"))
        try await service.store.upsertLink(StoredLink(id: "teller-enr_1", provider: .teller, institution: "Harbor", externalID: "enr_1", sealedToken: sealed,
                                                      cursor: nil, status: .connected, lastSync: nil, lastError: nil, createdAt: Date()))
        try await dash.test(.router) { client in
            try await client.execute(uri: "/v1/links/teller-enr_1/sync", method: .post, headers: Self.write) { response in
                #expect(response.status == .ok)
                let result = try RemoteBudgetAPI.decoder.decode(LinkSyncResult.self, from: Data(response.body.readableBytesView))
                #expect(!result.ok && result.error == SyncService.tellerGone)
            }
            try await client.execute(uri: "/v1/links", method: .get) { response in
                let links = try RemoteBudgetAPI.decoder.decode([LinkSummary].self, from: Data(response.body.readableBytesView))
                #expect(links.map(\.provider) == [.teller])
                #expect(links.first?.lastError == SyncService.tellerGone)
            }
            // "Sync everything" leaves it out: it can't recover, so nothing retries it.
            try await client.execute(uri: "/v1/sync", method: .post, headers: Self.write) { response in
                #expect(response.status == .ok)
                let results = try RemoteBudgetAPI.decoder.decode([LinkSyncResult].self, from: Data(response.body.readableBytesView))
                #expect(results.isEmpty)
            }
            try await client.execute(uri: "/v1/links/teller-enr_1", method: .delete, headers: Self.write) { #expect($0.status == .noContent) }
        }
        #expect(try await service.store.links().isEmpty)
    }

    @Test("The phone's note for a stored Teller link names the shut-down, not a retry")
    func phoneNote() {
        let link = StoredLink(id: "teller-enr_1", provider: .teller, institution: "Harbor", externalID: "enr_1", sealedToken: "x",
                              cursor: nil, status: .connected, lastSync: nil, lastError: SyncService.tellerGone, createdAt: Date())
        #expect(SyncService.note(link, Date.FormatStyle()) == SyncService.tellerGone)
    }

    @Test("Plaid's update mode is only for Plaid links")
    func plaidUpdateModeOnlyForPlaid() async throws {
        let (dash, service) = try await TestServer.app(seedDemo: false, surface: .dashboard)
        let sealed = try #require(try service.sealer?.seal("https://user:pass@bridge.example/simplefin"))
        try await service.store.upsertLink(StoredLink(id: "simplefin-1", provider: .simplefin, institution: "SimpleFIN Bridge", externalID: nil, sealedToken: sealed,
                                                      cursor: nil, status: .connected, lastSync: nil, lastError: nil, createdAt: Date()))
        try await dash.test(.router) { client in
            try await client.execute(uri: "/v1/links/plaid/token", method: .post, headers: Self.write,
                                     body: TestServer.body(#"{"linkID":"simplefin-1"}"#)) { response in
                #expect(response.status == .unprocessableContent)
                #expect(String(buffer: response.body).contains("not Plaid"))
            }
        }
    }
}
