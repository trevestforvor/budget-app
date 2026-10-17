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

/// A SimpleFIN Bridge: claims a setup token, then answers `/accounts` for the window asked (one row per account per
/// window, dated a day after its start), with a scripted status, `con.auth` banks and a `gen.auth`.
final class FakeBridge: HTTPTransport, @unchecked Sendable {
    struct Bank { var connID: String; var name: String; var accounts: [String] }
    private let lock = NSLock()
    private var _banks: [Bank]
    private var _status = 200
    private var _conAuth: Set<String> = []
    private var _claimed = 0
    private(set) var accountRequests: [URLComponents] = []

    init(_ banks: [Bank]) { _banks = banks }

    var banks: [Bank] { get { lock.withLock { _banks } } set { lock.withLock { _banks = newValue } } }
    var status: Int { get { lock.withLock { _status } } set { lock.withLock { _status = newValue } } }
    var conAuth: Set<String> { get { lock.withLock { _conAuth } } set { lock.withLock { _conAuth = newValue } } }
    var claimed: Int { lock.withLock { _claimed } }
    var requestCount: Int { lock.withLock { accountRequests.count } }

    static let setupToken = Data("https://bridge.example/simplefin/claim/abc".utf8).base64EncodedString()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let (status, body): (Int, String) = lock.withLock {
            if url.path.hasPrefix("/simplefin/claim/") {
                _claimed += 1
                return (200, "https://user:pass\(_claimed)@bridge.example/simplefin")
            }
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            accountRequests.append(components)
            guard _status == 200 else { return (_status, "Forbidden") }
            let query = components.queryItems ?? []
            let start = Int(query.first { $0.name == "start-date" }?.value ?? "0") ?? 0
            let only = Set(query.filter { $0.name == "account" }.compactMap(\.value))
            var accounts: [String] = []
            for bank in _banks {
                for id in bank.accounts where only.isEmpty || only.contains(id) {
                    let rows = _conAuth.contains(bank.connID) ? "" :
                        #"{"id": "\#(id)-\#(start)", "posted": \#(start + 86_400), "amount": "-12.50", "description": "COFFEE \#(id) \#(start)"}"#
                    accounts.append(#"{"id": "\#(id)", "name": "\#(bank.name) Checking", "conn_id": "\#(bank.connID)", "currency": "USD", "balance": "100.00", "balance-date": \#(Int(Date().timeIntervalSince1970)), "transactions": [\#(rows)]}"#)
                }
            }
            let errlist = _conAuth.map { #"{"code": "con.auth", "msg": "Sign in again", "conn_id": "\#($0)"}"# }
            let connections = _banks.map { #"{"conn_id": "\#($0.connID)", "name": "\#($0.name)", "org_id": "ORG"}"# }
            return (200, #"{"errlist": [\#(errlist.joined(separator: ","))], "connections": [\#(connections.joined(separator: ","))], "accounts": [\#(accounts.joined(separator: ","))]}"#)
        }
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// Keeps every log message, to show what a sync logs (and what it doesn't).
final class CapturedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func append(_ line: String) { lock.withLock { _lines.append(line) } }

    var logger: Logger {
        Logger(label: "capture") { _ in Handler(log: self) }
    }

    struct Handler: LogHandler {
        let log: CapturedLog
        var metadata: Logger.Metadata = [:]
        var logLevel: Logger.Level = .info
        subscript(metadataKey key: String) -> Logger.Metadata.Value? { get { metadata[key] } set { metadata[key] = newValue } }
        func log(event: LogEvent) { log.append("\(event.message)") }
    }
}

@Suite("SimpleFIN: hardened sync")
struct SimpleFINSyncTests {
    static let harbor = FakeBridge.Bank(connID: "CON-A", name: "Harbor", accounts: ["ACT-A1"])
    static let keystone = FakeBridge.Bank(connID: "CON-B", name: "Keystone", accounts: ["ACT-B1"])

    static func decode<T: Decodable>(_ type: T.Type, _ response: TestResponse) throws -> T {
        try RemoteBudgetAPI.decoder.decode(T.self, from: Data(response.body.readableBytesView))
    }

    static func stored(_ service: BudgetService) async throws -> StoredLink {
        try #require(try await service.store.links().first { $0.provider == .simplefin })
    }

    /// A new SimpleFIN link through the route, as the dashboard makes one.
    static func link(_ client: some TestClientProtocol) async throws -> LinkSyncResult {
        try await client.execute(uri: "/v1/links/simplefin", method: .post, headers: TestServer.auth,
                                 body: TestServer.body(#"{"setupToken": "\#(FakeBridge.setupToken)"}"#)) { response in
            #expect(response.status == .created)
            return try Self.decode(LinkSyncResult.self, response)
        }
    }

    @Test("The first link pulls fresh and three history windows (four requests), as one batch, and starts the walk")
    func simplefinFirstLinkBackfillsThreeWindows() async throws {
        let bridge = FakeBridge([Self.harbor, Self.keystone])
        let (app, service) = try await TestServer.app(seedDemo: false, plaid: bridge)
        try await app.test(.router) { client in
            let result = try await Self.link(client)
            #expect(result.ok && result.report?.rowsAdded == 8) // 2 accounts × 4 windows
        }
        #expect(bridge.claimed == 1 && bridge.requestCount == 4)
        let queries = bridge.accountRequests.map { Dictionary(($0.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a }) }
        #expect(queries[0]["pending"] == "1" && queries[0]["end-date"] == nil)
        #expect(queries.dropFirst().allSatisfy { $0["end-date"] != nil && $0["pending"] == nil })
        // Each history window ends where the one before it started.
        for (newer, older) in zip(queries.dropLast(), queries.dropFirst()) { #expect(older["end-date"] == newer["start-date"]) }
        let link = try await Self.stored(service)
        let state = try #require(link.simplefin)
        #expect(state.requests.count == 4 && state.requests.map(\.purpose) == [.fresh, .backfill, .backfill, .backfill])
        #expect(state.requests.allSatisfy { $0.trigger == "firstLink" && $0.status == 200 })
        #expect(state.backfill?.done == false && state.connections.keys.sorted() == ["CON-A", "CON-B"])
        #expect(state.connections.values.allSatisfy { $0.status == .connected && $0.lastGoodData != nil && $0.gap == nil })
        #expect(try await service.store.imports().count == 1)
        #expect(link.summary.requestsToday == 4 && link.summary.banks?.map(\.name) == ["Harbor", "Keystone"])
    }

    @Test("A scheduled sync with the budget spent asks nothing and isn't an error")
    func scheduledSyncSkipsWhenBudgetSpent() async throws {
        let bridge = FakeBridge([Self.harbor])
        let (app, service) = try await TestServer.app(seedDemo: false, plaid: bridge)
        try await app.test(.router) { client in _ = try await Self.link(client) }
        // The first scheduled run pulls (fresh, plus history windows within the day's allowance).
        let first = await service.sync.syncAll(trigger: .schedule)
        #expect(first.map(\.ok) == [true] && first[0].skipped == nil)
        let afterFirst = bridge.requestCount
        #expect(afterFirst > 4)
        // An hour later on the schedule (a short interval): too soon after the last automatic pull.
        let second = await service.sync.syncAll(trigger: .schedule)
        #expect(bridge.requestCount == afterFirst)
        #expect(second.map(\.ok) == [true] && second[0].report == nil && second[0].error == nil)
        #expect(second[0].skipped?.contains("about once a day") == true)
        let link = try await Self.stored(service)
        #expect(link.lastError == nil && link.status == .connected && link.errorKind == nil)
    }

    @Test("The person asking past 20 requests in a day is refused here, rate limited, with when to try; nothing is asked")
    func personRefusedAtHardStop() async throws {
        let bridge = FakeBridge([Self.harbor])
        let (app, service) = try await TestServer.app(seedDemo: false, plaid: bridge)
        try await app.test(.router) { client in _ = try await Self.link(client) }
        var link = try await Self.stored(service)
        link.simplefin?.requests = (0..<20).map { SimpleFINRequest(at: Date().addingTimeInterval(-Double($0) * 60), purpose: .fresh, trigger: "person", status: 200) }
        try await service.store.upsertLink(link)
        let before = bridge.requestCount
        let result = try await service.sync.sync(linkID: link.id, trigger: .personLink)
        #expect(!result.ok && result.errorKind == .rateLimited)
        #expect(result.error?.hasPrefix("SimpleFIN allows about 24 requests a day; this server stops at 20. The next pull can run at ") == true)
        #expect(bridge.requestCount == before)
        #expect(try await Self.stored(service).status == .connected)
    }

    @Test("403 marks the whole link revoked: it waits for a new setup token, and the one request still counts")
    func simplefin403MarksLinkRevoked() async throws {
        let bridge = FakeBridge([Self.harbor, Self.keystone])
        let (app, service) = try await TestServer.app(seedDemo: false, plaid: bridge)
        try await app.test(.router) { client in
            let id = try await Self.link(client).linkID
            bridge.status = 403
            try await client.execute(uri: "/v1/links/\(id)/sync", method: .post, headers: TestServer.auth) { response in
                let result = try Self.decode(LinkSyncResult.self, response)
                #expect(!result.ok && result.errorKind == .revoked && result.error?.contains("new setup token") == true)
            }
            let link = try await Self.stored(service)
            #expect(link.status == .needsReauth && link.errorKind == .revoked && link.errorCode == "http-403")
            #expect(link.simplefin?.requests.count == 5 && link.simplefin?.requests.last?.status == 403)
            // One row for the link: the fix is a new token on the dashboard, not a sign-in at the Bridge.
            try await client.execute(uri: "/v1/status", method: .get, headers: TestServer.auth) { response in
                let rows = try Self.decode(ServerStatus.self, response).institutions
                #expect(rows.map(\.id) == [id] && rows[0].status == .needsReauth && rows[0].reconnect == .dashboard && rows[0].reconnectURL == nil)
            }
            // Scheduled runs leave it alone.
            #expect(await service.sync.syncAll(trigger: .schedule).isEmpty)
        }
    }

    @Test("gen.auth in the errlist is revoked too")
    func genAuthRevokes() async throws {
        let (_, service) = try await TestServer.app(seedDemo: false)
        let bridge = FakeBridgeGenAuth()
        var link = StoredLink(id: "simplefin-g", provider: .simplefin, institution: "SimpleFIN Bridge", externalID: nil, sealedToken: "",
                              cursor: nil, status: .connected, lastSync: nil, lastError: nil, createdAt: Date())
        await #expect(throws: SimpleFINError.revoked) {
            _ = try await SimpleFINSync.run(link: &link, url: URL(string: "https://u:p@bridge.example/simplefin")!, trigger: .personLink, batchID: "b",
                                            api: service.api, transport: bridge, automaticPerDay: 4, timeZone: .gmt, logger: Logger(label: "t"))
        }
        #expect(link.simplefin?.requests.count == 1)
    }

    @Test("One bank's con.auth leaves the link connected: the other bank's rows come in and its window moves on")
    func conAuthLeavesOtherBanksSyncing() async throws {
        let bridge = FakeBridge([Self.harbor, Self.keystone])
        let (app, service) = try await TestServer.app(seedDemo: false, plaid: bridge)
        try await app.test(.router) { client in
            let id = try await Self.link(client).linkID
            let before = try #require(try await Self.stored(service).simplefin?.connections)
            try await Task.sleep(for: .milliseconds(1100)) // a new start-date second, so the fresh rows are new
            bridge.conAuth = ["CON-B"]
            try await client.execute(uri: "/v1/links/\(id)/sync", method: .post, headers: TestServer.auth) { response in
                let result = try Self.decode(LinkSyncResult.self, response)
                #expect(result.ok && result.report?.rowsAdded == 1 && result.errorKind == nil)
            }
            let link = try await Self.stored(service)
            let after = try #require(link.simplefin?.connections)
            #expect(link.status == .connected && link.lastError == nil)
            #expect(after["CON-A"]?.status == .connected && after["CON-A"]!.lastGoodData! > before["CON-A"]!.lastGoodData!)
            #expect(after["CON-B"]?.status == .needsReauth && after["CON-B"]?.lastGoodData == before["CON-B"]?.lastGoodData)
            #expect(after["CON-B"]?.firstFailedAt != nil && after["CON-B"]?.errorCode == "con.auth" && after["CON-B"]?.lastMessage == "Sign in again")
            #expect(link.summary.banks?.map(\.errorKind) == [nil, .needsSignIn])
            // The broken bank's accounts aren't stamped as synced; the other's are.
            try await client.execute(uri: "/v1/overview", method: .get, headers: TestServer.auth) { response in
                let accounts = try Self.decode(Overview.self, response).accounts
                let a = try #require(accounts.first { $0.id == "simplefin:ACT-A1" }), b = try #require(accounts.first { $0.id == "simplefin:ACT-B1" })
                #expect(a.lastSyncedAt! > b.lastSyncedAt!)
            }
            // Signed in again at the Bridge: back to connected, and the next pull reaches back for it again.
            bridge.conAuth = []
            _ = try await service.sync.sync(linkID: id, trigger: .personLink)
            let healed = try #require(try await Self.stored(service).simplefin?.connections["CON-B"])
            #expect(healed.status == .connected && healed.firstFailedAt == nil && healed.lastMessage == nil)
        }
    }

    @Test("Settings → Accounts lists a row per bank; the one needing a sign-in sends the phone to the Bridge, by name")
    func institutionsSplitPerConnection() async throws {
        let bridge = FakeBridge([Self.harbor, Self.keystone])
        let (app, service) = try await TestServer.app(seedDemo: false, plaid: bridge)
        try await app.test(.router) { client in
            let id = try await Self.link(client).linkID
            bridge.conAuth = ["CON-B"]
            _ = try await service.sync.sync(linkID: id, trigger: .personLink)
            let keystoneRow = "\(id)~\(StableHash.short("CON-B"))"
            try await client.execute(uri: "/v1/status", method: .get, headers: TestServer.auth) { response in
                let rows = try Self.decode(ServerStatus.self, response).institutions
                #expect(rows.map(\.institution) == ["Harbor", "Keystone"])
                let harbor = rows[0], keystone = rows[1]
                #expect(harbor.id == "\(id)~\(StableHash.short("CON-A"))" && harbor.status == .connected && harbor.reconnectURL == nil)
                #expect(harbor.accountIDs == ["simplefin:ACT-A1"] && harbor.syncLinkID == id)
                #expect(keystone.id == keystoneRow && keystone.status == .needsReauth && keystone.errorKind == .needsSignIn)
                #expect(keystone.reconnect == .providerSite && keystone.reconnectURL == "https://beta-bridge.simplefin.org" && keystone.providerSiteURL != nil)
                #expect(keystone.syncLinkID == id && keystone.accountIDs == ["simplefin:ACT-B1"] && keystone.failingSince != nil)
                #expect(keystone.note.contains("your other banks keep syncing"))
                // The bridge's own ids stay on the server.
                #expect(!rows.contains { $0.id.contains("CON-") })
            }
            // Home names the bank, not the Bridge.
            try await client.execute(uri: "/v1/overview", method: .get, headers: TestServer.auth) { response in
                let attention = try Self.decode(Overview.self, response).attention ?? []
                #expect(attention.contains { $0.id == "reauth-\(keystoneRow)" && $0.title.contains("Keystone") })
                #expect(!attention.contains { $0.id.hasPrefix("reauth-") && $0.title.contains("Harbor") })
            }
        }
    }

    @Test("An old app's Try again on a bank's row (a composite id) syncs the link: 200")
    func oldAppCompositeIDTryAgain() async throws {
        let bridge = FakeBridge([Self.harbor, Self.keystone])
        let (app, _) = try await TestServer.app(seedDemo: false, plaid: bridge)
        try await app.test(.router) { client in
            let id = try await Self.link(client).linkID
            let row = "\(id)~\(StableHash.short("CON-B"))"
            try await client.execute(uri: "/v1/links/\(row)/sync", method: .post, headers: TestServer.auth) { response in
                #expect(response.status == .ok)
                let result = try Self.decode(LinkSyncResult.self, response)
                #expect(result.ok && result.linkID == id)
            }
            // Percent-encoded, as an app that escapes the path sends it.
            try await client.execute(uri: "/v1/links/\(id)%7E\(StableHash.short("CON-B"))/sync", method: .post, headers: TestServer.auth) { #expect($0.status == .ok) }
            try await client.execute(uri: "/v1/links/simplefin-nope~abc/sync", method: .post, headers: TestServer.auth) { #expect($0.status == .notFound) }
        }
    }

    @Test("A new setup token keeps the link id; when the accounts come back under new ids it says so")
    func replaceSetupTokenKeepsLinkID() async throws {
        let bridge = FakeBridge([Self.harbor])
        let (app, service) = try await TestServer.app(seedDemo: false, plaid: bridge)
        try await app.test(.router) { client in
            let id = try await Self.link(client).linkID
            bridge.status = 403
            _ = try await service.sync.sync(linkID: id, trigger: .personLink)
            let sealedBefore = try await Self.stored(service).sealedToken
            bridge.status = 200
            try await client.execute(uri: "/v1/links/\(id)/token", method: .put, headers: TestServer.auth,
                                     body: TestServer.body(#"{"setupToken": "\#(FakeBridge.setupToken)"}"#)) { response in
                #expect(response.status == .ok)
                let body = try #require(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
                #expect(body["linkID"] as? String == id && body["ok"] as? Bool == true && body["note"] == nil)
            }
            var link = try await Self.stored(service)
            #expect(try await service.store.links().count == 1)
            #expect(link.status == .connected && link.errorKind == nil && link.sealedToken != sealedBefore && bridge.claimed == 2)

            // SimpleFIN hands out new ids with the new token: the person is told, and the history walk starts over.
            bridge.banks = [FakeBridge.Bank(connID: "CON-A2", name: "Harbor", accounts: ["ACT-A9"])]
            try await client.execute(uri: "/v1/links/\(id)/token", method: .put, headers: TestServer.auth,
                                     body: TestServer.body(#"{"setupToken": "\#(FakeBridge.setupToken)"}"#)) { response in
                let body = try #require(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
                #expect(body["note"] as? String == "These accounts came in as new ones; your old ones keep their history.")
            }
            link = try await Self.stored(service)
            #expect(link.simplefin?.connections.keys.sorted() == ["CON-A2"] && link.simplefin?.backfill?.done == false)

            // Only SimpleFIN links take one, and only as a setup token.
            try await service.store.upsertLink(StoredLink(id: "plaid-item-1", provider: .plaid, institution: "Chase", externalID: "item-1", sealedToken: "x",
                                                          cursor: nil, status: .connected, lastSync: nil, lastError: nil, createdAt: Date()))
            try await client.execute(uri: "/v1/links/plaid-item-1/token", method: .put, headers: TestServer.auth,
                                     body: TestServer.body(#"{"setupToken": "\#(FakeBridge.setupToken)"}"#)) { #expect($0.status == .unprocessableContent) }
            try await client.execute(uri: "/v1/links/\(id)/token", method: .put, headers: TestServer.auth,
                                     body: TestServer.body(#"{"accessToken": "t"}"#)) { #expect($0.status == .badRequest) }
            try await client.execute(uri: "/v1/links/\(id)/token", method: .put, headers: TestServer.auth,
                                     body: TestServer.body(#"{"setupToken": "not a token!"}"#)) { response in
                #expect(response.status == .unprocessableContent)
                #expect(String(buffer: response.body).contains("isn't a SimpleFIN setup token"))
            }
        }
    }

    @Test("Each request logs its count, never the access URL; the bridge's extra keys are logged by name once a day")
    func logsRequestCount() async throws {
        let (_, service) = try await TestServer.app(seedDemo: false)
        let log = CapturedLog()
        var link = StoredLink(id: "simplefin-log", provider: .simplefin, institution: "SimpleFIN Bridge", externalID: nil, sealedToken: "",
                              cursor: nil, status: .connected, lastSync: nil, lastError: nil, createdAt: Date())
        let url = URL(string: "https://user:SECRETPASS@bridge.example/simplefin")!
        _ = try await SimpleFINSync.run(link: &link, url: url, trigger: .personLink, batchID: "b1", api: service.api,
                                        transport: FakeBridge([Self.harbor]), automaticPerDay: 4, timeZone: .gmt, logger: log.logger)
        #expect(log.lines.contains("simplefin simplefin-log: request 1 of 20 today (fresh)"))
        #expect(!log.lines.joined().contains("SECRETPASS") && !log.lines.joined().contains("bridge.example"))
        print(log.lines.filter { $0.hasPrefix("simplefin ") }.joined(separator: "\n"))
    }

    @Test("A bank needing a sign-in gets one push per episode, named; a revoked link's banks don't")
    func bankNeedsSignInAlert() throws {
        let since = Date(timeIntervalSince1970: 1_790_000_000)
        var state = SimpleFINLinkState()
        state.connections = ["CON-A": SimpleFINConnectionState(name: "Harbor", lastGoodData: since),
                             "CON-B": SimpleFINConnectionState(name: "Keystone", status: .needsReauth, firstFailedAt: since, accountIDs: ["ACT-B1"])]
        var link = StoredLink(id: "simplefin-1", provider: .simplefin, institution: "SimpleFIN Bridge", externalID: nil, sealedToken: "",
                              cursor: nil, status: .connected, lastSync: nil, lastError: nil, createdAt: since)
        link.simplefin = state
        let alerts = ConnectionAlerts.healthAlerts([], links: [link], now: since.addingTimeInterval(3600))
        let alert = try #require(alerts.first)
        #expect(alerts.count == 1 && alert.kind == .bankNeedsSignIn && alert.linkID == "simplefin-1")
        #expect(alert.episodeKeys == ["bank|simplefin-1|\(StableHash.short("CON-B"))|1790000000"])
        #expect(alert.bankID == "simplefin-1~\(StableHash.short("CON-B"))" && alert.title == "Keystone needs you to sign in")
        link.status = .needsReauth
        #expect(ConnectionAlerts.healthAlerts([], links: [link], now: since).isEmpty)
    }

    @Test("A link stored before 0.6.0 decodes, lists as one row, and starts its history walk on the next pull")
    func oldLinkUpgrades() async throws {
        let bridge = FakeBridge([Self.harbor])
        let (app, service) = try await TestServer.app(seedDemo: false, plaid: bridge)
        let sealed = try #require(try service.sealer?.seal("https://user:pass@bridge.example/simplefin"))
        try await service.store.upsertLink(StoredLink(id: "simplefin-old", provider: .simplefin, institution: "SimpleFIN Bridge", externalID: nil,
                                                      sealedToken: sealed, cursor: nil, status: .connected, lastSync: Date().addingTimeInterval(-86_400),
                                                      lastError: nil, createdAt: Date().addingTimeInterval(-90 * 86_400)))
        await service.sync.publishInstitutions()
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/status", method: .get, headers: TestServer.auth) { response in
                let rows = try Self.decode(ServerStatus.self, response).institutions
                #expect(rows.map(\.id) == ["simplefin-old"])
            }
        }
        let results = await service.sync.syncAll(trigger: .schedule)
        #expect(results.map(\.ok) == [true])
        let state = try #require(try await Self.stored(service).simplefin)
        // Fresh, then six history windows: the day's scheduled allowance.
        #expect(state.requests.map(\.purpose) == [.fresh] + Array(repeating: .backfill, count: 6))
        #expect(state.backfill?.done == false)
    }
}

/// A bridge that answers every pull with `gen.auth`.
struct FakeBridgeGenAuth: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(#"{"errlist": [{"code": "gen.auth", "msg": "revoked"}], "accounts": []}"#.utf8),
         HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
