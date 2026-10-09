import BudgetKit
import Foundation
import HTTPTypes
import Hummingbird

/// When this process started, for the dashboard's uptime.
let serverStartedAt = Date()

/// What the dashboard shows beyond the phone's API: ledger counts, links, imports and how the
/// server is configured. Never a secret — the token has its own call (`/dash/connect`).
struct DashboardSummary: Encodable {
    struct Settings: Encodable {
        var database: String
        /// No database: everything is lost on restart. The dashboard warns in orchid.
        var inMemory: Bool
        var modelBaseURL: String?
        var decisionBaseURL: String?
        var modelName: String
        var plaid: String?
        var teller: Bool
        var jev: Bool
        var linkingEnabled: Bool
        var demoAllowed: Bool
        var syncIntervalHours: Double
        var timeZone: String
        var apiURL: String?
    }

    var version: String
    var startedAt: Date
    var now: Date
    var stats: LedgerStats
    var links: [LinkSummary]
    var imports: [ImportRecord]
    var settings: Settings
    /// Every decision provider's name as the phone shows it (`DecisionProvider.displayName`), so the
    /// dashboard never keeps its own copy of the list.
    var providerNames: [String: String]
    /// How a row got its category, in the phone's words (`CategorizationTier.displayName`), keyed by tier.
    var tierNames: [String: String]
    /// Every category, merged-away ones included (so old rows and rules still name theirs), each with the color it wears.
    var categories: [DashboardCategory]
}

func addDashboardRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService) {
    router.get("/") { request, _ in
        DashboardAssets.response(for: DashboardAssets.page, request: request, extraHeaders: [
            .contentSecurityPolicy: DashboardAssets.contentSecurityPolicy,
            HTTPField.Name("Referrer-Policy")!: "no-referrer",
        ])
    }

    /// The page's stylesheets, scripts and icons. Only this listener serves them; the phone's API has no page.
    router.get("/dash/assets/:name") { request, context in
        let name = try context.parameters.require("name")
        guard let asset = DashboardAssets.files[name] else { return HTTP.error(.notFound, "No such dashboard file.") }
        return DashboardAssets.response(for: asset, request: request)
    }

    router.get("/dash/summary") { _, _ in
        let config = service.config, live = service.settings
        let settings = DashboardSummary.Settings(
            database: config.database.map { "Postgres · \($0.host)/\($0.database)" } ?? "In memory (nothing survives a restart)",
            inMemory: config.database == nil,
            modelBaseURL: await live.modelBaseURL?.absoluteString, decisionBaseURL: await live.decisionBaseURL?.absoluteString,
            modelName: await live.modelName, plaid: (try? await service.providers.plaid())?.environment.rawValue, teller: await service.providers.teller() != nil,
            jev: await live.openRouterKey != nil, linkingEnabled: service.sealer != nil, demoAllowed: config.allowDemo,
            syncIntervalHours: await live.syncIntervalHours, timeZone: await live.timeZone.identifier, apiURL: await live.publicURL)
        let imports = try await service.store.imports().sorted { $0.createdAt > $1.createdAt }
        return try HTTP.json(DashboardSummary(
            version: BudgetServerVersion.current, startedAt: serverStartedAt, now: Date(), stats: await service.api.stats(),
            links: try await service.store.links().map(\.summary), imports: Array(imports.prefix(50)), settings: settings,
            providerNames: Dictionary(uniqueKeysWithValues: DecisionProvider.allCases.map { ($0.rawValue, $0.displayName) }),
            tierNames: Dictionary(uniqueKeysWithValues: CategorizationTier.allCases.map { ($0.rawValue, $0.displayName) }),
            categories: try await service.api.categories().map(DashboardCategory.init)))
    }

    /// Accounts × the last 24 months: rows per month, and the months with none since each account's first row.
    router.get("/dash/coverage") { _, _ in
        try HTTP.json(DashboardCoverage.build(state: await service.api.state, now: Date(), calendar: await service.settings.calendar))
    }

    /// The review queue grouped by account, direction and bank descriptor, biggest groups first. Filing a group sends
    /// its `transactionIDs` to `POST /v1/actions` (`editTransactions`), so nothing outside it changes.
    router.get("/dash/review/groups") { _, _ in
        let state = await service.api.state
        return try HTTP.json(DashboardReviewGroups.build(queue: try await service.api.reviewQueue(), categories: state.categories))
    }

    /// Plaid and Teller setup — what's configured and where from, never a secret. `suggestedRedirectURI`
    /// is this dashboard's own URL: registered with Plaid, it lets OAuth banks (Chase, Schwab) finish here.
    router.get("/dash/providers") { request, _ in
        struct Body: Encodable { var providers: ProviderSummary; var suggestedRedirectURI: String? }
        let host = request.headers[HTTPField.Name("X-Forwarded-Host")!] ?? request.head.authority
        return try HTTP.json(Body(providers: await service.providers.summary(), suggestedRedirectURI: host.map { "https://\($0)/" }))
    }

    router.put("/dash/providers/plaid") { request, _ in
        struct Body: Decodable { var clientID: String; var secret: String?; var environment: String; var redirectURI: String? }
        let body = try await HTTP.body(Body.self, request)
        guard let environment = PlaidSource.Environment(rawValue: body.environment) else { throw BudgetAPIError.rejected("Plaid's environment is sandbox or production.") }
        try await service.providers.savePlaid(clientID: body.clientID, secret: body.secret, environment: environment, redirectURI: body.redirectURI)
        await BudgetServerApp.apply(service)
        return try HTTP.json(await service.providers.summary())
    }

    router.put("/dash/providers/teller") { request, _ in
        struct Body: Decodable { var applicationID: String; var environment: String; var certificatePEM: String?; var keyPEM: String? }
        let body = try await HTTP.body(Body.self, request)
        try await service.providers.saveTeller(applicationID: body.applicationID, environment: body.environment,
                                               certificatePEM: body.certificatePEM, keyPEM: body.keyPEM)
        await BudgetServerApp.apply(service)
        return try HTTP.json(await service.providers.summary())
    }

    // Exact paths, not "/dash/providers/:provider": the router matches the static "plaid" segment the PUT
    // registered and never falls back to a parameter route, so a wildcard DELETE answered 404.
    router.delete("/dash/providers/plaid") { _, _ in
        try await service.providers.clearPlaid()
        await BudgetServerApp.apply(service)
        return try HTTP.json(await service.providers.summary())
    }
    router.delete("/dash/providers/teller") { _, _ in
        try await service.providers.clearTeller()
        await BudgetServerApp.apply(service)
        return try HTTP.json(await service.providers.summary())
    }

    /// Every server setting with its value in force and where it comes from (dashboard / environment /
    /// default). Secrets report only whether they're set.
    router.get("/dash/settings") { _, _ in try HTTP.json(await service.settings.fields()) }

    /// `{"changes": {"key": "value" | null}}` — a value sets it here, null resets it to the environment or
    /// default, "" turns it off. Applied immediately.
    router.patch("/dash/settings") { request, _ in
        struct Body: Decodable { var changes: [String: String?] }
        let body = try await HTTP.body(Body.self, request)
        try await service.settings.update(body.changes)
        await BudgetServerApp.apply(service)
        return try HTTP.json(await service.settings.fields())
    }

    /// The model names the chat server lists (`GET /v1/models`), for the Model field's list: `{modelBaseURL?, modelAPIKey?}`
    /// as typed, else saved. `{models: [String]?}`; nil when the server doesn't say.
    router.post("/dash/models/names") { request, _ in
        struct Body: Decodable { var modelBaseURL: String?, modelAPIKey: String? }
        struct Names: Encodable { var models: [String]? }
        let body = (try? await HTTP.body(Body.self, request)) ?? Body()
        var address = await service.settings.modelBaseURL
        if let text = body.modelBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines) { address = text.isEmpty ? nil : URL(string: text) }
        var key = await service.settings.modelAPIKey
        if let text = body.modelAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { key = text }
        guard let address else { return try HTTP.json(Names(models: nil)) }
        return try HTTP.json(Names(models: await ModelCheck.listModels(at: ModelCheck.base(address), key: key)))
    }

    /// The Models section's Test, on what's in its fields (saved or not): `{modelBaseURL, modelName, modelAPIKey,
    /// categorizing: off|chat|own|jev, decisionBaseURL, decisionAPIKey, openRouterKey, openRouterZeroRetention}`. A field
    /// left out uses the saved setting; an empty key uses the saved key; an empty chat address is off. Sends a one-word
    /// question and a made-up coffee charge, nothing from the ledger. `ModelCheck.Report`.
    router.post("/dash/models/test") { request, _ in
        struct Body: Decodable {
            var modelBaseURL: String?, modelName: String?, modelAPIKey: String?
            var categorizing: ModelCheck.Categorizing?, decisionBaseURL: String?, decisionAPIKey: String?
            var openRouterKey: String?, openRouterZeroRetention: Bool?
        }
        let body = try await HTTP.body(Body.self, request)
        let settings = service.settings
        func typed(_ text: String?) -> String? { text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } }
        func key(_ text: String?, saved: String?) -> String? { typed(text).flatMap { $0.isEmpty ? nil : $0 } ?? saved }
        var chat = await settings.modelBaseURL
        if let text = typed(body.modelBaseURL) { chat = text.isEmpty ? nil : URL(string: text) }
        let savedChatKey = await settings.modelAPIKey
        let chatKey = key(body.modelAPIKey, saved: savedChatKey)
        let policy = try await service.api.serverStatus().decisionPolicy
        let savedDecision = await settings.value("decisionBaseURL")
        var categorizing = ModelCheck.Categorizing.off
        if let chosen = body.categorizing {
            categorizing = chosen
        } else {
            switch policy.provider {
            case .off: categorizing = .off
            case .localDecide: categorizing = savedDecision == nil ? .chat : .own
            case .laya: categorizing = .laya
            case .jev: categorizing = .jev
            }
        }
        var decision = savedDecision.flatMap(URL.init(string:))
        if let text = typed(body.decisionBaseURL), !text.isEmpty { decision = URL(string: text) }
        let savedDecisionKey = await settings.value("decisionAPIKey")
        let decisionKey = categorizing == .chat ? key(body.decisionAPIKey, saved: nil) ?? chatKey : key(body.decisionAPIKey, saved: savedDecisionKey)
        var model = await settings.modelName
        if let text = typed(body.modelName), !text.isEmpty { model = text }
        let savedOpenRouter = await settings.openRouterKey
        var zeroRetention = await settings.openRouterZeroRetention
        if let chosen = body.openRouterZeroRetention { zeroRetention = chosen }
        let setup = ModelCheck.Setup(chat: chat, chatKey: chatKey, model: model, categorizing: categorizing, decision: decision,
                                     decisionKey: decisionKey, openRouterKey: key(body.openRouterKey, saved: savedOpenRouter),
                                     zeroRetention: zeroRetention)
        return try HTTP.json(await ModelCheck.run(setup))
    }

    /// `{"apply": false}` previews which merchants the model would move under the current categories;
    /// `{"apply": true}` moves them. Never touches the person's confirmations or rules.
    router.post("/dash/recheck-filed") { request, _ in
        struct Body: Decodable { var apply: Bool? }
        let body = (try? await HTTP.body(Body.self, request)) ?? Body(apply: false)
        return try HTTP.json(try await service.api.recheckModelFiled(apply: body.apply ?? false))
    }

    /// What the phone needs: the API's URL and its bearer token. Only on this signed-in listener.
    router.get("/dash/connect") { _, _ in
        try HTTP.json(["apiURL": await service.settings.publicURL ?? "", "token": service.config.apiToken ?? ""])
    }
}

/// The dashboard's page and files, compiled into the binary from `Dashboard/` (Package.swift declares them
/// with `.embedInCode`). Plain HTML, CSS and native ES modules: no build step, no bundle on disk.
enum DashboardAssets {
    struct Asset: Sendable {
        let bytes: [UInt8]
        let contentType: String
        /// A content hash, so a browser revalidates cheaply and never runs a stale script after a deploy.
        let etag: String

        init(_ bytes: [UInt8], _ contentType: String) {
            self.bytes = bytes
            self.contentType = contentType
            // FNV-1a 64: stable across runs and platforms (Swift's Hasher is seeded per process).
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
            etag = "\"\(String(hash, radix: 16))\""
        }
    }

    static let page = Asset(PackageResources.index_html, "text/html; charset=utf-8")

    /// Served at `/dash/assets/<name>`. The page and each module refer to these names.
    static let files: [String: Asset] = [
        "tokens.css": Asset(PackageResources.tokens_css, "text/css; charset=utf-8"),
        "app.css": Asset(PackageResources.app_css, "text/css; charset=utf-8"),
        "app.js": Asset(PackageResources.app_js, "text/javascript; charset=utf-8"),
        "core.js": Asset(PackageResources.core_js, "text/javascript; charset=utf-8"),
        "providers.js": Asset(PackageResources.providers_js, "text/javascript; charset=utf-8"),
        "overview.js": Asset(PackageResources.overview_js, "text/javascript; charset=utf-8"),
        "accounts.js": Asset(PackageResources.accounts_js, "text/javascript; charset=utf-8"),
        "imports.js": Asset(PackageResources.imports_js, "text/javascript; charset=utf-8"),
        "review.js": Asset(PackageResources.review_js, "text/javascript; charset=utf-8"),
        "settings.js": Asset(PackageResources.settings_js, "text/javascript; charset=utf-8"),
        "rules.js": Asset(PackageResources.rules_js, "text/javascript; charset=utf-8"),
        "categories.js": Asset(PackageResources.categories_js, "text/javascript; charset=utf-8"),
        "groups.js": Asset(PackageResources.groups_js, "text/javascript; charset=utf-8"),
        "transactions.js": Asset(PackageResources.transactions_js, "text/javascript; charset=utf-8"),
        "icon-64.png": Asset(PackageResources.icon_64_png, "image/png"),
        "icon-180.png": Asset(PackageResources.icon_180_png, "image/png"),
    ]

    /// Scripts only from this server and the two bank-linking CDNs (loaded when you press Link). Styles allow
    /// inline because Plaid Link and Teller Connect style their own overlays; the dashboard itself uses none
    /// (a test checks). `frame-ancestors` lets the Olares desktop show the dashboard in its window.
    static let contentSecurityPolicy = [
        "default-src 'self'",
        "script-src 'self' https://cdn.plaid.com https://*.plaid.com https://cdn.teller.io https://*.teller.io",
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data: https://*.plaid.com https://*.teller.io",
        "font-src 'self' data:",
        "connect-src 'self' https://*.plaid.com https://*.teller.io",
        "frame-src https://*.plaid.com https://teller.io https://*.teller.io",
        "frame-ancestors 'self' https://*.olares.com https://*.olares.cn https://*.olares.local http://*.olares.local",
        "base-uri 'none'",
        "form-action 'self'",
        "object-src 'none'",
    ].joined(separator: "; ")

    static func response(for asset: Asset, request: Request, extraHeaders: HTTPFields = [:]) -> Response {
        var headers: HTTPFields = [
            .contentType: asset.contentType,
            // The page is never cached (it names the files); files revalidate by ETag.
            .cacheControl: asset.contentType.hasPrefix("text/html") ? "no-store" : "no-cache",
            .eTag: asset.etag,
            HTTPField.Name("X-Content-Type-Options")!: "nosniff",
        ]
        headers.append(contentsOf: extraHeaders)
        if request.headers[.ifNoneMatch] == asset.etag {
            return Response(status: .notModified, headers: headers)
        }
        return Response(status: .ok, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(bytes: asset.bytes)))
    }
}
