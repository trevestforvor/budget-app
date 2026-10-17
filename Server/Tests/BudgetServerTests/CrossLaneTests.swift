import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import NIOCore
import Testing

// Tests that need more than one lane's work merged (SPEC §6.1 step 4): Lane P's daily Item check and webhooks driving
// Lane A's holdings, Lane P's link pushes and Lane S's stale pushes sharing one budget, and Lane L's statement-id
// migration under Lane P's syncs, webhooks and Lane A's holdings.

/// A Plaid Item at Harbor with a checking and a brokerage account, billed for Investments. Nothing reaches Plaid.
enum CrossLaneScript {
    static let accounts = (200, #"""
    {"accounts": [
      {"account_id": "chk", "balances": {"current": 5000, "iso_currency_code": "USD"}, "name": "Checking", "type": "depository", "subtype": "checking"},
      {"account_id": "inv", "balances": {"current": 20000, "iso_currency_code": "USD"}, "name": "Brokerage", "type": "investment", "subtype": "brokerage"}
    ], "request_id": "req-acc"}
    """#)

    static func provider(syncPages: [(Int, String)] = [PlaidScript.page("c1", PlaidScript.row)]) -> ScriptedProvider {
        ScriptedProvider([
            "/transactions/sync": syncPages,
            "/accounts/get": [accounts],
            "/accounts/balance/get": [accounts],
            "/item/get": [ItemCheckTests.item(billed: ["transactions", "investments"], webhook: nil)],
            "/item/webhook/update": [(200, #"{"item": {"item_id": "item-1"}, "request_id": "req-wh"}"#)],
            HoldingsScript.path: [HoldingsScript.ok],
            "/webhook_verification_key/get": [WebhookFixture.jwk()],
        ])
    }

    /// Harbor's Item, stored as the exchange leaves it.
    static func link(_ service: BudgetService, createdAt: Date = Date()) async throws {
        let sealed = try #require(try service.sealer?.seal("access-sandbox-9"))
        try await service.store.upsertLink(StoredLink(id: PlaidErrorKindTests.id, provider: .plaid, institution: "Harbor", externalID: WebhookFixture.itemID,
                                                      sealedToken: sealed, cursor: nil, status: .connected, lastSync: nil, lastError: nil,
                                                      createdAt: createdAt))
    }

    /// The webhook route for `service`, verified as in production, with a quick queue.
    static func webhookApp(_ service: BudgetService) -> (PlaidWebhookReceiver, Application<RouterResponder<BasicRequestContext>>) {
        let verifier = PlaidWebhookVerifier(fetch: PlaidWebhookReceiver.fetchKey(service), logger: service.logger, clock: { Date() })
        let receiver = PlaidWebhookReceiver(service: service, verifier: verifier, queue: PlaidWebhookQueue(service: service, settle: 0.1, syncSpacing: 60))
        let router = Router()
        router.add(middleware: ErrorMiddleware(logger: service.logger))
        router.add(middleware: AuthMiddleware(surface: .api, token: service.config.apiToken, allowedOrigins: service.config.allowedOrigins))
        addPlaidWebhookRoutes(router, service, receiver: receiver)
        return (receiver, Application(router: router))
    }

    /// Posts one signed webhook and waits for the queue to finish what it asked for.
    static func deliver(_ type: String, _ code: String, receiver: PlaidWebhookReceiver,
                        app: Application<RouterResponder<BasicRequestContext>>) async throws {
        let body = WebhookFixture.body(type, code)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/plaid/webhook", method: .post, headers: WebhookFixture.headers(WebhookFixture.jwt(body)),
                                     body: ByteBuffer(bytes: body)) { #expect($0.status == .ok) }
        }
        for _ in 0..<400 {
            if await receiver.queue.isIdle { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await receiver.queue.isIdle)
    }
}

extension NetWorthRouteTests {
    @Test("Holdings come from the daily Item check, once a day: no sync of any kind asks for them")
    func holdingsFetchedOncePerDayNotEverySync() async throws {
        let plaid = CrossLaneScript.provider()
        let f = try await ItemCheckTests.fixture(plaid, holdings: "auto", realHoldings: true)
        // The fixture's link is Harbor's Item; a first sync brings its two accounts in.
        #expect(try await f.service.sync.sync(linkID: ItemCheckTests.id, trigger: .personLink).ok)
        #expect(await f.service.api.accountList().contains { $0.kind == .investment && $0.institution == "Harbor" })
        _ = await f.service.sync.syncAll()
        _ = await f.service.sync.syncAll(trigger: .person)
        _ = try await f.service.sync.sync(linkID: ItemCheckTests.id, trigger: .webhook("SYNC_UPDATES_AVAILABLE"))
        #expect(plaid.count("/transactions/sync") == 4)
        #expect(plaid.count(HoldingsScript.path) == 0, "a sync never asks for holdings")

        // The day's check asks once and stores the positions.
        #expect(await f.maintenance.checkDueItems() == 1)
        #expect(plaid.count(HoldingsScript.path) == 1)
        #expect(try await f.link().holdings?.access == .ok)
        #expect(try await f.service.api.holdings().accounts.contains { $0.id == "plaid:inv" && !$0.holdings.isEmpty })

        // More syncs and another look the same day: nothing more.
        _ = await f.service.sync.syncAll(trigger: .person)
        f.clock.set(ItemCheckTests.start.addingTimeInterval(6 * 3600))
        #expect(await f.maintenance.checkDueItems() == 0)
        #expect(plaid.count(HoldingsScript.path) == 1)

        // A day on (the check's ±1 h jitter included), the next check asks again.
        f.clock.set(ItemCheckTests.start.addingTimeInterval(25 * 3600 + 1))
        #expect(await f.maintenance.checkDueItems() == 1)
        #expect(plaid.count(HoldingsScript.path) == 2)
    }

    @Test("A HOLDINGS webhook makes holdings due: the Item check it starts asks the same day")
    func webhookMarkMakesHoldingsDue() async throws {
        let plaid = CrossLaneScript.provider()
        var config = TestServer.config()
        config.plaidHoldings = "auto"
        let (service, _) = try await BudgetServerApp.makeService(config: config, store: MemoryStore(), logger: Logger(label: "test"), plaidTransport: plaid)
        try await BudgetServerApp.prepare(service)
        try await CrossLaneScript.link(service)
        #expect(try await service.sync.sync(linkID: PlaidErrorKindTests.id, trigger: .personLink).ok)

        // The first check asks; a second one the same day (forced, as a webhook's is) doesn't, holdings aren't due yet.
        await service.plaidMaintenance.checkItem(PlaidErrorKindTests.id)
        #expect(plaid.count(HoldingsScript.path) == 1)
        await service.plaidMaintenance.checkItem(PlaidErrorKindTests.id)
        #expect(plaid.count("/item/get") == 2 && plaid.count(HoldingsScript.path) == 1)

        // HOLDINGS/DEFAULT_UPDATE: marked due, and the check the webhook starts asks at once, then clears the mark.
        let (receiver, app) = CrossLaneScript.webhookApp(service)
        try await CrossLaneScript.deliver("HOLDINGS", "DEFAULT_UPDATE", receiver: receiver, app: app)
        #expect(plaid.count("/item/get") == 3)
        #expect(plaid.count(HoldingsScript.path) == 2)
        let holdings = try #require(try await PlaidErrorKindTests.link(service).holdings)
        #expect(holdings.access == .ok && holdings.due == nil)
    }
}

extension ConnectionAlertTests {
    @Test("Sign-in pushes (Lane P) and stale pushes (Lane S) share one cap of 3 per check, most pressing first")
    func staleAndSignInShareOneBudget() async throws {
        typealias F = ConnectionAlertFixture
        let apns = FakeAPNs()
        let clock = TestClock(F.noon)
        // Two Items waiting for a sign-in, and two banks whose accounts went quiet five days ago (the ledger's clock is
        // the real one, so their last good pull is too).
        let quietSince = Date().addingTimeInterval(-5 * 86_400)
        let waiting = (1...2).map { F.link("plaid-wait-\($0)", institution: "Bank \($0)", kind: .needsSignIn, since: F.noon.addingTimeInterval(-600)) }
        let quiet = [F.link("plaid-harbor", institution: "Harbor"), F.link("plaid-summit", institution: "Summit")]
        var state = LedgerState.empty
        state.accounts = [("harbor", "Harbor", "Freedom"), ("summit", "Summit", "Gold Card")].map { id, institution, name in
            var account = Account(id: "plaid:\(id)", name: name, institution: institution, kind: .credit, balance: Money(-10), source: .plaid)
            account.lastSyncedAt = quietSince
            return account
        }
        let store = MemoryStore(ledger: state)
        let (service, _) = try await F.service(apns: apns, clock: clock, links: waiting + quiet, store: store)
        let stale = try await service.api.overview().accountHealth?.filter { $0.state == .stale }.map(\.id).sorted()
        #expect(stale == ["plaid:harbor", "plaid:summit"])
        try await F.register(service)

        // Four due: the two sign-ins go first, then one stale bank; the cap stops there.
        await service.alerts.sendDue()
        let first = F.sent(apns)
        #expect(first.count == 3)
        #expect(first.prefix(2).allSatisfy { $0.info["alert"] == "needsSignIn" })
        #expect(first.last?.info["alert"] == "accountStale")
        // The stale push names the account (the sender hands the collector the ledger's accounts), never a number.
        #expect(first.last.map { $0.title.hasPrefix("Harbor Freedom hasn't updated since") || $0.title.hasPrefix("Summit Gold Card hasn't updated since") } == true)

        // The next check sends the one left, and nothing after that.
        await service.alerts.sendDue()
        #expect(F.sent(apns).count == 4)
        #expect(F.sent(apns).last?.info["alert"] == "accountStale")
        await service.alerts.sendDue()
        #expect(F.sent(apns).count == 4)
    }
}

/// Every lane at once on one ledger: start-up migration (L), a Plaid sync and a webhook-queued sync (P), holdings (A).
@Suite("Integration: migration, sync, webhook and holdings together")
struct IntegrationTests {
    static let number = StatementIDMigrationTests.number

    @Test("A legacy-id ledger migrates at start, then syncs, takes a webhook and refreshes holdings: no account number anywhere, no deadlock")
    func migrationThenSyncThenWebhook() async throws {
        let done = Flag()
        let work = Task {
            defer { done.set() }
            try await Self.flow()
        }
        // A deadlock would hang the flow rather than fail it: give it 10 s and stop waiting.
        let deadline = ContinuousClock.now + .seconds(10)
        while !done.isSet, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(done.isSet, "the flow didn't finish within 10 s")
        if done.isSet { try await work.value } else { work.cancel() }
    }

    static func flow() async throws {
        let plaid = CrossLaneScript.provider(syncPages: [
            PlaidScript.page("c1", PlaidScript.row),
            PlaidScript.page("c2", #"{"transaction_id": "t2", "account_id": "chk", "amount": 4.25, "iso_currency_code": "USD", "date": "2026-09-21", "name": "CORNER MARKET", "pending": false}"#),
        ])
        let log = CapturedLog()
        var config = TestServer.config()
        config.plaidHoldings = "auto"
        let store = MemoryStore(ledger: StatementIDMigrationTests.legacy())
        try await store.upsertImport(StatementIDMigrationTests.importRecord())
        #expect(try StatementIDMigrationTests.json(try #require(try await store.loadLedger())).contains("9876543210"), "the ledger starts with legacy ids")
        let (service, _) = try await BudgetServerApp.makeService(config: config, store: store, logger: log.logger, plaidTransport: plaid)
        try await CrossLaneScript.link(service)

        // L: the migration runs in prepare.
        try await BudgetServerApp.prepare(service)
        #expect(try await store.loadLedger()?.upgrades.contains(Ledger.statementIDsUpgrade) == true)
        #expect(service.statementIDs?.gate.isOpen == true)

        // P: the person's sync of the link, then a webhook's.
        let synced = try await service.sync.sync(linkID: PlaidErrorKindTests.id, trigger: .personLink)
        #expect(synced.ok && synced.report?.rowsAdded == 1)
        let (receiver, app) = CrossLaneScript.webhookApp(service)
        try await CrossLaneScript.deliver("TRANSACTIONS", "SYNC_UPDATES_AVAILABLE", receiver: receiver, app: app)
        #expect(plaid.count("/transactions/sync") == 2)

        // A: holdings through the daily check (forced, as a webhook's).
        await service.plaidMaintenance.checkItem(PlaidErrorKindTests.id)
        #expect(plaid.count(HoldingsScript.path) == 1)
        #expect(try await service.api.holdings().accounts.contains { $0.id == "plaid:inv" })

        // Nothing anywhere holds the number: the ledger, the history, the links, the settings and the log.
        let ledger = try #require(try await store.loadLedger())
        #expect(ledger.transactions.contains { $0.id.contains("t2") }, "the webhook's row is in")
        #expect(!(try StatementIDMigrationTests.json(ledger)).contains("9876543210"))
        #expect(!(try StatementIDMigrationTests.json(await service.api.state)).contains("9876543210"))
        #expect(!(try StatementIDMigrationTests.json(try await store.imports())).contains("9876543210"))
        #expect(!(try StatementIDMigrationTests.json(try await store.links())).contains("9876543210"))
        for key in [LedgerMigrations.chatsScrubbed, ConnectionAlerts.sentKey] {
            if let data = try await store.setting(key) { #expect(!String(decoding: data, as: UTF8.self).contains("9876543210")) }
        }
        #expect(!log.lines.joined(separator: "\n").contains("9876543210"))
    }

    /// Set once, read from any task.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
