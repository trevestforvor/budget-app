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

/// Plaid-shaped webhooks, signed here with a P-256 key the fake Plaid publishes as its verification key. The signing is
/// done with swift-crypto directly, not with the library the server verifies with, so the two can't share a mistake.
enum WebhookFixture {
    static let key = P256.Signing.PrivateKey()
    static let kid = "6c5516e1-92dc-479e-a8ff-5a51992e0001"
    static let itemID = "item-1"

    static func b64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `/webhook_verification_key/get`'s answer for `key`.
    static func jwk(_ key: P256.Signing.PrivateKey = key, kid: String = kid, expiredAt: Date? = nil) -> (Int, String) {
        let raw = key.publicKey.rawRepresentation
        let x = b64url(raw.prefix(32)), y = b64url(raw.suffix(32))
        let expired = expiredAt.map { String(Int($0.timeIntervalSince1970)) } ?? "null"
        return (200, #"{"key": {"alg": "ES256", "created_at": 1560466150, "crv": "P-256", "expired_at": \#(expired), "kid": "\#(kid)", "kty": "EC", "use": "sig", "x": "\#(x)", "y": "\#(y)"}, "request_id": "req-key"}"#)
    }

    static let unknownKey = (400, #"{"error_type": "INVALID_INPUT", "error_code": "INVALID_WEBHOOK_VERIFICATION_KEY_ID", "error_message": "invalid key_id provided", "request_id": "req-nokey"}"#)

    static func body(_ type: String = "TRANSACTIONS", _ code: String = "SYNC_UPDATES_AVAILABLE", item: String? = itemID,
                     environment: String = "sandbox", extra: String = "") -> Data {
        let itemField = item.map { #""item_id": "\#($0)", "# } ?? ""
        return Data(#"{"environment": "\#(environment)", \#(itemField)"webhook_type": "\#(type)", "webhook_code": "\#(code)"\#(extra)}"#.utf8)
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// A JWT over `body` as Plaid makes them: header {alg, kid, typ}, claims {iat, request_body_sha256}, ES256 signature.
    static func jwt(_ body: Data, iat: Date = Date(), kid: String = kid, alg: String = "ES256", key: P256.Signing.PrivateKey = key,
                    hash: String? = nil) -> String {
        let header = b64url(Data(#"{"alg": "\#(alg)", "kid": "\#(kid)", "typ": "JWT"}"#.utf8))
        let claims = b64url(Data(#"{"iat": \#(Int(iat.timeIntervalSince1970)), "request_body_sha256": "\#(hash ?? sha256(body))"}"#.utf8))
        let signature = try! key.signature(for: Data("\(header).\(claims)".utf8)).rawRepresentation
        return "\(header).\(claims).\(b64url(signature))"
    }

    /// A token with a hand-written header and any signature.
    static func forged(header: String, _ body: Data, signature: String = "c2lnbmF0dXJl") -> String {
        let claims = b64url(Data(#"{"iat": \#(Int(Date().timeIntervalSince1970)), "request_body_sha256": "\#(sha256(body))"}"#.utf8))
        return "\(b64url(Data(header.utf8))).\(claims).\(signature)"
    }

    static func provider(key: [(Int, String)] = [jwk()]) -> ScriptedProvider {
        ScriptedProvider([
            "/webhook_verification_key/get": key,
            "/transactions/sync": [PlaidScript.page("c1")],
            "/accounts/get": [LiabilitiesScript.balances],
            "/item/get": [ItemCheckTests.item(webhook: nil)],
            "/liabilities/get": [LiabilitiesScript.bills],
        ])
    }

    struct Fixture {
        var service: BudgetService
        var receiver: PlaidWebhookReceiver
        var plaid: ScriptedProvider
        var log: CapturedLog
        var app: Application<RouterResponder<BasicRequestContext>>

        var fetches: Int { plaid.count("/webhook_verification_key/get") }
        var syncs: Int { plaid.count("/transactions/sync") }
        func link() async throws -> StoredLink { try await PlaidErrorKindTests.link(service) }
        func change(_ edit: @escaping @Sendable (inout StoredLink) -> Void) async throws { try await service.sync.updateLink(PlaidErrorKindTests.id, edit) }

        /// Waits for the queue to finish what the webhooks asked for.
        func settled() async throws {
            for _ in 0..<400 {
                if await receiver.queue.isIdle { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await receiver.queue.isIdle)
        }
    }

    /// The test server with Harbor's Item linked, and the webhook route with a quick queue (`settle`, `spacing`) and,
    /// when given, a fixed clock for the verifier.
    static func fixture(_ plaid: ScriptedProvider = provider(), settle: TimeInterval = 0.1, spacing: TimeInterval = 60,
                        clock: (@Sendable () -> Date)? = nil) async throws -> Fixture {
        let log = CapturedLog()
        let (service, _) = try await BudgetServerApp.makeService(config: TestServer.config(), store: MemoryStore(), logger: log.logger, plaidTransport: plaid)
        try await BudgetServerApp.prepare(service)
        let sealed = try #require(try service.sealer?.seal("access-sandbox-9"))
        try await service.store.upsertLink(StoredLink(id: PlaidErrorKindTests.id, provider: .plaid, institution: "Harbor", externalID: itemID,
                                                      sealedToken: sealed, cursor: "c0", status: .connected, lastSync: nil, lastError: nil,
                                                      createdAt: Date()))
        let now = clock ?? { Date() }
        let verifier = PlaidWebhookVerifier(fetch: PlaidWebhookReceiver.fetchKey(service), logger: service.logger, clock: now)
        let queue = PlaidWebhookQueue(service: service, settle: settle, syncSpacing: spacing)
        let receiver = PlaidWebhookReceiver(service: service, verifier: verifier, queue: queue)
        let router = Router()
        router.add(middleware: ErrorMiddleware(logger: service.logger))
        router.add(middleware: AuthMiddleware(surface: .api, token: service.config.apiToken, allowedOrigins: service.config.allowedOrigins))
        addPlaidWebhookRoutes(router, service, receiver: receiver)
        return Fixture(service: service, receiver: receiver, plaid: plaid, log: log, app: Application(router: router))
    }

    static func headers(_ jwt: String?, name: String = "Plaid-Verification") -> HTTPFields {
        var fields: HTTPFields = [.contentType: "application/json"]
        if let jwt { fields[HTTPField.Name(name)!] = jwt }
        return fields
    }
}

@Suite("Plaid webhook receiver (WEBHOOK-001..007)")
struct PlaidWebhookTests {
    typealias F = WebhookFixture

    /// Posts `body` with `jwt` (signed over `body` unless given) and returns the status.
    static func status(_ client: some TestClientProtocol, _ body: Data, jwt: String?? = nil, header: String = "Plaid-Verification") async throws -> HTTPResponse.Status {
        let token: String? = jwt ?? F.jwt(body)
        return try await client.execute(uri: "/v1/plaid/webhook", method: .post, headers: F.headers(token, name: header),
                                        body: ByteBuffer(bytes: body)) { $0.status }
    }

    /// Posts and expects `expected`.
    static func post(_ client: some TestClientProtocol, _ body: Data, jwt: String?? = nil, header: String = "Plaid-Verification",
                     expecting expected: HTTPResponse.Status, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let status = try await status(client, body, jwt: jwt, header: header)
        #expect(status == expected, sourceLocation: sourceLocation)
    }

    // MARK: Verified

    @Test("A good webhook: 200 at once, one sync, its type and code stored; the header is read whatever its case")
    func good() async throws {
        let f = try await F.fixture()
        try await f.app.test(.router) { client in
            try await Self.post(client, F.body(), header: "plaid-verification", expecting: .ok)
        }
        try await f.settled()
        #expect(f.fetches == 1)
        #expect(f.syncs == 1)
        let link = try await f.link()
        #expect(link.plaid?.lastWebhookCode == "TRANSACTIONS/SYNC_UPDATES_AVAILABLE")
        #expect(link.plaid?.lastWebhookAt != nil)
    }

    @Test("Duplicate and out-of-order deliveries cause one sync, and the key is fetched once")
    func duplicates() async throws {
        let f = try await F.fixture(settle: 0.3)
        let body = F.body()
        try await f.app.test(.router) { client in
            let older = F.jwt(body, iat: Date().addingTimeInterval(-30))
            try await Self.post(client, body, expecting: .ok)
            try await Self.post(client, body, expecting: .ok)
            try await Self.post(client, body, jwt: older, expecting: .ok)
        }
        try await f.settled()
        #expect(f.syncs == 1)
        #expect(f.fetches == 1)
    }

    @Test("A webhook's sync of one Item starts at most once per spacing; a later ask waits for the end of it")
    func spacing() async throws {
        let f = try await F.fixture(settle: 0.05, spacing: 0.6)
        let started = Date()
        try await f.app.test(.router) { client in
            try await Self.post(client, F.body(), expecting: .ok)
            try await f.settled()
            #expect(f.syncs == 1)
            try await Self.post(client, F.body(), expecting: .ok)
            try await Task.sleep(for: .milliseconds(250))
            #expect(f.syncs == 1)
        }
        try await f.settled()
        #expect(f.syncs == 2)
        #expect(Date().timeIntervalSince(started) >= 0.6)
    }

    @Test("An Item this server doesn't have: 200 and no work")
    func unknownItem() async throws {
        let f = try await F.fixture()
        try await f.app.test(.router) { client in
            try await Self.post(client, F.body(item: "item-elsewhere"), expecting: .ok)
        }
        try await f.settled()
        #expect(f.syncs == 0)
        #expect(f.plaid.count("/item/get") == 0)
        #expect(try await f.link().plaid?.lastWebhookAt == nil)
    }

    @Test("ITEM webhooks: PENDING_DISCONNECT keeps its first date and checks the Item; WEBHOOK_UPDATE_ACKNOWLEDGED is noted")
    func itemWebhooks() async throws {
        let f = try await F.fixture()
        try await f.app.test(.router) { client in
            try await Self.post(client, F.body("ITEM", "PENDING_DISCONNECT"), expecting: .ok)
        }
        try await f.settled()
        #expect(f.plaid.count("/item/get") == 1)
        let first = try #require(try await f.link().plaid?.pendingDisconnectAt)
        try await f.app.test(.router) { client in
            try await Self.post(client, F.body("ITEM", "PENDING_DISCONNECT"), expecting: .ok)
            try await Self.post(client, F.body("ITEM", "WEBHOOK_UPDATE_ACKNOWLEDGED"), expecting: .ok)
        }
        try await f.settled()
        let link = try await f.link()
        #expect(link.plaid?.pendingDisconnectAt == first)
        #expect(link.plaid?.webhookAcknowledgedAt != nil)
        #expect(link.plaid?.lastWebhookCode == "ITEM/WEBHOOK_UPDATE_ACKNOWLEDGED")
        // The two in one burst made one more check, not two.
        #expect(f.plaid.count("/item/get") == 2)
        #expect(f.syncs == 0)
    }

    @Test("ITEM/ERROR asks /item/get, which marks the sign-in; LOGIN_REPAIRED heals it and syncs once")
    func errorThenRepaired() async throws {
        let f = try await F.fixture(ScriptedProvider([
            "/webhook_verification_key/get": [F.jwk()],
            "/item/get": [ItemCheckTests.item(error: "ITEM_LOGIN_REQUIRED", webhook: nil), ItemCheckTests.item(webhook: nil)],
            "/transactions/sync": [PlaidScript.page("c1")], "/accounts/get": [PlaidScript.balances],
        ]))
        try await f.app.test(.router) { client in
            try await Self.post(client, F.body("ITEM", "ERROR"), expecting: .ok)
        }
        try await f.settled()
        var link = try await f.link()
        #expect(link.status == .needsReauth)
        #expect(link.errorKind == .needsSignIn)
        try await f.app.test(.router) { client in
            try await Self.post(client, F.body("ITEM", "LOGIN_REPAIRED"), expecting: .ok)
        }
        try await f.settled()
        for _ in 0..<200 where f.syncs == 0 { try await Task.sleep(for: .milliseconds(10)) }
        link = try await f.link()
        #expect(link.status == .connected)
        #expect(f.syncs == 1)
    }

    @Test("HOLDINGS/DEFAULT_UPDATE marks holdings due and checks the Item")
    func holdings() async throws {
        let f = try await F.fixture()
        try await f.change { $0.holdings = HoldingsCheck(access: .ok, checkedAt: Date(), accounts: 1) }
        try await f.app.test(.router) { client in
            try await Self.post(client, F.body("HOLDINGS", "DEFAULT_UPDATE"), expecting: .ok)
        }
        try await f.settled()
        #expect(f.plaid.count("/item/get") == 1)
        // Holdings themselves are Lane A's stub here: it hands the check back as it was, still marked due.
        #expect(try await f.link().holdings?.due == true)
    }

    @Test("LIABILITIES/DEFAULT_UPDATE reads card bills at most once per 6 hours, and only with card bills on")
    func liabilities() async throws {
        let f = try await F.fixture()
        try await f.app.test(.router) { client in
            try await Self.post(client, F.body("LIABILITIES", "DEFAULT_UPDATE"), expecting: .ok)
        }
        try await f.settled()
        #expect(f.plaid.count("/liabilities/get") == 0)

        try await f.service.settings.update(["cardBills": "true"])
        try await f.app.test(.router) { client in
            try await Self.post(client, F.body("LIABILITIES", "DEFAULT_UPDATE"), expecting: .ok)
        }
        try await f.settled()
        #expect(f.plaid.count("/liabilities/get") == 1)
        #expect(try await f.link().cardBills?.access == .ok)
        try await f.app.test(.router) { client in
            try await Self.post(client, F.body("LIABILITIES", "DEFAULT_UPDATE"), expecting: .ok)
        }
        try await f.settled()
        #expect(f.plaid.count("/liabilities/get") == 1)
        #expect(f.syncs == 0)
    }

    @Test("SYNC_UPDATES_AVAILABLE keeps the stop rules: no sync after 3 refused sign-ins, a sync through a transient backoff")
    func stopRules() async throws {
        let f = try await F.fixture()
        try await f.change { link in
            link.status = .needsReauth
            link.errorKind = .needsSignIn
            link.failureCount = 3
            var plaid = link.plaid ?? PlaidLinkState()
            plaid.signInFailures = 3
            link.plaid = plaid
        }
        try await f.app.test(.router) { client in
            try await Self.post(client, F.body(), expecting: .ok)
        }
        try await f.settled()
        #expect(f.syncs == 0)

        let g = try await F.fixture()
        try await g.change { link in
            link.errorKind = .transient
            link.failureCount = 2
            link.nextAttemptAt = Date().addingTimeInterval(3600)
        }
        try await g.app.test(.router) { client in
            try await Self.post(client, F.body(), expecting: .ok)
        }
        try await g.settled()
        #expect(g.syncs == 1)
    }

    @Test("LINK/SESSION_FINISHED is answered without an Item and without its tokens in the log")
    func sessionFinished() async throws {
        let f = try await F.fixture()
        let body = F.body("LINK", "SESSION_FINISHED", item: nil,
                          extra: #", "link_token": "link-sandbox-SECRETLINK", "public_tokens": ["public-sandbox-SECRETPUBLIC"], "status": "SUCCESS""#)
        try await f.app.test(.router) { client in
            try await Self.post(client, body, expecting: .ok)
        }
        #expect(!f.log.lines.joined().contains("SECRET"))
    }

    // MARK: Refused

    @Test("Wrong alg, alg none and HS256: 401, and no key is fetched")
    func wrongAlg() async throws {
        let f = try await F.fixture()
        let body = F.body()
        try await f.app.test(.router) { client in
            try await Self.post(client, body, jwt: F.jwt(body, alg: "ES384"), expecting: .unauthorized)
            try await Self.post(client, body, jwt: F.forged(header: #"{"alg": "none", "kid": "\#(F.kid)"}"#, body, signature: "AA"), expecting: .unauthorized)
            try await Self.post(client, body, jwt: F.forged(header: #"{"alg": "HS256", "kid": "\#(F.kid)"}"#, body), expecting: .unauthorized)
            try await Self.post(client, body, jwt: F.forged(header: #"{"alg": "es256", "kid": "\#(F.kid)"}"#, body), expecting: .unauthorized)
        }
        #expect(f.fetches == 0)
        #expect(f.syncs == 0)
    }

    @Test("An unknown kid: one fetch, then remembered (a second request makes no fetch)")
    func unknownKid() async throws {
        let f = try await F.fixture(F.provider(key: [F.unknownKey]))
        let body = F.body()
        try await f.app.test(.router) { client in
            try await Self.post(client, body, expecting: .unauthorized)
            try await Self.post(client, body, expecting: .unauthorized)
        }
        #expect(f.fetches == 1)
        #expect(f.syncs == 0)
    }

    @Test("A key Plaid retired: 401")
    func expiredKey() async throws {
        let f = try await F.fixture(F.provider(key: [F.jwk(expiredAt: Date().addingTimeInterval(-60))]))
        try await f.app.test(.router) { client in
            try await Self.post(client, F.body(), expecting: .unauthorized)
        }
        #expect(f.syncs == 0)
    }

    @Test("Signed by another key under Plaid's kid: 401")
    func otherKey() async throws {
        let f = try await F.fixture()
        let body = F.body()
        try await f.app.test(.router) { client in
            try await Self.post(client, body, jwt: F.jwt(body, key: P256.Signing.PrivateKey()), expecting: .unauthorized)
        }
        #expect(f.syncs == 0)
    }

    @Test("Issued 301 s ago, or 2 minutes ahead: 401; 290 s ago: 200")
    func stale() async throws {
        let f = try await F.fixture()
        let body = F.body()
        try await f.app.test(.router) { client in
            try await Self.post(client, body, jwt: F.jwt(body, iat: Date().addingTimeInterval(-301)), expecting: .unauthorized)
            try await Self.post(client, body, jwt: F.jwt(body, iat: Date().addingTimeInterval(120)), expecting: .unauthorized)
            try await Self.post(client, body, jwt: F.jwt(body, iat: Date().addingTimeInterval(-290)), expecting: .ok)
        }
    }

    @Test("A one-byte change to the body, or the same JSON re-serialized with 4-space indents: 401")
    func bodyChanged() async throws {
        let f = try await F.fixture()
        let body = F.body()
        var flipped = body
        flipped[flipped.count - 3] ^= 0x01
        let changed = flipped
        let object = try JSONSerialization.jsonObject(with: body)
        let pretty = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let fourSpaces = Data(String(decoding: pretty, as: UTF8.self).replacingOccurrences(of: "  ", with: "    ").utf8)
        try await f.app.test(.router) { client in
            try await Self.post(client, changed, jwt: F.jwt(body), expecting: .unauthorized)
            try await Self.post(client, fourSpaces, jwt: F.jwt(body), expecting: .unauthorized)
        }
        #expect(f.syncs == 0)
    }

    @Test("Another environment's webhook: 401")
    func wrongEnvironment() async throws {
        let f = try await F.fixture()
        try await f.app.test(.router) { client in
            try await Self.post(client, F.body(environment: "production"), expecting: .unauthorized)
        }
        #expect(f.syncs == 0)
    }

    @Test("No header: 400; a verified body that isn't a webhook: 400")
    func missingHeader() async throws {
        let f = try await F.fixture()
        try await f.app.test(.router) { client in
            try await Self.post(client, F.body(), jwt: .some(nil), expecting: .badRequest)
            let notWebhook = Data(#"{"hello": "world"}"#.utf8)
            try await Self.post(client, notWebhook, expecting: .badRequest)
        }
        #expect(f.syncs == 0)
    }

    @Test("Plaid's key can't be fetched: 503, which Plaid retries")
    func keyFetchFails() async throws {
        let f = try await F.fixture(F.provider(key: [(500, #"{"error_type": "API_ERROR", "error_code": "INTERNAL_SERVER_ERROR", "request_id": "req-500"}"#)]))
        try await f.app.test(.router) { client in
            try await Self.post(client, F.body(), expecting: .serviceUnavailable)
        }
        #expect(f.syncs == 0)
    }

    @Test("A kid with a slash, a 200-character kid and a 5 KiB header: refused with no fetch; a 65 KiB body: 413")
    func cheapChecks() async throws {
        let f = try await F.fixture()
        let body = F.body()
        try await f.app.test(.router) { client in
            try await Self.post(client, body, jwt: F.jwt(body, kid: "../keys/1"), expecting: .unauthorized)
            try await Self.post(client, body, jwt: F.jwt(body, kid: String(repeating: "k", count: 200)), expecting: .unauthorized)
            let huge = F.jwt(body, kid: String(repeating: "k", count: 5 * 1024))
            let status = try await Self.status(client, body, jwt: huge)
            #expect(status == .badRequest || status == .unauthorized)
            try await Self.post(client, body, jwt: "not.a-jwt", expecting: .unauthorized)
            let big = F.body(extra: #", "padding": "\#(String(repeating: "x", count: 65 * 1024))""#)
            try await Self.post(client, big, expecting: .contentTooLarge)
        }
        #expect(f.fetches == 0)
    }

    @Test("100 random kids at once: at most the cap of key fetches, the rest 503")
    func fetchCap() async throws {
        let clock = TestClock(Date())
        let f = try await F.fixture(F.provider(key: [F.unknownKey]), clock: { clock.now })
        let body = F.body()
        let statuses = try await f.app.test(.router) { client in
            var statuses: [HTTPResponse.Status] = []
            for _ in 0..<100 {
                statuses.append(try await Self.status(client, body, jwt: F.jwt(body, kid: UUID().uuidString)))
            }
            return statuses
        }
        #expect(f.fetches == 1)
        #expect(statuses.filter { $0 == .serviceUnavailable }.count == 99)
        #expect(statuses.filter { $0 == .unauthorized }.count == 1)
    }

    @Test("Spread over an hour, random kids cost at most 30 fetches")
    func hourlyCap() async throws {
        let start = Date()
        let clock = TestClock(start)
        let f = try await F.fixture(F.provider(key: [F.unknownKey]), clock: { clock.now })
        let body = F.body()
        try await f.app.test(.router) { client in
            for i in 0..<40 {
                clock.set(start.addingTimeInterval(Double(i) * 11))
                _ = try await Self.status(client, body, jwt: F.jwt(body, iat: clock.now, kid: UUID().uuidString))
            }
        }
        #expect(f.fetches == 30)
    }

    @Test("Nothing from a request is logged: no JWT, body or token, and from a forged request only the reason")
    func logging() async throws {
        let f = try await F.fixture()
        let good = F.body()
        let goodJWT = F.jwt(good)
        let forgedBody = F.body(item: "item-FORGEDMARK", extra: #", "public_tokens": ["public-FORGEDMARK"]"#)
        let forgedJWT = F.jwt(forgedBody, key: P256.Signing.PrivateKey())
        let linesBeforeForged = try await f.app.test(.router) { client in
            try await Self.post(client, good, jwt: goodJWT, expecting: .ok)
            try await f.settled()
            let count = f.log.lines.count
            try await Self.post(client, forgedBody, jwt: forgedJWT, expecting: .unauthorized)
            return count
        }
        let all = f.log.lines.joined(separator: "\n")
        for secret in [goodJWT, forgedJWT, String(decoding: good, as: UTF8.self), "FORGEDMARK", "access-sandbox", F.kid, "request_body_sha256"] {
            #expect(!all.contains(secret))
        }
        let forgedLines = f.log.lines.dropFirst(linesBeforeForged)
        #expect(forgedLines.count == 1)
        #expect(forgedLines.allSatisfy { $0.hasSuffix("plaid webhook refused: badSignature (1 so far)") })
        // The verified one is logged by type, code and link only.
        #expect(f.log.lines.contains { $0.contains("plaid webhook TRANSACTIONS/SYNC_UPDATES_AVAILABLE for link \(PlaidErrorKindTests.id)") })
    }

    // MARK: Routing

    @Test("The route needs no bearer token on the API and doesn't exist on the dashboard")
    func surfaces() async throws {
        let plaid = F.provider()
        let (service, _) = try await BudgetServerApp.makeService(config: TestServer.config(), store: MemoryStore(), logger: Logger(label: "test"),
                                                                 plaidTransport: plaid)
        try await BudgetServerApp.prepare(service)
        let body = F.body(item: "item-none")
        try await Application(router: buildRouter(service)).test(.router) { client in
            try await Self.post(client, body, expecting: .ok)
            // Exactly the path: anything near it still needs the token.
            try await client.execute(uri: "/v1/plaid/webhook/", method: .post, headers: F.headers(F.jwt(body)), body: ByteBuffer(bytes: body)) {
                #expect($0.status == .unauthorized)
            }
        }
        try await Application(router: buildRouter(service, surface: .dashboard)).test(.router) { client in
            var headers = F.headers(F.jwt(body))
            headers[HTTPField.Name("X-Budget-Dashboard")!] = "1"
            try await client.execute(uri: "/v1/plaid/webhook", method: .post, headers: headers, body: ByteBuffer(bytes: body)) {
                #expect($0.status == .notFound)
            }
        }
    }

    @Test("The dashboard's link token carries the webhook URL when there's a public URL and webhooks are on")
    func linkTokenWebhook() async throws {
        func tokenBody(publicURL: String?, webhooks: Bool) async throws -> [String: JSONValue] {
            var config = TestServer.config()
            config.publicURL = publicURL
            config.plaidWebhooks = webhooks
            let plaid = ScriptedProvider(["/link/token/create": [(200, #"{"link_token": "link-sandbox-1"}"#)]])
            let (service, _) = try await BudgetServerApp.makeService(config: config, store: MemoryStore(), logger: Logger(label: "test"), plaidTransport: plaid)
            try await BudgetServerApp.prepare(service)
            try await Application(router: buildRouter(service, surface: .dashboard)).test(.router) { client in
                try await client.execute(uri: "/v1/links/plaid/token", method: .post, headers: SyncRouteTests.write, body: TestServer.body("{}")) {
                    #expect($0.status == .ok)
                }
            }
            return LiabilitiesScript.body(plaid, "/link/token/create")
        }
        #expect(try await tokenBody(publicURL: "https://budget.example/", webhooks: true)["webhook"] == .string("https://budget.example/v1/plaid/webhook"))
        #expect(try await tokenBody(publicURL: nil, webhooks: true)["webhook"] == nil)
        #expect(try await tokenBody(publicURL: "https://budget.example", webhooks: false)["webhook"] == nil)
    }
}
