import BudgetKit
@testable import BudgetServerCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Hummingbird
import HummingbirdTesting
import Logging
import Testing

/// A bridge that answers every `/accounts` request with the body it's given (scripted by the test), status 200.
final class ScriptedBridge: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _body: String
    init(_ body: String) { _body = body }
    var body: String { get { lock.withLock { _body } } set { lock.withLock { _body = newValue } } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// No day of a bank's rows is skipped for good: a whole link down for months, new account ids after a new token, a bank
/// needing a sign-in while the history walk runs, an account SimpleFIN leaves out.
@Suite("SimpleFIN: no rows lost to a gap")
struct SimpleFINGapTests {
    static let day: TimeInterval = 86_400
    static let url = URL(string: "https://user:pass@bridge.example/simplefin")!

    static func newLink(_ id: String) -> StoredLink {
        StoredLink(id: id, provider: .simplefin, institution: "SimpleFIN Bridge", externalID: nil, sealedToken: "",
                   cursor: nil, status: .connected, lastSync: nil, lastError: nil, createdAt: Date())
    }

    @discardableResult
    static func run(_ link: inout StoredLink, _ transport: any HTTPTransport, _ trigger: SyncTrigger, at now: Date, api: LedgerBudgetAPI) async throws -> ProviderSyncOutcome {
        try await SimpleFINSync.run(link: &link, url: url, trigger: trigger, batchID: "b-\(now.timeIntervalSince1970)", api: api, transport: transport,
                                    automaticPerDay: 4, timeZone: .gmt, now: now, logger: Logger(label: "t"))
    }

    static func query(_ components: URLComponents) -> [String: String] {
        Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    static func seconds(_ date: Date) -> String { String(Int(date.timeIntervalSince1970)) }

    @Test("A link refused for 120 days, then a new token: each bank gets repair windows over the days the fresh pull can't reach")
    func longLinkOutageRepairsTheHole() async throws {
        let (_, service) = try await TestServer.app(seedDemo: false)
        let bridge = FakeBridge([SimpleFINSyncTests.harbor, SimpleFINSyncTests.keystone])
        var link = Self.newLink("simplefin-out")
        let t0 = Date().addingTimeInterval(-130 * Self.day)
        try await Self.run(&link, bridge, .afterLink, at: t0, api: service.api)
        // Revoked (or the subscription lapsed): nothing for 120 days, and the banks themselves were never marked.
        bridge.status = 403
        await #expect(throws: SimpleFINError.revoked) { try await Self.run(&link, bridge, .personLink, at: t0.addingTimeInterval(Self.day), api: service.api) }
        bridge.status = 200
        let t1 = t0.addingTimeInterval(120 * Self.day)
        try await Self.run(&link, bridge, .reconnect, at: t1, api: service.api)
        let freshStart = t1.addingTimeInterval(-SimpleFINPlanner.maxSpan)
        let state = try #require(link.simplefin)
        for id in ["CON-A", "CON-B"] {
            #expect(state.connections[id]?.gap == SimpleFINGap(from: t0.addingTimeInterval(-10 * Self.day), through: freshStart, purpose: .repair))
        }
        // The next scheduled run asks for the hole, each bank's accounts on their own.
        let before = bridge.requestCount
        try await Self.run(&link, bridge, .schedule, at: t1.addingTimeInterval(3600), api: service.api)
        let repairs = bridge.accountRequests[before...].map(Self.query).filter { $0["account"] != nil }
        #expect(repairs.map { $0["account"] } == ["ACT-A1", "ACT-B1"])
        #expect(repairs.allSatisfy { $0["start-date"] == Self.seconds(t0.addingTimeInterval(-10 * Self.day)) && $0["end-date"] == Self.seconds(freshStart) })
        #expect(link.simplefin?.connections.values.allSatisfy { $0.gap == nil } == true)
    }

    @Test("New account ids after a new token: the next runs walk their history back from where the swap's fresh pull began")
    func newIDsAfterTokenSwapGetTheirHistory() async throws {
        let bridge = FakeBridge([SimpleFINSyncTests.harbor])
        let (app, service) = try await TestServer.app(seedDemo: false, plaid: bridge)
        try await app.test(.router) { client in
            let id = try await SimpleFINSyncTests.link(client).linkID
            let lastGood = try #require(try await SimpleFINSyncTests.stored(service).simplefin?.connections["CON-A"]?.lastGoodData)
            bridge.banks = [FakeBridge.Bank(connID: "CON-A2", name: "Harbor", accounts: ["ACT-A9"])]
            // A bank's row id works here too, as it does for Try again.
            try await client.execute(uri: "/v1/links/\(id)~\(StableHash.short("CON-A"))/token", method: .put, headers: TestServer.auth,
                                     body: TestServer.body(#"{"setupToken": "\#(FakeBridge.setupToken)"}"#)) { response in
                #expect(response.status == .ok)
                let body = try #require(try JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
                #expect(body["linkID"] as? String == id && body["note"] as? String != nil)
            }
            let freshStart = lastGood.addingTimeInterval(-SimpleFINPlanner.overlap)
            let gap = try #require(try await SimpleFINSyncTests.stored(service).simplefin?.connections["CON-A2"]?.gap)
            #expect(gap.purpose == .backfill && gap.through == freshStart)
            let before = bridge.requestCount
            _ = await service.sync.syncAll(trigger: .schedule)
            let windows = bridge.accountRequests[before...].map(Self.query).filter { $0["account"] == "ACT-A9" }
            // The first reaches from the swap's fresh start back a full window: [now − 89 d, freshStart) is in it.
            let first = try #require(windows.first)
            #expect(first["end-date"] == Self.seconds(freshStart))
            #expect(Int(first["start-date"]!)! <= Int(Date().addingTimeInterval(-SimpleFINPlanner.maxSpan).timeIntervalSince1970))
        }
    }

    @Test("The history walk waits while a bank needs a sign-in, and goes on from where it was once the bank is back")
    func historyWalkWaitsForASignIn() async throws {
        let (_, service) = try await TestServer.app(seedDemo: false)
        let bridge = FakeBridge([SimpleFINSyncTests.harbor, SimpleFINSyncTests.keystone])
        var link = Self.newLink("simplefin-walk")
        let t0 = Date().addingTimeInterval(-10 * Self.day)
        try await Self.run(&link, bridge, .afterLink, at: t0, api: service.api)
        let reached = try #require(link.simplefin?.backfill?.reachedBack)
        bridge.conAuth = ["CON-B"]
        var before = bridge.requestCount
        try await Self.run(&link, bridge, .schedule, at: t0.addingTimeInterval(3600), api: service.api)
        #expect(bridge.requestCount == before + 1) // the fresh pull only
        #expect(link.simplefin?.backfill?.reachedBack == reached && link.simplefin?.connections["CON-B"]?.status == .needsReauth)
        // Signed in again: its missed days first, then the walk from where it stopped.
        bridge.conAuth = []
        before = bridge.requestCount
        try await Self.run(&link, bridge, .schedule, at: t0.addingTimeInterval(7 * 3600), api: service.api)
        let asked = bridge.accountRequests[before...].map(Self.query)
        #expect(asked.dropFirst().first?["account"] == "ACT-B1")
        #expect(asked.first { $0["account"] == nil && $0["end-date"] != nil }?["end-date"] == Self.seconds(reached))
        #expect(link.simplefin?.connections["CON-B"]?.status == .connected)
    }

    @Test("An account SimpleFIN names only in act.failed stays the bank's, and the bank's last good pull doesn't move")
    func accountLeftOutStaysTheBanks() async throws {
        let (_, service) = try await TestServer.app(seedDemo: false)
        func body(_ accounts: [String], errlist: String = "") -> String {
            let list = accounts.map { #"{"id": "\#($0)", "name": "Harbor \#($0)", "conn_id": "CON-A", "currency": "USD", "balance": "1.00", "balance-date": 1790000000, "transactions": []}"# }
            return #"{"errlist": [\#(errlist)], "connections": [{"conn_id": "CON-A", "name": "Harbor"}], "accounts": [\#(list.joined(separator: ","))]}"#
        }
        let bridge = ScriptedBridge(body(["ACT-A1", "ACT-A2"]))
        var link = Self.newLink("simplefin-act")
        let t0 = Date().addingTimeInterval(-3 * Self.day)
        try await Self.run(&link, bridge, .personLink, at: t0, api: service.api)
        #expect(link.simplefin?.connections["CON-A"]?.lastGoodData == t0)
        // Matched by conn_id.
        bridge.body = body(["ACT-A1"], errlist: #"{"code": "act.failed", "msg": "Could not fetch", "conn_id": "CON-A", "account_id": "ACT-A2"}"#)
        try await Self.run(&link, bridge, .personLink, at: t0.addingTimeInterval(Self.day), api: service.api)
        var bank = try #require(link.simplefin?.connections["CON-A"])
        #expect(bank.accountIDs == ["ACT-A1", "ACT-A2"] && bank.lastGoodData == t0 && bank.lastMessage == "Could not fetch")
        // Matched by the account alone.
        bridge.body = body(["ACT-A1"], errlist: #"{"code": "act.missingdata", "account_id": "ACT-A2"}"#)
        try await Self.run(&link, bridge, .personLink, at: t0.addingTimeInterval(2 * Self.day), api: service.api)
        bank = try #require(link.simplefin?.connections["CON-A"])
        #expect(bank.accountIDs == ["ACT-A1", "ACT-A2"] && bank.lastGoodData == t0)
        // All there again: it moves on.
        bridge.body = body(["ACT-A1", "ACT-A2"])
        try await Self.run(&link, bridge, .personLink, at: t0.addingTimeInterval(2.5 * Self.day), api: service.api)
        #expect(link.simplefin?.connections["CON-A"]?.lastGoodData == t0.addingTimeInterval(2.5 * Self.day))
    }

    @Test("A 200 that can't be read is recorded as 200, not as no answer")
    func unreadableAnswerRecordsItsStatus() async throws {
        let (_, service) = try await TestServer.app(seedDemo: false)
        var link = Self.newLink("simplefin-bad")
        await #expect(throws: DecodingError.self) { try await Self.run(&link, ScriptedBridge("<html>not json</html>"), .personLink, at: Date(), api: service.api) }
        #expect(link.simplefin?.requests.map(\.status) == [200])
    }

    @Test("A scheduled run at the hard stop asks nothing and records no problem")
    func scheduledSyncAtHardStopSkipsQuietly() async throws {
        let bridge = FakeBridge([SimpleFINSyncTests.harbor])
        let (app, service) = try await TestServer.app(seedDemo: false, plaid: bridge)
        try await app.test(.router) { client in _ = try await SimpleFINSyncTests.link(client) }
        var link = try await SimpleFINSyncTests.stored(service)
        link.simplefin?.requests = (0..<20).map { SimpleFINRequest(at: Date().addingTimeInterval(-Double($0) * 60 - 60), purpose: .fresh, trigger: "person", status: 200) }
        try await service.store.upsertLink(link)
        let before = bridge.requestCount
        let results = await service.sync.syncAll(trigger: .schedule)
        #expect(bridge.requestCount == before)
        #expect(results.map(\.ok) == [true] && results[0].error == nil && results[0].errorKind == nil && results[0].skipped != nil)
        let after = try await SimpleFINSyncTests.stored(service)
        #expect(after.lastError == nil && after.errorKind == nil && after.errorCode == nil && after.status == .connected)
        #expect((after.failureCount ?? 0) == 0 && after.simplefin?.requests.count == 20)
    }
}
