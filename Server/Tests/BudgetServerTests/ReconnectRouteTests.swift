import BudgetKit
@testable import BudgetServerCore
import Crypto
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import NIOCore
import Testing

@Suite("Reconnect from the phone (P0.5, Hosted Link update mode)")
struct ReconnectRouteTests {
    static let id = PlaidErrorKindTests.id
    static let start = ItemCheckTests.start
    static let publicURL = "https://budget.example"
    static let mobileRedirect = "https://budget.example/plaid/oauth-return"
    // Stand-ins for Plaid's secrets, distinctive enough to search the logs for.
    static let linkToken = "link-sandbox-SECRETLINKTOKEN"
    static let hostedURL = "https://secure.plaid.com/hl/SECRETHOSTEDURL"
    static let publicToken = "public-sandbox-SECRETPUBLICTOKEN"

    static let created = (200, #"{"link_token": "\#(linkToken)", "hosted_link_url": "\#(hostedURL)", "expiration": "2026-10-15T09:00:00Z", "request_id": "req-lt"}"#)
    static let pending = (200, #"{"link_token": "\#(linkToken)", "link_sessions": [], "request_id": "req-get"}"#)
    static let succeeded = (200, #"{"link_token": "\#(linkToken)", "link_sessions": [{"link_session_id": "s1", "started_at": "2026-10-15T08:31:00Z", "finished_at": "2026-10-15T08:33:00Z", "on_success": {"public_token": "\#(publicToken)", "metadata": {"institution": {"name": "Harbor", "institution_id": "ins_3"}}}}], "request_id": "req-get"}"#)
    static let exited = (200, #"{"link_token": "\#(linkToken)", "link_sessions": [{"link_session_id": "s1", "started_at": "2026-10-15T08:31:00Z", "finished_at": "2026-10-15T08:33:00Z", "exit": {"error": null, "metadata": {"status": "requires_credentials"}}}], "request_id": "req-get"}"#)

    static func provider(create: [(Int, String)] = [created], get: [(Int, String)] = [pending], item: [(Int, String)] = [ItemCheckTests.item()],
                         delay: Duration = .zero) -> ScriptedProvider {
        ScriptedProvider([
            "/link/token/create": create,
            "/link/token/get": get,
            "/item/get": item,
            "/item/webhook/update": [(200, #"{"request_id": "req-wh"}"#)],
            "/transactions/sync": [PlaidScript.page("c1", PlaidScript.row)],
            "/accounts/get": [PlaidScript.balances],
        ], delay: delay)
    }

    struct Fixture {
        var app: Application<RouterResponder<BasicRequestContext>>
        var service: BudgetService
        var plaid: ScriptedProvider
        var clock: TestClock
        var log: CapturedLog

        func link() async throws -> StoredLink { try await PlaidErrorKindTests.link(service) }
        func bodies(_ path: String) -> [String] { plaid.requests.filter { $0.path == path }.map(\.body) }
        func json(_ body: String) throws -> [String: Any] { try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]) }
    }

    /// A server with one Plaid link that needs a sign-in (or is healthy), on the API surface.
    static func fixture(_ plaid: ScriptedProvider = provider(), needsSignIn: Bool = true, surface: Surface = .api,
                        edit: (inout ServerConfig) -> Void = { _ in },
                        link change: (inout StoredLink) -> Void = { _ in }) async throws -> Fixture {
        var config = TestServer.config()
        config.publicURL = publicURL
        edit(&config)
        let log = CapturedLog()
        let clock = TestClock(start)
        let (service, _) = try await BudgetServerApp.makeService(config: config, store: MemoryStore(), logger: log.logger, plaidTransport: plaid,
                                                                 clock: { clock.now })
        try await BudgetServerApp.prepare(service)
        var link = StoredLink(id: id, provider: .plaid, institution: "Harbor", externalID: "item-1",
                              sealedToken: try #require(try service.sealer?.seal("access-sandbox-9")), cursor: "c0",
                              status: needsSignIn ? .needsReauth : .connected, lastSync: nil, lastError: nil, createdAt: start)
        if needsSignIn {
            LinkHealthBook.recordFailure(&link, LinkFailure(kind: .needsSignIn, code: "ITEM_LOGIN_REQUIRED", message: "sign in"), now: start)
        }
        change(&link)
        try await service.store.upsertLink(link)
        return Fixture(app: Application(router: buildRouter(service, surface: surface)), service: service, plaid: plaid, clock: clock, log: log)
    }

    static func decode(_ response: TestResponse) throws -> ReconnectSession {
        try RemoteBudgetAPI.decoder.decode(ReconnectSession.self, from: Data(response.body.readableBytesView))
    }

    static let path = "/v1/links/\(id)/reconnect"

    /// POSTs a reconnect and returns the status, the body and the Cache-Control header.
    static func post(_ client: some TestClientProtocol, _ linkID: String = id) async throws -> (HTTPResponse.Status, String, String?) {
        try await client.execute(uri: "/v1/links/\(linkID)/reconnect", method: .post, headers: TestServer.auth, body: TestServer.body("{}")) {
            ($0.status, String(buffer: $0.body), $0.headers[.cacheControl])
        }
    }

    static func poll(_ client: some TestClientProtocol, _ session: String, linkID: String = id) async throws -> (HTTPResponse.Status, String, String?) {
        try await client.execute(uri: "/v1/links/\(linkID)/reconnect/\(session)", method: .get, headers: TestServer.auth) {
            ($0.status, String(buffer: $0.body), $0.headers[.cacheControl])
        }
    }

    /// Polls until the session leaves waiting/syncing (the confirmation and sync run in a task after the poll answers).
    static func settle(_ client: some TestClientProtocol, _ session: String) async throws -> ReconnectSession {
        for _ in 0..<200 {
            let (status, body, _) = try await poll(client, session)
            #expect(status == .ok)
            let decoded = try RemoteBudgetAPI.decoder.decode(ReconnectSession.self, from: Data(body.utf8))
            if decoded.state != .waiting && decoded.state != .syncing { return decoded }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the session never settled")
        throw ReconnectError.notFound
    }

    static func session(_ body: String) throws -> ReconnectSession {
        try RemoteBudgetAPI.decoder.decode(ReconnectSession.self, from: Data(body.utf8))
    }

    // MARK: Starting

    @Test("The link token is update mode for the Item: access_token, products [], the mobile redirect, the webhook and Hosted Link")
    func tokenBody() async throws {
        let f = try await Self.fixture()
        try await f.app.test(.router) { client in
            let (status, body, cache) = try await Self.post(client)
            #expect(status == .created)
            #expect(cache == "no-store")
            let session = try Self.session(body)
            #expect(session.state == .waiting)
            #expect(session.url == Self.hostedURL)
            #expect(session.callbackScheme == "budgetapp-plaid")
            #expect(session.linkID == Self.id)
            #expect(session.id.count == 64)
            #expect(session.expiresAt == Self.start.addingTimeInterval(900))
        }
        let sent = try f.json(try #require(f.bodies("/link/token/create").first))
        #expect(sent["access_token"] as? String == "access-sandbox-9")
        #expect((sent["products"] as? [Any])?.isEmpty == true)
        #expect(sent["redirect_uri"] as? String == Self.mobileRedirect)
        #expect(sent["webhook"] as? String == "https://budget.example/v1/plaid/webhook")
        let hosted = try #require(sent["hosted_link"] as? [String: Any])
        #expect(hosted["completion_redirect_uri"] as? String == "budgetapp-plaid://reconnect-done")
        #expect(hosted["is_mobile_app"] as? Bool == true)
        #expect(hosted["url_lifetime_seconds"] as? Int == 900)
        #expect(sent["additional_consented_products"] == nil)
        // A broken sign-in is plain update mode; reauthorization is only for renewing a healthy Item.
        #expect(sent["update"] == nil)
        #expect(f.plaid.count("/item/public_token/exchange") == 0)
    }

    @Test("Renewing a healthy Item asks for Plaid's reauthorization flow, and never account selection")
    func renewal() async throws {
        let f = try await Self.fixture(needsSignIn: false)
        try await f.app.test(.router) { client in
            let status = try await Self.post(client).0
            #expect(status == .created)
        }
        let sent = try f.json(try #require(f.bodies("/link/token/create").first))
        let update = try #require(sent["update"] as? [String: Any])
        #expect(update["reauthorization_enabled"] as? Bool == true)
        #expect(update["account_selection_enabled"] == nil)
    }

    @Test("A link that isn't Plaid's, whose access was withdrawn, whose Item is gone, or whose token won't open: 422 with no Plaid call")
    func refusedBeforePlaid() async throws {
        let cases: [(String, (inout StoredLink) -> Void)] = [
            ("SimpleFIN", { $0.provider = .simplefin }),
            ("revoked", { LinkHealthBook.recordFailure(&$0, LinkFailure(kind: .revoked, code: "USER_PERMISSION_REVOKED", message: "x"), now: Self.start) }),
            ("Item gone", { $0.sealedToken = "" }),
            ("unsealable", { $0.sealedToken = "not-a-sealed-token" }),
        ]
        for (name, change) in cases {
            let f = try await Self.fixture(link: change)
            try await f.app.test(.router) { client in
                let (status, body, cache) = try await Self.post(client)
                #expect(status == .unprocessableContent, "\(name)")
                #expect(cache == "no-store")
                #expect(body.contains("\"error\""), "\(name)")
            }
            #expect(f.plaid.count("/link/token/create") == 0, "\(name)")
        }
        let f = try await Self.fixture()
        try await f.app.test(.router) { client in
            let status = try await Self.post(client, "plaid-nope").0
            #expect(status == .notFound)
        }
        #expect(f.plaid.count("/link/token/create") == 0)
    }

    @Test("Plaid not set up, or no public URL: 422 providerSetup with no Plaid call")
    func setupMissing() async throws {
        for edit in [{ (c: inout ServerConfig) in c.plaid = nil }, { (c: inout ServerConfig) in c.publicURL = nil }] {
            let f = try await Self.fixture(edit: edit)
            try await f.app.test(.router) { client in
                let (status, body, _) = try await Self.post(client)
                #expect(status == .unprocessableContent)
                #expect(body.contains("providerSetup"))
            }
            #expect(f.plaid.count("/link/token/create") == 0)
        }
    }

    @Test("A waiting session with more than 5 minutes left is handed out again, URL and all; with less, a new one")
    func reuse() async throws {
        let f = try await Self.fixture()
        try await f.app.test(.router) { client in
            let first = try Self.session(try await Self.post(client).1)
            f.clock.set(Self.start.addingTimeInterval(9 * 60))
            let (status, body, _) = try await Self.post(client)
            #expect(status == .created)
            let again = try Self.session(body)
            #expect(again.id == first.id)
            #expect(again.url == Self.hostedURL)
            #expect(f.plaid.count("/link/token/create") == 1)
            // 4 minutes left: a fresh session, and the old one gives way.
            f.clock.set(Self.start.addingTimeInterval(11 * 60))
            let fresh = try Self.session(try await Self.post(client).1)
            #expect(fresh.id != first.id)
            #expect(f.plaid.count("/link/token/create") == 2)
            #expect(try Self.session(try await Self.poll(client, first.id).1).state == .expired)
        }
    }

    @Test("Two taps at once start one session")
    func concurrentStarts() async throws {
        let f = try await Self.fixture(Self.provider(delay: .milliseconds(100)))
        try await f.app.test(.router) { client in
            async let a = Self.post(client)
            async let b = Self.post(client)
            let (one, two) = try await (a, b)
            #expect(try Self.session(one.1).id == Self.session(two.1).id)
        }
        #expect(f.plaid.count("/link/token/create") == 1)
    }

    @Test("At most 5 new sessions an hour per link: the 6th is 429")
    func hourlyLimit() async throws {
        let f = try await Self.fixture()
        try await f.app.test(.router) { client in
            for n in 0..<5 {
                f.clock.set(Self.start.addingTimeInterval(Double(n) * 11 * 60))
                let status = try await Self.post(client).0
                #expect(status == .created)
            }
            f.clock.set(Self.start.addingTimeInterval(55 * 60))
            let (status, _, cache) = try await Self.post(client)
            #expect(status == .tooManyRequests)
            #expect(cache == "no-store")
            #expect(f.plaid.count("/link/token/create") == 5)
            // An hour after the first, one more is allowed.
            f.clock.set(Self.start.addingTimeInterval(61 * 60))
            let later = try await Self.post(client).0
            #expect(later == .created)
        }
    }

    @Test("At most 10 new sessions a day per link")
    func dailyLimit() async throws {
        let f = try await Self.fixture()
        try await f.app.test(.router) { client in
            for n in 0..<10 {
                f.clock.set(Self.start.addingTimeInterval(Double(n) * 2 * 3600))
                let status = try await Self.post(client).0
                #expect(status == .created)
            }
            f.clock.set(Self.start.addingTimeInterval(20 * 3600))
            let status = try await Self.post(client).0
            #expect(status == .tooManyRequests)
            f.clock.set(Self.start.addingTimeInterval(24 * 3600 + 60))
            let nextDay = try await Self.post(client).0
            #expect(nextDay == .created)
        }
    }

    // MARK: Polling

    @Test("Finished → /item/get → syncing → done, with the sync's result, the link repaired and nothing exchanged")
    func success() async throws {
        let f = try await Self.fixture(Self.provider(get: [Self.pending, Self.succeeded]))
        try await f.app.test(.router) { client in
            let session = try Self.session(try await Self.post(client).1)
            let (status, body, cache) = try await Self.poll(client, session.id)
            #expect(status == .ok)
            #expect(cache == "no-store")
            #expect(try Self.session(body).state == .waiting)
            #expect(!body.contains("\"url\""))
            f.clock.set(Self.start.addingTimeInterval(5))
            let done = try await Self.settle(client, session.id)
            #expect(done.state == .done)
            #expect(done.result?.ok == true)
            #expect(done.result?.report?.rowsAdded == 1)
            #expect(done.url == nil)
            // Polling after the end asks Plaid nothing more.
            #expect(!(try await Self.poll(client, session.id).1.contains("\"url\"")))
        }
        #expect(f.plaid.count("/link/token/get") == 2)
        #expect(f.plaid.count("/item/get") == 1)
        #expect(f.plaid.count("/item/public_token/exchange") == 0)
        let link = try await f.link()
        #expect(link.status == .connected)
        #expect(link.errorKind == nil)
        #expect(link.firstFailedAt == nil)
        #expect(link.cursor == "c1")
        // Every Plaid request this made carried the Item's access token, except reading the Link session.
        for request in f.plaid.requests where request.path != "/link/token/get" {
            #expect(request.body.contains("access-sandbox-9"), "\(request.path)")
        }
        for request in f.plaid.requests {
            #expect(!request.body.contains("account_selection_enabled"))
            #expect(!request.body.contains("additional_consented_products"))
        }
        // The published institution says the phone can repair it.
        #expect(try await f.service.api.serverStatus().institutions.first { $0.id == Self.id }?.reconnect == .phone)
    }

    @Test("Plaid's link and public tokens, the hosted URL and the access token never reach a log line")
    func secretsStayOutOfLogs() async throws {
        let f = try await Self.fixture(Self.provider(get: [Self.succeeded]))
        try await f.app.test(.router) { client in
            let session = try Self.session(try await Self.post(client).1)
            #expect(try await Self.settle(client, session.id).state == .done)
            for line in f.log.lines {
                for secret in [Self.linkToken, Self.hostedURL, "SECRETHOSTEDURL", Self.publicToken, "access-sandbox-9", session.id] {
                    #expect(!line.contains(secret), "\(line)")
                }
            }
        }
        #expect(f.log.lines.contains { $0.contains("reconnect started for Harbor") && $0.contains("req-lt") })
    }

    @Test("Plaid's exit → exited, the link left as it was")
    func exit() async throws {
        let f = try await Self.fixture(Self.provider(get: [Self.exited]))
        try await f.app.test(.router) { client in
            let session = try Self.session(try await Self.post(client).1)
            let (_, body, _) = try await Self.poll(client, session.id)
            let ended = try Self.session(body)
            #expect(ended.state == .exited)
            #expect(ended.message?.contains("Harbor") == true)
        }
        #expect(f.plaid.count("/item/get") == 0)
        #expect(try await f.link().status == .needsReauth)
    }

    @Test("Past the page's 15 minutes a session still waits while the link token lasts; past the token's 30 it's expired, without asking Plaid")
    func expiry() async throws {
        let f = try await Self.fixture()
        try await f.app.test(.router) { client in
            let session = try Self.session(try await Self.post(client).1)
            f.clock.set(Self.start.addingTimeInterval(901))
            #expect(try Self.session(try await Self.poll(client, session.id).1).state == .waiting)
            #expect(f.plaid.count("/link/token/get") == 1)
            f.clock.set(Self.start.addingTimeInterval(1800))
            #expect(try Self.session(try await Self.poll(client, session.id).1).state == .expired)
        }
        #expect(f.plaid.count("/link/token/get") == 1)
    }

    @Test("Plaid is asked how the session went at most every 5 seconds")
    func lookSpacing() async throws {
        let f = try await Self.fixture()
        try await f.app.test(.router) { client in
            let session = try Self.session(try await Self.post(client).1)
            _ = try await Self.poll(client, session.id)
            _ = try await Self.poll(client, session.id)
            f.clock.set(Self.start.addingTimeInterval(4))
            _ = try await Self.poll(client, session.id)
            #expect(f.plaid.count("/link/token/get") == 1)
            f.clock.set(Self.start.addingTimeInterval(5))
            _ = try await Self.poll(client, session.id)
            #expect(f.plaid.count("/link/token/get") == 2)
        }
    }

    @Test("A session under another link's id, or an unknown one, is 404")
    func wrongIDs() async throws {
        let f = try await Self.fixture()
        try await f.app.test(.router) { client in
            let session = try Self.session(try await Self.post(client).1)
            let (status, _, cache) = try await Self.poll(client, session.id, linkID: "plaid-other")
            #expect(status == .notFound)
            #expect(cache == "no-store")
            let unknown = try await Self.poll(client, String(repeating: "0", count: 64)).0
            #expect(unknown == .notFound)
        }
    }

    @Test("Finished, but /item/get still reports a sign-in error: failed, and no sync")
    func stillBroken() async throws {
        let f = try await Self.fixture(Self.provider(get: [Self.succeeded], item: [ItemCheckTests.item(error: "ITEM_LOGIN_REQUIRED")]))
        try await f.app.test(.router) { client in
            let session = try Self.session(try await Self.post(client).1)
            let ended = try await Self.settle(client, session.id)
            #expect(ended.state == .failed)
            #expect(ended.message?.contains("Harbor") == true)
        }
        #expect(f.plaid.count("/transactions/sync") == 0)
        #expect(try await f.link().status == .needsReauth)
    }

    @Test("A LINK/SESSION_FINISHED webhook moves the session on before the next poll")
    func webhookFinishes() async throws {
        let f = try await Self.fixture(Self.provider(get: [Self.succeeded]))
        try await f.app.test(.router) { client in
            let session = try Self.session(try await Self.post(client).1)
            await f.service.reconnects.check(linkTokenHash: PlaidWebhookVerifier.hex(SHA256.hash(data: Data(Self.linkToken.utf8))))
            // The look runs in its own task, after check has returned.
            for _ in 0..<200 where f.plaid.count("/link/token/get") == 0 { try await Task.sleep(for: .milliseconds(5)) }
            #expect(f.plaid.count("/link/token/get") == 1)
            #expect(try await Self.settle(client, session.id).state == .done)
            // The settle polls didn't ask again: the webhook's look already moved it on.
            #expect(f.plaid.count("/link/token/get") == 1)
        }
    }

    // MARK: Setup errors and the mobile redirect

    @Test("A redirect URI Plaid hasn't allowed → 422 providerSetup naming the URI to add")
    func redirectNotAllowed() async throws {
        let refusal = PlaidErrorKindTests.plaidError("INVALID_FIELD", type: "INVALID_REQUEST")
        let f = try await Self.fixture(Self.provider(create: [refusal]))
        try await f.app.test(.router) { client in
            let (status, body, cache) = try await Self.post(client)
            #expect(status == .unprocessableContent)
            #expect(cache == "no-store")
            let json = try f.json(body)
            #expect(json["errorKind"] as? String == "providerSetup")
            #expect((json["error"] as? String)?.contains(Self.mobileRedirect) == true)
            #expect((json["error"] as? String)?.contains("Hosted Link") == true)
        }
        #expect(f.log.lines.contains { $0.contains("INVALID_FIELD") && $0.contains("req-42") })
    }

    @Test("Plaid answers without a hosted URL → 422 providerSetup (Hosted Link not enabled)")
    func noHostedURL() async throws {
        let f = try await Self.fixture(Self.provider(create: [(200, #"{"link_token": "\#(Self.linkToken)", "request_id": "req-lt"}"#)]))
        try await f.app.test(.router) { client in
            let (status, body, _) = try await Self.post(client)
            #expect(status == .unprocessableContent)
            #expect(body.contains("providerSetup"))
        }
    }

    @Test("Production with PLAID_MOBILE_REDIRECT_URI=off: reconnect is the dashboard's and the POST is 422; sandbox falls back")
    func mobileRedirectOff() async throws {
        let production = try await Self.fixture(edit: { $0.plaid?.environment = .production; $0.plaidMobileRedirectURI = "off" })
        try await production.app.test(.router) { client in
            let (status, body, _) = try await Self.post(client)
            #expect(status == .unprocessableContent)
            #expect(body.contains("PLAID_MOBILE_REDIRECT_URI"))
        }
        #expect(production.plaid.count("/link/token/create") == 0)
        await production.service.sync.publishInstitutions()
        #expect(try await production.service.api.serverStatus().institutions.first { $0.id == Self.id }?.reconnect == .dashboard)

        let sandbox = try await Self.fixture(edit: { $0.plaidMobileRedirectURI = "off"; $0.plaid?.redirectURI = "https://dash.example/plaid" })
        try await sandbox.app.test(.router) { client in
            let status = try await Self.post(client).0
            #expect(status == .created)
        }
        let sent = try sandbox.json(try #require(sandbox.bodies("/link/token/create").first))
        #expect(sent["redirect_uri"] as? String == "https://dash.example/plaid")
        #expect((sent["hosted_link"] as? [String: Any])?["is_mobile_app"] as? Bool == false)

        let configured = try await Self.fixture(edit: { $0.plaid?.environment = .production; $0.iosAppID = "TEAMID.com.example.budget" })
        await configured.service.sync.publishInstitutions()
        #expect(try await configured.service.api.serverStatus().institutions.first { $0.id == Self.id }?.reconnect == .phone)
    }

    @Test("Production without BUDGET_IOS_APP_ID: the default redirect wouldn't open the app, so reconnect is the dashboard's and the POST is 422")
    func productionWithoutAppID() async throws {
        let f = try await Self.fixture(edit: { $0.plaid?.environment = .production })
        try await f.app.test(.router) { client in
            let (status, body, _) = try await Self.post(client)
            #expect(status == .unprocessableContent)
            #expect(body.contains("BUDGET_IOS_APP_ID"))
        }
        #expect(f.plaid.count("/link/token/create") == 0)
        await f.service.sync.publishInstitutions()
        #expect(try await f.service.api.serverStatus().institutions.first { $0.id == Self.id }?.reconnect == .dashboard)
        // An explicit PLAID_MOBILE_REDIRECT_URI is the operator's choice, trusted as given.
        let explicit = try await Self.fixture(edit: { $0.plaid?.environment = .production; $0.plaidMobileRedirectURI = Self.mobileRedirect })
        await explicit.service.sync.publishInstitutions()
        #expect(try await explicit.service.api.serverStatus().institutions.first { $0.id == Self.id }?.reconnect == .phone)
    }

    @Test("Signed in (/item/get healthy) but the first sync failed: done, carrying the failed sync, not \"couldn't sign in\"")
    func signedInButSyncFailed() async throws {
        let plaid = ScriptedProvider([
            "/link/token/create": [Self.created],
            "/link/token/get": [Self.succeeded],
            "/item/get": [ItemCheckTests.item()],
            "/item/webhook/update": [(200, #"{"request_id": "req-wh"}"#)],
            "/transactions/sync": [PlaidErrorKindTests.plaidError("INSTITUTION_DOWN", type: "INSTITUTION_ERROR")],
        ])
        let f = try await Self.fixture(plaid, link: { link in link.plaid = PlaidLinkState(); link.plaid?.pendingDisconnectAt = Self.start.addingTimeInterval(-86_400) })
        try await f.app.test(.router) { client in
            let session = try Self.session(try await Self.post(client).1)
            let ended = try await Self.settle(client, session.id)
            #expect(ended.state == .done)
            #expect(ended.result?.ok == false)
            #expect(ended.result?.error != nil)
        }
        let link = try await f.link()
        #expect(link.status == .connected)
        #expect(link.plaid?.pendingDisconnectAt == nil)
    }

    @Test("How each link is repaired")
    func reconnectMethod() async throws {
        let f = try await Self.fixture()
        let link = try await f.link()
        #expect(ReconnectMethod.for(link, phoneCapable: true) == .phone)
        #expect(ReconnectMethod.for(link, phoneCapable: false) == .dashboard)
        var gone = link
        gone.sealedToken = ""
        #expect(ReconnectMethod.for(gone, phoneCapable: true) == .newLink)
        var revoked = link
        revoked.errorKind = .revoked
        #expect(ReconnectMethod.for(revoked, phoneCapable: true) == .newLink)
        var simplefin = link
        simplefin.provider = .simplefin
        #expect(ReconnectMethod.for(simplefin, phoneCapable: true) == .providerSite)
    }

    // MARK: App links

    @Test("apple-app-site-association names the app and the OAuth return path; the return page needs no token")
    func appLinks() async throws {
        let f = try await Self.fixture(edit: { $0.iosAppID = "ABCDE12345.com.example.budget" })
        try await f.app.test(.router) { client in
            try await client.execute(uri: "/.well-known/apple-app-site-association", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/json")
                let json = try #require(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
                let details = try #require((json["applinks"] as? [String: Any])?["details"] as? [[String: Any]])
                #expect(details.count == 1)
                #expect(details[0]["appIDs"] as? [String] == ["ABCDE12345.com.example.budget"])
                #expect(details[0]["components"] as? [[String: String]] == [["/": "/plaid/oauth-return*"]])
            }
            try await client.execute(uri: "/plaid/oauth-return?oauth_state_id=abc", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-store")
                #expect(String(buffer: response.body).contains("Return to the Budget app"))
            }
        }
        #expect(!f.log.lines.contains { $0.contains("oauth_state_id") })

        let unset = try await Self.fixture()
        try await unset.app.test(.router) { client in
            try await client.execute(uri: "/.well-known/apple-app-site-association", method: .get) { #expect($0.status == .notFound) }
        }
        let dashboard = try await Self.fixture(surface: .dashboard, edit: { $0.iosAppID = "ABCDE12345.com.example.budget" })
        try await dashboard.app.test(.router) { client in
            try await client.execute(uri: "/.well-known/apple-app-site-association", method: .get) { #expect($0.status == .notFound) }
            try await client.execute(uri: "/plaid/oauth-return", method: .get) { #expect($0.status == .notFound) }
        }
    }
}
