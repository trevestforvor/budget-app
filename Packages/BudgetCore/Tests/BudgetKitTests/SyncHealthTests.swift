import Foundation
import Testing
@testable import BudgetKit

/// A clock a test moves forward.
final class TestClock: @unchecked Sendable {
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
                     accountIDs: [String]? = nil, syncLinkID: String? = nil) -> InstitutionLink {
        InstitutionLink(id: id, institution: institution, primary: provider, fallback: nil, accountKinds: [], status: status, note: "",
                        lastSync: day(0.1), accountIDs: accountIDs, syncLinkID: syncLinkID)
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

    static func api(clock: TestClock) -> LedgerBudgetAPI {
        LedgerBudgetAPI(state: .empty, calendar: Fixture.calendar, clock: { clock.now }, chatModel: nil, decisions: DecisionRouting(),
                        persistence: nil, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
    }
}

@Suite("Sync health: how fresh each account is")
struct SyncHealthTests {
    @Test("A clean pull stamps the account as synced and keeps the bank's own balance date")
    func ingestStampsLastSyncedAndBalanceAsOf() async throws {
        let clock = TestClock(HealthFixture.now)
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
        let api = HealthFixture.api(clock: TestClock(HealthFixture.now))
        _ = try await api.ingest(SourceSnapshot(source: .fileImport, accounts: [HealthFixture.source("stmt", balanceDate: HealthFixture.day(3))], warnings: []), batchID: "f1")
        let account = try #require(await api.accountList().first)
        #expect(account.lastSyncedAt == nil && account.balanceAsOf == HealthFixture.day(3))
    }

    @Test("An account the provider had a problem with isn't stamped; the rest of the pull is")
    func accountWithProblemNotStamped() async throws {
        let api = HealthFixture.api(clock: TestClock(HealthFixture.now))
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

    @Test("Not synced: no link brings the account any more, or no clean pull since stamping began (0.6.0)")
    func notSynced() {
        let health = HealthFixture.health([HealthFixture.account("unlinked", institution: "Gone", syncedDaysAgo: 30),
                                           HealthFixture.account("unstamped")], links: [HealthFixture.link()])
        #expect(health["unlinked"]?.state == .notSynced && health["unlinked"]?.lastGoodSync == HealthFixture.day(30))
        #expect(health["unstamped"]?.state == .notSynced)
        // Neither is pushed nor listed as stale.
        let attention = MonthFixture.ledger(accounts: [HealthFixture.account("unlinked", institution: "Gone", syncedDaysAgo: 30)],
                                            rows: [MonthFixture.row("r", "unlinked", daysAgo: 31, -5)])
            .dataHealth(institutions: [HealthFixture.link()])
        #expect(!attention.contains { $0.reason == .syncStale })
    }

    @Test("Investment accounts count: their balance feeds net worth")
    func investmentsCount() {
        let health = HealthFixture.health([HealthFixture.account("brokerage", "Brokerage", kind: .investment, syncedDaysAgo: 4)], links: [HealthFixture.link()])
        #expect(health["brokerage"]?.state == .stale)
    }

    @Test("A ledger stored before 0.6.0 decodes without the new account fields, and its accounts read as not synced")
    func oldLedgerDecodesWithoutNewFields() throws {
        let json = #"{"id":"plaid:x","name":"Freedom","institution":"Harbor","kind":"credit","balance":{"minor":-100,"currency":"USD"},"source":"plaid"}"#
        let account = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
        #expect(account.lastSyncedAt == nil && account.balanceAsOf == nil)
        #expect(HealthFixture.health([account], links: [HealthFixture.link()])[account.id]?.state == .notSynced)
    }
}
