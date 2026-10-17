import BudgetKit
@testable import BudgetServerCore
import Foundation
import Logging
import Testing

/// The `enabled` flag of each holdings refresh the Item check asked for.
final class HoldingsCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Bool] = []
    var enabled: [Bool] { lock.withLock { stored } }

    var refresh: PlaidMaintenance.HoldingsRefresh {
        { enabled, _, previous, _, _, now in
            self.lock.withLock { self.stored.append(enabled) }
            return HoldingsCheck(access: enabled ? .ok : (previous?.access ?? .failed), checkedAt: now, accounts: enabled ? 1 : nil)
        }
    }
}

@Suite("Daily Item check (P0.5)")
struct ItemCheckTests {
    static let id = PlaidErrorKindTests.id
    static let start = Date(timeIntervalSince1970: 1_792_000_000)  // 2026-10-15
    static let publicURL = "https://budget.example"
    static let webhook = "https://budget.example/v1/plaid/webhook"

    /// An `/item/get` answer.
    static func item(error: String? = nil, errorType: String = "ITEM_ERROR", consent: Date? = nil, billed: [String] = ["transactions"],
                     webhook: String? = webhook, institution: String = "ins_3", updated: String? = "2026-10-14T09:00:00Z") -> (Int, String) {
        func list(_ values: [String]) -> String { "[" + values.map { "\"\($0)\"" }.joined(separator: ", ") + "]" }
        let errorJSON = error.map { #"{"error_type": "\#(errorType)", "error_code": "\#($0)", "error_message": "message for \#($0)", "request_id": "req-err"}"# } ?? "null"
        let consentJSON = consent.map { "\"\($0.formatted(.iso8601))\"" } ?? "null"
        let status = updated.map { #", "status": {"transactions": {"last_successful_update": "\#($0)"}}"# } ?? ""
        return (200, #"{"item": {"item_id": "item-1", "institution_id": "\#(institution)", "webhook": "\#(webhook ?? "")", "error": \#(errorJSON), "consent_expiration_time": \#(consentJSON), "billed_products": \#(list(billed)), "available_products": ["liabilities"]}\#(status), "request_id": "req-item"}"#)
    }

    static func provider(_ items: [(Int, String)]) -> ScriptedProvider {
        ScriptedProvider([
            "/item/get": items,
            "/item/webhook/update": [(200, #"{"item": {"item_id": "item-1"}, "request_id": "req-wh"}"#)],
            "/transactions/sync": [PlaidScript.page("c1")],
            "/accounts/get": [PlaidScript.balances],
        ])
    }

    struct Fixture {
        var service: BudgetService
        var maintenance: PlaidMaintenance
        var clock: TestClock
        var holdings: HoldingsCalls
        var log: CapturedLog

        func link() async throws -> StoredLink { try await PlaidErrorKindTests.link(service) }
        func change(_ edit: @escaping @Sendable (inout StoredLink) -> Void) async throws { try await service.sync.updateLink(ItemCheckTests.id, edit) }
    }

    static func fixture(_ plaid: ScriptedProvider, publicURL: String? = publicURL, environment: PlaidSource.Environment = .sandbox,
                        holdings mode: String = "auto", webhooks: Bool = true) async throws -> Fixture {
        var config = TestServer.config()
        config.publicURL = publicURL
        config.plaid?.environment = environment
        config.plaidHoldings = mode
        config.plaidWebhooks = webhooks
        let log = CapturedLog()
        let (service, _) = try await BudgetServerApp.makeService(config: config, store: MemoryStore(), logger: log.logger, plaidTransport: plaid)
        try await BudgetServerApp.prepare(service)
        let sealed = try #require(try service.sealer?.seal("access-sandbox-9"))
        try await service.store.upsertLink(StoredLink(id: id, provider: .plaid, institution: "Harbor", externalID: "item-1", sealedToken: sealed,
                                                      cursor: "c0", status: .connected, lastSync: nil, lastError: nil, createdAt: start))
        let clock = TestClock(start)
        let calls = HoldingsCalls()
        let maintenance = PlaidMaintenance(api: service.api, store: service.store, sync: service.sync, providers: service.providers,
                                           sealer: service.sealer, settings: service.settings, logger: log.logger, clock: { clock.now },
                                           holdings: calls.refresh)
        return Fixture(service: service, maintenance: maintenance, clock: clock, holdings: calls, log: log)
    }

    static func webhookBodies(_ plaid: ScriptedProvider) -> [String] {
        plaid.requests.filter { $0.path == "/item/webhook/update" }.map(\.body)
    }

    /// Waits up to two seconds for a queued sync to reach Plaid.
    static func waitForSyncs(_ plaid: ScriptedProvider, _ count: Int) async throws {
        for _ in 0..<200 where plaid.count("/transactions/sync") < count { try await Task.sleep(for: .milliseconds(10)) }
    }

    // MARK: What /item/get says

    @Test("A consent expiry 13 days out is stored, with the institution, billed products and Plaid's last update; the summary shows them")
    func storesConsent() async throws {
        let expires = Self.start.addingTimeInterval(13 * 86_400)
        let plaid = Self.provider([Self.item(consent: expires, billed: ["transactions", "investments"])])
        let f = try await Self.fixture(plaid)
        #expect(await f.maintenance.checkDueItems() == 1)
        let state = try #require(try await f.link().plaid)
        #expect(state.consentExpiresAt == expires)
        #expect(state.institutionID == "ins_3")
        #expect(state.billedProducts == ["transactions", "investments"] && state.availableProducts == ["liabilities"])
        #expect(state.lastItemCheckAt == Self.start)
        #expect(state.lastTransactionsUpdate == (try? Date("2026-10-14T09:00:00Z", strategy: .iso8601)))
        let summary = try await f.link().summary
        #expect(summary.consentExpiresAt == expires && summary.institutionID == "ins_3" && summary.lastItemCheckAt == Self.start)
        #expect(summary.webhook?.url == Self.webhook)
        // The phone reads the date off the institution rows.
        #expect(try await f.service.api.serverStatus().institutions.first { $0.id == Self.id }?.consentExpiresAt == expires)
        #expect(plaid.count("/transactions/sync") == 0)
    }

    @Test("An Item error that waits for the person sets the kind, once per episode", arguments: [
        ("ITEM_LOGIN_REQUIRED", LinkErrorKind.needsSignIn), ("USER_PERMISSION_REVOKED", .revoked),
    ])
    func errorSetsKind(code: String, kind: LinkErrorKind) async throws {
        let plaid = Self.provider([Self.item(error: code)])
        let f = try await Self.fixture(plaid)
        await f.maintenance.checkItem(Self.id)
        var link = try await f.link()
        #expect(link.status == .needsReauth && link.errorKind == kind && link.errorCode == code)
        #expect(link.failureCount == 1 && link.firstFailedAt == Self.start && link.hasLiveItem)
        // The next day says the same: still one failure in the run, so a webhook's three tries aren't used up by checks.
        f.clock.set(Self.start.addingTimeInterval(26 * 3600))
        #expect(await f.maintenance.checkDueItems() == 1)
        link = try await f.link()
        #expect(link.failureCount == 1 && link.firstFailedAt == Self.start)
        #expect(plaid.count("/item/get") == 2 && plaid.count("/transactions/sync") == 0)
    }

    @Test("An Item error the bank may clear by itself leaves the link as it was")
    func transientErrorLeavesLink() async throws {
        let plaid = Self.provider([Self.item(error: "INSTITUTION_DOWN", errorType: "INSTITUTION_ERROR")])
        let f = try await Self.fixture(plaid)
        await f.maintenance.checkItem(Self.id)
        let link = try await f.link()
        #expect(link.status == .connected && link.errorKind == nil && link.nextAttemptAt == nil)
        #expect(link.plaid?.lastItemCheckAt == Self.start)
    }

    @Test("A link waiting for a sign-in that /item/get calls healthy is healed, its episode ended, and exactly one sync queued")
    func nullErrorHeals() async throws {
        let plaid = Self.provider([Self.item()])
        let f = try await Self.fixture(plaid)
        let failedAt = Self.start.addingTimeInterval(-3 * 86_400)
        try await f.change { link in
            LinkHealthBook.recordFailure(&link, LinkFailure(kind: .needsSignIn, code: "ITEM_LOGIN_REQUIRED", message: "sign in"), now: failedAt)
        }
        #expect(try await f.link().status == .needsReauth)
        await f.maintenance.checkItem(Self.id)
        try await Self.waitForSyncs(plaid, 1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(plaid.count("/transactions/sync") == 1)
        let link = try await f.link()
        #expect(link.status == .connected && link.errorKind == nil && link.firstFailedAt == nil && link.failureCount == nil)
        #expect(link.plaid?.signInFailures == nil)
        // The queued sync went through and moved the cursor.
        #expect(link.cursor == "c1" && link.lastSync != nil)
    }

    @Test("A healthy link that /item/get calls healthy queues no sync")
    func healthyQueuesNothing() async throws {
        let plaid = Self.provider([Self.item()])
        let f = try await Self.fixture(plaid)
        await f.maintenance.checkItem(Self.id)
        try await Task.sleep(for: .milliseconds(200))
        #expect(plaid.count("/item/get") == 1 && plaid.count("/transactions/sync") == 0)
    }

    @Test("ITEM_NOT_FOUND from /item/get drops the token, keeps the link and makes no /item/remove call")
    func itemNotFound() async throws {
        let plaid = ScriptedProvider(["/item/get": [PlaidErrorKindTests.plaidError("ITEM_NOT_FOUND", type: "INVALID_INPUT")]])
        let f = try await Self.fixture(plaid)
        await f.maintenance.checkItem(Self.id)
        let link = try await f.link()
        #expect(link.sealedToken.isEmpty && !link.hasLiveItem)
        #expect(link.errorKind == .revoked && link.errorCode == "ITEM_NOT_FOUND" && link.errorRequestID == "req-42")
        #expect(plaid.count("/item/remove") == 0)
        // Never asked again: there's no Item to ask about.
        f.clock.set(Self.start.addingTimeInterval(3 * 86_400))
        #expect(await f.maintenance.checkDueItems() == 0)
        await f.maintenance.checkItem(Self.id)
        #expect(plaid.count("/item/get") == 1)
    }

    @Test("A failed /item/get changes nothing but the check time, and waits for the next day")
    func failedCheck() async throws {
        let plaid = ScriptedProvider(["/item/get": [PlaidErrorKindTests.plaidError("INTERNAL_SERVER_ERROR", type: "API_ERROR", status: 500)]])
        let f = try await Self.fixture(plaid)
        #expect(await f.maintenance.check(Self.id, force: false) == .failed)
        let link = try await f.link()
        #expect(link.status == .connected && link.errorKind == nil && link.plaid?.lastItemCheckAt == Self.start)
        f.clock.set(Self.start.addingTimeInterval(3600))
        #expect(await f.maintenance.checkDueItems() == 0)
        #expect(f.log.lines.contains { $0.contains("INTERNAL_SERVER_ERROR") && $0.contains("req-42") })
    }

    // MARK: Once a day

    @Test("Two checks within a day make one call; a day later makes another")
    func oncePerDay() async throws {
        let plaid = Self.provider([Self.item()])
        let f = try await Self.fixture(plaid)
        #expect(await f.maintenance.checkDueItems() == 1)
        f.clock.set(Self.start.addingTimeInterval(22 * 3600 + 50 * 60))
        #expect(await f.maintenance.checkDueItems() == 0)
        #expect(plaid.count("/item/get") == 1)
        f.clock.set(Self.start.addingTimeInterval(25 * 3600 + 60))
        #expect(await f.maintenance.checkDueItems() == 1)
        #expect(plaid.count("/item/get") == 2)
    }

    @Test("The day varies by at most an hour either way, the same for one check")
    func jitter() {
        let values = (0..<500).map { PlaidMaintenance.jitter("plaid-\($0)", Self.start) }
        #expect(values.allSatisfy { abs($0) <= 3600 })
        #expect(values.min()! < -1800 && values.max()! > 1800)
        #expect(PlaidMaintenance.jitter("plaid-1", Self.start) == PlaidMaintenance.jitter("plaid-1", Self.start))
    }

    @Test("A webhook's check runs even when the daily one just ran")
    func webhookCheckForces() async throws {
        let plaid = Self.provider([Self.item()])
        let f = try await Self.fixture(plaid)
        #expect(await f.maintenance.checkDueItems() == 1)
        await f.maintenance.checkItem(Self.id)
        #expect(plaid.count("/item/get") == 2)
    }

    @Test("Only live Plaid Items are checked")
    func onlyLiveItems() async throws {
        let plaid = Self.provider([Self.item()])
        let f = try await Self.fixture(plaid)
        try await f.service.store.upsertLink(StoredLink(id: "simplefin-1", provider: .simplefin, institution: "Bridge", externalID: nil,
                                                        sealedToken: "x", cursor: nil, status: .connected, lastSync: nil, lastError: nil, createdAt: Self.start))
        try await f.change { $0.sealedToken = "" }
        #expect(await f.maintenance.checkDueItems() == 0)
        #expect(plaid.requests.isEmpty)
    }

    // MARK: Webhook URL

    @Test("An Item whose webhook goes elsewhere gets exactly one /item/webhook/update to this server")
    func webhookReconcile() async throws {
        let plaid = Self.provider([Self.item(webhook: "https://old.example/v1/plaid/webhook"), Self.item()])
        let f = try await Self.fixture(plaid)
        await f.maintenance.checkItem(Self.id)
        let bodies = Self.webhookBodies(plaid)
        #expect(bodies.count == 1)
        let body = try #require(bodies.first.flatMap { try? JSONValue.parse(Data($0.utf8)) })
        guard case let .object(o) = body else { Issue.record("not an object"); return }
        #expect(o["webhook"] == .string(Self.webhook) && o["access_token"] == .string("access-sandbox-9"))
        #expect(try await f.link().plaid?.webhookURL == Self.webhook)
        // Plaid now has it: the next check sends nothing.
        await f.maintenance.checkItem(Self.id)
        #expect(Self.webhookBodies(plaid).count == 1)
        #expect(f.log.lines.allSatisfy { !$0.contains("access-sandbox-9") })
    }

    @Test("An Item linked without a webhook gets one")
    func webhookMissing() async throws {
        let plaid = Self.provider([Self.item(webhook: nil)])
        let f = try await Self.fixture(plaid)
        await f.maintenance.checkItem(Self.id)
        #expect(Self.webhookBodies(plaid).count == 1)
    }

    @Test("A public URL with a trailing slash matches the Item's webhook: no update")
    func webhookTrailingSlash() async throws {
        let plaid = Self.provider([Self.item(webhook: Self.webhook)])
        let f = try await Self.fixture(plaid, publicURL: Self.publicURL + "/")
        await f.maintenance.checkItem(Self.id)
        #expect(Self.webhookBodies(plaid).isEmpty)
        #expect(try await f.link().plaid?.webhookURL == Self.webhook)
    }

    @Test("No webhook update without an https public URL in production, or with webhooks off")
    func webhookNeedsHTTPS() async throws {
        for (url, environment, webhooks) in [("http://budget.example", PlaidSource.Environment.production, true),
                                             (nil, .sandbox, true), (Self.publicURL, .sandbox, false)] as [(String?, PlaidSource.Environment, Bool)] {
            let plaid = Self.provider([Self.item(webhook: "https://old.example/v1/plaid/webhook")])
            let f = try await Self.fixture(plaid, publicURL: url, environment: environment, webhooks: webhooks)
            await f.maintenance.checkItem(Self.id)
            #expect(Self.webhookBodies(plaid).isEmpty)
            #expect(plaid.count("/item/get") == 1)
        }
    }

    @Test("A plain http public URL is allowed for a sandbox test server")
    func webhookHTTPInSandbox() async throws {
        let plaid = Self.provider([Self.item(webhook: nil)])
        let f = try await Self.fixture(plaid, publicURL: "http://127.0.0.1:18080")
        await f.maintenance.checkItem(Self.id)
        #expect(Self.webhookBodies(plaid).count == 1)
        #expect(Self.webhookBodies(plaid).first?.contains("http://127.0.0.1:18080/v1/plaid/webhook") == true)
    }

    @Test("A failed webhook update is logged by code and tried again the next check")
    func webhookUpdateFails() async throws {
        let plaid = ScriptedProvider(["/item/get": [Self.item(webhook: nil)],
                                      "/item/webhook/update": [PlaidErrorKindTests.plaidError("INVALID_FIELD", type: "INVALID_REQUEST")]])
        let f = try await Self.fixture(plaid)
        await f.maintenance.checkItem(Self.id)
        #expect(try await f.link().plaid?.webhookURL == nil)
        #expect(f.log.lines.contains { $0.contains("INVALID_FIELD") && $0.contains("req-42") })
        await f.maintenance.checkItem(Self.id)
        #expect(Self.webhookBodies(plaid).count == 2)
    }

    // MARK: Holdings

    @Test("Holdings auto: an Item billed for Investments is enabled, one that isn't is not")
    func holdingsAuto() async throws {
        let billed = try await Self.fixture(Self.provider([Self.item(billed: ["transactions", "investments"])]))
        await billed.maintenance.checkItem(Self.id)
        #expect(billed.holdings.enabled == [true])
        #expect(try await billed.link().holdings?.access == .ok)

        let unbilled = try await Self.fixture(Self.provider([Self.item(billed: ["transactions"])]))
        await unbilled.maintenance.checkItem(Self.id)
        #expect(!unbilled.holdings.enabled.contains(true))
    }

    @Test("Holdings on and off override what Plaid bills", arguments: [("on", ["transactions"], true), ("off", ["transactions", "investments"], false)])
    func holdingsMode(mode: String, billed: [String], enabled: Bool) async throws {
        let f = try await Self.fixture(Self.provider([Self.item(billed: billed)]), holdings: mode)
        await f.maintenance.checkItem(Self.id)
        #expect(f.holdings.enabled == [enabled])
    }

    @Test("Holdings are asked once a day, sooner when a webhook marked them due, and never for an Item waiting for a sign-in")
    func holdingsWhenDue() async throws {
        let plaid = Self.provider([Self.item(billed: ["investments"])])
        let f = try await Self.fixture(plaid)
        await f.maintenance.checkItem(Self.id)
        await f.maintenance.checkItem(Self.id)
        #expect(f.holdings.enabled.count == 1)
        try await f.change { $0.holdings?.due = true }
        await f.maintenance.checkItem(Self.id)
        #expect(f.holdings.enabled.count == 2)

        let locked = try await Self.fixture(Self.provider([Self.item(error: "ITEM_LOGIN_REQUIRED", billed: ["investments"])]))
        await locked.maintenance.checkItem(Self.id)
        #expect(locked.holdings.enabled.isEmpty)
    }

    // MARK: PENDING_DISCONNECT

    @Test("A PENDING_DISCONNECT warning ends once consent is renewed or a month has passed, and stays while Plaid reports an error")
    func pendingDisconnect() async throws {
        let warned = Self.start.addingTimeInterval(-2 * 86_400)
        func after(_ answer: (Int, String), at now: Date) async throws -> Date? {
            let f = try await Self.fixture(Self.provider([answer]))
            try await f.change { link in
                var state = link.plaid ?? PlaidLinkState()
                state.pendingDisconnectAt = warned
                link.plaid = state
            }
            f.clock.set(now)
            await f.maintenance.checkItem(Self.id)
            return try await f.link().plaid?.pendingDisconnectAt
        }
        #expect(try await after(Self.item(consent: Self.start.addingTimeInterval(365 * 86_400)), at: Self.start) == nil)
        #expect(try await after(Self.item(consent: warned.addingTimeInterval(7 * 86_400)), at: Self.start) == warned)
        #expect(try await after(Self.item(error: "ITEM_LOGIN_REQUIRED"), at: Self.start.addingTimeInterval(60 * 86_400)) == warned)
        #expect(try await after(Self.item(), at: Self.start.addingTimeInterval(31 * 86_400)) == nil)
    }
}
