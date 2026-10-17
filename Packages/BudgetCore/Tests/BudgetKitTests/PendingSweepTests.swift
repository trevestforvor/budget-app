import Foundation
import Testing
@testable import BudgetKit

/// A clock the test moves by hand, so syncs can land hours apart.
final class SweepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    func now() -> Date { lock.withLock { current } }
    func advance(hours: Double) { lock.withLock { current = current.addingTimeInterval(hours * 3_600) } }
}

/// B4 through the engine: a window source's pending rows that stop coming are settled into the posted row that replaced
/// them, or dropped once missed twice half a day apart, and either can be brought back from the merge log. The pulls go
/// through `SimpleFINSource.parse`; `coveredFrom` and `includesPending` are set the way the SimpleFIN sync sets them.
@Suite("Stale-pending sweep")
struct PendingSweepTests {
    static let base = Fixture.now
    static let checking = "simplefin:ACT-1"
    static func ago(_ days: Double) -> Int { Int(base.addingTimeInterval(-days * 86_400).timeIntervalSince1970) }

    struct Row {
        var id: String, days: Double, amount: String, description: String, pending = false
    }

    /// One SimpleFIN pull of the checking account (and, with `errored`, a second account on a connection that failed).
    static func pull(_ rows: [Row], coveredFrom days: Double = 30, includesPending: Bool = true, errored: [Row]? = nil) throws -> SourceSnapshot {
        func json(_ r: Row) -> String {
            r.pending ? #"{"id": "\#(r.id)", "posted": 0, "transacted_at": \#(ago(r.days)), "amount": "\#(r.amount)", "description": "\#(r.description)", "pending": true}"#
                : #"{"id": "\#(r.id)", "posted": \#(ago(r.days)), "amount": "\#(r.amount)", "description": "\#(r.description)"}"#
        }
        var accounts = [#"""
        {"id": "ACT-1", "name": "Total Checking", "conn_id": "CON-1", "currency": "USD", "balance": "1000.00", "balance-date": \#(ago(0)),
         "transactions": [\#(rows.map(json).joined(separator: ","))]}
        """#]
        if let errored {
            accounts.append(#"""
            {"id": "ACT-2", "name": "Rewards Card", "conn_id": "CON-2", "currency": "USD", "balance": "-200.00", "balance-date": \#(ago(0)),
             "transactions": [\#(errored.map(json).joined(separator: ","))]}
            """#)
        }
        let set = #"""
        {"errlist": [\#(errored == nil ? "" : #"{"code": "con.auth", "msg": "Sign in again at Lakeside", "conn_id": "CON-2"}"#)],
         "connections": [{"conn_id": "CON-1", "name": "Harbor Credit Union"}, {"conn_id": "CON-2", "name": "Lakeside Bank"}],
         "accounts": [\#(accounts.joined(separator: ","))]}
        """#
        var snapshot = try SimpleFINSource.parse(Data(set.utf8))
        snapshot.includesPending = includesPending
        for i in snapshot.accounts.indices {
            // A connection in the errlist covered nothing this time.
            if snapshot.accounts[i].externalID == "ACT-2" {
                snapshot.accountProblems["ACT-2"] = .needsSignIn(code: "con.auth")
            } else {
                snapshot.accounts[i].coveredFrom = base.addingTimeInterval(-days * 86_400)
            }
        }
        return snapshot
    }

    static func api(_ clock: SweepClock) -> LedgerBudgetAPI {
        LedgerBudgetAPI(state: .empty, calendar: Fixture.calendar, clock: { clock.now() }, chatModel: nil, decisions: DecisionRouting(),
                        persistence: nil, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.simplefin], institutions: []))
    }

    static func rows(_ api: LedgerBudgetAPI, account: String = checking) async -> [LedgerTransaction] {
        await api.ledger.transactions.filter { $0.accountID == account }
    }

    static let rent = Row(id: "t-rent", days: 20, amount: "-1500.00", description: "HARBOR PROPERTY MGMT RENT")

    @Test("A pending row that posts under a new id with a tip becomes one row, keeping its note, tags and category")
    func tipSettles() async throws {
        let clock = SweepClock(Self.base)
        let api = Self.api(clock)
        _ = try await api.ingest(Self.pull([Self.rent, Row(id: "p-1", days: 2, amount: "-40.00", description: "BLUE DOOR BISTRO", pending: true)]), batchID: "sync-1")
        _ = try await api.perform(.editTransactions(EditTransactions(transactionIDs: ["simplefin:p-1"], categoryID: "dining", note: "dinner with Sam",
                                                                     addTags: ["date night"])))
        clock.advance(hours: 6)
        let report = try await api.ingest(Self.pull([Self.rent, Row(id: "t-1", days: 1, amount: "-48.00", description: "BLUE DOOR BISTRO")]), batchID: "sync-2")
        #expect(report.pendingSettled == 1 && report.pendingDropped == nil)
        #expect(report.notes?.contains("1 pending charge settled under a new id.") == true)
        let rows = await Self.rows(api)
        #expect(rows.map(\.id).sorted() == ["simplefin:t-1", "simplefin:t-rent"])
        let posted = try #require(rows.first { $0.id == "simplefin:t-1" })
        #expect(posted.amount == Money(-48) && !posted.isPending)
        #expect(posted.note == "dinner with Sam" && posted.tags?.isEmpty == false)
        #expect(posted.categorization?.categoryID == "dining" && posted.categorization?.tier == .user)
        let logged = try #require(await api.merges(batchID: "sync-2").first)
        #expect(logged.kind == .pendingSettled && logged.keptID == "simplefin:t-1" && logged.droppedID == "simplefin:p-1")
        #expect(logged.dropped.note == "dinner with Sam" && logged.keptBefore?.note == nil)
        #expect(await api.ledger.pendingMisses.isEmpty)
    }

    @Test("A $1 pump authorization settles into the real fuel charge")
    func pumpPlaceholderSettles() async throws {
        let clock = SweepClock(Self.base)
        let api = Self.api(clock)
        _ = try await api.ingest(Self.pull([Row(id: "p-gas", days: 3, amount: "-1.00", description: "SHELL OIL 57442", pending: true)]), batchID: "sync-1")
        clock.advance(hours: 24)
        let report = try await api.ingest(Self.pull([Row(id: "t-gas", days: 2, amount: "-52.37", description: "SHELL OIL 57442")]), batchID: "sync-2")
        #expect(report.pendingSettled == 1)
        let rows = await Self.rows(api)
        #expect(rows.map(\.id) == ["simplefin:t-gas"] && rows.first?.amount == Money(-52.37))
        // The same $52.37 against an unrelated $1 hold would not settle: the wording has to agree.
        #expect(!PendingSweep.amountsFit(pending: Money(-1), posted: Money(-52.37), similarity: 0.5))
        #expect(!PendingSweep.amountsFit(pending: Money(-40), posted: Money(40), similarity: 1))
    }

    @Test("A pending row the bank dropped goes only after it's missed on two syncs half a day apart")
    func droppedAfterTwoMisses() async throws {
        let clock = SweepClock(Self.base)
        let api = Self.api(clock)
        _ = try await api.ingest(Self.pull([Self.rent, Row(id: "p-deli", days: 1, amount: "-18.00", description: "CORNER DELI", pending: true)]), batchID: "sync-1")
        clock.advance(hours: 2)
        let first = try await api.ingest(Self.pull([Self.rent]), batchID: "sync-2")
        #expect(first.pendingDropped == nil && first.notes == nil)
        #expect(await api.ledger.pendingMisses["simplefin:p-deli"] == clock.now())
        // A preview works on a copy: it never records or acts on a miss.
        clock.advance(hours: 6)
        #expect(try await api.previewIngest(Self.pull([Self.rent])).pendingDropped == nil)
        let early = try await api.ingest(Self.pull([Self.rent]), batchID: "sync-3")
        #expect(early.pendingDropped == nil)
        #expect(await Self.rows(api).contains { $0.id == "simplefin:p-deli" })
        clock.advance(hours: 7)
        let report = try await api.ingest(Self.pull([Self.rent]), batchID: "sync-4")
        #expect(report.pendingDropped == 1 && report.pendingSettled == nil)
        #expect(report.notes?.contains("1 pending charge the bank dropped was removed.") == true)
        #expect(await Self.rows(api).map(\.id) == ["simplefin:t-rent"])
        let logged = try #require(await api.merges(batchID: "sync-4").first)
        #expect(logged.kind == .pendingDropped && logged.keptID == nil && logged.droppedID == "simplefin:p-deli")
        #expect(await api.ledger.pendingMisses.isEmpty)
    }

    @Test("A pending row seen again is kept and its miss is forgotten")
    func seenAgainForgetsMiss() async throws {
        let clock = SweepClock(Self.base)
        let api = Self.api(clock)
        let deli = Row(id: "p-deli", days: 1, amount: "-18.00", description: "CORNER DELI", pending: true)
        _ = try await api.ingest(Self.pull([Self.rent, deli]), batchID: "sync-1")
        clock.advance(hours: 2)
        _ = try await api.ingest(Self.pull([Self.rent]), batchID: "sync-2")
        #expect(await api.ledger.pendingMisses["simplefin:p-deli"] != nil)
        clock.advance(hours: 18)
        _ = try await api.ingest(Self.pull([Self.rent, deli]), batchID: "sync-3")
        #expect(await api.ledger.pendingMisses.isEmpty)
        // Missed again a day later: a first miss again, not a second.
        clock.advance(hours: 20)
        let report = try await api.ingest(Self.pull([Self.rent]), batchID: "sync-4")
        #expect(report.pendingDropped == nil)
        #expect(await api.ledger.pendingMisses["simplefin:p-deli"] == clock.now())
        #expect(await Self.rows(api).contains { $0.id == "simplefin:p-deli" })
    }

    @Test("Rows before the window, accounts with a connection error, and fetches without pending rows are never swept")
    func neverSwept() async throws {
        let clock = SweepClock(Self.base)
        let api = Self.api(clock)
        // Inside the two-day margin at the start of what the pull covers (10 days back).
        let edge = Row(id: "p-edge", days: 9, amount: "-30.00", description: "LAKESIDE HARDWARE", pending: true)
        let card = Row(id: "p-card", days: 1, amount: "-12.00", description: "NOODLE BAR", pending: true)
        let later = Row(id: "p-late", days: 1, amount: "-9.00", description: "BOOKSHOP", pending: true)
        _ = try await api.ingest(Self.pull([Self.rent, edge, later], coveredFrom: 10, errored: [card]), batchID: "sync-1")
        #expect(await api.ledger.transactions.count == 4)
        // The card's connection keeps failing; the later pulls don't ask for pending rows.
        for hours in [13.0, 13, 13] {
            clock.advance(hours: hours)
            _ = try await api.ingest(Self.pull([Self.rent], coveredFrom: 10, errored: []), batchID: "sync-x")
        }
        #expect(await api.ledger.transactions.contains { $0.id == "simplefin:p-card" })
        #expect(await api.ledger.transactions.contains { $0.id == "simplefin:p-edge" })
        // p-late was missed by those pulls (they asked for pending rows): gone. Now the same with pending rows left out.
        #expect(await !api.ledger.transactions.contains { $0.id == "simplefin:p-late" })
        _ = try await api.ingest(Self.pull([Self.rent, later], coveredFrom: 10), batchID: "sync-again")
        for _ in 0..<3 {
            clock.advance(hours: 13)
            let report = try await api.ingest(Self.pull([Self.rent], coveredFrom: 10, includesPending: false), batchID: "sync-y")
            #expect(report.pendingDropped == nil && report.pendingSettled == nil)
        }
        #expect(await api.ledger.transactions.contains { $0.id == "simplefin:p-late" })
        #expect(await api.ledger.pendingMisses["simplefin:p-late"] == nil)
    }

    @Test("Two posted rows that both fit one pending row: nothing is carried, and the pending row waits for the miss rule")
    func ambiguousWaitsForMissRule() async throws {
        let clock = SweepClock(Self.base)
        let api = Self.api(clock)
        _ = try await api.ingest(Self.pull([Row(id: "p-tj", days: 2, amount: "-20.00", description: "TRADER JOES #552", pending: true)]), batchID: "sync-1")
        _ = try await api.perform(.editTransactions(EditTransactions(transactionIDs: ["simplefin:p-tj"], categoryID: "groceries", note: "party snacks")))
        clock.advance(hours: 6)
        let report = try await api.ingest(Self.pull([
            Row(id: "t-a", days: 1, amount: "-21.00", description: "TRADER JOES #552"),
            Row(id: "t-b", days: 1, amount: "-22.00", description: "TRADER JOES #552"),
        ]), batchID: "sync-2")
        #expect(report.pendingSettled == nil && report.rowsAdded == 2)
        var rows = await Self.rows(api)
        #expect(rows.count == 3)
        #expect(rows.filter { $0.id != "simplefin:p-tj" }.allSatisfy { $0.note == nil && $0.categorization?.tier != .user })
        #expect(await api.ledger.pendingMisses["simplefin:p-tj"] != nil)
        clock.advance(hours: 13)
        let later = try await api.ingest(Self.pull([
            Row(id: "t-a", days: 1, amount: "-21.00", description: "TRADER JOES #552"),
            Row(id: "t-b", days: 1, amount: "-22.00", description: "TRADER JOES #552"),
        ]), batchID: "sync-3")
        #expect(later.pendingDropped == 1)
        rows = await Self.rows(api)
        #expect(rows.map(\.id).sorted() == ["simplefin:t-a", "simplefin:t-b"])
        // Its edits are in the log copy, to bring back.
        #expect(await api.merges(batchID: "sync-3").first?.dropped.note == "party snacks")
    }

    @Test("Plaid pending rows are never swept")
    func plaidNeverSwept() async throws {
        let clock = SweepClock(Self.base)
        let api = Self.api(clock)
        func plaid(_ pending: Bool) -> SourceSnapshot {
            var rows = [SourceTransaction(externalID: "p-old", posted: Self.base.addingTimeInterval(-10 * 86_400), amount: Money(-60), description: "GROCERY OUTLET")]
            if pending { rows.append(SourceTransaction(externalID: "p-hold", posted: Self.base.addingTimeInterval(-86_400), amount: Money(-25), description: "CITY PARKING", isPending: true)) }
            return SourceSnapshot(source: .plaid, accounts: [
                SourceAccount(externalID: "chk", institution: "Harbor Bank", institutionDomain: nil, name: "Checking", kind: .checking, balance: Money(900),
                              availableBalance: nil, balanceDate: Self.base, transactions: rows, holdings: [],
                              coveredFrom: Self.base.addingTimeInterval(-30 * 86_400)),
            ], warnings: [], includesPending: true)
        }
        _ = try await api.ingest(plaid(true), batchID: "sync-1")
        for _ in 0..<3 {
            clock.advance(hours: 13)
            let report = try await api.ingest(plaid(false), batchID: "sync-x")
            #expect(report.pendingDropped == nil && report.pendingSettled == nil)
        }
        #expect(await api.ledger.transactions.contains { $0.id == "plaid:p-hold" })
        #expect(await api.ledger.pendingMisses.isEmpty)
    }

    @Test("A dropped pending row can be brought back from the log")
    func droppedRowComesBack() async throws {
        let clock = SweepClock(Self.base)
        let api = Self.api(clock)
        _ = try await api.ingest(Self.pull([Self.rent, Row(id: "p-deli", days: 1, amount: "-18.00", description: "CORNER DELI", pending: true)]), batchID: "sync-1")
        _ = try await api.perform(.editTransactions(EditTransactions(transactionIDs: ["simplefin:p-deli"], categoryID: "dining", note: "team lunch")))
        clock.advance(hours: 2)
        _ = try await api.ingest(Self.pull([Self.rent]), batchID: "sync-2")
        clock.advance(hours: 13)
        _ = try await api.ingest(Self.pull([Self.rent]), batchID: "sync-3")
        let entry = try #require(await api.merges(batchID: "sync-3").first { $0.kind == .pendingDropped })
        #expect(await !Self.rows(api).contains { $0.id == "simplefin:p-deli" })

        let result = try await api.undoMerge(id: entry.id)
        #expect(result.restored == 1 && result.waiting == 0)
        let back = try #require(await Self.rows(api).first { $0.id == "simplefin:p-deli" })
        #expect(back.isPending && back.note == "team lunch" && back.categorization?.categoryID == "dining")
        #expect(await api.merges(batchID: "sync-3").first?.undoneAt != nil)
        // The person wanted it back: the bank still not sending it doesn't drop it again.
        for _ in 0..<2 {
            clock.advance(hours: 13)
            #expect(try await api.ingest(Self.pull([Self.rent]), batchID: "sync-later").pendingDropped == nil)
        }
        #expect(await Self.rows(api).contains { $0.id == "simplefin:p-deli" })
    }

    @Test("A settled pending row can be brought back, and the posted row gives back what it took")
    func settledRowComesBack() async throws {
        let clock = SweepClock(Self.base)
        let api = Self.api(clock)
        _ = try await api.ingest(Self.pull([Row(id: "p-1", days: 2, amount: "-40.00", description: "BLUE DOOR BISTRO", pending: true)]), batchID: "sync-1")
        _ = try await api.perform(.editTransactions(EditTransactions(transactionIDs: ["simplefin:p-1"], note: "dinner with Sam")))
        clock.advance(hours: 6)
        _ = try await api.ingest(Self.pull([Row(id: "t-1", days: 1, amount: "-46.00", description: "BLUE DOOR BISTRO")]), batchID: "sync-2")
        let entry = try #require(await api.merges(batchID: "sync-2").first)
        #expect(entry.kind == .pendingSettled)
        // The category didn't come across (the person never filed the pending row), so the posted row was filed afresh.
        let filed = try #require(await Self.rows(api).first { $0.id == "simplefin:t-1" })
        #expect(filed.note == "dinner with Sam" && filed.categorization != nil)

        let result = try await api.undoMerge(id: entry.id)
        #expect(result.restored == 1)
        let rows = await Self.rows(api)
        #expect(rows.map(\.id).sorted() == ["simplefin:p-1", "simplefin:t-1"])
        let posted = try #require(rows.first { $0.id == "simplefin:t-1" })
        #expect(posted.note == nil && posted.categorization == filed.categorization)
        #expect(rows.first { $0.id == "simplefin:p-1" }?.note == "dinner with Sam")
    }

    @Test("The sweep's note reads naturally for every mix")
    func notes() {
        #expect(Ledger.pendingSweepNote(settled: 0, dropped: 0) == nil)
        #expect(Ledger.pendingSweepNote(settled: 2, dropped: 1) == "2 pending charges settled under new ids; 1 the bank dropped was removed.")
        #expect(Ledger.pendingSweepNote(settled: 0, dropped: 3) == "3 pending charges the bank dropped were removed.")
        #expect(Ledger.pendingSweepNote(settled: 1, dropped: 0) == "1 pending charge settled under a new id.")
    }
}
