import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import Testing

/// A clock the server-side health tests move forward.
final class MovingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date { lock.withLock { _now } }
    func advance(days: Double) { lock.withLock { _now = _now.addingTimeInterval(days * 86_400) } }
}

@Suite("Stale-account pushes")
struct StaleAlertTests {
    static let start = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 14:13 UTC
    static let zone = TimeZone(identifier: "America/Los_Angeles")!

    static func account(_ id: String, _ name: String, institution: String = "Harbor") -> Account {
        Account(id: id, name: name, institution: institution, kind: .credit, balance: Money(-412.50), source: .plaid, mask: "0909")
    }

    static func stale(_ id: String, lastGoodSync: Date) -> AccountHealth {
        AccountHealth(id: id, state: .stale, lastGoodSync: lastGoodSync, staleSince: lastGoodSync.addingTimeInterval(2 * 86_400))
    }

    /// What the sender does with the alerts: skips an alert whose own key went out, and marks every key it carries.
    static func deliver(_ alerts: [ConnectionAlert], sent: inout Set<String>) -> [ConnectionAlert] {
        let due = alerts.filter { !sent.contains($0.episodeKeys[0]) }
        for alert in due { sent.formUnion(alert.episodeKeys) }
        return due
    }

    /// The ledger the server runs, on a clock the test moves, with one Harbor card last pulled cleanly at `lastSyncedAt`
    /// (ingest's stamp is tested in BudgetKit).
    static func api(clock: MovingClock, lastSyncedAt: Date) async -> LedgerBudgetAPI {
        var state = LedgerState.empty
        var card = account("plaid:freedom", "Freedom")
        card.lastSyncedAt = lastSyncedAt
        state.accounts = [card]
        let api = LedgerBudgetAPI(state: state, calendar: Calendar(identifier: .gregorian), clock: { clock.now }, chatModel: nil, decisions: DecisionRouting(),
                                  persistence: nil, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
        await api.setInstitutions([InstitutionLink(id: "plaid-1", institution: "Harbor", primary: .plaid, fallback: nil, accountKinds: [],
                                                   status: .connected, note: "", lastSync: lastSyncedAt)])
        return api
    }

    @Test("One push per stale episode: not again on the next check, again after a good sync and a new stale spell")
    func oneStalePushPerEpisode() async throws {
        // A clean pull, then silence.
        let clock = MovingClock(Self.start)
        var api = await Self.api(clock: clock, lastSyncedAt: Self.start)
        func check() async throws -> [ConnectionAlert] {
            let overview = try await api.overview()
            return ConnectionAlerts.healthAlerts(overview.accountHealth ?? [], links: [], now: clock.now, accounts: overview.accounts, timeZone: Self.zone)
        }
        var sent: Set<String> = []
        clock.advance(days: 1)
        #expect(try await check().isEmpty, "a day without a pull is still current")
        clock.advance(days: 1.5)
        let first = Self.deliver(try await check(), sent: &sent)
        let alert = try #require(first.first)
        #expect(first.count == 1 && alert.kind == .accountStale && alert.accountID == "plaid:freedom")
        #expect(alert.episodeKeys == ["stale|plaid:freedom|\(Int(Self.start.timeIntervalSince1970))"])
        #expect(alert.title == "Harbor Freedom hasn't updated since Sep 21" && alert.body == "Open Accounts to check its connection.")
        #expect(!(alert.title + alert.body).contains("0909") && !(alert.title + alert.body).contains("$"), "no mask, no amount")
        // The next check, and the one after a restart (same keys), send nothing.
        #expect(Self.deliver(try await check(), sent: &sent).isEmpty)
        clock.advance(days: 1)
        #expect(Self.deliver(try await check(), sent: &sent).isEmpty)
        // A good sync ends the episode; the next stale spell is a new one.
        let resumed = clock.now
        api = await Self.api(clock: clock, lastSyncedAt: resumed)
        #expect(try await check().isEmpty)
        clock.advance(days: 3)
        let again = Self.deliver(try await check(), sent: &sent)
        #expect(again.count == 1 && again[0].episodeKeys == ["stale|plaid:freedom|\(Int(resumed.timeIntervalSince1970))"])
    }

    @Test("No stale push for an account waiting for a sign-in: the link's sign-in push covers it")
    func noStalePushWhileWaitingForSignIn() {
        let health = [AccountHealth(id: "plaid:freedom", state: .waitingForSignIn, lastGoodSync: Self.start),
                      AccountHealth(id: "plaid:sapphire", state: .current, lastGoodSync: Self.start),
                      AccountHealth(id: "stmt", state: .statementsOverdue, lastGoodSync: Self.start),
                      AccountHealth(id: "gone", state: .notSynced, lastGoodSync: Self.start)]
        let alerts = ConnectionAlerts.healthAlerts(health, links: [], now: Self.start.addingTimeInterval(10 * 86_400),
                                                   accounts: [Self.account("plaid:freedom", "Freedom")], timeZone: Self.zone)
        #expect(alerts.isEmpty)
    }

    @Test("A bank that stops answering is one push for its accounts, keyed by the one longest unheard from")
    func oneBankOnePush() throws {
        let early = Self.start, late = Self.start.addingTimeInterval(3600)
        let accounts = [Self.account("a", "Freedom"), Self.account("b", "Sapphire"), Self.account("c", "Gold Card", institution: "Summit")]
        let health = [Self.stale("b", lastGoodSync: late), Self.stale("a", lastGoodSync: early), Self.stale("c", lastGoodSync: late)]
        var sent: Set<String> = []
        let alerts = Self.deliver(ConnectionAlerts.healthAlerts(health, links: [], now: late, accounts: accounts, timeZone: Self.zone), sent: &sent)
        #expect(alerts.count == 2)
        let harbor = try #require(alerts.first)
        #expect(harbor.episodeKeys == [ConnectionAlerts.staleKey(accountID: "a", lastGoodSync: early), ConnectionAlerts.staleKey(accountID: "b", lastGoodSync: late)])
        #expect(harbor.title == "Harbor hasn't updated since Sep 21" && harbor.body.hasPrefix("2 of its accounts are behind."))
        #expect(alerts[1].title == "Summit Gold Card hasn't updated since Sep 21")
        // The first account recovers; the other still stale doesn't push again, its key went out with the first.
        let later = ConnectionAlerts.healthAlerts([Self.stale("b", lastGoodSync: late)], links: [], now: late, accounts: accounts, timeZone: Self.zone)
        #expect(Self.deliver(later, sent: &sent).isEmpty)
    }

    @Test("Without the accounts to name them, the push still goes, unnamed")
    func unnamedFallback() {
        let alerts = ConnectionAlerts.healthAlerts([Self.stale("x", lastGoodSync: Self.start)], links: [], now: Self.start, timeZone: Self.zone)
        #expect(alerts.count == 1 && alerts[0].title.hasPrefix("An account hasn't updated since"))
    }

    @Test("GET /v1/overview carries each account's health")
    func overviewCarriesHealth() async throws {
        let (app, _) = try await TestServer.app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/overview", method: .get, headers: TestServer.auth) { response in
                let overview = try RemoteBudgetAPI.decoder.decode(Overview.self, from: Data(response.body.readableBytesView))
                let health = try #require(overview.accountHealth)
                #expect(Set(health.map(\.id)) == Set(overview.accounts.map(\.id)))
                // The demo's Keystone card comes from a recent statement; nothing is linked, so the rest aren't synced.
                #expect(health.first { $0.id == "keystone" }?.state == .current)
                #expect(health.filter { $0.id != "keystone" }.allSatisfy { $0.state == .notSynced })
            }
        }
    }
}
