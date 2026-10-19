import BudgetKit
import Foundation
import Hummingbird
import HTTPTypes
import Logging
import NIOCore

/// Everything a request handler needs.
public struct BudgetService: Sendable {
    public let api: LedgerBudgetAPI
    public let store: any ServerStore
    public let sync: SyncService
    /// Yesterday's spending at 9:30 in each phone's time zone.
    public let morning: MorningSummary
    /// Pace alerts: a target past 80% or on pace to go over, once a month, in each phone's daytime.
    public let pace: PaceAlertSender
    public let config: ServerConfig
    public let sealer: TokenSealer?
    /// Plaid as configured right now (dashboard settings over environment).
    public let providers: Providers
    /// Models, sync, time zone, public URL — dashboard over environment over defaults.
    public let settings: ServerSettings
    public let logger: Logger
    /// Pushes about bank connections (a sign-in needed, consent running out, an account gone quiet).
    public let alerts: ConnectionAlertSender
    /// Signing in to a bank again from the phone.
    public let reconnects: ReconnectSessions
    /// The daily Plaid Item check.
    public let plaidMaintenance: PlaidMaintenance
    /// How statement ids are made unreadable; nil until that's built, or without BUDGET_TOKEN_KEY.
    public let statementIDs: StatementIDs?
    /// API requests turned away for their token, per day and address, and a push when one carried a wrong token.
    public let access: AccessWatch
    /// Swaps the models in as settings change, never an older snapshot over a newer one (`BudgetServerApp.apply`).
    let modelApplier = ModelApplier()

    /// A new ledger (first boot or admin reset). With a local decision model configured it starts
    /// categorizing on it at the default threshold; the person can change or turn that off in Settings.
    public func freshState(seedDemo: Bool) async -> LedgerState {
        var state = seedDemo ? LedgerBudgetAPI.demoState(now: Date(), calendar: await settings.calendar) : LedgerState.empty
        let hasLocalModel = await settings.decisionBaseURL != nil
        if hasLocalModel, state.decisionPolicy.provider == .off {
            state.decisionPolicy.provider = .localDecide
        } else if !hasLocalModel, state.decisionPolicy.provider == .localDecide {
            // The demo ledger decides with the phone's stand-in model; a server with no local model says it's off.
            state.decisionPolicy.provider = .off
        }
        return state
    }
}

// MARK: - HTTP helpers

enum HTTP {
    /// The same coding the iPhone app's RemoteBudgetAPI uses.
    static let encoder = RemoteBudgetAPI.encoder
    static let decoder = RemoteBudgetAPI.decoder

    static func json(_ value: some Encodable, status: HTTPResponse.Status = .ok) throws -> Response {
        let data = try encoder.encode(value)
        return Response(status: status, headers: [.contentType: "application/json"], body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    static func error(_ status: HTTPResponse.Status, _ message: String) -> Response {
        let data = (try? JSONEncoder().encode(["error": message])) ?? Data()
        return Response(status: status, headers: [.contentType: "application/json"], body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    /// A row id from the path. Clients send it as one percent-encoded segment (a statement row's id can hold a slash).
    static func rowID(_ context: some RequestContext) throws -> String {
        let raw = try context.parameters.require("id")
        return raw.removingPercentEncoding ?? raw
    }

    static func body<T: Decodable>(_ type: T.Type, _ request: Request, limit: Int = 8 * 1024 * 1024) async throws -> T {
        let buffer = try await request.body.collect(upTo: limit)
        return try decoder.decode(T.self, from: Data(buffer.readableBytesView))
    }

    /// Maps domain errors onto statuses the app understands.
    /// A provider's refusal in its own words: Plaid's `error_message` (+ `error_code`).
    static func providerMessage(_ e: SourceHTTPError) -> String {
        if let object = try? JSONSerialization.jsonObject(with: Data(e.body.utf8)) as? [String: Any],
           let message = object["error_message"] as? String {
            return "Plaid: \(message)" + ((object["error_code"] as? String).map { " (\($0))" } ?? "")
        }
        return "The provider answered \(e.status): \(e.body.prefix(200))"
    }

    /// Ask's model failing, said as that and by name: a stopped Olares app answers its gateway's HTML 502 page, which
    /// used to reach the phone as raw HTML in a 500 — read as this server failing, not the model.
    static func chatModelDown(_ error: any Error, _ models: ModelSnapshot) -> BudgetAPIError {
        let model = models.chatURL.map { "\(models.chatName) at \($0.host() ?? $0.absoluteString)" } ?? models.chatName
        let path = models.chatURL.map { OpenAIChatModel(baseURL: $0, model: models.chatName).endpoint.path } ?? "/v1/chat/completions"
        var why = ModelCheck.explain(error, path: path, key: models.chatKey, decision: false)
        // On the phone "the server" reads as the Budget server; here it's the model's.
        if why.hasPrefix("The server ") { why = "Its server " + why.dropFirst("The server ".count) }
        if !why.hasSuffix("."), !why.hasSuffix("?") { why += "." }
        return .server(status: 502, message: "Ask's model, \(model), isn't answering. \(why) If it's a model you host, check that it's "
            + "running; or pick another model on the dashboard, under Settings → Models.")
    }

    static func respond(to error: any Error) -> Response {
        switch error {
        case let e as BudgetAPIError:
            switch e {
            case .notFound: return self.error(.notFound, e.localizedDescription)
            case let .rejected(message): return self.error(.unprocessableContent, message)
            // Here these are the bank provider's, not the phone's reach to this server.
            case .unreachable, .offline: return self.error(.badGateway, "Couldn't reach the bank data provider.")
            case .timedOut: return self.error(.gatewayTimeout, "The bank data provider took too long to answer.")
            case let .server(status, message): return self.error(HTTPResponse.Status(code: status), message ?? "Server error")
            case let .decoding(detail): return self.error(.badRequest, detail)
            }
        case let e as ToolArgumentError: return self.error(.unprocessableContent, e.localizedDescription)
        case let e as FileImport.ParseError: return self.error(.unprocessableContent, e.message)
        case let e as SourceHTTPError: return self.error(.badGateway, providerMessage(e))
        case is DecodingError: return self.error(.badRequest, "Malformed request body: \(error)")
        case let e as HTTPError: return self.error(e.status, e.body ?? "\(e.status)")
        // A body past the route's limit (`body(_:_:limit:)`).
        case is NIOTooManyBytesError: return self.error(.contentTooLarge, "That's too much to send at once.")
        // Anything else says what it is in its own words (the assistant running out of tokens, a model's error) rather
        // than as a Swift case name.
        default: return self.error(.internalServerError, (error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }
}

// MARK: - Auth

/// Which listener a router serves.
public enum Surface: Sendable {
    /// The phone's API: bearer token on every /v1 route, Origin check on writes.
    case api
    /// The browser dashboard, reached only through an Olares `private` entrance, so the person has
    /// already signed in to Olares. No token; writes must carry `X-Budget-Dashboard: 1`, which a
    /// cross-site page can't send without a CORS preflight this server never approves, and must
    /// come from the dashboard's own origin.
    case dashboard
}

struct AuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let surface: Surface
    let token: String?
    let allowedOrigins: [String]
    /// Without a token the API refuses every non-public request, unless the server is the loopback demo carve-out
    /// (`ServerConfig.tokenlessAPIAllowed`). The start check already refuses such a server; this is the second line.
    var tokenlessDemo = false
    /// Counts the requests the token check turns away (the API surface only).
    var access: AccessWatch? = nil

    /// Routes on the API surface that take no bearer token and no Origin check, as "METHOD /path". Plaid's webhook
    /// carries its own auth (a signed JWT the route verifies); the rest are a health probe and the phone's Universal
    /// Link files, which hold nothing private. Everything else on the API needs the token: the check denies by default
    /// rather than keying on a "/v1" prefix, so a path the router reads differently from the check (`//v1/overview`,
    /// which the router's split still sends to `/v1/overview`) can't slip past it.
    static var publicRoutes: Set<String> {
        ["POST /v1/plaid/webhook",
         "GET /health", "HEAD /health",
         "GET /.well-known/apple-app-site-association", "HEAD /.well-known/apple-app-site-association",
         "GET /plaid/oauth-return", "HEAD /plaid/oauth-return"]
    }

    /// Exactly a public route: the method and the path as sent, with no prefix match, case folding or trailing-slash
    /// tidying, so anything else (`/v1/plaid/webhook/`, `/V1/…`, `…/../admin/reset`) still needs the token.
    static func isPublic(_ request: Request) -> Bool {
        publicRoutes.contains("\(request.method.rawValue) \(request.uri.path)")
    }

    /// A path the router would read differently from how it's written: an empty segment (`//`), which the router drops,
    /// or no leading slash. Refused outright on both surfaces, so no check ever has to guess which form the router sees.
    static func isMalformed(_ path: String) -> Bool {
        !path.hasPrefix("/") || path.contains("//")
    }

    /// The request carries exactly this token, compared in constant time so the answer's timing says nothing about how
    /// much of a guess was right.
    static func carries(_ token: String, _ headers: HTTPFields) -> Bool {
        guard let sent = headers[.authorization] else { return false }
        return PlaidWebhookVerifier.constantTimeEqual(sent, "Bearer \(token)")
    }

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        if Self.isMalformed(path) { return HTTP.error(.badRequest, "That path isn't well formed.") }
        let isWrite = request.method != .get && request.method != .head
        switch surface {
        case .api:
            if Self.isPublic(request) { return try await next(request, context) }
            if let token, !token.isEmpty {
                guard Self.carries(token, request.headers) else {
                    await access?.record(AccessWatch.kind(request.headers), address: AccessWatch.clientAddress(request.headers), path: path)
                    return HTTP.error(.unauthorized, "Missing or wrong API token.")
                }
            } else if !tokenlessDemo {
                // Nothing to check against is a closed door, not an open one.
                return HTTP.error(.unauthorized, "This server has no API token: set BUDGET_API_TOKEN in budget.env and restart it.")
            }
            if isWrite, let origin = request.headers[.origin], !allowedOrigins.contains(origin) {
                return HTTP.error(.forbidden, "Cross-origin writes aren't allowed.")
            }
        case .dashboard:
            // Every write, whatever its path: the dashboard's page and its assets are reads.
            if isWrite {
                guard request.headers[HTTPField.Name("X-Budget-Dashboard")!] == "1" else { return HTTP.error(.forbidden, "Dashboard writes need the X-Budget-Dashboard header.") }
                if let origin = request.headers[.origin] {
                    // An opaque origin ("null": a sandboxed frame, a file, a cross-site redirect) is never the dashboard's own.
                    guard let host = URL(string: origin)?.host else { return HTTP.error(.forbidden, "Cross-origin writes aren't allowed.") }
                    let served = [request.head.authority, request.headers[HTTPField.Name("X-Forwarded-Host")!]].compactMap { $0?.split(separator: ":").first.map(String.init) }
                    guard served.contains(host) else { return HTTP.error(.forbidden, "Cross-origin writes aren't allowed.") }
                }
            }
        }
        return try await next(request, context)
    }
}

/// Every error becomes a JSON body with a meaningful status.
struct ErrorMiddleware<Context: RequestContext>: RouterMiddleware {
    let logger: Logger
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        do {
            return try await next(request, context)
        } catch {
            let response = HTTP.respond(to: error)
            if response.status.code >= 500 { logger.error("\(request.method) \(request.uri.path): \(error)") }
            return response
        }
    }
}

// MARK: - Request bodies

struct ConfirmBody: Decodable { let categoryID: String }
/// `conversationID` continues that conversation (`sessionID` is the same thing by its other name).
/// `capabilities` (0.5.0+ apps): what the app can take back from Ask (`AskCapabilities`); none means an app from before
/// 0.5.0, which is never offered what it can't decode or apply.
struct AskBody: Decodable { let question: String; let conversationID: String?; let sessionID: String?; let capabilities: [String]? }
/// `scenarioID` (0.5.0) projects with a Plan scenario's changes on top; an older server ignores it.
struct ProjectionBody: Decodable { let horizonMonths: Int; let goal: GoalQuery?; let scenarioID: String? }
/// `institutionID` (0.6.0 dashboards): Link's `institution_id`, for the one-Item-per-bank check and stored on the link.
struct PlaidExchangeBody: Decodable { let publicToken: String; let institution: String; var institutionID: String? = nil }
/// `afterUpdateMode` (0.6.0 dashboards): Plaid Link just finished update mode on the link (`SyncService.noteUpdateMode`).
/// No body is a plain sync.
struct LinkSyncBody: Decodable { var afterUpdateMode: Bool? = nil }
struct PlaidTokenBody: Decodable {
    let linkID: String?
    /// With `linkID`: update mode asking the person to consent to liabilities (the dashboard's "Grant card-bill access").
    var grantCardBills: Bool? = nil
}
struct SimpleFINBody: Decodable { let setupToken: String }
struct ImportBody: Decodable {
    let content: String
    let accountID: String?
    let options: FileImport.Options?
    let label: String?
    /// Work out what the import would do and return that report; nothing is saved.
    let preview: Bool?
}
struct ImportPreviewBody: Decodable { let files: [ImportBody] }
struct ApplyBody: Decodable { let apply: Bool? }
struct ResetBody: Decodable {
    let confirm: String
    let seedDemo: Bool?
    /// Also remove every linked account (revoked at Plaid), the import history, saved provider keys.
    let removeLinks: Bool?
    let clearImports: Bool?
    let removeProviderKeys: Bool?
    /// Keep the ledger (only remove the other things).
    let keepLedger: Bool?
}

// MARK: - [lane P] revoke

/// Stops a link at its provider where that's possible (Plaid `/item/remove`). A live Item's link may only be dropped once
/// Plaid confirms the removal (or says the Item is already gone): deleting the only copy of its token otherwise leaves a
/// live, billed Item nobody can remove (ITEM-005). So this throws when Plaid didn't confirm, and the caller keeps the link
/// for another try. Nothing to remove (no live Item), nothing to remove it with (no BUDGET_TOKEN_KEY, no Plaid keys, a
/// token that won't open) or a sandbox Item (never billed) never stops the removal here.
func revoke(_ link: StoredLink, _ service: BudgetService) async throws {
    // An empty token is an Item Plaid already deleted (ITEM_NOT_FOUND): there's nothing left to remove.
    guard link.hasLiveItem, let sealer = service.sealer else { return }
    guard let plaid = try? await service.providers.plaid(), let accessToken = try? sealer.open(link.sealedToken) else {
        service.logger.warning("couldn't remove \(link.institution) at Plaid: no Plaid keys or the token won't open (removed here anyway)")
        return
    }
    do {
        try await PlaidSource.removeItem(accessToken: accessToken, environment: plaid.environment,
                                         credentials: .init(clientID: plaid.clientID, secret: plaid.secret), transport: service.providers.transport)
        service.logger.info("revoked Plaid item for \(link.institution)")
    } catch where PlaidErrors.plaidError(error)?.errorCode == "ITEM_NOT_FOUND" {
        service.logger.info("Plaid had already removed the item for \(link.institution)")
    } catch {
        if plaid.environment == .sandbox {
            service.logger.warning("couldn't revoke sandbox item for \(link.institution) (removed here anyway): \(error)")
            return
        }
        service.logger.warning("couldn't revoke \(link.institution) at Plaid, so it's kept: \(error)")
        throw BudgetAPIError.server(status: 502, message: ItemRemoval.notConfirmed([link.institution]))
    }
}

enum ItemRemoval {
    /// What the dashboard says when Plaid didn't confirm removing an Item (kept under its 180-character limit).
    static func notConfirmed(_ institutions: [String]) -> String {
        let names = institutions.map { $0.count > 30 ? String($0.prefix(29)) + "…" : $0 }
        let list = names.count > 2 ? "\(names.count) banks" : names.joined(separator: " and ")
        return "Plaid didn't confirm removing \(list), so \(names.count == 1 ? "it's" : "they're") kept (Plaid would go on billing). Try again in a minute."
    }
}

// MARK: - [end lane P] revoke

// MARK: - Router

public func buildRouter(_ service: BudgetService, surface: Surface = .api) -> Router<BasicRequestContext> {
    let router = Router()
    router.add(middleware: ErrorMiddleware(logger: service.logger))
    router.add(middleware: AuthMiddleware(surface: surface, token: service.config.apiToken, allowedOrigins: service.config.allowedOrigins,
                                          tokenlessDemo: service.config.tokenlessAPIAllowed, access: surface == .api ? service.access : nil))
    if surface == .dashboard {
        addDashboardRoutes(router, service)
        TestHooks.addRoutes(router, service)
    }
    let api = service.api

    // The version only to the dashboard and to a request with the token: to anyone else it says which release to try.
    let token = service.config.apiToken
    router.get("/health") { request, _ in
        let known = surface == .dashboard || token?.isEmpty != false || AuthMiddleware<BasicRequestContext>.carries(token!, request.headers)
        return try HTTP.json(known ? ["status": "ok", "version": BudgetServerVersion.current] : ["status": "ok"])
    }

    // The contract in docs/API.md — same shapes RemoteBudgetAPI decodes.
    router.get("/v1/overview") { _, _ in try HTTP.json(try await api.overview()) }
    /// `?month=2026-09`; without one, this month.
    router.get("/v1/budget") { request, _ in try HTTP.json(try await api.budget(month: request.uri.queryParameters.get("month"))) }
    router.get("/v1/categories") { _, _ in try HTTP.json(try await api.categories()) }
    /// `?months=12` (the default), at most 36.
    router.get("/v1/categories/:id/history") { request, context in
        let months = try request.uri.queryParameters.get("months").map { raw in
            guard let n = Int(raw), n >= 1 else { throw BudgetAPIError.decoding("months must be a whole number, 1 or more, got “\(raw)”") }
            return n
        } ?? 12
        return try HTTP.json(try await api.categoryHistory(id: try HTTP.rowID(context), months: months))
    }
    router.get("/v1/rules") { _, _ in try HTTP.json(try await api.rules()) }
    router.get("/v1/memory") { _, _ in try HTTP.json(try await api.rememberedMerchants()) }
    router.get("/v1/spending") { request, _ in
        let range = request.uri.queryParameters.get("range").flatMap(SpendingRange.init(rawValue:)) ?? .thisMonth
        return try HTTP.json(try await api.spending(range))
    }
    /// The filter as the app's `TransactionFilter.queryItems` sent it; bare days read in the ledger's time zone.
    @Sendable func filter(_ request: Request) async throws -> TransactionFilter {
        let items = request.uri.queryParameters.map { URLQueryItem(name: String($0.key), value: String($0.value)) }
        return try TransactionFilter(queryItems: items, calendar: await service.settings.calendar)
    }
    router.get("/v1/transactions") { request, _ in try HTTP.json(try await api.transactions(try await filter(request))) }
    router.get("/v1/transactions/summary") { request, _ in try HTTP.json(try await api.transactionSummary(try await filter(request))) }
    router.get("/v1/transactions/:id") { _, context in try HTTP.json(try await api.transaction(id: try HTTP.rowID(context))) }
    router.get("/v1/review") { _, _ in try HTTP.json(try await api.reviewQueue()) }
    router.post("/v1/review/:id") { request, context in
        let body = try await HTTP.body(ConfirmBody.self, request)
        return try HTTP.json(try await api.confirmCategory(transactionID: try HTTP.rowID(context), categoryID: body.categoryID))
    }
    router.post("/v1/ask") { request, _ in
        let body = try await HTTP.body(AskBody.self, request)
        do {
            return try HTTP.json(try await api.ask(body.question, conversationID: body.conversationID ?? body.sessionID,
                                                   capabilities: AskCapabilities(names: body.capabilities)))
        } catch let error where error is DecisionError || error is URLError {
            throw HTTP.chatModelDown(error, await service.settings.modelSnapshot())
        }
    }
    router.post("/v1/projection") { request, _ in
        let body = try await HTTP.body(ProjectionBody.self, request)
        return try HTTP.json(try await api.projection(horizonMonths: body.horizonMonths, goal: body.goal, scenarioID: body.scenarioID))
    }
    router.get("/v1/status") { _, _ in try HTTP.json(try await api.serverStatus()) }
    // MARK: - [lane A] actions
    /// `Budget-Basis` (optional): the fingerprint an Ask proposal was made against. The change is refused with a 409,
    /// and nothing changes, when the rows it reaches changed since; without it the action applies as it is.
    router.post("/v1/actions") { request, _ in
        let action = try await HTTP.body(AppAction.self, request)
        let basis = request.headers[HTTPField.Name("Budget-Basis")!].flatMap { $0.isEmpty ? nil : $0 }
        return try HTTP.json(try await api.perform(action, basis: basis))
    }
    /// What the action would do; nothing changes. A write only in method: it takes a body, so it's POST.
    router.post("/v1/actions/preview") { request, _ in
        let action = try await HTTP.body(AppAction.self, request)
        guard !action.isClientOnly else { throw BudgetAPIError.rejected("\(action.toolName) is handled on the device.") }
        return try HTTP.json(try await api.preview(action))
    }
    // MARK: - [end lane A] actions
    router.get("/v1/assistant") { _, _ in try HTTP.json(try await api.assistantConfig()) }
    router.get("/v1/checkup") { _, _ in try HTTP.json(try await api.checkup()) }
    router.get("/v1/subscriptions") { _, _ in try HTTP.json(try await api.subscriptions()) }
    router.get("/v1/savings") { _, _ in try HTTP.json(try await api.savingsPlan()) }
    /// `?days=30` (the default), 1–366.
    router.get("/v1/upcoming") { request, _ in
        let days = try request.uri.queryParameters.get("days").map { raw in
            guard let n = Int(raw), (1...366).contains(n) else { throw BudgetAPIError.decoding("days must be a whole number from 1 to 366, got “\(raw)”") }
            return n
        } ?? 30
        return try HTTP.json(try await api.upcoming(days: days))
    }

    addTransactionToolRoutes(router, service)
    addLinkRoutes(router, service, surface: surface)
    addImportRoutes(router, service, surface: surface)
    addMerchantRoutes(router, service)
    addMorningSummaryRoutes(router, service)
    addAssistantRoutes(router, service)
    addPaceAlertRoutes(router, service)
    addNetWorthRoutes(router, service)
    addPlanRoutes(router, service)
    addRecapRoutes(router, service)
    addReconnectRoutes(router, service)
    addLedgerSafetyRoutes(router, service, surface: surface)
    if surface == .api {
        addPlaidWebhookRoutes(router, service)
        addAppLinkRoutes(router, service)
    }
    return router
}

// MARK: - Links (Plaid, SimpleFIN) and sync

/// What only the dashboard may do (SPEC §10, P0.2): add or remove a bank link, give a link a new token, erase the
/// ledger, list the import history, sweep import duplicates, and undo a sync's batch. The phone's token keeps reading,
/// syncing, signing in again (`/v1/links/:id/reconnect`) and file imports. On the API those routes aren't there (404),
/// so a lost phone or a leaked token can't unlink banks or wipe the ledger.
enum DashboardOnly {
    /// Said by a route on both surfaces that refuses one case on the API (a sync's batch to `DELETE /v1/imports/:batch`).
    static let message = "Only the Budget dashboard can do that: the phone can't add or remove bank links or erase data."
}

func addLinkRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService, surface: Surface) {
    @Sendable func requireSealer() throws -> TokenSealer {
        guard let sealer = service.sealer else { throw BudgetAPIError.rejected("Set BUDGET_TOKEN_KEY on the server before linking accounts.") }
        return sealer
    }

    router.get("/v1/links") { _, _ in try HTTP.json(try await service.store.links().map(\.summary)) }

    /// A Link token for Plaid Link. With `linkID`, Link opens in update mode for that Item: the person signs in again
    /// and the Item (with its accounts and history) carries on — there's no public token to exchange afterwards, just
    /// `POST /v1/links/:id/sync`. An unknown or non-Plaid `linkID` is refused rather than starting a second Item.
    /// `grantCardBills` with a `linkID` opens the same update mode to add liabilities consent (card bills) to that Item;
    /// only the person's click on the dashboard asks for it.
    // MARK: - [lane P] Plaid link routes
    if surface == .dashboard {  // P0.2: linking a bank is the dashboard's
        router.post("/v1/links/plaid/token") { request, _ in
            guard let plaid = try await service.providers.plaid() else { throw BudgetAPIError.rejected("Plaid isn't set up yet. Add its keys on the dashboard (Connect a bank → Plaid).") }
            let body = (try? await HTTP.body(PlaidTokenBody.self, request)) ?? PlaidTokenBody(linkID: nil)
            if body.grantCardBills == true, body.linkID == nil { throw BudgetAPIError.rejected("Granting card-bill access needs the link it's for.") }
            var accessToken: String?
            var renewal = false
            // A new Item needs somewhere to keep its token: without BUDGET_TOKEN_KEY, Link never opens (an Item made then
            // would be lost, still billed and in a Trial slot).
            if body.linkID == nil { _ = try requireSealer() }
            if let linkID = body.linkID {
                guard let link = try await service.store.links().first(where: { $0.id == linkID }) else { throw BudgetAPIError.notFound }
                guard link.provider == .plaid else { throw BudgetAPIError.rejected("\(link.institution) connects through \(link.provider.displayName), not Plaid.") }
                // Update mode needs a live Item; one Plaid deleted can only be linked again.
                guard link.hasLiveItem else { throw BudgetAPIError.rejected(SyncService.itemGoneMessage(link)) }
                accessToken = try requireSealer().open(link.sealedToken)
                // A working link opened in update mode is "Renew access": Plaid's reauthorization renews the bank's consent
                // (as the phone's renewal does); without it Link would find nothing to fix.
                renewal = body.grantCardBills != true && !LinkHealthBook.waitsForPerson(link)
            }
            // WEBHOOK-002: a new Item takes this server's webhook URL from its link token.
            let webhook = await PlaidMaintenance.webhookURL(service.settings, sandbox: plaid.environment == .sandbox)
            // OAUTH-005: a return address, when one is set, goes on every link token, update mode included. None is set on a
            // computer install: desktop Link opens OAuth banks in a pop-up without one (`PlaidRedirect`).
            let token: String
            do {
                token = try await PlaidSource.linkToken(environment: plaid.environment, credentials: .init(clientID: plaid.clientID, secret: plaid.secret),
                                                        userID: "owner", investments: true, redirectURI: plaid.redirectURI,
                                                        accessToken: accessToken, grantLiabilities: body.grantCardBills == true,
                                                        webhook: webhook, reauthorization: renewal, transport: service.providers.transport)
            } catch {
                if let redirect = plaid.redirectURI, PlaidRedirect.refusedReturnAddress(error) { throw PlaidRedirect.unknownAddress(redirect) }
                throw error
            }
            return try HTTP.json(["linkToken": token])
        }

        router.post("/v1/links/plaid/exchange") { request, _ in
            guard let plaid = try await service.providers.plaid() else { throw BudgetAPIError.rejected("Plaid isn't set up yet. Add its keys on the dashboard.") }
            let body = try await HTTP.body(PlaidExchangeBody.self, request)
            let institutionID = StoredLink.institutionID(body.institutionID)
            // ITEM-011: one Item per bank, checked before the exchange, so a second Item never comes to exist on this server
            // (each one uses up a Plaid Trial slot). The public token is left to expire unexchanged. The check, the exchange
            // and the insert take one turn in the sync queue, so two exchanges for the same bank at once (two tabs) can't
            // both pass the check.
            // Checked before the exchange: once exchanged, an Item that can't be stored is lost but still billed.
            let sealer = try requireSealer()
            let link = try await service.sync.serialized { () async throws -> StoredLink in
                let before = try await service.store.links()
                if let existing = StoredLink.duplicateItem(in: before, institutionID: institutionID, institution: body.institution) {
                    service.logger.info("plaid exchange refused: \(existing.id) already holds an Item at that bank")
                    throw BudgetAPIError.server(status: 409, message: StoredLink.duplicateItemMessage(existing))
                }
                let credentials = PlaidSource.Credentials(clientID: plaid.clientID, secret: plaid.secret)
                let exchanged = try await PlaidSource.exchange(publicToken: body.publicToken, environment: plaid.environment,
                                                               credentials: credentials, transport: service.providers.transport)
                var link = StoredLink(id: "plaid-" + exchanged.itemID, provider: .plaid, institution: body.institution, externalID: exchanged.itemID,
                                      sealedToken: "", cursor: nil, status: .connected,
                                      lastSync: nil, lastError: nil, createdAt: Date())
                if let institutionID {
                    var plaid = PlaidLinkState()
                    plaid.institutionID = institutionID
                    link.plaid = plaid
                }
                do {
                    link.sealedToken = try sealer.seal(exchanged.accessToken)
                    try await service.store.upsertLink(link)
                } catch {
                    // The Item exists at Plaid but can't be kept here: remove it while the token is still in hand, so it
                    // isn't left billed with no way to reach it.
                    service.logger.error("couldn't store the new Plaid item for \(body.institution) (\(error)); removing it at Plaid")
                    do {
                        try await PlaidSource.removeItem(accessToken: exchanged.accessToken, environment: plaid.environment,
                                                         credentials: credentials, transport: service.providers.transport)
                    } catch let removal {
                        service.logger.error("couldn't remove the unstored Plaid item for \(body.institution) either: \(removal)")
                    }
                    throw error
                }
                // Linking again after access was withdrawn: the old Item still exists (it kept its token). Remove it now
                // that the new one has taken over, and drop its token; its accounts and rows stay. A failure leaves it for
                // the person's Remove on the dashboard.
                for old in StoredLink.withdrawnItems(in: before, institutionID: institutionID, institution: body.institution) {
                    do {
                        try await revoke(old, service)
                        var gone = old
                        gone.sealedToken = ""
                        try await service.store.upsertLink(gone)
                    } catch {
                        service.logger.warning("couldn't remove the withdrawn Plaid item for \(old.institution) after linking it again: \(error)")
                    }
                }
                return link
            }
            let result = try await service.sync.sync(linkID: link.id, trigger: .afterLink)
            return try HTTP.json(result, status: .created)
        }
    }
    // MARK: - [end lane P] Plaid link routes

    // MARK: - [lane S] SimpleFIN link routes

    if surface == .dashboard {  // P0.2: linking a bank is the dashboard's
        router.post("/v1/links/simplefin") { request, _ in
            let body = try await HTTP.body(SimpleFINBody.self, request)
            // Checked before the claim: a setup token works once, so claiming it on a server that can't seal the access
            // address would burn it and drop the address (the replace path and Plaid check first too).
            let sealer = try requireSealer()
            let accessURL = try await SimpleFINSync.claim(body.setupToken, throwaway: service.config.isThrowaway, transport: service.providers.transport)
            let id = "simplefin-" + UUID().uuidString.prefix(8)
            let link = StoredLink(id: id, provider: .simplefin, institution: "SimpleFIN Bridge", externalID: nil,
                                  sealedToken: try sealer.seal(accessURL.absoluteString), cursor: nil, status: .connected,
                                  lastSync: nil, lastError: nil, createdAt: Date())
            try await service.store.upsertLink(link)
            return try HTTP.json(try await service.sync.sync(linkID: id, trigger: .afterLink), status: .created)
        }
    }

    // A link id is never "plaid" or "simplefin" (it's "<provider>-<id>"), so these parameter routes never
    // meet the static segments above — the router takes a matching static segment and doesn't fall back.

    /// Syncs one link now; for a link waiting for a sign-in, a retry. Plaid's reconnect ends here. One bank's row of a
    /// SimpleFIN link (`<linkID>~<bank>`, what an app before 0.6.0 sends back) syncs the link.
    router.post("/v1/links/:id/sync") { request, context in
        // Update mode is the dashboard's (the phone's arrives as the reconnect session's own sync), so only the dashboard
        // may say it just finished: on the API it would clear a PENDING_DISCONNECT warning without any sign-in.
        let claimed = (try? await HTTP.body(LinkSyncBody.self, request))?.afterUpdateMode == true
        let afterUpdateMode = surface == .dashboard && claimed
        let linkID = SimpleFINLinkState.linkID(fromRowID: try HTTP.rowID(context))
        return try HTTP.json(try await service.sync.sync(linkID: linkID, trigger: .personLink, afterUpdateMode: afterUpdateMode))
    }

    if surface == .dashboard {  // P0.2: a new setup token is the dashboard's
        /// A SimpleFIN link SimpleFIN stopped accepting: a new setup token, the same link (its accounts and history carry on).
        /// Answers the sync's result, plus `note` when the accounts came back under new ids.
        router.put("/v1/links/:id/token") { request, context in
            let body = try await HTTP.body(SimpleFINBody.self, request)
            let (result, note) = try await service.sync.replaceSimpleFINToken(linkID: SimpleFINLinkState.linkID(fromRowID: try HTTP.rowID(context)), setupToken: body.setupToken)
            return try HTTP.json(ReplacedToken(result: result, note: note))
        }
    }
    // MARK: - [end lane S] SimpleFIN link routes

    if surface == .dashboard {  // P0.2: removing a link is the dashboard's
        /// Removes the link (stops syncing). Its rows stay; roll back its batches to remove them.
        router.delete("/v1/links/:id") { _, context in
            let id = try context.parameters.require("id")
            // In the link's turn, so a sync or Item check already holding the link can't write it back after the delete.
            try await service.sync.serialized {
                if let link = try await service.store.links().first(where: { $0.id == id }) { try await revoke(link, service) }
                try await service.store.deleteLink(id)
            }
            await service.sync.publishInstitutions()
            return Response(status: .noContent)
        }
    }

    /// Every link now. `{"requestedByPerson": true}` is the person asking; no body (older phones, scripts) is a
    /// scheduled run.
    router.post("/v1/sync") { request, _ in
        let body = try? await HTTP.body(SyncRequest.self, request, limit: 64 * 1024)
        return try HTTP.json(await service.sync.syncAll(trigger: body?.requestedByPerson == true ? .person : .schedule))
    }
}

// MARK: - File imports and rollback

// MARK: - [lane L] addImportRoutes
func addImportRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService, surface: Surface) {
    if surface == .dashboard {  // P0.2: the import history, sync batches among it, is the dashboard's
        router.get("/v1/imports") { _, _ in try HTTP.json(await ImportUndo.annotated(try await service.store.imports(), service)) }
    }

    /// CSV / OFX / QFX text. `accountID` files the rows into an existing account, or `options.accountName` into a new one.
    /// A file's rows as a snapshot, with a CSV's signs read by the kind of account it's filed into. An OFX file's ids are
    /// made unreadable (`StatementIDs`); it waits (503) while the ledger's own statement ids are being upgraded.
    @Sendable func snapshot(_ body: ImportBody) async throws -> SourceSnapshot {
        var options = body.options ?? FileImport.Options()
        if options.accountKind == nil, let id = body.accountID, let account = try await service.api.overview().accounts.first(where: { $0.id == id }) {
            options.accountKind = account.kind
        }
        if FileImport.format(of: body.content, options: options) == .ofx, let ids = service.statementIDs, !ids.gate.isOpen {
            throw BudgetAPIError.server(status: 503, message: "Statement ids are being upgraded; try again after a restart.")
        }
        let snapshot = try FileImport.parse(body.content, options: options, ids: service.statementIDs)
        if body.accountID == nil, snapshot.accounts.first?.externalID == "file" {
            throw BudgetAPIError.rejected("Statement files need an account: choose one, or name a new one (options.accountName).")
        }
        return snapshot
    }

    router.post("/v1/imports") { request, _ in
        let body = try await HTTP.body(ImportBody.self, request, limit: 32 * 1024 * 1024)
        let snapshot = try await snapshot(body)
        if body.preview == true { return try HTTP.json(try await service.api.previewIngest(snapshot, into: body.accountID)) }
        let batchID = "file-" + UUID().uuidString.lowercased().prefix(12)
        let report = try await service.api.ingest(snapshot, batchID: batchID, into: body.accountID)
        // A file name can hold the account number ("Checking_9876543210123.qfx").
        let record = ImportRecord(batchID: batchID, kind: .file, linkID: nil, label: StatementIDs.maskNumbers(body.label ?? "File import"),
                                  report: report, createdAt: Date(), rolledBack: false)
        try await service.store.upsertImport(record)
        return try HTTP.json(record.annotated(), status: .created)
    }

    /// `{files: [import bodies]}` → one `IngestReport` per file, worked out in order without saving.
    router.post("/v1/imports/preview") { request, _ in
        let body = try await HTTP.body(ImportPreviewBody.self, request, limit: 64 * 1024 * 1024)
        var files: [(snapshot: SourceSnapshot, into: String?)] = []
        for file in body.files { files.append((try await snapshot(file), file.accountID)) }
        return try HTTP.json(try await service.api.previewIngest(files))
    }

    if surface == .dashboard {  // P0.2: removing imported copies is the dashboard's
        /// Imported rows that a later sync also brought in. `{apply: true}` removes the imported copies.
        router.post("/v1/imports/duplicates") { request, _ in
            let body = try await HTTP.body(ApplyBody.self, request)
            return try HTTP.json(try await service.api.importDuplicates(apply: body.apply == true))
        }
    }

    @Sendable func importRecord(_ context: BasicRequestContext) async throws -> ImportRecord {
        let batch = try context.parameters.require("batch")
        guard let record = try await service.store.imports().first(where: { $0.batchID == batch }) else { throw BudgetAPIError.notFound }
        return record
    }

    /// What Undo would do with a batch (`RollbackPlan`): how many rows, how many come back at the next sync, and
    /// whether it's refused (Plaid: hide instead).
    router.get("/v1/imports/:batch/undo") { _, context in
        try HTTP.json(try await ImportUndo.plan(for: try await importRecord(context), service))
    }

    /// Rolls a batch back. 409, changing nothing, when Undo is refused (a Plaid sync), and when SimpleFIN rows could
    /// come back (at the next sync, or once linked again) unless `?acknowledge=returning`. On the API only a file's batch
    /// (P0.2): a sync's batch answers 404 there and is undone on the dashboard.
    router.delete("/v1/imports/:batch") { request, context in
        let record = try await importRecord(context)
        if surface == .api, record.kind != .file { throw BudgetAPIError.server(status: 404, message: DashboardOnly.message) }
        let policy = ImportUndo.policy(for: record)
        if policy.mode == .refused { throw BudgetAPIError.server(status: 409, message: policy.message) }
        let removed = try await service.api.rollback(batchID: record.batchID, nextWindowStart: try await ImportUndo.nextWindowStart(for: record, service),
                                                     acknowledgeReturning: request.uri.queryParameters.get("acknowledge") == "returning")
        // Read again after the ledger work and change only `rolledBack`, so a hide that ran meanwhile keeps its `hiddenAt`.
        var fresh = try await importRecord(context)
        fresh.rolledBack = true
        try await service.store.upsertImport(fresh)
        return try HTTP.json(["removed": removed])
    }

    /// Hides a batch's rows from every total instead of removing them (`ActionResult`, with its undo). `hiddenAt` is
    /// set whenever the batch's rows end up all hidden, so a retry after a failed save still marks the record.
    router.post("/v1/imports/:batch/hide") { _, context in
        let record = try await importRecord(context)
        let result = try await service.api.hideBatch(batchID: record.batchID)
        if await service.api.hiddenBatchIDs().contains(record.batchID) {
            var fresh = try await importRecord(context)
            if fresh.hiddenAt == nil || result.affectedTransactions > 0 {
                fresh.hiddenAt = Date()
                try await service.store.upsertImport(fresh)
            }
        }
        return try HTTP.json(result)
    }
    // MARK: - [end lane L] addImportRoutes

    if surface == .dashboard {  // P0.2: erasing is the dashboard's
        /// Erases the ledger (links and import history are kept). Guarded by a confirm phrase.
        router.post("/v1/admin/reset") { request, _ in
            let body = try await HTTP.body(ResetBody.self, request)
            guard body.confirm == "erase my ledger" else { throw BudgetAPIError.rejected("Send {\"confirm\": \"erase my ledger\"} to reset.") }
            if body.seedDemo == true, !service.config.allowDemo {
                throw BudgetAPIError.rejected("This server holds real accounts, so it won't load the demo ledger (set BUDGET_ALLOW_DEMO=1 on a test server).")
            }
            var removed: [String] = []
            if body.removeLinks == true {
                // In the queue's turn (no sync can write a link back), and a link whose Item Plaid didn't confirm removing
                // is kept; then nothing else is reset, so the person can try again.
                let (count, kept) = try await service.sync.serialized { () async throws -> (Int, [String]) in
                    var count = 0, kept: [String] = []
                    for link in try await service.store.links() {
                        do { try await revoke(link, service) } catch { kept.append(link.institution); continue }
                        try await service.store.deleteLink(link.id)
                        count += 1
                    }
                    return (count, kept)
                }
                await service.sync.publishInstitutions()
                if !kept.isEmpty { throw BudgetAPIError.server(status: 502, message: ItemRemoval.notConfirmed(kept) + " Nothing else was reset.") }
                removed.append("\(count) linked account\(count == 1 ? "" : "s")")
            }
            if body.clearImports == true { try await service.store.clearImports(); removed.append("import history") }
            if body.removeProviderKeys == true {
                try await service.providers.clearPlaid()
                await BudgetServerApp.apply(service)
                removed.append("Plaid keys")
            }
            if body.keepLedger != true {
                try await service.api.replaceState(await service.freshState(seedDemo: body.seedDemo == true))
                try await service.api.clearChatSessions() // conversations about the old ledger go with it
                try await service.api.resetBalanceHistory(seedDemo: body.seedDemo == true)
                removed.insert(body.seedDemo == true ? "the ledger (replaced with the demo)" : "all transactions and accounts", at: 0)
            }
            return try HTTP.json(["reset": "true", "removed": removed.joined(separator: ", ")])
        }
    }
}

// MARK: - Morning summary

struct TestSummaryBody: Decodable { let token: String }

func addMorningSummaryRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService) {
    /// `?day=2026-09-28`: that day's summary as the notification would tell it (saved, so the model writes it once).
    router.get("/v1/digest") { request, _ in
        guard let day = request.uri.queryParameters.get("day") else { throw BudgetAPIError.decoding("day is required, like ?day=2026-09-28") }
        return try HTTP.json(try await service.morning.digest(day: day))
    }
    /// The phone turning the summary on or off, or saying where it is now.
    router.post("/v1/devices") { request, _ in
        try HTTP.json(try await service.morning.register(try await HTTP.body(DeviceRegistration.self, request)))
    }
    /// Yesterday's summary to this phone, now.
    router.post("/v1/devices/test") { request, _ in
        try HTTP.json(try await service.morning.sendTest(token: try await HTTP.body(TestSummaryBody.self, request).token))
    }
}
