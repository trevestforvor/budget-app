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

/// Answers provider calls by path (fake Plaid).
final class FakeProvider: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: [String]]
    private(set) var requests: [(path: String, body: String)] = []
    init(_ routes: [String: [String]]) { self.routes = routes }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append((request.url!.path, String(decoding: request.httpBody ?? Data(), as: UTF8.self))) }
        let body = lock.withLock { () -> String? in
            guard var bodies = routes[request.url!.path], !bodies.isEmpty else { return nil }
            let first = bodies.removeFirst()
            routes[request.url!.path] = bodies.isEmpty ? [first] : bodies
            return first
        }
        return (Data((body ?? #"{"error_code":"NOT_FOUND"}"#).utf8),
                HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!)
    }
}

enum TestServer {
    static let token = "test-token"
    static let key = Data((0..<32).map { UInt8($0) }).base64EncodedString()

    static func config() -> ServerConfig {
        var c = ServerConfig()
        c.apiToken = token
        c.allowDemo = true  // the test server seeds the demo; a real one refuses (see demoRefusedOnRealServer)
        c.tokenKey = key
        c.plaid = .init(clientID: "cid", secret: "sec", environment: .sandbox, redirectURI: nil)
        return c
    }

    static func app(seedDemo: Bool = true, plaid: (any HTTPTransport)? = nil, surface: Surface = .api) async throws -> (some ApplicationProtocol, BudgetService) {
        let store = MemoryStore(ledger: seedDemo ? LedgerBudgetAPI.demoState(now: Date(), calendar: config().calendar) : nil)
        let (service, _) = try await BudgetServerApp.makeService(config: config(), store: store, logger: Logger(label: "test"), plaidTransport: plaid)
        try await BudgetServerApp.prepare(service)
        return (Application(router: buildRouter(service, surface: surface)), service)
    }

    static var auth: HTTPFields { [.authorization: "Bearer \(token)", .contentType: "application/json"] }

    static func body(_ json: String) -> ByteBuffer { ByteBuffer(string: json) }
}

@Suite("Budget API server")
struct ServerTests {
    @Test("Health is open; /v1 needs the token")
    func auth() async throws {
        let (app, _) = try await TestServer.app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { #expect($0.status == .ok) }
            try await client.execute(uri: "/v1/overview", method: .get) { #expect($0.status == .unauthorized) }
            try await client.execute(uri: "/v1/overview", method: .get, headers: [.authorization: "Bearer wrong"]) { #expect($0.status == .unauthorized) }
            try await client.execute(uri: "/v1/overview", method: .get, headers: TestServer.auth) { response in
                #expect(response.status == .ok)
                let overview = try RemoteBudgetAPI.decoder.decode(Overview.self, from: Data(response.body.readableBytesView))
                #expect(overview.accounts.count == 7) // the demo's six, and a Keystone card that only comes from statements
            }
        }
    }

    @Test("Cross-origin writes are refused; malformed bodies are 400; bad actions are 422 with a message")
    func guards() async throws {
        let (app, _) = try await TestServer.app()
        try await app.test(.router) { client in
            var evil = TestServer.auth
            evil[.origin] = "https://evil.example"
            try await client.execute(uri: "/v1/actions", method: .post, headers: evil, body: TestServer.body(#"{"type":"navigate","screen":"home"}"#)) {
                #expect($0.status == .forbidden)
            }
            try await client.execute(uri: "/v1/actions", method: .post, headers: TestServer.auth, body: TestServer.body("{nope")) {
                #expect($0.status == .badRequest)
            }
            try await client.execute(uri: "/v1/actions", method: .post, headers: TestServer.auth,
                                     body: TestServer.body(#"{"type":"setCategoryTarget","categoryID":"nope","monthlyAmount":"5"}"#)) { response in
                #expect(response.status == .unprocessableContent)
                #expect(String(buffer: response.body).contains("Unknown category"))
            }
        }
    }

    /// The real client against the real server: every call the app makes, same wire format.
    @Test("The app's RemoteBudgetAPI works against the running server")
    func parity() async throws {
        let (app, _) = try await TestServer.app()
        try await app.test(.live) { client in
            let port = try #require(client.port)
            let remote = RemoteBudgetAPI(baseURL: URL(string: "http://localhost:\(port)")!, token: TestServer.token)
            let overview = try await remote.overview()
            // Seven unsure merchants plus the demo's four Meadow withdrawals.
            #expect(overview.reviewCount == 11)
            #expect(try await remote.categories().contains { $0.id == "dining" })
            let spending = try await remote.spending(.thisMonth)
            #expect(spending.categories.map(\.spent).sum() == spending.total)
            #expect(try await remote.transactions(TransactionFilter(search: "Casa Taco")).count == 1)
            let review = try await remote.reviewQueue()
            _ = try await remote.confirmCategory(transactionID: review[0].id, categoryID: "dining")
            #expect(try await remote.reviewQueue().count == 10)
            let result = try await remote.perform(.setCategoryTarget(SetCategoryTarget(categoryID: "dining", monthlyAmount: DecimalAmount(string: "500")!)))
            #expect(result.message.contains("$500"))
            #expect(try await remote.spending(.thisMonth).categories.first { $0.id == "dining" }?.target == Money(500))
            let reply = try await remote.ask("What is my DoorDash budget?", conversationID: nil)
            #expect(reply.toolCalls.first?.name == "sumByMerchant")
            _ = try await remote.projection(horizonMonths: 6, goal: nil)
            #expect(try await remote.assistantConfig().tools.count == ToolCatalog.specs.count)
            #expect(try await remote.savingsPlan().canSaveTypical.minorUnits > 0)
            let checkup = try await remote.checkup()
            #expect(checkup.sections.contains { $0.id == "categories" })
            #expect(try await remote.serverStatus().version == BudgetServerVersion.current)
            await #expect(throws: BudgetAPIError.rejected("Unknown category “pets”.")) {
                try await remote.perform(.setCategoryTarget(SetCategoryTarget(categoryID: "pets", monthlyAmount: DecimalAmount(string: "5")!)))
            }
        }
    }

    @Test("Transactions over HTTP: filters, pages, one row, the summary, and undo for a review answer and an edit")
    func transactionsParity() async throws {
        let (app, _) = try await TestServer.app()
        try await app.test(.live) { client in
            let port = try #require(client.port)
            let remote = RemoteBudgetAPI(baseURL: URL(string: "http://localhost:\(port)")!, token: TestServer.token)
            let largest = try await remote.transactions(TransactionFilter(sort: .largest, limit: 5))
            #expect(largest.map(\.amount.magnitude) == largest.map(\.amount.magnitude).sorted(by: >))
            let twenty = try await remote.transactions(TransactionFilter(limit: 20))
            let pages = try await remote.transactions(TransactionFilter(limit: 10)) + (try await remote.transactions(TransactionFilter(limit: 10, offset: 10)))
            #expect(pages == twenty)
            let food = try await remote.transactions(TransactionFilter(categoryIDs: ["dining", "groceries"], period: "this_month", limit: 500))
            #expect(!food.isEmpty && food.allSatisfy { ["dining", "groceries"].contains($0.categorization?.categoryID ?? "") })
            #expect(try await remote.transactionSummary(TransactionFilter(period: "this_month")).spent == (try await remote.spending(.thisMonth)).total)
            #expect(try await remote.transaction(id: twenty[0].id) == twenty[0])
            await #expect(throws: BudgetAPIError.notFound) { try await remote.transaction(id: "nope") }

            let review = try await remote.reviewQueue()
            let filed = try await remote.confirmCategory(transactionID: review[0].id, categoryID: "shopping")
            #expect(filed.affectedTransactions == 1 && filed.undo != nil)
            #expect(try await remote.reviewQueue().count == review.count - 1)
            _ = try await remote.perform(try #require(filed.undo))
            #expect(try await remote.reviewQueue().count == review.count)

            let spent = try await remote.overview().monthSpent
            let charge = try #require(try await remote.transactions(TransactionFilter(period: "this_month", direction: .moneyOut, visibility: .counted, limit: 500))
                .first { $0.categorization?.categoryID == "dining" })
            let hidden = try await remote.perform(.editTransactions(EditTransactions(transactionIDs: [charge.id], isHidden: true)))
            #expect(try await remote.overview().monthSpent == spent - charge.amount.magnitude)
            #expect(try await remote.transaction(id: charge.id).isHidden)
            _ = try await remote.perform(try #require(hidden.undo))
            #expect(try await remote.overview().monthSpent == spent)
        }
    }

    @Test("Transaction routes: the summary isn't an id, ids are percent-decoded, bad filters say why")
    func transactionRoutes() async throws {
        let (app, service) = try await TestServer.app()
        let id = try #require(try await service.api.transactions(TransactionFilter(limit: 1)).first?.id)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/transactions/summary?period=this_month&category=dining", method: .get, headers: TestServer.auth) { response in
                #expect(response.status == .ok)
                let summary = try RemoteBudgetAPI.decoder.decode(TransactionSummary.self, from: Data(response.body.readableBytesView))
                #expect(summary.count > 0 && summary.spent.minorUnits > 0)
            }
            let encoded = id.replacingOccurrences(of: "-", with: "%2D")
            try await client.execute(uri: "/v1/transactions/\(encoded)", method: .get, headers: TestServer.auth) { response in
                #expect(response.status == .ok)
                let row = try RemoteBudgetAPI.decoder.decode(LedgerTransaction.self, from: Data(response.body.readableBytesView))
                #expect(row.id == id)
            }
            try await client.execute(uri: "/v1/transactions?sort=biggest", method: .get, headers: TestServer.auth) { response in
                #expect(response.status == .badRequest)
                #expect(String(buffer: response.body).contains("sort must be newest, oldest or largest"))
            }
            try await client.execute(uri: "/v1/transactions?period=fortnight", method: .get, headers: TestServer.auth) { #expect($0.status == .unprocessableContent) }
            try await client.execute(uri: "/v1/review/\(id)", method: .post, headers: TestServer.auth, body: TestServer.body(#"{"categoryID":"dining"}"#)) { response in
                #expect(response.status == .ok)
                let result = try RemoteBudgetAPI.decoder.decode(ActionResult.self, from: Data(response.body.readableBytesView))
                #expect(result.undo != nil)
            }
        }
    }

    @Test("Loading an older ledger pairs its matched transfers and saves that once")
    func loadUpgrades() async throws {
        var state = LedgerState.empty
        state.accounts = [Account(id: "chk", name: "Checking", institution: "Harbor", kind: .checking, balance: Money(100), source: .plaid),
                          Account(id: "sav", name: "Savings", institution: "Harbor", kind: .savings, balance: Money(500), source: .plaid)]
        state.transactions = [
            LedgerTransaction(id: "out", accountID: "chk", postedAt: Date(), merchant: "Transfer", rawDescription: "ONLINE TRANSFER TO SAV", amount: Money(-500),
                              categorization: Categorization(categoryID: "transfer", confidence: 1, tier: .rule, needsReview: false, decidedBy: "Matched transfer · Savings"),
                              isPending: false, source: .plaid),
            LedgerTransaction(id: "in", accountID: "sav", postedAt: Date(), merchant: "Transfer", rawDescription: "ONLINE TRANSFER FROM CHK", amount: Money(500),
                              categorization: Categorization(categoryID: "transfer", confidence: 1, tier: .rule, needsReview: false, decidedBy: "Matched transfer · Checking"),
                              isPending: false, source: .plaid),
        ]
        let store = MemoryStore(ledger: state)
        let (service, _) = try await BudgetServerApp.makeService(config: TestServer.config(), store: store, logger: Logger(label: "test"))
        try await BudgetServerApp.prepare(service)
        let saved = try #require(try await store.loadLedger())
        #expect(saved.transactions.first { $0.id == "out" }?.transferPeerID == "in")
        #expect(saved.transactions.first { $0.id == "in" }?.transferPeerID == "out")
        #expect(saved.transactions.allSatisfy { $0.categorization?.tier == .transferMatch }) // no longer passed off as the person's rule
        #expect(await store.saveCount == 1)
    }

    @Test("Rules, merchant memory, categories and action previews over HTTP with the app's client")
    func rulesMemoryPreview() async throws {
        let (app, service) = try await TestServer.app()
        try await app.test(.live) { client in
            let port = try #require(client.port)
            let remote = RemoteBudgetAPI(baseURL: URL(string: "http://localhost:\(port)")!, token: TestServer.token)
            let seeded = try await remote.rules() // the demo's own three, newest first
            #expect(seeded.map(\.id) == ["rule-3", "rule-2", "rule-1"])
            let create = AppAction.createBudgetRule(CreateBudgetRule(match: .init(merchantContains: "Uber", direction: .moneyOut), categoryID: "travel", applyToExisting: true))
            let preview = try await remote.preview(create)
            #expect(preview.title == "Always file “Uber” (money out) under Travel")
            #expect((preview.matchCount ?? 0) > 0 && preview.sample.allSatisfy { $0.merchant == "Uber" } && preview.changeCount == preview.matchCount)
            #expect(try await remote.rules() == seeded) // a preview changes nothing
            _ = try await remote.perform(create)
            let rules = try await remote.rules()
            #expect(rules.map(\.id) == ["rule-4"] + seeded.map(\.id) && rules[0].hitCount == preview.matchCount && rules[0].rule.createdBy == .person)
            #expect(rules[0].matchDescription == "Merchant name contains “Uber” · money out")
            _ = try await remote.perform(.updateBudgetRule(UpdateBudgetRule(ruleID: "rule-4", isEnabled: false)))
            #expect(try await remote.rules().first?.rule.isEnabled == false)
            await #expect(throws: BudgetAPIError.notFound) { try await remote.perform(.deleteBudgetRule(DeleteBudgetRule(ruleID: "rule-9"))) }

            let memory = try await remote.rememberedMerchants()
            let netflix = try #require(memory.first { $0.merchant == "Netflix" })
            #expect(netflix.categoryID == "subscriptions" && netflix.rowCount > 0)
            _ = try await remote.perform(.forgetMerchant(ForgetMerchant(descriptor: netflix.descriptor)))
            #expect(try await remote.rememberedMerchants().contains { $0.descriptor == netflix.descriptor } == false)

            _ = try await remote.perform(.mergeCategory(MergeCategory(from: "entertainment", into: "shopping")))
            _ = try await remote.perform(.updateCategory(UpdateCategory(categoryID: "health", color: "teal")))
            let categories = try await remote.categories()
            #expect(categories.first { $0.id == "entertainment" }?.isArchived == true)
            #expect(categories.first { $0.id == "health" }?.effectiveColor == .teal)
            await #expect(throws: BudgetAPIError.rejected("navigate is handled on the device.")) { try await remote.preview(.navigate(Navigate(screen: .home))) }
        }
        #expect(await service.api.state.forgottenMerchants.count == 1)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/actions/preview", method: .post, headers: TestServer.auth, body: TestServer.body(#"{"type":"navigate","screen":"home"}"#)) {
                #expect($0.status == .unprocessableContent)
            }
            try await client.execute(uri: "/v1/actions/preview", method: .post, headers: TestServer.auth,
                                     body: TestServer.body(#"{"type":"createBudgetRule","match":{},"categoryID":"dining","applyToExisting":false}"#)) { response in
                #expect(response.status == .unprocessableContent)
                #expect(String(buffer: response.body).contains("A rule needs text to match, or an account."))
            }
        }
    }

    @Test("File import files rows into an account, and rolling the batch back removes them")
    func imports() async throws {
        let (app, service) = try await TestServer.app()
        let accountID = try #require(try await service.api.overview().accounts.first { $0.kind == .credit }?.id)
        try await app.test(.router) { client in
            let csv = "Date,Description,Amount\\n09/10/2026,UNITED AIRLINES,486.20\\n09/11/2026,HOTEL NIKKO,312.00\\n"
            let body = #"{"content":"\#(csv)","accountID":"\#(accountID)","options":{"format":"csv","sign":"positiveIsOut","institution":"Summit"}}"#
            var batch = ""
            try await client.execute(uri: "/v1/imports", method: .post, headers: TestServer.auth, body: TestServer.body(body)) { response in
                #expect(response.status == .created)
                let record = try RemoteBudgetAPI.decoder.decode(ImportRecord.self, from: Data(response.body.readableBytesView))
                #expect(record.report.rowsAdded == 2)
                batch = record.batchID
            }
            #expect(try await service.api.transactions(TransactionFilter(search: "Hotel Nikko")).first?.amount == Money(-312))
            try await client.execute(uri: "/v1/imports/\(batch)", method: .delete, headers: TestServer.auth) { #expect($0.status == .ok) }
            #expect(try await service.api.transactions(TransactionFilter(search: "Hotel Nikko")).isEmpty)
            try await client.execute(uri: "/v1/imports", method: .post, headers: TestServer.auth,
                                     body: TestServer.body(#"{"content":"\#(csv)"}"#)) { #expect($0.status == .unprocessableContent) } // CSV needs an account
        }
    }

    @Test("Plaid: exchange stores a sealed token, syncs, ingests, and lists the link without the token")
    func plaidLink() async throws {
        let plaid = FakeProvider([
            "/item/public_token/exchange": [#"{"access_token": "access-sandbox-9", "item_id": "item-1"}"#],
            "/transactions/sync": [#"""
            {"added": [{"transaction_id": "t1", "account_id": "chk", "amount": 12.5, "iso_currency_code": "USD", "date": "2026-09-20", "name": "BLUE BOTTLE COFFEE", "merchant_name": "Blue Bottle", "pending": false},
                       {"transaction_id": "t2", "account_id": "chk", "amount": -3850, "iso_currency_code": "USD", "date": "2026-09-15", "name": "ACME CORP PAYROLL", "pending": false}],
             "modified": [], "removed": [], "next_cursor": "cursor-1", "has_more": false}
            """#],
            "/accounts/balance/get": [#"{"accounts": [{"account_id": "chk", "balances": {"current": 5000, "available": 5000, "iso_currency_code": "USD"}, "name": "Checking", "subtype": "checking", "type": "depository"}]}"#],
        ])
        let (app, service) = try await TestServer.app(seedDemo: false, plaid: plaid)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/links/plaid/exchange", method: .post, headers: TestServer.auth,
                                     body: TestServer.body(#"{"publicToken":"public-1","institution":"Harbor"}"#)) { response in
                #expect(response.status == .created)
                let result = try RemoteBudgetAPI.decoder.decode(LinkSyncResult.self, from: Data(response.body.readableBytesView))
                #expect(result.ok)
                #expect(result.report?.rowsAdded == 2)
            }
            try await client.execute(uri: "/v1/links", method: .get, headers: TestServer.auth) { response in
                let text = String(buffer: response.body)
                #expect(text.contains("Harbor"))
                #expect(!text.contains("access-sandbox-9"))
            }
        }
        let link = try #require(try await service.store.links().first)
        #expect(link.cursor == "cursor-1")
        #expect(link.sealedToken != "access-sandbox-9")
        #expect(try service.sealer?.open(link.sealedToken) == "access-sandbox-9")
        let overview = try await service.api.overview()
        #expect(overview.cashOnHand == Money(5000))
        #expect(try await service.api.transactions(TransactionFilter()).first { $0.merchant == "Blue Bottle" }?.amount == Money(-12.5))
    }

    @Test("A fresh ledger categorizes on the local model only when one is configured")
    func freshLedgerPolicy() async throws {
        let (_, plain) = try await TestServer.app()
        #expect(await plain.freshState(seedDemo: false).decisionPolicy.provider == .off)
        // The demo decides with the phone's stand-in model; a server with no local model says it's off.
        #expect(await plain.freshState(seedDemo: true).decisionPolicy.provider == .off)
        var config = TestServer.config()
        config.decisionBaseURL = URL(string: "https://qwen.example")
        let (withModel, _) = try await BudgetServerApp.makeService(config: config, store: MemoryStore(), logger: Logger(label: "test"))
        let fresh = await withModel.freshState(seedDemo: true)
        #expect(fresh.decisionPolicy.provider == .localDecide)
        #expect(fresh.decisionPolicy.autoAcceptPercent == 80)
        #expect(!fresh.transactions.isEmpty)
    }

    @Test("The dashboard listener: page and reads without a token, writes only with its header from its own origin")
    func dashboard() async throws {
        let (dash, dashService) = try await TestServer.app(surface: .dashboard)
        let rows = await dashService.api.stats().rows
        try await dash.test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("<title>Budget dashboard</title>"))
            }
            try await client.execute(uri: "/v1/overview", method: .get) { #expect($0.status == .ok) }
            try await client.execute(uri: "/dash/summary", method: .get) { response in
                let text = String(buffer: response.body)
                #expect(rows > 0 && text.contains("\"rows\":\(rows)"))
                #expect(!text.contains(TestServer.token))
                #expect(text.contains(#""localDecide":"Qwen Decide · on your Olares""#))  // names come from BudgetKit
                #expect(text.contains(#""inMemory":true"#))
            }
            try await client.execute(uri: "/dash/connect", method: .get) { #expect(String(buffer: $0.body).contains(TestServer.token)) }
            try await client.execute(uri: "/v1/sync", method: .post) { #expect($0.status == .forbidden) }
            try await client.execute(uri: "/v1/sync", method: .post, headers: [HTTPField.Name("X-Budget-Dashboard")!: "1", .origin: "https://evil.example"]) {
                #expect($0.status == .forbidden)
            }
            try await client.execute(uri: "/v1/sync", method: .post, headers: [HTTPField.Name("X-Budget-Dashboard")!: "1"]) { #expect($0.status == .ok) }
        }
        // The phone's listener never serves the page or the token.
        let (api, _) = try await TestServer.app()
        try await api.test(.router) { client in
            try await client.execute(uri: "/", method: .get) { #expect($0.status == .notFound) }
            try await client.execute(uri: "/dash/connect", method: .get, headers: TestServer.auth) { #expect($0.status == .notFound) }
        }
    }

    @Test("The dashboard's files: served on its listener with their types and ETags, never on the phone's; the page carries a CSP")
    func dashboardAssets() async throws {
        let (dash, _) = try await TestServer.app(surface: .dashboard)
        try await dash.test(.router) { client in
            var page = ""
            try await client.execute(uri: "/", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-store")
                page = String(buffer: response.body)
                let csp = response.headers[.contentSecurityPolicy] ?? ""
                #expect(csp.contains("default-src 'self'"))
                #expect(csp.contains("script-src 'self' https://cdn.plaid.com"))
                #expect(csp.contains("https://cdn.teller.io"))
                #expect(csp.contains("frame-ancestors 'self' https://*.olares.com"))
                #expect(csp.contains("object-src 'none'") && csp.contains("base-uri 'none'"))
            }
            // Everything the page names is one of the embedded files.
            let named = Set(page.matches(of: #/\/dash\/assets\/([\w.-]+)/#).map { String($0.1) })
            #expect(named == ["icon-64.png", "icon-180.png", "tokens.css", "app.css", "app.js"])
            for name in DashboardAssets.files.keys.sorted() {
                try await client.execute(uri: "/dash/assets/\(name)", method: .get) { response in
                    #expect(response.status == .ok, "\(name)")
                    let type = response.headers[.contentType] ?? ""
                    #expect(name.hasSuffix(".js") ? type.hasPrefix("text/javascript") : name.hasSuffix(".css") ? type.hasPrefix("text/css") : type == "image/png", "\(name): \(type)")
                    #expect(response.headers[HTTPField.Name("X-Content-Type-Options")!] == "nosniff")
                    #expect(response.body.readableBytes > 0)
                }
            }
            var etag = ""
            try await client.execute(uri: "/dash/assets/core.js", method: .get) { response in
                // Every request the page makes carries the header dashboard writes need.
                #expect(String(buffer: response.body).contains(#""X-Budget-Dashboard": "1""#))
                etag = response.headers[.eTag] ?? ""
            }
            #expect(etag.hasPrefix("\""))
            try await client.execute(uri: "/dash/assets/core.js", method: .get, headers: [.ifNoneMatch: etag]) { #expect($0.status == .notModified) }
            try await client.execute(uri: "/dash/assets/missing.js", method: .get) { #expect($0.status == .notFound) }
        }
        // The phone's listener has no page and no files, with or without the token.
        let (api, _) = try await TestServer.app()
        try await api.test(.router) { client in
            try await client.execute(uri: "/dash/assets/core.js", method: .get) { #expect($0.status == .unauthorized) }
            try await client.execute(uri: "/dash/assets/core.js", method: .get, headers: TestServer.auth) { #expect($0.status == .notFound) }
            try await client.execute(uri: "/dash/assets/app.css", method: .get, headers: TestServer.auth) { #expect($0.status == .notFound) }
        }
    }

    @Test("The dashboard's code: one request helper, nothing inline for the CSP to refuse, and every import resolves")
    func dashboardCode() throws {
        let page = String(decoding: DashboardAssets.page.bytes, as: UTF8.self)
        let modules = DashboardAssets.files.filter { $0.key.hasSuffix(".js") }.mapValues { String(decoding: $0.bytes, as: UTF8.self) }
        #expect(page.components(separatedBy: "<script").count == 2)
        #expect(page.contains(#"<script type="module" src="/dash/assets/app.js"></script>"#))
        for text in [page] + Array(modules.values) {
            #expect(!text.contains("style="))
            #expect(!text.contains("<style"))
            #expect(!text.contains("innerHTML"))
            #expect(!text.contains("onclick=\""))
        }
        for (name, source) in modules {
            // Only core.js talks to the server, through api(), which always sends X-Budget-Dashboard.
            #expect(name == "core.js" || !source.contains("fetch("), "\(name) calls fetch directly")
            for match in source.matches(of: #/from "\.\/([\w.-]+)"/#) {
                #expect(modules[String(match.1)] != nil, "\(name) imports \(match.1), which isn't embedded")
            }
        }
        #expect(modules["core.js"]!.components(separatedBy: "fetch(").count == 2)
        // Money never shows a hyphen for a minus.
        #expect(modules["core.js"]!.contains(#""\u2212""#))

        // Categories & rules is its own page, after Review. A category is made in one place (core.js's createCategory,
        // a POST /v1/actions through api()), from the Categories section and from a rule's "New category…".
        #expect(page.contains(##"<a href="#/categories" data-view="categories">"##))
        #expect(modules["app.js"]!.contains(#"import categories from "./categories.js""#))
        #expect(modules["core.js"]!.contains(#"api("/v1/actions", { method: "POST", body: action })"#))
        #expect(modules["core.js"]!.contains(#"type: "createCategory""#))
        #expect(modules["categories.js"]!.contains("createCategory(action)"))
        #expect(modules["rules.js"]!.contains("createCategory(create)"))
        #expect(modules["rules.js"]!.contains("New category…"))
        #expect(modules["categories.js"]!.contains("Rename, recolor or merge on your phone in Settings → Categories."))
        // Review keeps what's waiting, duplicates and re-checks; its "Make a rule" opens the drawer on Categories & rules.
        #expect(!modules["review.js"]!.contains("renderRules"))
        #expect(modules["groups.js"]!.contains("makeRuleFrom("))
        #expect(!modules.values.contains { $0.contains("#/review/rules") })
    }

    @Test("A category made on the dashboard is in the summary the page reads, with its budget type and icon")
    func dashboardCreatesCategory() async throws {
        let (dash, _) = try await TestServer.app(surface: .dashboard)
        let write: HTTPFields = [HTTPField.Name("X-Budget-Dashboard")!: "1", .contentType: "application/json"]
        try await dash.test(.router) { client in
            try await client.execute(uri: "/v1/actions", method: .post, headers: write,
                                     body: TestServer.body(#"{"type":"createCategory","name":"Pottery","kind":"spending","group":"subscriptions"}"#)) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("Added Pottery"))
            }
            try await client.execute(uri: "/v1/actions", method: .post, headers: write,
                                     body: TestServer.body(#"{"type":"createCategory","name":"Cash back","kind":"moneyIn"}"#)) { #expect($0.status == .ok) }
            try await client.execute(uri: "/dash/summary", method: .get) { response in
                let summary = try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any]
                let categories = summary?["categories"] as? [[String: Any]] ?? []
                let pottery = try #require(categories.first { $0["name"] as? String == "Pottery" })
                #expect(pottery["group"] as? String == "subscriptions")
                #expect(pottery["kind"] as? String == "spending")
                #expect(pottery["countsAsSpending"] as? Bool == true)
                #expect(pottery["symbol"] as? String == "tag")
                let cashBack = try #require(categories.first { $0["name"] as? String == "Cash back" })
                #expect(cashBack["kind"] as? String == "moneyIn")
                #expect(cashBack["countsAsSpending"] as? Bool == false)
            }
            // Without the dashboard's header the write is refused, as every dashboard write is.
            try await client.execute(uri: "/v1/actions", method: .post, headers: [.contentType: "application/json"],
                                     body: TestServer.body(#"{"type":"createCategory","name":"Nope"}"#)) { #expect($0.status == .forbidden) }
        }
    }

    @Test("An import preview reports what it would add and saves nothing; the target account's kind reads the signs")
    func importPreview() async throws {
        let (app, service) = try await TestServer.app()
        let accountID = try #require(try await service.api.overview().accounts.first { $0.kind == .credit }?.id)
        let rows = try await service.api.transactions(TransactionFilter()).count
        let csv = "Date,Description,Amount\\n09/10/2026,UNITED AIRLINES,486.20\\n09/11/2026,HOTEL NIKKO,312.00\\n"
        let body = #"{"content":"\#(csv)","accountID":"\#(accountID)","preview":true,"options":{"format":"csv","sign":"auto","institution":"Summit"}}"#
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/imports", method: .post, headers: TestServer.auth, body: TestServer.body(body)) { response in
                #expect(response.status == .ok)
                let report = try RemoteBudgetAPI.decoder.decode(IngestReport.self, from: Data(response.body.readableBytesView))
                #expect(report.rowsAdded == 2)
                #expect(report.addedFrom != nil)
            }
        }
        #expect(try await service.api.transactions(TransactionFilter()).count == rows)
        #expect(try await service.store.imports().isEmpty)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/imports", method: .post, headers: TestServer.auth,
                                     body: TestServer.body(body.replacingOccurrences(of: #""preview":true,"#, with: ""))) { #expect($0.status == .created) }
        }
        // Positive amounts on a card are charges: filed as money out without being told.
        #expect(try await service.api.transactions(TransactionFilter(search: "Hotel Nikko")).first?.amount == Money(-312))

        // Several files at once, in order: a row two overlapping exports share counts once.
        let a = "Date,Description,Amount\\n08/01/2026,BLUE BOTTLE,6.50\\n08/02/2026,SHAKE SHACK,14.20\\n"
        let b = "Date,Description,Amount\\n08/02/2026,SHAKE SHACK,14.20\\n08/03/2026,SWEETGREEN,11.11\\n"
        let files = [a, b].map { #"{"content":"\#($0)","accountID":"\#(accountID)","options":{"format":"csv","sign":"auto","institution":"Summit"}}"# }
        let previewBody = #"{"files":[\#(files.joined(separator: ","))]}"#
        let before = try await service.api.transactions(TransactionFilter()).count
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/imports/preview", method: .post, headers: TestServer.auth,
                                     body: TestServer.body(previewBody)) { response in
                #expect(response.status == .ok)
                let reports = try RemoteBudgetAPI.decoder.decode([IngestReport].self, from: Data(response.body.readableBytesView))
                #expect(reports.map(\.rowsAdded) == [2, 1])
            }
        }
        #expect(try await service.api.transactions(TransactionFilter()).count == before)
    }

    @Test("A CSV can create its own named account with today's balance, and re-importing adds nothing")
    func namedCSVAccount() async throws {
        let (app, service) = try await TestServer.app(seedDemo: false)
        let csv = "Date,Description,Amount\\n09/20/2026,SAFEWAY #1234,-88.43\\n09/21/2026,PAYROLL ACME,3850.00\\n"
        let body = #"{"content":"\#(csv)","options":{"format":"csv","sign":"auto","institution":"Harbor","accountName":"Joint Checking","accountKind":"checking","balance":{"minor":245018,"currency":"USD"}}}"#
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/imports", method: .post, headers: TestServer.auth, body: TestServer.body(body)) { #expect($0.status == .created) }
            try await client.execute(uri: "/v1/imports", method: .post, headers: TestServer.auth, body: TestServer.body(body)) { response in
                let record = try RemoteBudgetAPI.decoder.decode(ImportRecord.self, from: Data(response.body.readableBytesView))
                #expect(record.report.rowsAdded == 0)
            }
        }
        let account = try #require(try await service.api.overview().accounts.first { $0.name == "Joint Checking" })
        #expect(account.institution == "Harbor")
        #expect(account.balance == Money(minorUnits: 245018))
        #expect(try await service.api.transactions(TransactionFilter()).count == 2)
    }

    @Test("Plaid keys saved on the dashboard override the environment, stay sealed, and drive Link")
    func dashboardPlaidKeys() async throws {
        let plaid = FakeProvider(["/link/token/create": [#"{"link_token": "link-sandbox-42"}"#]])
        let (dash, service) = try await TestServer.app(plaid: plaid, surface: .dashboard)
        let write: HTTPFields = [HTTPField.Name("X-Budget-Dashboard")!: "1", .contentType: "application/json"]
        try await dash.test(.router) { client in
            try await client.execute(uri: "/dash/providers", method: .get) { #expect(String(buffer: $0.body).contains(#""origin":"environment""#)) }
            let keys = #"{"clientID":"5f2b3c4d5e6f708192a3b4c5","secret":"0123456789abcdef0123456789abcd","environment":"sandbox","redirectURI":"https://dash.example/"}"#
            try await client.execute(uri: "/dash/providers/plaid", method: .put, headers: write, body: TestServer.body(keys)) { response in
                #expect(response.status == .ok)
                let text = String(buffer: response.body)
                #expect(text.contains(#""origin":"dashboard""#))
                #expect(!text.contains("0123456789abcdef0123456789abcd"))
            }
            try await client.execute(uri: "/v1/links/plaid/token", method: .post, headers: write, body: TestServer.body("{}")) { response in
                #expect(String(buffer: response.body).contains("link-sandbox-42"))
            }
            // Changing only the environment keeps the saved secret.
            try await client.execute(uri: "/dash/providers/plaid", method: .put, headers: write,
                                     body: TestServer.body(#"{"clientID":"5f2b3c4d5e6f708192a3b4c5","environment":"production"}"#)) { #expect($0.status == .ok) }
            try await client.execute(uri: "/dash/providers/plaid", method: .put, headers: write,
                                     body: TestServer.body(#"{"clientID":"5f2b3c4d5e6f708192a3b4c5","environment":"production","redirectURI":"http://insecure/"}"#)) {
                #expect($0.status == .unprocessableContent)
            }
        }
        try await dash.test(.router) { client in
            // A password manager's generated value, or a swapped field, is refused with a readable reason.
            try await client.execute(uri: "/dash/providers/plaid", method: .put, headers: write,
                                     body: TestServer.body(#"{"clientID":"gjxgx1A6qatXwmZdnpmjuwd5Zw","secret":"x","environment":"sandbox"}"#)) { response in
                #expect(response.status == .unprocessableContent)
                #expect(String(buffer: response.body).contains("isn't a Plaid client_id"))
            }
        }
        let sent = try #require(plaid.requests.first { $0.path == "/link/token/create" })
        #expect(sent.body.contains("5f2b3c4d5e6f708192a3b4c5") && sent.body.contains("0123456789abcdef0123456789abcd") && sent.body.contains("https://dash.example/"))
        let stored = try #require(try await service.store.providerSettings()?.plaid)
        #expect(stored.sealedSecret != "0123456789abcdef0123456789abcd")
        #expect(stored.environment == "production")
        #expect(try await service.providers.plaid()?.secret == "0123456789abcdef0123456789abcd")
        try await dash.test(.router) { client in
            // Remove really removes (this 404'd once: a wildcard DELETE lost to the static PUT route).
            try await client.execute(uri: "/dash/providers/plaid", method: .delete, headers: write) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains(#""origin":"environment""#)) // back to the env keys
            }
            try await client.execute(uri: "/dash/providers/teller", method: .delete, headers: write) { #expect($0.status == .ok) }
        }
        #expect(try await service.store.providerSettings()?.plaid == nil)
    }

    @Test("Teller: sandbox needs no certificate, real environments do, and bad PEMs are refused")
    func dashboardTeller() async throws {
        let (dash, service) = try await TestServer.app(surface: .dashboard)
        let write: HTTPFields = [HTTPField.Name("X-Budget-Dashboard")!: "1", .contentType: "application/json"]
        try await dash.test(.router) { client in
            try await client.execute(uri: "/v1/links/teller", method: .post, headers: write,
                                     body: TestServer.body(#"{"accessToken":"t","institution":"Harbor"}"#)) { #expect($0.status == .unprocessableContent) }
            try await client.execute(uri: "/dash/providers/teller", method: .put, headers: write,
                                     body: TestServer.body(#"{"applicationID":"app_1","environment":"development"}"#)) { response in
                #expect(response.status == .unprocessableContent)
                #expect(String(buffer: response.body).contains("certificate.pem"))
            }
            try await client.execute(uri: "/dash/providers/teller", method: .put, headers: write,
                                     body: TestServer.body(#"{"applicationID":"app_1","environment":"development","certificatePEM":"nope","keyPEM":"nope"}"#)) {
                #expect($0.status == .unprocessableContent)
            }
            try await client.execute(uri: "/dash/providers/teller", method: .put, headers: write,
                                     body: TestServer.body(#"{"applicationID":"app_1","environment":"sandbox"}"#)) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains(#""applicationID":"app_1""#))
            }
            try await client.execute(uri: "/v1/status", method: .get) { #expect(String(buffer: $0.body).contains("teller")) }
        }
        let teller = try #require(await service.providers.teller())
        #expect(teller.environment == "sandbox" && !teller.hasCertificate)
    }

    @Test("Server settings: dashboard over environment over default, validated, applied live; the models have their own calls")
    func serverSettings() async throws {
        var config = TestServer.config()
        config.modelBaseURL = URL(string: "https://qwen.example")
        config.environmentKeys = ["MODEL_BASE_URL"]
        let (service, _) = try await BudgetServerApp.makeService(config: config, store: MemoryStore(), logger: Logger(label: "test"))
        try await BudgetServerApp.prepare(service)
        let dash = Application(router: buildRouter(service, surface: .dashboard))
        let write: HTTPFields = [HTTPField.Name("X-Budget-Dashboard")!: "1", .contentType: "application/json"]
        @Sendable func field(_ fields: [SettingField], _ key: String) -> SettingField? { fields.first { $0.key == key } }
        try await dash.test(.router) { client in
            try await client.execute(uri: "/dash/settings", method: .get) { response in
                let fields = try JSONDecoder().decode([SettingField].self, from: Data(response.body.readableBytesView))
                for key in ServerSettings.chatKeys + ServerSettings.decisionKeys { #expect(field(fields, key) == nil, "\(key)") }
                #expect(field(fields, "openRouterKey") != nil && field(fields, "openRouterZeroRetention") != nil)
                #expect(field(fields, "syncIntervalHours")?.origin == .default)
            }
            try await client.execute(uri: "/dash/settings", method: .patch, headers: write,
                                     body: TestServer.body(#"{"changes":{"syncIntervalHours":"2","timeZone":"America/New_York","openRouterKey":"sk-or-test"}}"#)) { response in
                let text = String(buffer: response.body)
                #expect(response.status == .ok)
                #expect(!text.contains("sk-or-test"))
            }
            try await client.execute(uri: "/dash/settings", method: .patch, headers: write,
                                     body: TestServer.body(#"{"changes":{"timeZone":"Mars/Olympus"}}"#)) { #expect($0.status == .unprocessableContent) }
            // The flat model keys are the models' now (and only a rollback mirror in the row).
            try await client.execute(uri: "/dash/settings", method: .patch, headers: write,
                                     body: TestServer.body(#"{"changes":{"modelBaseURL":""}}"#)) { response in
                #expect(response.status == .unprocessableContent)
                #expect(String(buffer: response.body).contains("Unknown setting"))
            }
            try await client.execute(uri: "/dash/models/use", method: .post, headers: write, body: TestServer.body(#"{"chat":"off"}"#)) {
                #expect($0.status == .ok)
            }
        }
        #expect(await service.settings.syncIntervalHours == 2)
        #expect(await service.settings.timeZone.identifier == "America/New_York")
        #expect(await service.settings.openRouterKey == "sk-or-test")
        #expect(try await service.api.serverStatus().roles.first { $0.role == .chat }?.model == nil) // turned off, live
        let stored = try #require(try await service.store.serverSettings())
        #expect(stored.values["openRouterKey"] != "sk-or-test") // sealed
        try await service.settings.use(chat: "environment", decision: nil)
        await BudgetServerApp.apply(service)
        #expect(await service.settings.modelBaseURL?.absoluteString == "https://qwen.example") // back to the environment
        #expect(try await service.api.serverStatus().roles.first { $0.role == .chat }?.model != nil)

        // Jev's key can't go while Jev categorizes, or while it's asked when the local model is unsure.
        try await dash.test(.router) { client in
            try await client.execute(uri: "/v1/actions", method: .post, headers: write,
                                     body: TestServer.body(#"{"type":"updateDecisionPolicy","provider":"jev","rerunPending":false}"#)) { #expect($0.status == .ok) }
            for change in [#"{"changes":{"openRouterKey":""}}"#, #"{"changes":{"openRouterKey":null}}"#] {
                try await client.execute(uri: "/dash/settings", method: .patch, headers: write, body: TestServer.body(change)) { response in
                    #expect(response.status == .unprocessableContent)
                    #expect(String(buffer: response.body).contains("Jev is categorizing now. Pick another one and save first."))
                }
            }
            try await client.execute(uri: "/v1/actions", method: .post, headers: write,
                                     body: TestServer.body(#"{"type":"updateDecisionPolicy","provider":"localDecide","escalateToJev":true,"rerunPending":false}"#)) { #expect($0.status == .ok) }
            try await client.execute(uri: "/dash/settings", method: .patch, headers: write, body: TestServer.body(#"{"changes":{"openRouterKey":""}}"#)) { response in
                #expect(response.status == .unprocessableContent)
                #expect(String(buffer: response.body).contains("Jev is asked when the local model is unsure. Turn that off and save first."))
            }
            // A new key is fine, and so is anything else.
            try await client.execute(uri: "/dash/settings", method: .patch, headers: write,
                                     body: TestServer.body(#"{"changes":{"openRouterKey":"sk-or-new","syncIntervalHours":"3"}}"#)) { #expect($0.status == .ok) }
        }
        #expect(await service.settings.openRouterKey == "sk-or-new")
    }

    @Test("Models: addresses are saved as the server's base; keys stay sealed; categorizing on the chat model's server borrows its key; Test says what's wrong")
    func modelSettingsAndTest() async throws {
        let (service, _) = try await BudgetServerApp.makeService(config: TestServer.config(), store: MemoryStore(), logger: Logger(label: "test"))
        try await BudgetServerApp.prepare(service)
        #expect(ModelCheck.base(URL(string: "https://switchboard.example/v1/chat/completions")!).absoluteString == "https://switchboard.example")
        #expect(ModelCheck.base(URL(string: "https://switchboard.example/v1/")!).absoluteString == "https://switchboard.example")
        #expect(ModelCheck.base(URL(string: "https://llm.example/api")!).absoluteString == "https://llm.example/api")
        // Through the path production takes (saved base, then the chat client), each documented address reaches its endpoint.
        func chat(_ typed: String) -> String { OpenAIChatModel(baseURL: ModelCheck.base(URL(string: typed)!), model: "m").endpoint.absoluteString }
        #expect(chat("https://switchboard.example/v1/") == "https://switchboard.example/v1/chat/completions")
        #expect(chat("https://api.groq.com/openai/v1") == "https://api.groq.com/openai/v1/chat/completions")
        #expect(chat("https://generativelanguage.googleapis.com/v1beta/openai/") == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")
        #expect(chat("https://openrouter.ai/api/v1") == "https://openrouter.ai/api/v1/chat/completions")
        #expect(chat("https://api.openai.com/v1") == "https://api.openai.com/v1/chat/completions")
        let settings = service.settings
        let (chatID, picked) = try await settings.saveModel(ModelDraft(kind: "chat", address: "https://switchboard.example/v1", apiKey: "sk-switch", model: "smart"),
                                                            policy: .off)
        #expect(picked) // the first chat model on a server with none
        #expect(await settings.modelBaseURL?.absoluteString == "https://switchboard.example")
        let (chatKey, decisionKey) = (await settings.modelAPIKey, await settings.decisionAPIKey)
        #expect(chatKey == "sk-switch" && decisionKey == "sk-switch")
        let saved = try #require(try await service.store.modelSettings()?.models.first { $0.id == chatID })
        #expect(saved.name == "smart" && saved.sealedKey != nil && saved.sealedKey != "sk-switch") // sealed
        let (clefID, _) = try await settings.saveModel(ModelDraft(kind: "decision", address: "https://decide.example/v1/systemone"), policy: .off)
        try await settings.use(chat: nil, decision: clefID)
        #expect(await settings.decisionBaseURL?.absoluteString == "https://decide.example")
        #expect(await settings.decisionAPIKey == nil) // its own server: its own key, or none
        let list = await settings.modelList()
        #expect(list.chat.first { $0.id == chatID }.map { $0.hasKey && !$0.keyUnreadable && $0.name == "smart" } == true)
        #expect(list.decision.first?.name == "decide.example")

        let dash = Application(router: buildRouter(service, surface: .dashboard))
        let write: HTTPFields = [HTTPField.Name("X-Budget-Dashboard")!: "1", .contentType: "application/json"]
        try await dash.test(.router) { client in
            // Nothing listens on port 9: can't reach it.
            try await client.execute(uri: "/dash/models/test", method: .post, headers: write,
                                     body: TestServer.body(#"{"draft":{"kind":"chat","address":"http://127.0.0.1:9/v1","model":"smart"}}"#)) { response in
                #expect(response.status == .ok)
                let report = try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any]
                let draft = report?["draft"] as? [String: Any]
                #expect(draft?["ok"] as? Bool == false && draft?["address"] as? String == "http://127.0.0.1:9")
                #expect((draft?["detail"] as? String)?.contains("Can't reach") == true)
                #expect((report?["chat"] as? [String: Any])?.isEmpty == true && (report?["decision"] as? [String: Any])?.isEmpty == true)
                #expect(!String(buffer: response.body).contains("sk-switch"))
            }
            try await client.execute(uri: "/dash/models", method: .get) { response in
                let text = String(buffer: response.body)
                #expect(text.contains(#""chatInUse":"\#(chatID)""#) && text.contains(#""decisionInUse":"\#(clefID)""#))
                #expect(!text.contains("sk-switch") && !text.contains(saved.sealedKey!))
            }
        }
    }

    @Test("Remove data: ledger, links (revoked at Plaid), import history and keys, each on request")
    func removeData() async throws {
        let plaid = FakeProvider([
            "/item/public_token/exchange": [#"{"access_token": "access-sandbox-9", "item_id": "item-1"}"#],
            "/transactions/sync": [#"{"added": [{"transaction_id": "t1", "account_id": "chk", "amount": 12.5, "date": "2026-09-20", "name": "BLUE BOTTLE", "pending": false}], "modified": [], "removed": [], "next_cursor": "c1", "has_more": false}"#],
            "/accounts/balance/get": [#"{"accounts": [{"account_id": "chk", "balances": {"current": 50}, "name": "Checking", "type": "depository", "subtype": "checking"}]}"#],
            "/item/remove": [#"{"request_id": "r"}"#],
        ])
        let (dash, service) = try await TestServer.app(seedDemo: false, plaid: plaid, surface: .dashboard)
        let write: HTTPFields = [HTTPField.Name("X-Budget-Dashboard")!: "1", .contentType: "application/json"]
        try await dash.test(.router) { client in
            try await client.execute(uri: "/v1/links/plaid/exchange", method: .post, headers: write,
                                     body: TestServer.body(#"{"publicToken":"p","institution":"Harbor"}"#)) { #expect($0.status == .created) }
            try await client.execute(uri: "/v1/admin/reset", method: .post, headers: write,
                                     body: TestServer.body(#"{"confirm":"nope"}"#)) { #expect($0.status == .unprocessableContent) }
            try await client.execute(uri: "/v1/admin/reset", method: .post, headers: write,
                                     body: TestServer.body(#"{"confirm":"erase my ledger","removeLinks":true,"clearImports":true,"removeProviderKeys":true}"#)) { response in
                #expect(response.status == .ok)
                #expect(String(buffer: response.body).contains("1 linked account"))
            }
        }
        #expect(plaid.requests.contains { $0.path == "/item/remove" && $0.body.contains("access-sandbox-9") })
        #expect(try await service.store.links().isEmpty)
        #expect(try await service.store.imports().isEmpty)
        #expect(try await service.api.overview().accounts.isEmpty)
        #expect(try await service.providers.plaid() != nil) // env keys remain; only dashboard-saved ones are removed
    }

    @Test("A real server (no BUDGET_ALLOW_DEMO) refuses the demo ledger, even if BUDGET_SEED_DEMO is set")
    func demoRefusedOnRealServer() async throws {
        let env = try ServerConfig.fromEnvironment(["BUDGET_SEED_DEMO": "1"])
        #expect(!env.allowDemo && !env.seedDemo)
        #expect(try ServerConfig.fromEnvironment(["BUDGET_ALLOW_DEMO": "1", "BUDGET_SEED_DEMO": "true"]).seedDemo)
        var config = TestServer.config()
        config.allowDemo = false
        let (service, _) = try await BudgetServerApp.makeService(config: config, store: MemoryStore(), logger: Logger(label: "test"))
        let dash = Application(router: buildRouter(service, surface: .dashboard))
        try await dash.test(.router) { client in
            try await client.execute(uri: "/v1/admin/reset", method: .post,
                                     headers: [HTTPField.Name("X-Budget-Dashboard")!: "1", .contentType: "application/json"],
                                     body: TestServer.body(#"{"confirm":"erase my ledger","seedDemo":true}"#)) { response in
                #expect(response.status == .unprocessableContent)
                #expect(String(buffer: response.body).contains("won't load the demo"))
            }
        }
    }

    @Test("Token sealing round-trips and rejects a bad key")
    func sealing() throws {
        let sealer = try TokenSealer(base64Key: TestServer.key)
        let sealed = try sealer.seal("secret")
        #expect(sealed != "secret")
        #expect(try sealer.open(sealed) == "secret")
        #expect(throws: ServerConfig.ConfigError.self) { try TokenSealer(base64Key: "short") }
    }

    @Test("Configuration from the environment")
    func config() throws {
        let c = try ServerConfig.fromEnvironment([
            "PORT": "9090", "BUDGET_API_TOKEN": "t", "POSTGRES_HOST": "db", "POSTGRES_PASSWORD": "pw",
            "MODEL_BASE_URL": "https://qwen.example", "PLAID_CLIENT_ID": "a", "PLAID_SECRET": "b", "PLAID_ENV": "production",
            "BUDGET_TIMEZONE": "America/New_York",
        ])
        #expect(c.port == 9090)
        #expect(c.database?.host == "db")
        #expect(c.decisionBaseURL?.absoluteString == "https://qwen.example")
        #expect(c.plaid?.environment == .production)
        #expect(c.timeZone.identifier == "America/New_York")
        #expect(throws: ServerConfig.ConfigError.self) { try ServerConfig.fromEnvironment(["PLAID_CLIENT_ID": "a", "PLAID_SECRET": "b", "PLAID_ENV": "development"]) }
    }
}
