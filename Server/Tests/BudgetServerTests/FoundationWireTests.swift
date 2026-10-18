import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Testing

/// Server 0.6.0's additions only add: what 0.5.5 stored still loads, and today's behaviour holds until the lanes build.
@Suite("0.6.0 foundation")
struct FoundationWireTests {
    @Test("A link stored by 0.5.5 decodes, with every new field nil, and its summary carries no new keys")
    func oldStoredLink() throws {
        let doc = #"""
        {"id": "plaid-item-1", "provider": "plaid", "institution": "Harbor", "externalID": "item-1", "sealedToken": "x", "cursor": "c1",
         "status": "needsReauth", "lastSync": 800000000, "lastError": "Plaid: login required (ITEM_LOGIN_REQUIRED)", "createdAt": 790000000,
         "cardBills": {"access": "ok", "checkedAt": 800000000, "cards": 2}}
        """#
        // The store's own coding (PostgresStore uses Foundation's defaults).
        let link = try JSONDecoder().decode(StoredLink.self, from: Data(doc.utf8))
        #expect(link.status == .needsReauth && link.cardBills?.cards == 2)
        #expect(link.errorKind == nil && link.plaid == nil && link.simplefin == nil && link.holdings == nil && link.failureCount == nil)
        let summary = try JSONSerialization.jsonObject(with: JSONEncoder().encode(link.summary)) as? [String: Any]
        #expect(Set(summary?.keys.map { $0 } ?? []) == ["id", "provider", "institution", "status", "lastSync", "lastError", "createdAt", "externalID", "cardBills"])
        // And a 0.5.5 import record: nil optionals aren't written, so this is the shape it stored.
        let record = try JSONEncoder().encode(ImportRecord(batchID: "b", kind: .sync, linkID: "plaid-item-1", label: "Harbor sync",
                                                           report: IngestReport(batchID: "b", source: .plaid), createdAt: Date(), rolledBack: false))
        let keys = try JSONSerialization.jsonObject(with: record) as? [String: Any]
        #expect(Set(keys?.keys.map { $0 } ?? []) == ["batchID", "kind", "linkID", "label", "report", "createdAt", "rolledBack"])
        let old = try JSONDecoder().decode(ImportRecord.self, from: record)
        #expect(old.outcome == nil && old.undo == nil && old.annotated().undo?.mode == .refused) // a Plaid sync (L1: hide instead)
        var undone = old
        undone.rolledBack = true
        #expect(undone.annotated().undo?.mode == .refused)
        #expect(try JSONDecoder().decode(UndoPolicy.Mode.self, from: Data(#""maybe""#.utf8)) == .refused)
        #expect(try JSONDecoder().decode(ImportOutcome.self, from: Data(#""partial""#.utf8)) == .ok)
    }

    @Test("Who asked for a sync: only the person's own asks count as theirs; retries are for the person and reconnects")
    func triggers() {
        let all: [SyncTrigger] = [.schedule, .morningCatchUp, .person, .personLink, .reconnect, .afterLink, .webhook("SYNC_UPDATES_AVAILABLE")]
        #expect(all.filter(\.requestedByPerson) == [.person, .personLink])
        #expect(all.filter(\.retriesSignIn) == [.personLink, .reconnect, .afterLink])
    }

    @Test("POST /v1/sync reads an optional body; the phone's own client sends requestedByPerson")
    func syncBody() async throws {
        let (app, _) = try await TestServer.app(seedDemo: false)
        try await app.test(.router) { client in
            for body in ["", "{}", #"{"requestedByPerson": true}"#, "not json"] {
                try await client.execute(uri: "/v1/sync", method: .post, headers: TestServer.auth, body: TestServer.body(body)) { response in
                    #expect(response.status == .ok)
                    #expect(String(buffer: response.body) == "[]")
                }
            }
        }
        let encoded = try RemoteBudgetAPI.encoder.encode(SyncRequest(requestedByPerson: true))
        #expect(String(decoding: encoded, as: UTF8.self) == #"{"requestedByPerson":true}"#)
    }

    @Test("Imports read back with what Undo may do; status reads this server's version")
    func annotatedImports() async throws {
        let (app, service) = try await TestServer.app(seedDemo: false, surface: .dashboard)
        let report = IngestReport(batchID: "b1", source: .fileImport)
        try await service.store.upsertImport(ImportRecord(batchID: "b1", kind: .file, linkID: nil, label: "File", report: report, createdAt: Date(), rolledBack: false))
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/imports", method: .get, headers: TestServer.dash) { response in
                let records = try RemoteBudgetAPI.decoder.decode([ImportRecord].self, from: Data(response.body.readableBytesView))
                #expect(records.map(\.undo) == [UndoPolicy(mode: .allowed)])
            }
            try await client.execute(uri: "/v1/status", method: .get, headers: TestServer.dash) { response in
                let status = try RemoteBudgetAPI.decoder.decode(ServerStatus.self, from: Data(response.body.readableBytesView))
                #expect(status.version == BudgetServerVersion.current)
                #expect(ServerStatus.version(status.version, isAtLeast: ServerStatus.connectionsSince))
            }
        }
    }

    @Test("updateLink changes a stored link in its turn; an unknown one is not found")
    func updateLink() async throws {
        let (_, service) = try await TestServer.app(seedDemo: false)
        let sealed = try #require(try service.sealer?.seal("tok"))
        try await service.store.upsertLink(StoredLink(id: "plaid-x", provider: .plaid, institution: "Harbor", externalID: "x", sealedToken: sealed,
                                                      cursor: nil, status: .connected, lastSync: nil, lastError: nil, createdAt: Date()))
        try await service.sync.updateLink("plaid-x") { link in
            var plaid = link.plaid ?? PlaidLinkState()
            plaid.institutionID = "ins_1"
            link.plaid = plaid
        }
        #expect(try await service.store.links().first?.plaid?.institutionID == "ins_1")
        await #expect(throws: BudgetAPIError.notFound) { try await service.sync.updateLink("nope") { _ in } }
    }

    @Test("New settings: holdings auto/on/off, webhooks on, SimpleFIN pulls; the public URL providers call back is tidy https")
    func settings() async throws {
        let base = try ServerConfig.fromEnvironment([:])
        #expect(base.plaidHoldings == "auto" && base.plaidWebhooks && base.simplefinDailyPulls == 4)
        #expect(try ServerConfig.fromEnvironment(["BUDGET_PLAID_HOLDINGS": "1"]).plaidHoldings == "on")
        #expect(try ServerConfig.fromEnvironment(["BUDGET_PLAID_HOLDINGS": "false"]).plaidHoldings == "off")
        #expect(throws: ServerConfig.ConfigError.self) { try ServerConfig.fromEnvironment(["BUDGET_PLAID_HOLDINGS": "sometimes"]) }
        #expect(try !ServerConfig.fromEnvironment(["BUDGET_PLAID_WEBHOOKS": "0"]).plaidWebhooks)
        #expect(try ServerConfig.fromEnvironment(["BUDGET_PUBLIC_URL": "https://api.example//"]).publicURL == "https://api.example")
        #expect(ServerConfig.normalizedPublicURL("https://api.example/", allowHTTP: false) == "https://api.example")
        #expect(ServerConfig.normalizedPublicURL("http://127.0.0.1:18080", allowHTTP: false) == nil)
        #expect(ServerConfig.normalizedPublicURL("http://127.0.0.1:18080", allowHTTP: true) == "http://127.0.0.1:18080")
        #expect(ServerConfig.normalizedPublicURL(nil, allowHTTP: true) == nil)

        var config = TestServer.config()
        config.publicURL = "https://api.example"
        let settings = ServerSettings(config: config, store: MemoryStore(), sealer: nil, logger: .init(label: "test"))
        try await settings.load()
        let (mode, webhooks, pulls) = (await settings.holdingsMode, await settings.plaidWebhooksEnabled, await settings.simplefinDailyPulls)
        #expect(mode == .auto && webhooks && pulls == 4)
        // Production's default needs BUDGET_IOS_APP_ID (the AASA file), else the redirect wouldn't open the app.
        #expect(await settings.plaidMobileRedirectURI(sandbox: false) == nil)
        #expect(await settings.missingAppLinks(sandbox: false))
        #expect(await settings.plaidMobileRedirectURI(sandbox: true) == "https://api.example/plaid/oauth-return")
        config.iosAppID = "TEAMID.com.example.budget"
        let withApp = ServerSettings(config: config, store: MemoryStore(), sealer: nil, logger: .init(label: "test"))
        #expect(await withApp.plaidMobileRedirectURI(sandbox: false) == "https://api.example/plaid/oauth-return")
        try await settings.update(["holdings": "on", "simplefinDailyPulls": "6"], policy: nil)
        let (mode2, pulls2) = (await settings.holdingsMode, await settings.simplefinDailyPulls)
        #expect(mode2 == .on && pulls2 == 6)
        await #expect(throws: BudgetAPIError.self) { try await settings.update(["holdings": "maybe"], policy: nil) }
        await #expect(throws: BudgetAPIError.self) { try await settings.update(["simplefinDailyPulls": "50"], policy: nil) }
        config.plaidMobileRedirectURI = "off"
        let off = ServerSettings(config: config, store: MemoryStore(), sealer: nil, logger: .init(label: "test"))
        #expect(await off.plaidMobileRedirectURI(sandbox: false) == nil)
    }

    @Test("A derived key is stable for its purpose and differs between purposes")
    func derivedKeys() throws {
        let sealer = try TokenSealer(base64Key: TestServer.key)
        let a = sealer.derivedKey(info: "budget statement ids v1").withUnsafeBytes { Data($0) }
        let b = sealer.derivedKey(info: "budget statement ids v1").withUnsafeBytes { Data($0) }
        let c = sealer.derivedKey(info: "something else").withUnsafeBytes { Data($0) }
        #expect(a.count == 32 && a == b && a != c)
    }
}
