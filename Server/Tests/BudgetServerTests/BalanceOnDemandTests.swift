import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import Testing

@Suite("Balance only on request; holdings off the routine sync (P0.1)")
struct BalanceOnDemandTests {
    static let id = PlaidErrorKindTests.id

    /// A link that syncs cleanly, answering both balance reads and holdings, so a test sees which ones were asked.
    static func plaid(live: (Int, String) = PlaidScript.balances, cached: (Int, String) = PlaidScript.balances, delay: Duration = .zero) -> ScriptedProvider {
        ScriptedProvider([
            "/transactions/sync": [PlaidScript.page("c1")],
            "/accounts/get": [cached],
            "/accounts/balance/get": [live],
            "/investments/holdings/get": [(200, #"{"accounts": [], "holdings": [], "securities": []}"#)],
        ], delay: delay)
    }

    static func checking(_ service: BudgetService) async throws -> Account {
        try #require(await service.api.accountList().first { $0.name == "Checking" })
    }

    static func setPlaid(_ service: BudgetService, _ change: (inout PlaidLinkState) -> Void) async throws {
        var link = try await PlaidErrorKindTests.link(service)
        var state = link.plaid ?? PlaidLinkState()
        change(&state)
        link.plaid = state
        try await service.store.upsertLink(link)
    }

    // MARK: Which syncs read live

    @Test("A scheduled sync reads Plaid's cached balances: no live balance call and no holdings call")
    func scheduled() async throws {
        let plaid = Self.plaid()
        let (_, service) = try await PlaidErrorKindTests.service(plaid)
        #expect(await service.sync.syncAll().map(\.ok) == [true])
        #expect(plaid.count("/accounts/get") == 1)
        #expect(plaid.count("/accounts/balance/get") == 0 && plaid.count("/investments/holdings/get") == 0)
        #expect(try await PlaidErrorKindTests.link(service).plaid?.balanceRequests == nil)
    }

    @Test("Webhook, reconnect, new-link and morning catch-up syncs never read live", arguments: [
        SyncTrigger.webhook("SYNC_UPDATES_AVAILABLE"), .reconnect, .afterLink, .morningCatchUp, .schedule,
    ])
    func notThePerson(trigger: SyncTrigger) async throws {
        let plaid = Self.plaid()
        let (_, service) = try await PlaidErrorKindTests.service(plaid)
        if trigger == .morningCatchUp || trigger == .schedule {
            #expect(await service.sync.syncAll(trigger: trigger).map(\.ok) == [true])
        } else {
            #expect(try await service.sync.sync(linkID: Self.id, trigger: trigger).ok)
        }
        #expect(plaid.count("/accounts/balance/get") == 0 && plaid.count("/investments/holdings/get") == 0)
        #expect(plaid.count("/accounts/get") == 1)
    }

    @Test("The person's sync reads live once; a second within the hour reads the cache")
    func personOncePerHour() async throws {
        let plaid = Self.plaid()
        let (_, service) = try await PlaidErrorKindTests.service(plaid)
        #expect(try await service.sync.sync(linkID: Self.id, trigger: .personLink).ok)
        #expect(plaid.count("/accounts/balance/get") == 1 && plaid.count("/accounts/get") == 0)
        let link = try await PlaidErrorKindTests.link(service)
        #expect(link.plaid?.balanceRequests?.count == 1 && link.plaid?.balanceAsOf != nil)

        #expect(await service.sync.syncAll(trigger: .person).map(\.ok) == [true])
        #expect(plaid.count("/accounts/balance/get") == 1 && plaid.count("/accounts/get") == 1)
        #expect(try await PlaidErrorKindTests.link(service).plaid?.balanceRequests?.count == 1)
        #expect(plaid.count("/investments/holdings/get") == 0)
    }

    @Test("The phone's \"Sync now\" (requestedByPerson) reads live; an old phone's empty body is a scheduled sync")
    func routes() async throws {
        let plaid = Self.plaid()
        let (app, service) = try await PlaidErrorKindTests.service(plaid)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/sync", method: .post, headers: TestServer.auth) { #expect($0.status == .ok) }
            #expect(plaid.count("/accounts/balance/get") == 0)
            try await client.execute(uri: "/v1/sync", method: .post, headers: TestServer.auth,
                                     body: TestServer.body(#"{"requestedByPerson": true}"#)) { #expect($0.status == .ok) }
            #expect(plaid.count("/accounts/balance/get") == 1)
        }
        #expect(try await PlaidErrorKindTests.link(service).plaid?.balanceRequests?.count == 1)
    }

    @Test("The daily cap: six live reads in a day, then the cache until the oldest is a day old")
    func dailyCap() async throws {
        let plaid = Self.plaid()
        let (_, service) = try await PlaidErrorKindTests.service(plaid)
        let now = Date()
        // Five in the last day, none in the last hour: one more is allowed.
        try await Self.setPlaid(service) { $0.balanceRequests = (2...6).map { now.addingTimeInterval(-Double($0) * 3_600) } + [now.addingTimeInterval(-25 * 3_600)] }
        #expect(try await service.sync.sync(linkID: Self.id).ok)
        #expect(plaid.count("/accounts/balance/get") == 1)
        // The read a day old is pruned; the six left fill the day.
        let requests = try #require(try await PlaidErrorKindTests.link(service).plaid?.balanceRequests)
        #expect(requests.count == 6 && requests.allSatisfy { now.timeIntervalSince($0) < 86_400 })
        try await Self.setPlaid(service) { $0.balanceRequests = (2...7).map { now.addingTimeInterval(-Double($0) * 3_600) } }
        #expect(try await service.sync.sync(linkID: Self.id).ok)
        #expect(plaid.count("/accounts/balance/get") == 1 && plaid.count("/accounts/get") == 1)
    }

    @Test("The cap itself: one an hour, six a day, a day's window")
    func capRules() {
        let now = Date()
        var state = PlaidLinkState()
        #expect(state.mayReadLiveBalance(now: now))
        state.recordBalanceRead(now: now)
        #expect(!state.mayReadLiveBalance(now: now.addingTimeInterval(3_599)))
        #expect(state.mayReadLiveBalance(now: now.addingTimeInterval(3_600)))
        for hour in 1...5 { state.recordBalanceRead(now: now.addingTimeInterval(Double(hour) * 3_600)) }
        #expect(state.balanceRequests?.count == 6)
        #expect(!state.mayReadLiveBalance(now: now.addingTimeInterval(7 * 3_600)))
        #expect(state.mayReadLiveBalance(now: now.addingTimeInterval(86_400)))
        state.recordBalanceRead(now: now.addingTimeInterval(86_400 + 3_600))
        #expect(state.balanceRequests?.count == 5) // the first two fell out of the day
    }

    @Test("A person's sync that joins a run already under way gets that run's results and no live read")
    func joinsRun() async throws {
        let plaid = Self.plaid(delay: .milliseconds(150))
        let (_, service) = try await PlaidErrorKindTests.service(plaid)
        let scheduled = Task { await service.sync.syncAll(trigger: .schedule) }
        try await Task.sleep(for: .milliseconds(50))
        let joined = await service.sync.syncAll(trigger: .person)
        #expect(joined.map(\.ok) == [true])
        #expect(await scheduled.value.map(\.ok) == [true])
        #expect(plaid.count("/accounts/balance/get") == 0 && plaid.count("/transactions/sync") == 1)
    }

    // MARK: Honest dates

    @Test("A cached balance isn't stamped with the fetch time: the last live read dates it")
    func cachedNotNow() async throws {
        let plaid = Self.plaid()
        let (_, service) = try await PlaidErrorKindTests.service(plaid)
        let liveAt = Date().addingTimeInterval(-3 * 3_600)
        try await Self.setPlaid(service) { $0.balanceAsOf = liveAt }
        #expect(await service.sync.syncAll().map(\.ok) == [true])
        let asOf = try #require(try await Self.checking(service).balanceAsOf)
        #expect(abs(asOf.timeIntervalSince(liveAt)) < 1)
        // A newer transactions update from Plaid dates it instead.
        let updated = Date().addingTimeInterval(-3_600)
        try await Self.setPlaid(service) { $0.lastTransactionsUpdate = updated }
        #expect(await service.sync.syncAll().map(\.ok) == [true])
        #expect(abs(try #require(try await Self.checking(service).balanceAsOf).timeIntervalSince(updated)) < 1)
    }

    @Test("Plaid's own last_updated_datetime wins; a live read is dated when it ran")
    func plaidDate() async throws {
        let cached = (200, #"{"accounts": [{"account_id": "chk", "balances": {"current": 5000, "iso_currency_code": "USD", "last_updated_datetime": "2026-10-15T08:30:00Z"}, "name": "Checking", "type": "depository", "subtype": "checking"}]}"#)
        let plaid = Self.plaid(cached: cached)
        let (_, service) = try await PlaidErrorKindTests.service(plaid)
        try await Self.setPlaid(service) { $0.balanceAsOf = Date().addingTimeInterval(-600); $0.balanceRequests = [Date().addingTimeInterval(-600)] }
        #expect(await service.sync.syncAll().map(\.ok) == [true])
        #expect(try await Self.checking(service).balanceAsOf == (try Date("2026-10-15T08:30:00Z", strategy: .iso8601)))

        try await Self.setPlaid(service) { $0.balanceRequests = [] }
        let before = Date()
        #expect(try await service.sync.sync(linkID: Self.id).ok)
        let asOf = try #require(try await Self.checking(service).balanceAsOf)
        #expect(asOf >= before.addingTimeInterval(-1) && asOf <= Date().addingTimeInterval(1))
        let state = try #require(try await PlaidErrorKindTests.link(service).plaid)
        #expect(abs(try #require(state.balanceAsOf).timeIntervalSince(asOf)) < 1)
    }

    // MARK: When Plaid refuses the live read

    @Test("A refused live read falls back to the cache: the sync succeeds, the code and request_id are logged, the call still counts")
    func refusedFallsBack() async throws {
        let log = CapturedLog()
        let limit = PlaidErrorKindTests.plaidError("ACCOUNTS_BALANCE_GET_LIMIT", type: "RATE_LIMIT_EXCEEDED", status: 429, requestID: "req-bal")
        let plaid = Self.plaid(live: limit)
        let (_, service) = try await PlaidErrorKindTests.service(plaid, logger: log.logger)
        let result = try await service.sync.sync(linkID: Self.id)
        #expect(result.ok && result.errorKind == nil)
        #expect(plaid.count("/accounts/balance/get") == 1 && plaid.count("/accounts/get") == 1)
        let link = try await PlaidErrorKindTests.link(service)
        #expect(link.errorKind == nil && link.plaid?.balanceRequests?.count == 1 && link.plaid?.balanceAsOf == nil)
        let line = try #require(log.lines.first { $0.contains("live balance for Harbor refused") })
        #expect(line.contains("ACCOUNTS_BALANCE_GET_LIMIT") && line.contains("req-bal"))
        #expect(!log.lines.contains { $0.contains("access-sandbox-9") || $0.contains("error_type") })
    }

    @Test("A sign-in refused on the live read still fails the sync as a sign-in, through the cached read")
    func refusedSignIn() async throws {
        let plaid = Self.plaid(live: PlaidScript.loginRequired, cached: PlaidScript.loginRequired)
        let (_, service) = try await PlaidErrorKindTests.service(plaid)
        let result = try await service.sync.sync(linkID: Self.id)
        #expect(!result.ok && result.errorKind == .needsSignIn)
        #expect(try await PlaidErrorKindTests.link(service).cursor == "c0")
    }

    @Test("The live read sends a freshness floor (Capital One, Apple Card); the cached read sends only the token")
    func requestBodies() async throws {
        let plaid = Self.plaid()
        let (_, service) = try await PlaidErrorKindTests.service(plaid)
        #expect(try await service.sync.sync(linkID: Self.id).ok)
        #expect(await service.sync.syncAll().map(\.ok) == [true])
        func body(_ path: String) throws -> [String: JSONValue] {
            let request = try #require(plaid.requests.last { $0.path == path })
            guard case let .object(o) = try JSONValue.parse(Data(request.body.utf8)) else { Issue.record("not an object"); return [:] }
            return o
        }
        let live = try body("/accounts/balance/get")
        #expect(live["access_token"] == .string("access-sandbox-9"))
        guard case let .object(options)? = live["options"], case let .string(floor)? = options["min_last_updated_datetime"],
              let date = try? Date(floor, strategy: .iso8601) else { Issue.record("no freshness floor"); return }
        #expect(abs(date.timeIntervalSinceNow + 86_400) < 120)
        let cached = try body("/accounts/get")
        #expect(cached["options"] == nil && cached["access_token"] == .string("access-sandbox-9"))
    }
}
