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
        /// Card bills from Plaid Liabilities are on (the server setting).
        var cardBills: Bool
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

/// What `/dash/models/test` checks; every part is optional, and `{}` means everything listed.
struct ModelTestBody: Decodable {
    /// A model as typed in its drawer, saved or not. `apiKey` is plaintext, so it never prints.
    struct Draft: Decodable, CustomStringConvertible {
        enum Kind: String, Decodable { case chat, decision, jev }
        var id: String?
        var kind: Kind
        var address: String?
        var apiKey: String?
        var removeKey: Bool?
        var model: String?
        var zeroRetention: Bool?
        /// A chat draft on OpenRouter: Jev's OpenRouter key instead of a typed or saved one.
        var useOpenRouterKey: Bool?
        var description: String { "Draft(\(id ?? "new"), \(kind.rawValue))" }
    }
    var chat: [String]?
    var decision: [String]?
    var jev: Bool?
    var draft: Draft?
}

/// `/dash/models/test`'s answer: an outcome per model id tested, per job.
struct ModelTestReport: Encodable {
    var chat: [String: ModelCheck.Outcome] = [:]
    var decision: [String: ModelCheck.Outcome] = [:]
    var jev: ModelCheck.Outcome?
    var draft: ModelCheck.Outcome?
    /// The names a chat draft's server lists; nil when it doesn't say.
    var models: [String]?
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
            syncIntervalHours: await live.syncIntervalHours, timeZone: await live.timeZone.identifier, apiURL: await live.publicURL, cardBills: await live.cardBillsEnabled)
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
    /// default). Secrets report only whether they're set. The models have their own calls (`/dash/models…`).
    router.get("/dash/settings") { _, _ in try HTTP.json(await service.settings.fields()) }

    /// `{"changes": {"key": "value" | null}}` — a value sets it here, null resets it to the environment or
    /// default, "" turns it off. Applied immediately. Jev's key can't go while the saved policy uses Jev.
    router.patch("/dash/settings") { request, _ in
        struct Body: Decodable { var changes: [String: String?] }
        let body = try await HTTP.body(Body.self, request)
        try await service.settings.update(body.changes, policy: await service.api.state.decisionPolicy)
        await BudgetServerApp.apply(service)
        return try HTTP.json(await service.settings.fields())
    }

    // The models: exact paths, never "/dash/models/:id" (the router takes a matching static segment and doesn't fall back).

    /// Every model per job and which one each uses (`ModelList`). Never a key, sealed or opened.
    router.get("/dash/models") { _, _ in try HTTP.json(await service.settings.modelList()) }

    /// Adds or edits a model (`ModelDraft`): `{id, autoSelected, list}`. Saved and applied right away.
    router.post("/dash/models/save") { request, _ in
        struct Saved: Encodable { var id: String; var autoSelected: Bool; var list: ModelList }
        let draft = try await HTTP.body(ModelDraft.self, request, limit: 64 * 1024)
        let (id, autoSelected) = try await service.settings.saveModel(draft, policy: await service.api.state.decisionPolicy.provider)
        await BudgetServerApp.apply(service)
        return try HTTP.json(Saved(id: id, autoSelected: autoSelected, list: await service.settings.modelList()))
    }

    /// `{id}`: removes a saved model, unless a job uses it. `ModelList`.
    router.post("/dash/models/remove") { request, _ in
        struct Body: Decodable { var id: String }
        let body = try await HTTP.body(Body.self, request, limit: 64 * 1024)
        try await service.settings.removeModel(id: body.id, policy: await service.api.state.decisionPolicy.provider)
        await BudgetServerApp.apply(service)
        return try HTTP.json(await service.settings.modelList())
    }

    /// `{chat?, decision?}`: the model each given job uses from now on. `ModelList`.
    router.post("/dash/models/use") { request, _ in
        struct Body: Decodable { var chat: String?; var decision: String? }
        let body = try await HTTP.body(Body.self, request, limit: 64 * 1024)
        try await service.settings.use(chat: body.chat, decision: body.decision)
        await BudgetServerApp.apply(service)
        return try HTTP.json(await service.settings.modelList())
    }

    /// The model names a chat server lists (`GET /v1/models`), for the Model field's list: `{id?, address?, apiKey?,
    /// useOpenRouterKey?}`. `id` is a chat model's. The address is the typed one, else the model's; the key is the typed
    /// one, else Jev's OpenRouter key when asked for and the address is OpenRouter's, else the model's only on its own
    /// server. `{models?: [String]}`, only those that take tools when the server says, left out when it doesn't say.
    router.post("/dash/models/names") { request, _ in
        struct Body: Decodable { var id: String?, address: String?, apiKey: String?, useOpenRouterKey: Bool? }
        struct Names: Encodable { var models: [String]? }
        let body = (try? await HTTP.body(Body.self, request, limit: 64 * 1024)) ?? Body()
        var entry: ModelConnection?
        if let id = body.id { entry = await service.settings.connection(.chat, id: id) }
        let typed = body.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let address = typed.isEmpty ? entry?.address : try? ModelCheck.address(typed) else { return try HTTP.json(Names(models: nil)) }
        let key = ModelCheck.openRouterKey(await service.settings.openRouterKey, asked: body.useOpenRouterKey, typed: body.apiKey, for: address)
            ?? ModelCheck.key(typed: body.apiKey, removeKey: false, for: address, entry: entry)
        return try HTTP.json(Names(models: await ModelCheck.listModels(at: address, key: key)))
    }

    /// The Models card's Test. `{chat?: [id], decision?: [id], jev?: Bool, draft?: {id?, kind: chat|decision|jev, address?,
    /// apiKey?, removeKey?, model?, zeroRetention?, useOpenRouterKey?}}`; `{}` tests everything listed, six at a time. A
    /// draft's blank key is its saved model's only on that model's own server; Jev's with `useOpenRouterKey` on OpenRouter.
    /// Chat models on OpenRouter are routed as Ask's are, with Jev's "only providers that keep nothing". Sends a one-word question and a made-up coffee charge,
    /// nothing from the ledger. `{chat: {id: Outcome}, decision: {id: Outcome}, jev?, draft?, models?}`.
    router.post("/dash/models/test") { request, _ in
        let body = try await HTTP.body(ModelTestBody.self, request, limit: 64 * 1024)
        let settings = service.settings
        let list = await settings.modelList()
        let everything = body.chat == nil && body.decision == nil && body.jev == nil && body.draft == nil
        func once(_ ids: [String]) -> [String] {
            var seen = Set<String>()
            return ids.filter { seen.insert($0).inserted }
        }
        let chatIDs = once(body.chat ?? (everything ? list.chat.map(\.id) : []))
        let decisionIDs = once(body.decision ?? (everything ? list.decision.map(\.id) + (list.chatServer.address == nil ? [] : ["chat"]) : []))
        let fallbackName = await settings.modelName
        let jevKey = await settings.openRouterKey, zeroRetention = await settings.openRouterZeroRetention

        var work: [@Sendable () async -> (ModelCheck.Outcome, [String]?)] = []
        for id in chatIDs {
            let entry = await settings.connection(.chat, id: id)
            work.append {
                guard let entry else { return (ModelCheck.Outcome(ok: false, detail: "No such model."), nil) }
                if id == "off" { return (ModelCheck.Outcome(ok: false, off: true, detail: "Off: Ask gives simple built-in answers."), nil) }
                guard let address = entry.address else { return (ModelCheck.Outcome(ok: false, detail: "The install settings don't set its address now."), nil) }
                return (await ModelCheck.chat(base: address, key: entry.key, model: entry.model ?? fallbackName, zeroRetention: zeroRetention), nil)
            }
        }
        for id in decisionIDs {
            let entry = await settings.connection(.decision, id: id)
            work.append {
                guard let entry else { return (ModelCheck.Outcome(ok: false, detail: "No such model."), nil) }
                guard let address = entry.address else {
                    return (ModelCheck.Outcome(ok: false, detail: id == "chat" ? "It uses the chat model's server, and no chat model is in use."
                                                                            : "The install settings don't set its address now."), nil)
                }
                return (await ModelCheck.decision(base: address, key: entry.key), nil)
            }
        }
        let testJev = body.jev ?? (everything && jevKey != nil)
        if testJev { work.append { (await ModelCheck.jev(key: jevKey, zeroRetention: zeroRetention), nil) } }
        if let draft = body.draft {
            switch draft.kind {
            case .jev:
                // Jev's address is always OpenRouter's, so a blank key can only mean the saved one.
                let typedKey = draft.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let key = !typedKey.isEmpty ? typedKey : draft.removeKey == true ? nil : jevKey
                let zdr = draft.zeroRetention ?? zeroRetention
                work.append { (await ModelCheck.jev(key: key, zeroRetention: zdr), nil) }
            case .chat, .decision:
                let job: ServerSettings.Job = draft.kind == .chat ? .chat : .decision
                var found: ModelConnection?
                if let id = draft.id { found = await settings.connection(job, id: id) }
                let entry = found, missing = draft.id != nil && entry == nil
                let typed = draft.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let address: Result<URL?, any Error> = typed.isEmpty ? .success(entry?.address) : Result { try ModelCheck.address(typed) }
                work.append {
                    if missing { return (ModelCheck.Outcome(ok: false, detail: "No such model."), nil) }
                    let base: URL
                    switch address {
                    case let .failure(error): return (ModelCheck.Outcome(ok: false, detail: error.localizedDescription), nil)
                    case .success(nil): return (ModelCheck.Outcome(ok: false, detail: "Add the server's address."), nil)
                    case let .success(url?): base = url
                    }
                    let jev = job == .chat ? ModelCheck.openRouterKey(jevKey, asked: draft.useOpenRouterKey, typed: draft.apiKey, for: base) : nil
                    let key = jev ?? ModelCheck.key(typed: draft.apiKey, removeKey: draft.removeKey == true, for: base, entry: entry)
                    // The saved key stayed behind because this is another server: say so when that's why it was turned away.
                    func withKeyNote(_ outcome: ModelCheck.Outcome) -> ModelCheck.Outcome {
                        guard key == nil, draft.removeKey != true, entry?.key != nil, outcome.detail.hasPrefix("It wants an API key") else { return outcome }
                        var noted = outcome
                        noted.detail = outcome.detail.replacingOccurrences(of: "Add one in its Edit.", with: "The saved key only goes to its own server: type this one's key to try it.")
                        return noted
                    }
                    guard job == .chat else { return (withKeyNote(await ModelCheck.decision(base: base, key: key)), nil) }
                    async let names = ModelCheck.listModels(at: base, key: key)
                    let typedModel = draft.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard let model = typedModel.isEmpty ? entry?.model : typedModel else {
                        let offered = await names
                        let detail = "Add the model's name, as the server knows it." + (offered.map { $0.isEmpty ? "" : " It offers: \($0.prefix(12).joined(separator: ", "))." } ?? "")
                        return (ModelCheck.Outcome(ok: false, address: base.absoluteString, detail: detail), offered)
                    }
                    let outcome = withKeyNote(await ModelCheck.chat(base: base, key: key, model: model, zeroRetention: zeroRetention))
                    return (outcome, await names)
                }
            }
        }

        var results = await ModelCheck.bounded(work)
        var report = ModelTestReport()
        for id in chatIDs { report.chat[id] = results.removeFirst().0 }
        for id in decisionIDs { report.decision[id] = results.removeFirst().0 }
        if testJev { report.jev = results.removeFirst().0 }
        if body.draft != nil { (report.draft, report.models) = results.removeFirst() }
        return try HTTP.json(report)
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
        "flow.js": Asset(PackageResources.flow_js, "text/javascript; charset=utf-8"),
        "rules.js": Asset(PackageResources.rules_js, "text/javascript; charset=utf-8"),
        "categories.js": Asset(PackageResources.categories_js, "text/javascript; charset=utf-8"),
        "groups.js": Asset(PackageResources.groups_js, "text/javascript; charset=utf-8"),
        "transactions.js": Asset(PackageResources.transactions_js, "text/javascript; charset=utf-8"),
        "orders.js": Asset(PackageResources.orders_js, "text/javascript; charset=utf-8"),
        "assistant.js": Asset(PackageResources.assistant_js, "text/javascript; charset=utf-8"),
        "networth.js": Asset(PackageResources.networth_js, "text/javascript; charset=utf-8"),
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
