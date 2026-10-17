import Foundation
import Testing
@testable import BudgetKit

/// A clock a sync-health test moves forward.
final class SyncHealthClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date { lock.withLock { _now } }
    func advance(days: Double) { lock.withLock { _now = _now.addingTimeInterval(days * 86_400) } }
}

enum HealthFixture {
    static let now = Fixture.now
    static func day(_ back: Double) -> Date { now.addingTimeInterval(-back * 86_400) }

    static func account(_ id: String, _ name: String = "Freedom", institution: String = "Harbor", kind: AccountKind = .credit,
                        source: SourceKind = .plaid, syncedDaysAgo: Double? = nil, balanceDaysAgo: Double? = nil) -> Account {
        Account(id: id, name: name, institution: institution, kind: kind, balance: Money(-100), source: source,
                balanceAsOf: balanceDaysAgo.map(day), lastSyncedAt: syncedDaysAgo.map(day))
    }

    static func link(_ id: String = "plaid-1", institution: String = "Harbor", provider: SourceKind = .plaid, status: ConnectionStatus = .connected,
                     accountIDs: [String]? = nil, syncLinkID: String? = nil, syncedDaysAgo: Double? = 0.1) -> InstitutionLink {
        InstitutionLink(id: id, institution: institution, primary: provider, fallback: nil, accountKinds: [], status: status, note: "",
                        lastSync: syncedDaysAgo.map(day), accountIDs: accountIDs, syncLinkID: syncLinkID)
    }

    static func health(_ accounts: [Account], rows: [LedgerTransaction] = [], links: [InstitutionLink]) -> [String: AccountHealth] {
        let list = MonthFixture.ledger(accounts: accounts, rows: rows).accountHealth(institutions: links) ?? []
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    static func source(_ id: String, name: String = "Freedom", balanceDate: Date) -> SourceAccount {
        SourceAccount(externalID: id, institution: "Harbor", institutionDomain: nil, name: name, kind: .credit, balance: Money(-50),
                      availableBalance: nil, balanceDate: balanceDate, transactions: [
                          SourceTransaction(externalID: "\(id)-t1", posted: day(1), amount: Money(-5), description: "COFFEE"),
                      ], holdings: [])
    }

    static func api(clock: SyncHealthClock) -> LedgerBudgetAPI {
        LedgerBudgetAPI(state: .empty, calendar: Fixture.calendar, clock: { clock.now }, chatModel: nil, decisions: DecisionRouting(),
                        persistence: nil, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
    }
}

@Suite("Sync health: how fresh each account is")
struct SyncHealthTests {
    @Test("A clean pull stamps the account as synced and keeps the bank's own balance date")
    func ingestStampsLastSyncedAndBalanceAsOf() async throws {
        let clock = SyncHealthClock(HealthFixture.now)
        let api = HealthFixture.api(clock: clock)
        let bankDate = HealthFixture.day(1)
        _ = try await api.ingest(SourceSnapshot(source: .plaid, accounts: [HealthFixture.source("a", balanceDate: bankDate)], warnings: []), batchID: "s1")
        var account = try #require(await api.accountList().first)
        #expect(account.lastSyncedAt == HealthFixture.now && account.balanceAsOf == bankDate)
        // The next pull, a day on, moves both.
        clock.advance(days: 1)
        _ = try await api.ingest(SourceSnapshot(source: .plaid, accounts: [HealthFixture.source("a", balanceDate: HealthFixture.now)], warnings: []), batchID: "s2")
        account = try #require(await api.accountList().first)
        #expect(account.lastSyncedAt == clock.now && account.balanceAsOf == HealthFixture.now)
    }

    @Test("An imported statement isn't a sync: it never stamps lastSyncedAt")
    func fileImportDoesNotStampLastSynced() async throws {
        let api = HealthFixture.api(clock: SyncHealthClock(HealthFixture.now))
        // A "csv-" account: since L2 (P0.6) a statement names its account, never makes one from its own number.
        _ = try await api.ingest(SourceSnapshot(source: .fileImport, accounts: [HealthFixture.source("csv-stmt", balanceDate: HealthFixture.day(3))], warnings: []), batchID: "f1")
        let account = try #require(await api.accountList().first)
        #expect(account.lastSyncedAt == nil)
        // Nor does it give the account a balance date: the import's stamp is the day it ran, not the statement's.
        #expect(try await api.overview().accountHealth?.first { $0.id == account.id }?.balanceAsOf == nil)
    }

    @Test("An account the provider had a problem with isn't stamped; the rest of the pull is")
    func accountWithProblemNotStamped() async throws {
        let api = HealthFixture.api(clock: SyncHealthClock(HealthFixture.now))
        var snapshot = SourceSnapshot(source: .simplefin, accounts: [HealthFixture.source("ok", balanceDate: HealthFixture.now),
                                                                     HealthFixture.source("broken", name: "Card", balanceDate: HealthFixture.day(4))], warnings: [])
        snapshot.accountProblems = ["broken": .needsSignIn(code: "con.auth")]
        _ = try await api.ingest(snapshot, batchID: "s1")
        let accounts = await api.accountList()
        #expect(accounts.first { $0.id == "simplefin:ok" }?.lastSyncedAt == HealthFixture.now)
        #expect(accounts.first { $0.id == "simplefin:broken" }?.lastSyncedAt == nil)
    }

    @Test("A synced account is current for two days without a clean pull, then stale from the moment the two days ran out")
    func staleAfterTwoDays() throws {
        let link = HealthFixture.link()
        let health = HealthFixture.health([HealthFixture.account("fresh", syncedDaysAgo: 1.9, balanceDaysAgo: 2),
                                           HealthFixture.account("old", "Sapphire", syncedDaysAgo: 3)], links: [link])
        #expect(health["fresh"]?.state == .current && health["fresh"]?.staleSince == nil && health["fresh"]?.balanceAsOf == HealthFixture.day(2))
        let old = try #require(health["old"])
        #expect(old.state == .stale && old.lastGoodSync == HealthFixture.day(3) && old.staleSince == HealthFixture.day(1))
    }

    @Test("A stale account is its own attention item (reason syncStale), not also called quiet; quiet ones say .quiet")
    func staleAttention() throws {
        let accounts = [HealthFixture.account("old", "Sapphire", syncedDaysAgo: 3),
                        HealthFixture.account("quiet", "Checking", kind: .checking, syncedDaysAgo: 0.1)]
        // Both have had nothing new in 30 days: one because we haven't heard from the bank, the other because it's quiet.
        let rows = (0..<6).flatMap { i in [MonthFixture.row("o\(i)", "old", daysAgo: 30 + Double(i) * 2, -10),
                                           MonthFixture.row("q\(i)", "quiet", daysAgo: 30 + Double(i) * 2, -10)] }
        let ledger = MonthFixture.ledger(accounts: accounts, rows: rows)
        let attention = ledger.dataHealth(institutions: [HealthFixture.link()])
        #expect(attention.map(\.id) == ["sync-stale-old", "stale-quiet"])
        let stale = attention[0]
        #expect(stale.kind == .stale && stale.reason == .syncStale && stale.accountID == "old" && stale.linkID == "plaid-1")
        #expect(stale.title.hasPrefix("Harbor Sapphire hasn't updated since "))
        #expect(attention[1].reason == .quiet && attention[1].kind == .stale)
        // The overview carries the same health, and the checkup watches the stale account.
        #expect(ledger.overview(institutions: [HealthFixture.link()]).accountHealth?.first { $0.id == "old" }?.state == .stale)
        #expect(ledger.checkup(institutions: [HealthFixture.link()]).sections.first { $0.id == "data" }?.findings.first { $0.id == "sync-stale-old" }?.status == .watch)
    }

    @Test("A statement account is overdue once its newest row is more than 40 days old")
    func statementsOverdueAfterForty() throws {
        func state(newestDaysAgo: Double) -> AccountHealth? {
            let rows = (0..<5).map { MonthFixture.row("b\($0)", "stmt", daysAgo: newestDaysAgo + Double($0) * 30, -30, source: .fileImport) }
            return HealthFixture.health([HealthFixture.account("stmt", institution: "Keystone", source: .fileImport)], rows: rows, links: [])["stmt"]
        }
        #expect(state(newestDaysAgo: 39)?.state == .current)
        let overdue = try #require(state(newestDaysAgo: 41))
        #expect(overdue.state == .statementsOverdue && overdue.staleSince != nil)
        #expect(overdue.lastGoodSync == Fixture.calendar.startOfDay(for: HealthFixture.day(41)))
        #expect(Ledger.statementStaleAfterDays == 40)
        // A statement account has no balance date, whatever the import stamped on it.
        let stamped = HealthFixture.account("stmt", institution: "Keystone", source: .fileImport, balanceDaysAgo: 0)
        let rows = [MonthFixture.row("b", "stmt", daysAgo: 41, -30, source: .fileImport)]
        #expect(HealthFixture.health([stamped], rows: rows, links: [])["stmt"]?.balanceAsOf == nil)
        // No rows at all yet: nothing to be overdue against.
        #expect(HealthFixture.health([HealthFixture.account("empty", source: .fileImport)], links: [])["empty"]?.state == .notSynced)
    }

    @Test("Under a row waiting for a sign-in, an account is waitingForSignIn, never stale, and gets no stale item")
    func signInBeatsStale() throws {
        let accounts = [HealthFixture.account("card", syncedDaysAgo: 5)]
        let reauth = HealthFixture.link(status: .needsReauth)
        #expect(HealthFixture.health(accounts, links: [reauth])["card"]?.state == .waitingForSignIn)
        let attention = MonthFixture.ledger(accounts: accounts, rows: [MonthFixture.row("r", "card", daysAgo: 6, -5)]).dataHealth(institutions: [reauth])
        #expect(!attention.contains { $0.reason == .syncStale })
        // A row that names its accounts (one SimpleFIN bank) pauses only those; the other bank's account is just stale.
        let banks = [HealthFixture.account("a", institution: "Harbor", source: .simplefin, syncedDaysAgo: 5),
                     HealthFixture.account("b", institution: "Keystone", source: .simplefin, syncedDaysAgo: 5)]
        let rows = [HealthFixture.link("sf~1", institution: "Harbor", provider: .simplefin, status: .needsReauth, accountIDs: ["a"], syncLinkID: "sf"),
                    HealthFixture.link("sf~2", institution: "Keystone", provider: .simplefin, accountIDs: ["b"], syncLinkID: "sf")]
        let health = HealthFixture.health(banks, links: rows)
        #expect(health["a"]?.state == .waitingForSignIn && health["b"]?.state == .stale)
        // "Try again" on a bank's stale item syncs the whole link.
        let items = MonthFixture.ledger(accounts: banks, rows: [MonthFixture.row("r", "b", daysAgo: 6, -5, source: .simplefin)]).dataHealth(institutions: rows)
        #expect(items.first { $0.id == "sync-stale-b" }?.linkID == "sf")
    }

    @Test("Not synced: no link brings the account any more, or its link hasn't synced cleanly yet")
    func notSynced() {
        let health = HealthFixture.health([HealthFixture.account("unlinked", institution: "Gone", syncedDaysAgo: 30),
                                           HealthFixture.account("unstamped")], links: [HealthFixture.link(syncedDaysAgo: nil)])
        #expect(health["unlinked"]?.state == .notSynced && health["unlinked"]?.lastGoodSync == HealthFixture.day(30))
        #expect(health["unstamped"]?.state == .notSynced && health["unstamped"]?.lastGoodSync == nil)
        // Neither is pushed nor listed as stale.
        let attention = MonthFixture.ledger(accounts: [HealthFixture.account("unlinked", institution: "Gone", syncedDaysAgo: 30)],
                                            rows: [MonthFixture.row("r", "unlinked", daysAgo: 31, -5)])
            .dataHealth(institutions: [HealthFixture.link()])
        #expect(!attention.contains { $0.reason == .syncStale })
    }

    @Test("An account never stamped counts from its link's last clean sync: current after a recent one, stale after three days")
    func unstampedCountsFromItsLink() throws {
        let fresh = HealthFixture.health([HealthFixture.account("card")], links: [HealthFixture.link()])["card"]
        #expect(fresh?.state == .current && fresh?.lastGoodSync == HealthFixture.day(0.1))
        // Its link has failed for three days since 0.6.0 came up, so the account was never stamped: it's still behind.
        let accounts = [HealthFixture.account("card", kind: .investment)]
        let failing = HealthFixture.link(syncedDaysAgo: 3)
        let old = try #require(HealthFixture.health(accounts, links: [failing])["card"])
        #expect(old.state == .stale && old.lastGoodSync == HealthFixture.day(3) && old.staleSince == HealthFixture.day(1))
        let attention = MonthFixture.ledger(accounts: accounts, rows: [MonthFixture.row("r", "card", daysAgo: 4, -5)]).dataHealth(institutions: [failing])
        #expect(attention.contains { $0.id == "sync-stale-card" && $0.reason == .syncStale })
    }

    @Test("A SimpleFIN account whose bank date stopped moving goes stale though its pulls succeed; Plaid's doesn't count")
    func simplefinBalanceDateStops() throws {
        let link = HealthFixture.link("sf", provider: .simplefin)
        let stuck = HealthFixture.account("sf-card", source: .simplefin, syncedDaysAgo: 0.1, balanceDaysAgo: 3)
        let health = try #require(HealthFixture.health([stuck], links: [link])["sf-card"])
        #expect(health.state == .stale && health.lastGoodSync == HealthFixture.day(3) && health.balanceAsOf == HealthFixture.day(3))
        // Moving again (a day old) is current.
        let moving = HealthFixture.account("sf-card", source: .simplefin, syncedDaysAgo: 0.1, balanceDaysAgo: 1)
        #expect(HealthFixture.health([moving], links: [link])["sf-card"]?.state == .current)
        let plaid = HealthFixture.account("p-card", syncedDaysAgo: 0.1, balanceDaysAgo: 3)
        #expect(HealthFixture.health([plaid], links: [HealthFixture.link()])["p-card"]?.state == .current)
    }

    @Test("Investment accounts count: their balance feeds net worth")
    func investmentsCount() {
        let health = HealthFixture.health([HealthFixture.account("brokerage", "Brokerage", kind: .investment, syncedDaysAgo: 4)], links: [HealthFixture.link()])
        #expect(health["brokerage"]?.state == .stale)
    }

    @Test("A ledger stored before 0.6.0 decodes without the new account fields, and its accounts go by their link")
    func oldLedgerDecodesWithoutNewFields() throws {
        let json = #"{"id":"plaid:x","name":"Freedom","institution":"Harbor","kind":"credit","balance":{"minor":-100,"currency":"USD"},"source":"plaid"}"#
        let account = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
        #expect(account.lastSyncedAt == nil && account.balanceAsOf == nil)
        // Until its first stamp it goes by its link's last clean sync; with no link, it isn't synced.
        #expect(HealthFixture.health([account], links: [HealthFixture.link()])[account.id]?.state == .current)
        #expect(HealthFixture.health([account], links: [])[account.id]?.state == .notSynced)
    }
}
