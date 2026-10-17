import BudgetKit
import Crypto
import Foundation
import Logging

/// Why a reconnect can't start or be found: an HTTP status and words the phone shows. Never carries a token or a URL.
struct ReconnectError: Error, Sendable, Equatable {
    var status: Int
    var message: String
    /// `providerSetup` when the server's Plaid setup is what needs fixing (the phone then points to the dashboard).
    var kind: LinkErrorKind?

    static let notFound = ReconnectError(status: 404, message: "There's no such link or session.")
}

/// Signing in to a bank again from the phone: Hosted Link sessions in Plaid's update mode, in memory only. A restart
/// drops them, and the phone's next poll gets a 404 (it can start again).
///
/// Update mode only: a session opens Link for an Item the server already has, with its access token, so no new Item (a
/// Plaid Trial slot) can come of it, and nothing is ever exchanged afterwards: the Item's access token keeps working. A
/// finished session is confirmed with `/item/get` (Plaid's ground truth) before the link counts as repaired, then synced.
///
/// The link token and the hosted URL are sealed while kept, never logged, and the URL is given out only by `start`.
public actor ReconnectSessions {
    let store: any ServerStore
    let sync: SyncService
    let providers: Providers
    let sealer: TokenSealer?
    let settings: ServerSettings
    let logger: Logger
    let clock: @Sendable () -> Date
    /// Confirms a finished session with `/item/get`, in the Item's turn, the way the daily check does.
    let maintenance: PlaidMaintenance

    /// The browser session ends on this scheme; it carries no query and no secret.
    static let callbackScheme = "budgetapp-plaid"
    static let completionURI = "budgetapp-plaid://reconnect-done"
    /// How long Plaid's hosted page (and so a session) stays usable.
    static let lifetime = 900
    /// A waiting session with more than this left is handed out again instead of a new one.
    static let reuseIfLeft: TimeInterval = 5 * 60
    static let startsPerHour = 5
    static let startsPerDay = 10
    /// The most a session asks Plaid how it's going (`/link/token/get`), however often the phone polls.
    static let lookEvery: TimeInterval = 5
    /// What the phone waits between polls.
    static let pollAfter = 2
    /// An ended session is kept this long for a late poll.
    static let keepEnded: TimeInterval = 3600

    struct Entry: Sendable {
        var session: ReconnectSession
        /// SHA-256 of the link token, lowercase hex: what a LINK/SESSION_FINISHED webhook is matched by.
        var tokenHash: String
        var sealedLinkToken: String
        var sealedURL: String?
        var lastCheckedAt: Date?
        var endedAt: Date?
        /// Renewing the bank's consent on a healthy Item, rather than repairing a broken sign-in.
        var renewal: Bool
    }

    private var sessions: [String: Entry] = [:]
    /// When each link's sessions were started, for the limits.
    private var starts: [String: [Date]] = [:]
    /// A start under way per link, which a second tap joins instead of starting another.
    private var starting: [String: Task<ReconnectSession, any Error>] = [:]

    public init(store: any ServerStore, sync: SyncService, providers: Providers, sealer: TokenSealer?, settings: ServerSettings, logger: Logger,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.sync = sync; self.providers = providers; self.sealer = sealer; self.settings = settings
        self.logger = logger; self.clock = clock
        maintenance = PlaidMaintenance(api: sync.api, store: store, sync: sync, providers: providers, sealer: sealer, settings: settings,
                                       logger: logger, clock: clock)
    }

    // MARK: Starting

    /// `POST /v1/links/:id/reconnect`. A waiting session for the link with more than 5 minutes left comes back as it is
    /// (with its URL); otherwise a new one, within 5 an hour and 10 a day per link. Allowed for a healthy Item too: the
    /// person renewing access before the bank's consent runs out.
    func start(linkID: String) async throws -> ReconnectSession {
        prune()
        if let running = starting[linkID] { return try await running.value }
        let task = Task { try await self.begin(linkID: linkID) }
        starting[linkID] = task
        defer { starting[linkID] = nil }
        return try await task.value
    }

    private func begin(linkID: String) async throws -> ReconnectSession {
        let now = clock()
        guard let link = try await store.links().first(where: { $0.id == linkID }) else { throw ReconnectError.notFound }
        guard link.provider == .plaid else {
            throw ReconnectError(status: 422, message: "\(link.institution) connects through \(link.provider.displayName), not Plaid, so it can't be signed in to again from here.")
        }
        // An Item Plaid deleted can only be linked again; withdrawn access too. Update mode would get nowhere, and a new
        // Item is the dashboard's to start, never the phone's.
        guard link.hasLiveItem else { throw ReconnectError(status: 422, message: SyncService.itemGoneMessage(link)) }
        guard link.errorKind != .revoked else {
            throw ReconnectError(status: 422, message: "Access to \(link.institution) was withdrawn. Link it again on the Budget dashboard.")
        }
        guard let plaid = try? await providers.plaid() else {
            throw ReconnectError(status: 422, message: "Plaid isn't set up on the server.", kind: .providerSetup)
        }
        let sandbox = plaid.environment == .sandbox
        guard await settings.providerCallbackBase(sandbox: sandbox) != nil else {
            throw ReconnectError(status: 422, message: "The server has no public https address (BUDGET_PUBLIC_URL), which signing in again from the phone needs. Reconnect \(link.institution) on the Budget dashboard.",
                                 kind: .providerSetup)
        }
        // OAuth banks come back through the app's Universal Link. Without one, production has no phone flow (the bank
        // would return to the dashboard's login page inside the in-app browser); the sandbox falls back to the
        // dashboard's redirect, with the hosted page not told it's in an app.
        let mobileRedirect = await settings.plaidMobileRedirectURI(sandbox: sandbox)
        guard mobileRedirect != nil || sandbox else {
            throw ReconnectError(status: 422, message: "Signing in again from the phone is off on this server (PLAID_MOBILE_REDIRECT_URI=off). Reconnect \(link.institution) on the Budget dashboard.",
                                 kind: .providerSetup)
        }
        let redirect = mobileRedirect ?? plaid.redirectURI
        guard let sealer else {
            throw ReconnectError(status: 422, message: "BUDGET_TOKEN_KEY isn't set on the server, so it can't open saved sign-ins.", kind: .providerSetup)
        }
        guard let accessToken = try? sealer.open(link.sealedToken) else {
            throw ReconnectError(status: 422, message: "The saved sign-in for \(link.institution) won't open with this server's BUDGET_TOKEN_KEY.",
                                 kind: .providerSetup)
        }

        if let reused = reusable(linkID: linkID, now: now) { return reused }
        let recent = (starts[linkID] ?? []).filter { now.timeIntervalSince($0) < 86_400 }
        guard recent.count < Self.startsPerDay, recent.filter({ now.timeIntervalSince($0) < 3_600 }).count < Self.startsPerHour else {
            throw ReconnectError(status: 429, message: "Signing in to \(link.institution) again was started too many times. Try again in an hour.")
        }
        // Counted when asked, not when answered: a refused ask still went to Plaid.
        starts[linkID] = recent + [now]

        let renewal = !LinkHealthBook.waitsForPerson(link)
        let created: PlaidSource.UpdateModeLink
        do {
            created = try await PlaidSource.updateModeLinkToken(
                accessToken: accessToken, environment: plaid.environment, credentials: .init(clientID: plaid.clientID, secret: plaid.secret),
                userID: "owner", redirectURI: redirect, webhook: await PlaidMaintenance.webhookURL(settings, sandbox: sandbox),
                hostedLink: .init(completionRedirectURI: Self.completionURI, isMobileApp: mobileRedirect != nil, urlLifetimeSeconds: Self.lifetime),
                reauthorization: renewal, transport: providers.transport)
        } catch {
            throw refusal(error, link: link, redirect: redirect)
        }
        guard let url = created.hostedLinkURL, !url.isEmpty else {
            logger.error("reconnect for \(link.institution): Plaid returned no Hosted Link URL (request_id \(created.requestID ?? "none"))")
            throw ReconnectError(status: 422, message: "Plaid didn't give a Hosted Link page, so Hosted Link may not be enabled for this Plaid account. Ask Plaid to turn it on, or reconnect \(link.institution) on the Budget dashboard.",
                                 kind: .providerSetup)
        }

        let id = Self.newSessionID()
        // An older waiting session for the link (under 5 minutes left) gives way to this one.
        for (key, entry) in sessions where entry.session.linkID == linkID && entry.session.state == .waiting {
            end(key, .expired, "A newer sign-in replaced this one.", now: now)
        }
        let expiresAt = min(now.addingTimeInterval(TimeInterval(Self.lifetime)), created.expiresAt ?? .distantFuture)
        let session = ReconnectSession(id: id, linkID: linkID, institution: link.institution, state: .waiting, callbackScheme: Self.callbackScheme,
                                       expiresAt: expiresAt, pollAfterSeconds: Self.pollAfter)
        sessions[id] = Entry(session: session, tokenHash: PlaidWebhookVerifier.hex(SHA256.hash(data: Data(created.linkToken.utf8))),
                             sealedLinkToken: try sealer.seal(created.linkToken), sealedURL: try sealer.seal(url), renewal: renewal)
        logger.info("reconnect started for \(link.institution)\(renewal ? " (renewing access)" : "") (request_id \(created.requestID ?? "none"))")
        var answer = session
        answer.url = url
        return answer
    }

    /// The link's waiting session with more than 5 minutes left, with its URL, if there is one.
    private func reusable(linkID: String, now: Date) -> ReconnectSession? {
        guard let entry = sessions.values.first(where: {
            $0.session.linkID == linkID && $0.session.state == .waiting && $0.session.expiresAt.timeIntervalSince(now) > Self.reuseIfLeft
        }), let sealer, let url = entry.sealedURL.flatMap({ try? sealer.open($0) }) else { return nil }
        var session = entry.session
        session.url = url
        return session
    }

    /// Plaid's refusal of the link token as the phone should hear it. A setup problem (a redirect not on Plaid's allowed
    /// list, Hosted Link not enabled, the server's keys) names the fix and the redirect it sent. It branches on Plaid's
    /// `error_type` and `error_code`, never the message.
    private func refusal(_ error: any Error, link: StoredLink, redirect: String?) -> ReconnectError {
        let plaid = PlaidErrors.plaidError(error)
        logger.error("reconnect for \(link.institution) couldn't start: code \(plaid?.errorCode ?? plaid?.errorType ?? "none"), request_id \(plaid?.requestID ?? "none")")
        guard let plaid else {
            return ReconnectError(status: 502, message: "Couldn't reach Plaid to start signing in to \(link.institution) again. Try again in a moment.")
        }
        let kind = PlaidErrors.kind(type: plaid.errorType, code: plaid.errorCode)
        let request = ["INVALID_REQUEST", "INVALID_INPUT", "INVALID_CONFIGURATION"].contains(plaid.errorType ?? "")
        if kind == .providerSetup || request {
            let fix = redirect.map { "Check that \($0) is on Plaid's allowed redirect URIs (Plaid Dashboard → Developers → API) and that " } ?? "Check that "
            return ReconnectError(status: 422, message: "Plaid refused to start signing in again (\(plaid.errorCode ?? plaid.errorType ?? "error \(plaid.status)")). "
                                  + fix + "Hosted Link is enabled for your Plaid account. Until then, reconnect \(link.institution) on the Budget dashboard.",
                                  kind: .providerSetup)
        }
        switch kind {
        case .revoked:
            return ReconnectError(status: 422, message: "Access to \(link.institution) was withdrawn. Link it again on the Budget dashboard.", kind: .revoked)
        case .rateLimited:
            return ReconnectError(status: 429, message: "Plaid asked the server to slow down. Try again in a few minutes.", kind: .rateLimited)
        default:
            return ReconnectError(status: 502, message: "Plaid couldn't start signing in to \(link.institution) again right now. Try again in a moment.",
                                  kind: kind)
        }
    }

    /// 32 random bytes, hex.
    static func newSessionID() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    // MARK: Polling

    /// `GET /v1/links/:id/reconnect/:session`: where the session stands, never with its URL. While it waits, Plaid is
    /// asked at most every 5 seconds; a finished session moves to syncing (confirmed with `/item/get`, then synced) and
    /// on to done.
    func status(linkID: String, session id: String) async throws -> ReconnectSession {
        prune()
        guard let entry = sessions[id], entry.session.linkID == linkID else { throw ReconnectError.notFound }
        let now = clock()
        if entry.session.state == .waiting {
            if now >= entry.session.expiresAt {
                end(id, .expired, "That sign-in page expired. Start again to sign in to \(entry.session.institution).", now: now)
            } else if entry.lastCheckedAt.map({ now.timeIntervalSince($0) >= Self.lookEvery }) ?? true {
                await look(id)
            }
        }
        guard let current = sessions[id] else { throw ReconnectError.notFound }
        var session = current.session
        session.url = nil
        return session
    }

    /// A LINK/SESSION_FINISHED webhook for the Link session whose token hashes to `linkTokenHash` (SHA-256, lowercase
    /// hex): a reconnect waiting on it looks now rather than at its next poll (still at most every 5 seconds). The
    /// webhook's tokens are never passed in.
    func check(linkTokenHash: String) async {
        let now = clock()
        guard let match = sessions.first(where: { $0.value.tokenHash == linkTokenHash && $0.value.session.state == .waiting }),
              now < match.value.session.expiresAt, match.value.lastCheckedAt.map({ now.timeIntervalSince($0) >= Self.lookEvery }) ?? true else { return }
        await look(match.key)
    }

    /// Asks Plaid how the session went (`/link/token/get`). Not in the Item's turn: it reads no Item data, and a poll
    /// mustn't wait behind a long sync. A failure leaves it waiting for the next look.
    private func look(_ id: String) async {
        guard var entry = sessions[id], let sealer, let plaid = try? await providers.plaid() else { return }
        entry.lastCheckedAt = clock()
        sessions[id] = entry
        guard let token = try? sealer.open(entry.sealedLinkToken) else { return }
        let outcome: PlaidSource.LinkSessionOutcome
        do {
            let answer = try await PlaidSource.linkSession(linkToken: token, environment: plaid.environment,
                                                           credentials: .init(clientID: plaid.clientID, secret: plaid.secret), transport: providers.transport)
            outcome = answer.outcome
        } catch {
            let plaidError = PlaidErrors.plaidError(error)
            logger.warning("reconnect for \(entry.session.institution): couldn't read the Link session (code \(plaidError?.errorCode ?? "none"), request_id \(plaidError?.requestID ?? "none"))")
            return
        }
        // Another look may have moved it on while this one waited for Plaid.
        guard sessions[id]?.session.state == .waiting else { return }
        let now = clock()
        switch outcome {
        case .pending:
            break
        case let .exited(code):
            logger.info("reconnect for \(entry.session.institution) exited\(code.map { " (code \($0))" } ?? "")")
            end(id, .exited, entry.renewal ? "Nothing changed: \(entry.session.institution) wasn't renewed." :
                    "You left before finishing. \(entry.session.institution) still needs you to sign in again.", now: now)
        case .finished:
            sessions[id]?.session.state = .syncing
            Task { await self.finish(id) }
        }
    }

    /// The person went through Link: `/item/get` confirms the Item is healthy (that's what clears the link's error),
    /// then the link syncs. The access token is the same as before: nothing is exchanged.
    private func finish(_ id: String) async {
        guard let entry = sessions[id] else { return }
        let linkID = entry.session.linkID, institution = entry.session.institution
        await maintenance.checkItem(linkID, syncIfHealed: false)
        guard let link = try? await store.links().first(where: { $0.id == linkID }) else {
            end(id, .failed, "\(institution) isn't linked any more.", now: clock())
            return
        }
        if LinkHealthBook.waitsForPerson(link) {
            logger.warning("reconnect for \(institution) finished, but Plaid still reports \(link.errorCode ?? "an error")")
            end(id, .failed, "Plaid still says \(institution) needs you to sign in. Try again, or reconnect it on the Budget dashboard.", now: clock())
            return
        }
        do {
            let result = try await sync.sync(linkID: linkID, trigger: .reconnect)
            sessions[id]?.session.result = result
            if result.ok {
                end(id, .done, nil, now: clock())
            } else {
                end(id, .failed, result.error ?? "\(institution) signed in, but its sync didn't go through. The next sync tries again.", now: clock())
            }
        } catch {
            end(id, .failed, "\(institution) signed in, but its sync didn't go through. The next sync tries again.", now: clock())
        }
    }

    // MARK: Bookkeeping

    private func end(_ id: String, _ state: ReconnectSession.State, _ message: String?, now: Date) {
        guard var entry = sessions[id] else { return }
        entry.session.state = state
        entry.session.message = message
        entry.session.pollAfterSeconds = nil
        entry.endedAt = now
        // Nothing more to ask Plaid: the token and the URL go.
        entry.sealedLinkToken = ""
        entry.sealedURL = nil
        sessions[id] = entry
    }

    /// Drops sessions an hour after they ended or expired, and starts older than a day.
    private func prune() {
        let now = clock()
        sessions = sessions.filter { _, entry in
            let over = entry.endedAt ?? (entry.session.state == .waiting ? entry.session.expiresAt : nil)
            return over.map { now.timeIntervalSince($0) < Self.keepEnded } ?? true
        }
        starts = starts.compactMapValues { dates in
            let kept = dates.filter { now.timeIntervalSince($0) < 86_400 }
            return kept.isEmpty ? nil : kept
        }
    }
}
