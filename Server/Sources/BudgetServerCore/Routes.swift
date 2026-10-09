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
    /// Plaid and Teller as configured right now (dashboard settings over environment).
    public let providers: Providers
    /// Models, sync, time zone, public URL — dashboard over environment over defaults.
    public let settings: ServerSettings
    public let logger: Logger

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
    /// A provider's refusal in its own words: Plaid's `error_message` (+ `error_code`), Teller's `error.message`.
    static func providerMessage(_ e: SourceHTTPError) -> String {
        if let object = try? JSONSerialization.jsonObject(with: Data(e.body.utf8)) as? [String: Any] {
            if let message = object["error_message"] as? String {
                return "Plaid: \(message)" + ((object["error_code"] as? String).map { " (\($0))" } ?? "")
            }
            if let inner = object["error"] as? [String: Any], let message = inner["message"] as? String { return "Teller: \(message)" }
        }
        return "The provider answered \(e.status): \(e.body.prefix(200))"
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

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        guard path.hasPrefix("/v1") || path.hasPrefix("/dash") else { return try await next(request, context) }
        let isWrite = request.method != .get && request.method != .head
        switch surface {
        case .api:
            if let token {
                guard request.headers[.authorization] == "Bearer \(token)" else { return HTTP.error(.unauthorized, "Missing or wrong API token.") }
            }
            if isWrite, let origin = request.headers[.origin], !allowedOrigins.contains(origin) {
                return HTTP.error(.forbidden, "Cross-origin writes aren't allowed.")
            }
        case .dashboard:
            if isWrite {
                guard request.headers[HTTPField.Name("X-Budget-Dashboard")!] == "1" else { return HTTP.error(.forbidden, "Dashboard writes need the X-Budget-Dashboard header.") }
                if let origin = request.headers[.origin], let host = URL(string: origin)?.host {
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
struct AskBody: Decodable { let question: String; let conversationID: String?; let sessionID: String? }
/// `scenarioID` (0.5.0) projects with a Plan scenario's changes on top; an older server ignores it.
struct ProjectionBody: Decodable { let horizonMonths: Int; let goal: GoalQuery?; let scenarioID: String? }
struct PlaidExchangeBody: Decodable { let publicToken: String; let institution: String }
struct PlaidTokenBody: Decodable { let linkID: String? }
struct TellerBody: Decodable { let accessToken: String; let enrollmentID: String?; let institution: String }
struct TellerTokenBody: Decodable { let accessToken: String; let enrollmentID: String? }
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

/// Stops a link at its provider where that's possible (Plaid `/item/remove`); failures are logged, not fatal,
/// so a dead or sandbox Item can always be removed locally.
func revoke(_ link: StoredLink, _ service: BudgetService) async {
    guard link.provider == .plaid, let sealer = service.sealer else { return }
    do {
        guard let plaid = try await service.providers.plaid() else { return }
        try await PlaidSource.removeItem(accessToken: try sealer.open(link.sealedToken), environment: plaid.environment,
                                         credentials: .init(clientID: plaid.clientID, secret: plaid.secret), transport: service.providers.transport)
        service.logger.info("revoked Plaid item for \(link.institution)")
    } catch {
        service.logger.warning("couldn't revoke \(link.institution) at Plaid (removed here anyway): \(error)")
    }
}

// MARK: - Router

public func buildRouter(_ service: BudgetService, surface: Surface = .api) -> Router<BasicRequestContext> {
    let router = Router()
    router.add(middleware: ErrorMiddleware(logger: service.logger))
    router.add(middleware: AuthMiddleware(surface: surface, token: service.config.apiToken, allowedOrigins: service.config.allowedOrigins))
    if surface == .dashboard { addDashboardRoutes(router, service) }
    let api = service.api

    router.get("/health") { _, _ in
        try HTTP.json(["status": "ok", "version": BudgetServerVersion.current])
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
        return try HTTP.json(try await api.ask(body.question, conversationID: body.conversationID ?? body.sessionID))
    }
    router.post("/v1/projection") { request, _ in
        let body = try await HTTP.body(ProjectionBody.self, request)
        return try HTTP.json(try await api.projection(horizonMonths: body.horizonMonths, goal: body.goal, scenarioID: body.scenarioID))
    }
    router.get("/v1/status") { _, _ in try HTTP.json(try await api.serverStatus()) }
    router.post("/v1/actions") { request, _ in
        let action = try await HTTP.body(AppAction.self, request)
        return try HTTP.json(try await api.perform(action))
    }
    /// What the action would do; nothing changes. A write only in method: it takes a body, so it's POST.
    router.post("/v1/actions/preview") { request, _ in
        let action = try await HTTP.body(AppAction.self, request)
        guard !action.isClientOnly else { throw BudgetAPIError.rejected("\(action.toolName) is handled on the device.") }
        return try HTTP.json(try await api.preview(action))
    }
    router.get("/v1/assistant") { _, _ in try HTTP.json(try await api.assistantConfig()) }
    router.get("/v1/checkup") { _, _ in try HTTP.json(try await api.checkup()) }
    router.get("/v1/subscriptions") { _, _ in try HTTP.json(try await api.subscriptions()) }
    router.get("/v1/savings") { _, _ in try HTTP.json(try await api.savingsPlan()) }

    addTransactionToolRoutes(router, service)
    addLinkRoutes(router, service)
    addImportRoutes(router, service)
    addMerchantRoutes(router, service)
    addMorningSummaryRoutes(router, service)
    addAssistantRoutes(router, service)
    addPaceAlertRoutes(router, service)
    addNetWorthRoutes(router, service)
    addPlanRoutes(router, service)
    return router
}

// MARK: - Links (Plaid, Teller, SimpleFIN) and sync

func addLinkRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService) {
    @Sendable func requireSealer() throws -> TokenSealer {
        guard let sealer = service.sealer else { throw BudgetAPIError.rejected("Set BUDGET_TOKEN_KEY on the server before linking accounts.") }
        return sealer
    }

    router.get("/v1/links") { _, _ in try HTTP.json(try await service.store.links().map(\.summary)) }

    /// A Link token for Plaid Link. With `linkID`, Link opens in update mode for that Item: the person signs in again
    /// and the Item (with its accounts and history) carries on — there's no public token to exchange afterwards, just
    /// `POST /v1/links/:id/sync`. An unknown or non-Plaid `linkID` is refused rather than starting a second Item.
    router.post("/v1/links/plaid/token") { request, _ in
        guard let plaid = try await service.providers.plaid() else { throw BudgetAPIError.rejected("Plaid isn't set up yet — add its keys on the dashboard (Connect a bank → Plaid).") }
        let body = (try? await HTTP.body(PlaidTokenBody.self, request)) ?? PlaidTokenBody(linkID: nil)
        var accessToken: String?
        if let linkID = body.linkID {
            guard let link = try await service.store.links().first(where: { $0.id == linkID }) else { throw BudgetAPIError.notFound }
            guard link.provider == .plaid else { throw BudgetAPIError.rejected("\(link.institution) connects through \(link.provider.displayName), not Plaid.") }
            accessToken = try requireSealer().open(link.sealedToken)
        }
        let token = try await PlaidSource.linkToken(environment: plaid.environment, credentials: .init(clientID: plaid.clientID, secret: plaid.secret),
                                                    userID: "owner", investments: true, redirectURI: plaid.redirectURI,
                                                    accessToken: accessToken, transport: service.providers.transport)
        return try HTTP.json(["linkToken": token])
    }

    router.post("/v1/links/plaid/exchange") { request, _ in
        guard let plaid = try await service.providers.plaid() else { throw BudgetAPIError.rejected("Plaid isn't set up yet — add its keys on the dashboard.") }
        let body = try await HTTP.body(PlaidExchangeBody.self, request)
        let exchanged = try await PlaidSource.exchange(publicToken: body.publicToken, environment: plaid.environment,
                                                       credentials: .init(clientID: plaid.clientID, secret: plaid.secret), transport: service.providers.transport)
        let link = StoredLink(id: "plaid-" + exchanged.itemID, provider: .plaid, institution: body.institution, externalID: exchanged.itemID,
                              sealedToken: try requireSealer().seal(exchanged.accessToken), cursor: nil, status: .connected,
                              lastSync: nil, lastError: nil, createdAt: Date())
        try await service.store.upsertLink(link)
        let result = try await service.sync.sync(linkID: link.id)
        return try HTTP.json(result, status: .created)
    }

    router.post("/v1/links/teller") { request, _ in
        guard await service.providers.teller() != nil else { throw BudgetAPIError.rejected("Teller isn't set up yet — add its application ID on the dashboard (Connect a bank → Teller).") }
        let body = try await HTTP.body(TellerBody.self, request)
        let id = "teller-" + (body.enrollmentID ?? UUID().uuidString)
        let link = StoredLink(id: id, provider: .teller, institution: body.institution, externalID: body.enrollmentID,
                              sealedToken: try requireSealer().seal(body.accessToken), cursor: nil, status: .connected,
                              lastSync: nil, lastError: nil, createdAt: Date())
        try await service.store.upsertLink(link)
        return try HTTP.json(try await service.sync.sync(linkID: id), status: .created)
    }

    router.post("/v1/links/simplefin") { request, _ in
        let body = try await HTTP.body(SimpleFINBody.self, request)
        let accessURL = try await SimpleFINSource.claim(setupToken: body.setupToken)
        let id = "simplefin-" + UUID().uuidString.prefix(8)
        let link = StoredLink(id: id, provider: .simplefin, institution: "SimpleFIN Bridge", externalID: nil,
                              sealedToken: try requireSealer().seal(accessURL.absoluteString), cursor: nil, status: .connected,
                              lastSync: nil, lastError: nil, createdAt: Date())
        try await service.store.upsertLink(link)
        return try HTTP.json(try await service.sync.sync(linkID: id), status: .created)
    }

    // A link id is never "plaid", "teller" or "simplefin" (it's "<provider>-<id>"), so these parameter routes never
    // meet the static segments above — the router takes a matching static segment and doesn't fall back.

    /// Syncs one link now; for a link waiting for a sign-in, a retry. Plaid's reconnect ends here.
    router.post("/v1/links/:id/sync") { _, context in try HTTP.json(try await service.sync.sync(linkID: try HTTP.rowID(context))) }

    /// Teller's reconnect: the new access token for the enrollment replaces the stored one, then the link syncs.
    router.put("/v1/links/:id/token") { request, context in
        let body = try await HTTP.body(TellerTokenBody.self, request)
        return try HTTP.json(try await service.sync.replaceToken(linkID: try HTTP.rowID(context), accessToken: body.accessToken, enrollmentID: body.enrollmentID))
    }

    /// Removes the link (stops syncing). Its rows stay; roll back its batches to remove them.
    router.delete("/v1/links/:id") { _, context in
        let id = try context.parameters.require("id")
        if let link = try await service.store.links().first(where: { $0.id == id }) { await revoke(link, service) }
        try await service.store.deleteLink(id)
        await service.sync.publishInstitutions()
        return Response(status: .noContent)
    }

    router.post("/v1/sync") { _, _ in try HTTP.json(await service.sync.syncAll()) }
}

// MARK: - File imports and rollback

func addImportRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService) {
    router.get("/v1/imports") { _, _ in try HTTP.json(try await service.store.imports()) }

    /// CSV / OFX / QFX text. `accountID` files the rows into an existing account (needed for CSV).
    /// A file's rows as a snapshot, with a CSV's signs read by the kind of account it's filed into.
    @Sendable func snapshot(_ body: ImportBody) async throws -> SourceSnapshot {
        var options = body.options ?? FileImport.Options()
        if options.accountKind == nil, let id = body.accountID, let account = try await service.api.overview().accounts.first(where: { $0.id == id }) {
            options.accountKind = account.kind
        }
        let snapshot = try FileImport.parse(body.content, options: options)
        if body.accountID == nil, snapshot.accounts.first?.externalID == "file" {
            throw BudgetAPIError.rejected("CSV files carry no account number — pass accountID for an existing account, or options.accountName to create one.")
        }
        return snapshot
    }

    router.post("/v1/imports") { request, _ in
        let body = try await HTTP.body(ImportBody.self, request, limit: 32 * 1024 * 1024)
        let snapshot = try await snapshot(body)
        if body.preview == true { return try HTTP.json(try await service.api.previewIngest(snapshot, into: body.accountID)) }
        let batchID = "file-" + UUID().uuidString.lowercased().prefix(12)
        let report = try await service.api.ingest(snapshot, batchID: batchID, into: body.accountID)
        let record = ImportRecord(batchID: batchID, kind: .file, linkID: nil, label: body.label ?? "File import",
                                  report: report, createdAt: Date(), rolledBack: false)
        try await service.store.upsertImport(record)
        return try HTTP.json(record, status: .created)
    }

    /// `{files: [import bodies]}` → one `IngestReport` per file, worked out in order without saving.
    router.post("/v1/imports/preview") { request, _ in
        let body = try await HTTP.body(ImportPreviewBody.self, request, limit: 64 * 1024 * 1024)
        var files: [(snapshot: SourceSnapshot, into: String?)] = []
        for file in body.files { files.append((try await snapshot(file), file.accountID)) }
        return try HTTP.json(try await service.api.previewIngest(files))
    }

    /// Imported rows that a later sync also brought in. `{apply: true}` removes the imported copies.
    router.post("/v1/imports/duplicates") { request, _ in
        let body = try await HTTP.body(ApplyBody.self, request)
        return try HTTP.json(try await service.api.importDuplicates(apply: body.apply == true))
    }

    router.delete("/v1/imports/:batch") { _, context in
        let batch = try context.parameters.require("batch")
        guard var record = try await service.store.imports().first(where: { $0.batchID == batch }) else { throw BudgetAPIError.notFound }
        let removed = try await service.api.rollback(batchID: batch)
        record.rolledBack = true
        try await service.store.upsertImport(record)
        return try HTTP.json(["removed": removed])
    }

    /// Erases the ledger (links and import history are kept). Guarded by a confirm phrase.
    router.post("/v1/admin/reset") { request, _ in
        let body = try await HTTP.body(ResetBody.self, request)
        guard body.confirm == "erase my ledger" else { throw BudgetAPIError.rejected("Send {\"confirm\": \"erase my ledger\"} to reset.") }
        if body.seedDemo == true, !service.config.allowDemo {
            throw BudgetAPIError.rejected("This server holds real accounts, so it won't load the demo ledger (set BUDGET_ALLOW_DEMO=1 on a test server).")
        }
        var removed: [String] = []
        if body.removeLinks == true {
            let links = try await service.store.links()
            for link in links { await revoke(link, service); try await service.store.deleteLink(link.id) }
            await service.sync.publishInstitutions()
            removed.append("\(links.count) linked account\(links.count == 1 ? "" : "s")")
        }
        if body.clearImports == true { try await service.store.clearImports(); removed.append("import history") }
        if body.removeProviderKeys == true {
            try await service.providers.clearPlaid()
            try await service.providers.clearTeller()
            await BudgetServerApp.apply(service)
            removed.append("Plaid and Teller keys")
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
