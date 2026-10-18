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

/// Server 0.6.2, from the setup audit: the SimpleFIN add route checks the sealer before spending the one-time token, a
/// throwaway server has a made-up SimpleFIN bridge, and the Plaid return address works on a computer install.
@Suite("Setup audit (server 0.6.2)")
struct SetupAuditTests {
    static func json(_ response: TestResponse) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
    }

    /// The answer's `error` sentence (JSON escapes its slashes), or the raw body.
    static func text(_ response: TestResponse) -> String {
        let object = try? JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any]
        return object?["error"] as? String ?? String(buffer: response.body)
    }

    static func post(_ client: some TestClientProtocol, _ uri: String, _ body: String, headers: HTTPFields = TestServer.dash,
                     check: @escaping (TestResponse) throws -> Void) async throws {
        try await client.execute(uri: uri, method: .post, headers: headers, body: TestServer.body(body)) { try check($0) }
    }

    // MARK: SimpleFIN: the sealer before the claim

    @Test("Without BUDGET_TOKEN_KEY, adding a SimpleFIN link is refused before the setup token is claimed")
    func simplefinChecksSealerFirst() async throws {
        var config = TestServer.config()
        config.tokenKey = nil
        let bridge = FakeBridge([SimpleFINSyncTests.harbor])
        let (app, service) = try await TestServer.app(seedDemo: false, plaid: bridge, surface: .dashboard, config: config)
        try await app.test(.router) { client in
            try await Self.post(client, "/v1/links/simplefin", #"{"setupToken": "\#(FakeBridge.setupToken)"}"#) { response in
                #expect(response.status == .unprocessableContent)
                #expect(Self.text(response).contains("BUDGET_TOKEN_KEY"))
            }
        }
        // The one-time token is still good: nothing went to the bridge.
        #expect(bridge.claimed == 0 && bridge.requestCount == 0)
        #expect(try await service.store.links().isEmpty)
    }

    // MARK: SimpleFIN: the test bridge

    @Test("A throwaway server links the test SimpleFIN token in process: two banks, three accounts, rows, no network")
    func testBridgeLinksOnThrowaway() async throws {
        let outside = ScriptedProvider([:])
        let (app, service) = try await TestServer.app(seedDemo: false, plaid: outside, surface: .dashboard)
        #expect(service.config.isThrowaway)
        try await app.test(.router) { client in
            var linkID = ""
            try await Self.post(client, "/v1/links/simplefin", #"{"setupToken": "\#(TestSimpleFIN.setupToken)"}"#) { response in
                #expect(response.status == .created)
                let result = try RemoteBudgetAPI.decoder.decode(LinkSyncResult.self, from: Data(response.body.readableBytesView))
                #expect(result.ok)
                #expect((result.report?.accountsAdded ?? 0) == 3)
                #expect((result.report?.rowsAdded ?? 0) >= 10)
                linkID = result.linkID
            }
            // A sync the person asks for answers from the same bridge.
            try await client.execute(uri: "/v1/links/\(linkID)/sync", method: .post, headers: TestServer.dash) { response in
                #expect(response.status == .ok)
                let result = try RemoteBudgetAPI.decoder.decode(LinkSyncResult.self, from: Data(response.body.readableBytesView))
                #expect(result.ok && result.error == nil)
            }
        }
        let link = try #require(try await service.store.links().first)
        #expect(link.provider == .simplefin && link.status == .connected)
        #expect(link.summary.banks?.map(\.name).sorted() == ["Sample Card Bank", "Sample Credit Union"])
        let accounts = await service.api.state.accounts.filter { $0.id.hasPrefix(SimpleFINSource.ledgerAccountID("TEST-")) }
        #expect(accounts.count == 3)
        #expect(outside.requests.isEmpty)
    }

    @Test("The test SimpleFIN token is refused on a server with a database, before anything is sent")
    func testBridgeRefusedOnRealServer() async throws {
        var config = TestServer.config()
        config.database = .init(host: "db.invalid", port: 5432, username: "budget", password: nil, database: "budget")
        #expect(!config.isThrowaway)
        let outside = ScriptedProvider([:])
        let (app, service) = try await TestServer.app(seedDemo: false, plaid: outside, surface: .dashboard, config: config)
        try await app.test(.router) { client in
            try await Self.post(client, "/v1/links/simplefin", #"{"setupToken": "\#(TestSimpleFIN.setupToken)"}"#) { response in
                #expect(response.status == .unprocessableContent)
                #expect(Self.text(response).contains("test server"))
            }
        }
        #expect(outside.requests.isEmpty)
        #expect(try await service.store.links().isEmpty)
    }

    @Test("Without BUDGET_ALLOW_DEMO the test token is refused too, and the bridge isn't installed")
    func testBridgeNeedsDemoAllowance() async throws {
        var config = TestServer.config()
        config.allowDemo = false
        let outside = ScriptedProvider([:])
        let (app, service) = try await TestServer.app(seedDemo: false, plaid: outside, surface: .dashboard, config: config)
        #expect(!(service.providers.transport is TestSimpleFIN.Bridge))
        try await app.test(.router) { client in
            try await Self.post(client, "/v1/links/simplefin", #"{"setupToken": "\#(TestSimpleFIN.setupToken)"}"#) { response in
                #expect(response.status == .unprocessableContent)
            }
        }
        #expect(outside.requests.isEmpty)
    }

    @Test("The test token decodes to the documented claim address on a host that never resolves")
    func testTokenShape() throws {
        let url = try SimpleFINSource.claimURL(fromSetupToken: TestSimpleFIN.setupToken)
        #expect(url.absoluteString == "https://simplefin-test.budget.invalid/claim/demo")
        #expect(TestSimpleFIN.isTestToken(TestSimpleFIN.setupToken) && !TestSimpleFIN.isTestToken(FakeBridge.setupToken))
    }

    @Test("The test bridge passes other hosts through untouched")
    func testBridgeForwards() async throws {
        let outside = ScriptedProvider(["/link/token/create": [(200, #"{"link_token": "link-sandbox-1"}"#)]])
        let bridge = TestSimpleFIN.Bridge(inner: outside)
        var request = URLRequest(url: URL(string: "https://sandbox.plaid.com/link/token/create")!)
        request.httpMethod = "POST"
        let (_, response) = try await bridge.send(request)
        #expect(response.statusCode == 200 && outside.count("/link/token/create") == 1)
    }

    // MARK: Plaid: the return address

    @Test("This computer's own names are local; real names and other addresses aren't")
    func localNames() {
        for host in ["localhost", "budget.localhost", "budget.localhost:8081", "127.0.0.1", "127.0.0.1:8081", "[::1]:8081", "::1", "0.0.0.0", "LOCALHOST."] {
            #expect(PlaidRedirect.isLocalHost(host), "\(host)")
        }
        for host in ["budget1.example.olares.com", "budget.example.com:443", "10.0.0.5", "localhost.example.com"] {
            #expect(!PlaidRedirect.isLocalHost(host), "\(host)")
        }
        #expect(PlaidRedirect.usable("https://budget.localhost:8081/") == nil)
        #expect(PlaidRedirect.usable("http://budget.example.com/") == nil)
        #expect(PlaidRedirect.usable("  ") == nil)
        #expect(PlaidRedirect.usable("https://budget1.example.olares.com/") == "https://budget1.example.olares.com/")
    }

    @Test("The dashboard suggests its own address only when it was reached over https at a real name")
    func suggestion() {
        // A computer install: plain http on loopback, no proxy.
        #expect(PlaidRedirect.suggestion(forwardedProto: nil, forwardedHost: nil, host: "budget.localhost:8081") == nil)
        #expect(PlaidRedirect.suggestion(forwardedProto: nil, forwardedHost: nil, host: "127.0.0.1:8081") == nil)
        #expect(PlaidRedirect.suggestion(forwardedProto: "https", forwardedHost: "budget.localhost", host: nil) == nil)
        // An SSH tunnel or LAN address over http.
        #expect(PlaidRedirect.suggestion(forwardedProto: "http", forwardedHost: "budget.example.com", host: nil) == nil)
        #expect(PlaidRedirect.suggestion(forwardedProto: nil, forwardedHost: nil, host: "192.168.1.20:8081") == nil)
        // Olares or a tunnel in front.
        #expect(PlaidRedirect.suggestion(forwardedProto: "https", forwardedHost: "budget1.example.olares.com", host: "10.0.0.5:8081")
                == "https://budget1.example.olares.com/")
        #expect(PlaidRedirect.suggestion(forwardedProto: "https,http", forwardedHost: nil, host: "budget1.example.olares.com")
                == "https://budget1.example.olares.com/")
        #expect(PlaidRedirect.suggestion(forwardedProto: nil, forwardedHost: "budget1.example.olares.com", host: nil) == "https://budget1.example.olares.com/")
    }

    @Test("GET /dash/providers suggests nothing on a loopback dashboard, its https address behind a proxy, and the phone's return address")
    func providersRoute() async throws {
        var config = TestServer.config()
        config.publicURL = "https://budget-api.example.com"
        let (app, _) = try await TestServer.app(surface: .dashboard, config: config)
        try await app.test(.router) { client in
            let local: HTTPFields = [HTTPField.Name("X-Forwarded-Host")!: "budget.localhost:8081"]
            try await client.execute(uri: "/dash/providers", method: .get, headers: local) { response in
                let json = try Self.json(response)
                #expect(json["suggestedRedirectURI"] == nil || json["suggestedRedirectURI"] is NSNull)
                #expect(json["phoneReturnURI"] as? String == "https://budget-api.example.com/plaid/oauth-return")
            }
            let proxied: HTTPFields = [HTTPField.Name("X-Forwarded-Host")!: "budget1.example.olares.com", HTTPField.Name("X-Forwarded-Proto")!: "https"]
            try await client.execute(uri: "/dash/providers", method: .get, headers: proxied) { response in
                let json = try Self.json(response)
                #expect(json["suggestedRedirectURI"] as? String == "https://budget1.example.olares.com/")
            }
        }
    }

    static let keys = #"{"clientID": "0123456789abcdef01234567", "secret": "0123456789abcdef0123456789abcd", "environment": "sandbox", "redirectURI": "REDIRECT"}"#

    @Test("Saving keys refuses a return address on this computer's own name, and takes an https one with a real name")
    func savingRefusesLocalRedirect() async throws {
        let (app, service) = try await TestServer.app(surface: .dashboard)
        try await app.test(.router) { client in
            for bad in ["https://budget.localhost:8081/", "https://127.0.0.1:8081/", "http://budget.example.com/"] {
                try await client.execute(uri: "/dash/providers/plaid", method: .put, headers: TestServer.dash,
                                         body: TestServer.body(Self.keys.replacingOccurrences(of: "REDIRECT", with: bad))) { response in
                    #expect(response.status == .unprocessableContent, "\(bad)")
                    #expect(Self.text(response).contains("empty"), "\(bad)")
                }
            }
            try await client.execute(uri: "/dash/providers/plaid", method: .put, headers: TestServer.dash,
                                     body: TestServer.body(Self.keys.replacingOccurrences(of: "REDIRECT", with: "https://budget1.example.olares.com/"))) { response in
                #expect(response.status == .ok)
            }
        }
        #expect(try await service.providers.plaid()?.redirectURI == "https://budget1.example.olares.com/")
    }

    @Test("A localhost return address saved before 0.6.2 is ignored: the link token goes without redirect_uri")
    func savedLocalRedirectIgnored() async throws {
        let plaid = ScriptedProvider(["/link/token/create": [(200, #"{"link_token": "link-sandbox-1"}"#)]])
        let store = MemoryStore()
        let sealer = try TokenSealer(base64Key: TestServer.key)
        try await store.saveProviderSettings(StoredProviderSettings(plaid: .init(
            clientID: "0123456789abcdef01234567", sealedSecret: try sealer.seal("0123456789abcdef0123456789abcd"),
            environment: "sandbox", redirectURI: "https://budget.localhost:8081/")))
        let (service, _) = try await BudgetServerApp.makeService(config: TestServer.config(), store: store, logger: Logger(label: "test"), plaidTransport: plaid)
        try await BudgetServerApp.prepare(service)
        let app = Application(router: buildRouter(service, surface: .dashboard))
        #expect(try await service.providers.plaid()?.redirectURI == nil)
        #expect(await service.providers.summary().plaid.redirectURI == nil)
        try await app.test(.router) { client in
            try await Self.post(client, "/v1/links/plaid/token", "{}") { #expect($0.status == .ok) }
        }
        let sent = try #require(plaid.requests.first { $0.path == "/link/token/create" })
        #expect(!sent.body.contains("redirect_uri"))
    }

    @Test("Plaid refusing the return address says so, instead of blaming the keys")
    func unknownReturnAddress() async throws {
        let refusal = (400, #"{"error_type": "INVALID_REQUEST", "error_code": "INVALID_FIELD", "error_message": "OAuth redirect URI must be configured in the developer dashboard.", "request_id": "req-1"}"#)
        let plaid = ScriptedProvider(["/link/token/create": [refusal]])
        var config = TestServer.config()
        config.plaid?.redirectURI = "https://budget1.example.olares.com/"
        let (app, _) = try await TestServer.app(plaid: plaid, surface: .dashboard, config: config)
        try await app.test(.router) { client in
            try await Self.post(client, "/v1/links/plaid/token", "{}") { response in
                #expect(response.status == .unprocessableContent)
                let message = Self.text(response)
                #expect(message.contains("return address https://budget1.example.olares.com/"))
                #expect(message.contains("https://dashboard.plaid.com/developers/api"))
            }
        }
        // Without a return address, the same code isn't about one: Plaid's own answer stands.
        let other = ScriptedProvider(["/link/token/create": [refusal]])
        let (plain, _) = try await TestServer.app(plaid: other, surface: .dashboard)
        try await plain.test(.router) { client in
            try await Self.post(client, "/v1/links/plaid/token", "{}") { response in
                #expect(response.status == .badGateway)
                #expect(!Self.text(response).contains("return address"))
            }
        }
    }

    @Test("Server version is 0.6.2")
    func version() { #expect(BudgetServerVersion.current == "0.6.2") }
}
