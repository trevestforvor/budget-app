import BudgetKit
import Crypto
import Foundation
import HTTPTypes
import Hummingbird
import JWTKit
import Logging
import NIOCore

/// `POST /v1/plaid/webhook`, on the API surface only. Public (no bearer token): Plaid's signed JWT is its auth.
///
/// A webhook is only a trigger. Once its signature checks out the route answers 200 at once and leaves the work to
/// `PlaidWebhookQueue`, which goes back to Plaid for the facts (a sync, `/item/get`); nothing in the body is trusted but
/// the Item, the type and code, and a hash of a Link session's token. The 6-hourly sync and the daily Item check stay on
/// when webhooks work: they're the reconcile for a webhook that never came (a restart empties the queue, and Plaid gives
/// up on a delivery after a day of retries).
func addPlaidWebhookRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService) {
    addPlaidWebhookRoutes(router, service, receiver: PlaidWebhookReceiver(service: service))
}

func addPlaidWebhookRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService, receiver: PlaidWebhookReceiver) {
    router.post("/v1/plaid/webhook") { request, _ in await receiver.receive(request) }
}

extension PlaidMaintenance {
    /// Where Plaid should send this server's webhooks: `<public URL>/v1/plaid/webhook` when webhooks are on and the public
    /// URL is usable (https, or http for a sandbox test server); nil otherwise.
    static func webhookURL(_ settings: ServerSettings, sandbox: Bool) async -> String? {
        guard await settings.plaidWebhooksEnabled, let base = await settings.providerCallbackBase(sandbox: sandbox) else { return nil }
        return base + webhookPath
    }
}

// MARK: - Receiving

/// Verifies a webhook request, answers it, and hands what it asks for to the queue. Never throws: every answer is built
/// here, so no error (and none of the request) reaches `ErrorMiddleware`'s log.
struct PlaidWebhookReceiver: Sendable {
    let service: BudgetService
    let verifier: PlaidWebhookVerifier
    let queue: PlaidWebhookQueue
    let clock: @Sendable () -> Date

    static let maxBody = 64 * 1024
    static let maxHeader = 4 * 1024
    static let header = HTTPField.Name("Plaid-Verification")!

    init(service: BudgetService, verifier: PlaidWebhookVerifier? = nil, queue: PlaidWebhookQueue? = nil, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.service = service
        self.clock = clock
        self.verifier = verifier ?? PlaidWebhookVerifier(fetch: Self.fetchKey(service), logger: service.logger, clock: clock)
        self.queue = queue ?? PlaidWebhookQueue(service: service, clock: clock)
    }

    /// The live key fetch: `/webhook_verification_key/get` with this server's Plaid keys. On a test server with
    /// `BUDGET_TEST_WEBHOOK_JWK_FILE` (`TestHooks`), that file's keys instead.
    static func fetchKey(_ service: BudgetService) -> PlaidWebhookVerifier.KeyFetcher {
        if let keys = TestHooks.webhookKeys(service.config, logger: service.logger) {
            return { kid in
                guard let key = keys[kid] else {
                    throw PlaidAPIError(status: 400, errorType: "INVALID_INPUT", errorCode: "INVALID_WEBHOOK_VERIFICATION_KEY_ID")
                }
                return key
            }
        }
        return { kid in
            guard let plaid = try await service.providers.plaid() else { throw PlaidWebhookVerifier.Refusal.notConfigured }
            return try await PlaidSource.webhookVerificationKey(keyID: kid, environment: plaid.environment,
                                                                credentials: .init(clientID: plaid.clientID, secret: plaid.secret),
                                                                transport: service.providers.transport)
        }
    }

    func receive(_ request: Request) async -> Response {
        // The cheap checks come first, so a request that can't be Plaid's never makes this server call Plaid.
        guard let jwt = request.headers[Self.header] else { return await refuse(.missingHeader) }
        guard jwt.utf8.count <= Self.maxHeader else { return await refuse(.headerTooLarge) }
        let token: PlaidWebhookVerifier.Token
        switch PlaidWebhookVerifier.precheck(jwt) {
        case let .success(t): token = t
        case let .failure(refusal): return await refuse(refusal)
        }
        let body: Data
        do {
            body = Data(try await request.body.collect(upTo: Self.maxBody).readableBytesView)
        } catch is NIOTooManyBytesError {
            return await refuse(.bodyTooLarge)
        } catch {
            return await refuse(.malformedBody)
        }
        guard let plaid = try? await service.providers.plaid() else { return await refuse(.notConfigured) }
        if let refusal = await verifier.verify(token, body: body) { return await refuse(refusal) }
        guard let notice = PlaidWebhookNotice(body) else { return await refuse(.malformedBody) }
        guard notice.environment == plaid.environment.rawValue else { return await refuse(.wrongEnvironment) }

        // Verified: from here type, code and link may be logged. Never the body, the JWT or a token in it.
        await dispatch(notice)
        return Response(status: .ok, headers: [.contentType: "application/json"], body: ResponseBody(byteBuffer: ByteBuffer(string: "{}")))
    }

    /// The answer to a request that failed a check, with nothing from the request in it or in the log.
    func refuse(_ refusal: PlaidWebhookVerifier.Refusal) async -> Response {
        await verifier.count(refusal)
        return HTTP.error(refusal.status, refusal.message)
    }

    func dispatch(_ notice: PlaidWebhookNotice) async {
        let logger = service.logger
        let name = notice.name
        if notice.type == "LINK" {
            if notice.code == "SESSION_FINISHED", let hash = notice.linkTokenHash { await service.reconnects.check(linkTokenHash: hash) }
            logger.info("plaid webhook \(name)")
            return
        }
        guard let work = PlaidWebhookQueue.Work(type: notice.type, code: notice.code) else {
            logger.info("plaid webhook \(name): nothing to do for it")
            return
        }
        // DATA-005: an Item's webhooks find its link by item_id alone.
        guard let itemID = notice.itemID,
              let link = try? await service.store.links().first(where: { $0.provider == .plaid && ($0.externalID == itemID || $0.id == "plaid-" + itemID) })
        else {
            logger.notice("plaid webhook \(name) for an Item this server doesn't have; ignored")
            return
        }
        logger.info("plaid webhook \(name) for link \(link.id)")
        await queue.enqueue(link.id, work, code: name)
    }
}

/// What a verified webhook body says that this server uses: the rest of it is never read, stored or logged.
struct PlaidWebhookNotice: Sendable {
    var type: String
    var code: String
    var itemID: String?
    var environment: String?
    /// SHA-256 of a Link session's `link_token` (LINK webhooks), to find a reconnect session; never the token.
    var linkTokenHash: String?

    init?(_ body: Data) {
        guard case let .object(o)? = try? JSONValue.parse(body), case let .string(type)? = o["webhook_type"], case let .string(code)? = o["webhook_code"]
        else { return nil }
        func string(_ key: String) -> String? { if case let .string(v)? = o[key], !v.isEmpty { v } else { nil } }
        self.type = String(type.prefix(64))
        self.code = String(code.prefix(64))
        itemID = string("item_id")
        environment = string("environment")
        linkTokenHash = string("link_token").map { PlaidWebhookVerifier.hex(SHA256.hash(data: Data($0.utf8))) }
    }

    /// "TRANSACTIONS/SYNC_UPDATES_AVAILABLE".
    var name: String { "\(type)/\(code)" }
}

// MARK: - Verifying

/// Checks the `Plaid-Verification` JWT on a webhook (WEBHOOK-003/004): ES256 only, signed by a key Plaid publishes for
/// the `kid` it names, issued within the last 5 minutes, over exactly these body bytes.
///
/// The route is public, so a forged request mustn't be able to make this server call Plaid without limit: keys are
/// cached by `kid` (asked again after a day), a `kid` Plaid doesn't know is remembered for a minute, one fetch per `kid`
/// is in flight at a time, and all fetches together are capped at one per 10 seconds and 30 an hour. Over the cap the
/// answer is 503, which Plaid retries.
///
/// A key with no `expired_at` when fetched is trusted until its day is up, unless Plaid starts signing with a new `kid`
/// first: that's when Plaid rotates, so the others with no `expired_at` are asked again on their next use (within the
/// cap; until then, and while Plaid can't be reached, the cached key still verifies). Beyond that, a key Plaid retires
/// mid-day is accepted until its day is up, on purpose: asking on every webhook would put Plaid on the request path.
actor PlaidWebhookVerifier {
    typealias KeyFetcher = @Sendable (String) async throws -> PlaidSource.WebhookKey

    /// Why a request was refused. Only this name and a count are logged, never anything from the request.
    enum Refusal: String, Error, Sendable {
        case missingHeader, headerTooLarge, malformedToken, badAlg, badKid, bodyTooLarge, malformedBody
        case unknownKid, expiredKey, badSignature, stale, hashMismatch, wrongEnvironment
        case keyUnavailable, tooManyKeyFetches, notConfigured

        var status: HTTPResponse.Status {
            switch self {
            case .missingHeader, .headerTooLarge, .malformedBody: .badRequest
            case .bodyTooLarge: .contentTooLarge
            // Plaid retries a 5xx (WEBHOOK-007): the key may be reachable, or the cap lifted, next time.
            case .keyUnavailable, .tooManyKeyFetches, .notConfigured: .serviceUnavailable
            default: .unauthorized
            }
        }

        var message: String {
            switch status {
            case .badRequest: "Not a Plaid webhook."
            case .contentTooLarge: "Too large for a Plaid webhook."
            case .serviceUnavailable: "Can't verify Plaid webhooks right now."
            default: "The webhook's signature didn't verify."
            }
        }
    }

    /// The parts of a JWT that passed the cheap checks.
    struct Token: Sendable {
        var jwt: String
        var kid: String
    }

    /// The claims Plaid signs: when, and the SHA-256 of the body.
    struct Claims: JWTPayload {
        var iat: IssuedAtClaim
        var requestBodySHA256: String

        enum CodingKeys: String, CodingKey {
            case iat
            case requestBodySHA256 = "request_body_sha256"
        }

        /// The time and hash are checked by the verifier, against its clock and the body.
        func verify(using algorithm: some JWTAlgorithm) async throws {}
    }

    static let maxAge: TimeInterval = 300
    static let maxSkew: TimeInterval = 60
    static let keyLifetime: TimeInterval = 24 * 3600
    static let unknownKidFor: TimeInterval = 60
    static let fetchSpacing: TimeInterval = 10
    static let fetchesPerHour = 30

    let fetch: KeyFetcher
    let logger: Logger
    let clock: @Sendable () -> Date

    private var keys: [String: (key: PlaidSource.WebhookKey, fetchedAt: Date)] = [:]
    private var unknown: [String: Date] = [:]
    /// A fetch in flight, with what failed when it gave no key (logged once, by the request that started it).
    private var inFlight: [String: Task<(Lookup, (any Error)?), Never>] = [:]
    private var fetches: [Date] = []
    private var refusals: [Refusal: Int] = [:]
    private var fetchFailures = 0

    init(fetch: @escaping KeyFetcher, logger: Logger, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.fetch = fetch; self.logger = logger; self.clock = clock
    }

    enum Lookup: Sendable {
        case key(PlaidSource.WebhookKey)
        case unknown
        case unavailable
        /// Not asked: over the cap on key fetches.
        case capped
    }

    /// The checks that need no key: three base64url segments, a JSON header with `alg` exactly ES256 and a plain `kid`.
    nonisolated static func precheck(_ jwt: String) -> Result<Token, Refusal> {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy(isBase64URL) }),
              let headerData = base64URLDecode(parts[0]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        else { return .failure(.malformedToken) }
        guard header["alg"] as? String == "ES256" else { return .failure(.badAlg) }
        guard let kid = header["kid"] as? String, (1...128).contains(kid.utf8.count), kid.utf8.allSatisfy(isBase64URL) else {
            return .failure(.badKid)
        }
        return .success(Token(jwt: jwt, kid: kid))
    }

    /// Nil when the token is Plaid's and covers `body`; otherwise why not.
    func verify(_ token: Token, body: Data) async -> Refusal? {
        let key: PlaidSource.WebhookKey
        switch await lookup(token.kid) {
        case let .key(found): key = found
        case .unknown: return .unknownKid
        case .unavailable: return .keyUnavailable
        case .capped: return .tooManyKeyFetches
        }
        let now = clock()
        if let expired = key.expiredAt, expired <= now { return .expiredKey }
        let claims: Claims
        do {
            // A collection holding only this Plaid EC key: nothing else can verify the token.
            let collection = JWTKeyCollection()
            await collection.add(ecdsa: try ES256PublicKey(parameters: (x: key.x, y: key.y)), kid: JWKIdentifier(string: token.kid))
            claims = try await collection.verify(token.jwt, as: Claims.self)
        } catch {
            return .badSignature
        }
        let age = now.timeIntervalSince(claims.iat.value)
        guard age <= Self.maxAge, age >= -Self.maxSkew else { return .stale }
        // The raw bytes as they came: re-serialized JSON hashes differently, and that's the point.
        guard Self.constantTimeEqual(Self.hex(SHA256.hash(data: body)), claims.requestBodySHA256) else { return .hashMismatch }
        return nil
    }

    /// The key for `kid`: cached, remembered as unknown, joined to a fetch in flight, or fetched within the cap.
    func lookup(_ kid: String) async -> Lookup {
        let now = clock()
        let cached = keys[kid]
        if let cached, now.timeIntervalSince(cached.fetchedAt) < Self.keyLifetime { return .key(cached.key) }
        if let missed = unknown[kid], now.timeIntervalSince(missed) < Self.unknownKidFor { return .unknown }
        let result: Lookup
        if let running = inFlight[kid] {
            result = await running.value.0
        } else {
            guard fetchesAllowed(now) else { return cached.map { .key($0.key) } ?? .capped }
            fetches.append(now)
            let fetch = self.fetch
            let task = Task<(Lookup, (any Error)?), Never> {
                do {
                    let key = try await fetch(kid)
                    return (key.keyID == kid ? .key(key) : .unknown, nil)
                } catch let error as PlaidAPIError where Self.meansUnknownKey(error) {
                    return (.unknown, error)
                } catch {
                    return (.unavailable, error)
                }
            }
            inFlight[kid] = task
            let failure: (any Error)?
            (result, failure) = await task.value
            inFlight[kid] = nil
            if let failure { logFetchFailure(failure) }
            switch result {
            case let .key(key):
                // A kid this server hasn't seen: Plaid may have rotated, so the keys it had that showed no retirement date
                // are asked again on their next use.
                if cached == nil {
                    for (other, entry) in keys where other != kid && entry.key.expiredAt == nil { keys[other]?.fetchedAt = .distantPast }
                }
                keys[kid] = (key, clock())
                unknown[kid] = nil
            case .unknown:
                keys[kid] = nil
                unknown = unknown.filter { clock().timeIntervalSince($0.value) < Self.unknownKidFor }
                unknown[kid] = clock()
            case .unavailable, .capped:
                break
            }
        }
        // Plaid unreachable when a day-old key was due a refresh: the key it had still verifies until Plaid retires it.
        if case .unavailable = result, let cached = keys[kid] { return .key(cached.key) }
        return result
    }

    /// Under the cap: none in the last 10 seconds and fewer than 30 in the last hour.
    func fetchesAllowed(_ now: Date) -> Bool {
        fetches = fetches.filter { now.timeIntervalSince($0) < 3600 }
        if let last = fetches.last, now.timeIntervalSince(last) < Self.fetchSpacing { return false }
        return fetches.count < Self.fetchesPerHour
    }

    /// Plaid saying the key id isn't one of its keys, by its exact code (ITEM-002). Any other error, our own request's
    /// included, is a 503 that Plaid retries, never a 401 that drops the webhook for good.
    static func meansUnknownKey(_ error: PlaidAPIError) -> Bool {
        error.errorType == "INVALID_INPUT" && error.errorCode == "INVALID_WEBHOOK_VERIFICATION_KEY_ID"
    }

    /// Logs what Plaid said to a key fetch that didn't give a key: its type, code and request_id (or, without a Plaid
    /// answer, the failure), never the `kid` asked for. The first ten, then every hundredth; the fetch cap bounds it too.
    func logFetchFailure(_ error: any Error) {
        fetchFailures += 1
        guard fetchFailures <= 10 || fetchFailures % 100 == 0 else { return }
        if let plaid = PlaidErrors.plaidError(error) {
            logger.notice("plaid webhook key not fetched: HTTP \(plaid.status), type \(plaid.errorType ?? "none"), code \(plaid.errorCode ?? "none"), request_id \(plaid.requestID ?? "none") (\(fetchFailures) so far)")
        } else {
            logger.notice("plaid webhook key not fetched: type none, code none, request_id none: \(SyncService.describe(error)) (\(fetchFailures) so far)")
        }
    }

    /// Counts a refusal and logs its reason: the first ten, then every hundredth, so a flood can't fill the log.
    func count(_ refusal: Refusal) {
        let n = (refusals[refusal] ?? 0) + 1
        refusals[refusal] = n
        if n <= 10 || n % 100 == 0 { logger.notice("plaid webhook refused: \(refusal.rawValue) (\(n) so far)") }
    }

    var keyFetches: Int { fetches.count }

    // MARK: Helpers

    nonisolated static func isBase64URL(_ c: UInt8) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F
    }

    nonisolated static func base64URLDecode(_ s: Substring) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        return Data(base64Encoded: b64)
    }

    nonisolated static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

// MARK: - Queue

/// What webhooks asked for, per Item, done one Item at a time in the Item's turn (`SyncService.updateLink` and the sync
/// queue). Several webhooks for one Item within `settle` (a burst, a duplicate, one out of order) become one pass; and
/// a webhook's sync of one Item starts at most once per `syncSpacing`, a later ask waiting for the end of it.
///
/// In memory only: a restart drops what's waiting, and the 6-hourly sync and the daily Item check pick it up.
actor PlaidWebhookQueue {
    /// What one webhook asks for.
    enum Work: Sendable, Equatable {
        /// TRANSACTIONS/SYNC_UPDATES_AVAILABLE: Plaid has new data.
        case sync
        /// ITEM errors and warnings, LOGIN_REPAIRED, NEW_ACCOUNTS_AVAILABLE: `/item/get` says what's true now.
        case itemCheck
        /// PENDING_DISCONNECT: about a week's warning, then an Item check.
        case pendingDisconnect
        /// WEBHOOK_UPDATE_ACKNOWLEDGED: the Item's webhooks come here now.
        case acknowledged
        /// HOLDINGS/DEFAULT_UPDATE: holdings are due; the Item check asks for them.
        case holdings
        /// LIABILITIES/DEFAULT_UPDATE: card bills changed.
        case liabilities

        init?(type: String, code: String) {
            switch (type, code) {
            case ("TRANSACTIONS", "SYNC_UPDATES_AVAILABLE"): self = .sync
            case ("ITEM", "PENDING_DISCONNECT"): self = .pendingDisconnect
            case ("ITEM", "ERROR"), ("ITEM", "PENDING_EXPIRATION"), ("ITEM", "LOGIN_REPAIRED"), ("ITEM", "USER_PERMISSION_REVOKED"),
                 ("ITEM", "USER_ACCOUNT_REVOKED"), ("ITEM", "NEW_ACCOUNTS_AVAILABLE"): self = .itemCheck
            case ("ITEM", "WEBHOOK_UPDATE_ACKNOWLEDGED"): self = .acknowledged
            case ("HOLDINGS", "DEFAULT_UPDATE"): self = .holdings
            case ("LIABILITIES", "DEFAULT_UPDATE"): self = .liabilities
            default: return nil
            }
        }
    }

    /// One Item's waiting work.
    struct Pending: Sendable {
        var readyAt: Date
        var receivedAt: Date
        var lastCode: String?
        var sync = false
        var syncCode = "SYNC_UPDATES_AVAILABLE"
        var itemCheck = false
        var pendingDisconnect = false
        var acknowledged = false
        var holdings = false
        var liabilities = false
    }

    /// How long a first webhook waits for the rest of its burst.
    static let settle: TimeInterval = 2
    /// The least time between two webhook syncs of one Item.
    static let syncSpacing: TimeInterval = 60
    /// The least time between two card-bill reads a webhook asks for on one Item.
    static let liabilitiesSpacing: TimeInterval = 6 * 3600

    let service: BudgetService
    let clock: @Sendable () -> Date
    let settle: TimeInterval
    let syncSpacing: TimeInterval
    private var pending: [String: Pending] = [:]
    private var lastSync: [String: Date] = [:]
    private var draining = false

    init(service: BudgetService, clock: @escaping @Sendable () -> Date = { Date() }, settle: TimeInterval = PlaidWebhookQueue.settle,
         syncSpacing: TimeInterval = PlaidWebhookQueue.syncSpacing) {
        self.service = service; self.clock = clock; self.settle = settle; self.syncSpacing = syncSpacing
    }

    /// Nothing waiting and nothing running.
    var isIdle: Bool { pending.isEmpty && !draining }

    func enqueue(_ linkID: String, _ work: Work, code: String) {
        let now = clock()
        var entry = pending[linkID] ?? Pending(readyAt: now.addingTimeInterval(settle), receivedAt: now)
        entry.lastCode = code
        entry.receivedAt = now
        switch work {
        case .sync:
            entry.sync = true
            entry.syncCode = String(code.split(separator: "/").last ?? "SYNC_UPDATES_AVAILABLE")
        case .itemCheck: entry.itemCheck = true
        case .pendingDisconnect: entry.pendingDisconnect = true; entry.itemCheck = true
        case .acknowledged: entry.acknowledged = true
        case .holdings: entry.holdings = true; entry.itemCheck = true
        case .liabilities: entry.liabilities = true
        }
        pending[linkID] = entry
        startDraining()
    }

    private func startDraining() {
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    /// Works through what's ready, one Item at a time, sleeping until the next is.
    private func drain() async {
        while let next = pending.min(by: { $0.value.readyAt < $1.value.readyAt }) {
            let wait = next.value.readyAt.timeIntervalSince(clock())
            if wait > 0 {
                // A second at most, so work that arrives meanwhile and is ready sooner isn't kept waiting.
                try? await Task.sleep(for: .seconds(min(wait, 1)))
                continue
            }
            pending[next.key] = nil
            await run(next.key, next.value)
        }
        draining = false
    }

    private func run(_ linkID: String, _ work: Pending) async {
        let logger = service.logger
        // One write for what the webhooks said, in the Item's turn. A link removed meanwhile ends it here.
        let receivedAt = work.receivedAt
        do {
            try await service.sync.updateLink(linkID) { link in
                var state = link.plaid ?? PlaidLinkState()
                state.lastWebhookAt = receivedAt
                if let code = work.lastCode { state.lastWebhookCode = code }
                // The first warning counts: a repeat doesn't move the week it gives.
                if work.pendingDisconnect, state.pendingDisconnectAt == nil { state.pendingDisconnectAt = receivedAt }
                if work.acknowledged { state.webhookAcknowledgedAt = receivedAt }
                link.plaid = state
                if work.holdings { link.holdings?.due = true }
            }
        } catch {
            logger.notice("plaid webhook work for link \(linkID) dropped: the link is gone")
            return
        }
        // A check that heals the link leaves its sync to this queue, so it's spaced with the rest: LOGIN_REPAIRED and
        // SYNC_UPDATES_AVAILABLE in one burst make one sync, and one just after a heal waits its turn.
        var syncCode = work.sync ? work.syncCode : nil
        if work.itemCheck, await service.plaidMaintenance.checkItem(linkID, syncIfHealed: false) == .healed { syncCode = "LOGIN_REPAIRED" }
        if work.liabilities { await refreshCardBills(linkID) }
        if let syncCode { await sync(linkID, code: syncCode) }
    }

    /// The webhook's sync, or a wait for the end of the spacing when one ran too lately. The sync keeps the stop rules
    /// (a link revoked, or refused three sign-ins running, isn't asked) but not a transient failure's backoff.
    private func sync(_ linkID: String, code: String) async {
        let now = clock()
        if let last = lastSync[linkID], now.timeIntervalSince(last) < syncSpacing {
            var entry = pending[linkID] ?? Pending(readyAt: last.addingTimeInterval(syncSpacing), receivedAt: now)
            entry.readyAt = max(entry.readyAt, last.addingTimeInterval(syncSpacing))
            entry.sync = true
            entry.syncCode = code
            pending[linkID] = entry
            return
        }
        lastSync[linkID] = now
        _ = try? await service.sync.sync(linkID: linkID, trigger: .webhook(code))
    }

    /// LIABILITIES/DEFAULT_UPDATE: card bills read again, with the card-bill setting on, at most once per 6 hours per Item.
    private func refreshCardBills(_ linkID: String) async {
        guard await service.settings.cardBillsEnabled else { return }
        let service = self.service
        let now = clock()
        _ = try? await service.sync.updateLink(linkID) { link in
            guard link.hasLiveItem, now.timeIntervalSince(link.cardBills?.checkedAt ?? .distantPast) >= Self.liabilitiesSpacing,
                  let plaid = try? await service.providers.plaid(), let sealer = service.sealer, let token = try? sealer.open(link.sealedToken)
            else { return }
            let source = PlaidSource(environment: plaid.environment, credentials: .init(clientID: plaid.clientID, secret: plaid.secret),
                                     accessToken: token, institution: link.institution, transport: service.providers.transport)
            let snapshot: SourceSnapshot
            do {
                snapshot = try await source.accountsSnapshot(now: now)
            } catch {
                let plaidError = PlaidErrors.plaidError(error)
                service.logger.notice("card bills for \(link.institution) not read after a webhook: code \(plaidError?.errorCode ?? "none"), request_id \(plaidError?.requestID ?? "none")")
                return
            }
            // Not due by the daily rule: the webhook says they changed.
            link.cardBills = await CardBillSync.refresh(enabled: true, source: source, snapshot: snapshot,
                                                        previous: nil, requestedByPerson: false, api: service.api, now: now,
                                                        institution: link.institution, logger: service.logger)
        }
    }
}
