import Foundation
import Testing
@testable import BudgetKit

/// Hand-built ledgers for net worth: the three `Rows` accounts plus a brokerage, anchored so each ends at its balance.
enum NetWorthFixture {
    static let brokerage = Account(id: "inv", name: "Brokerage", institution: "Northwind", kind: .investment, balance: Money(20_000), source: .plaid)

    static func ledger(_ rows: [LedgerTransaction], manual: [ManualAsset] = []) -> Ledger {
        var state = Rows.state(rows)
        state.accounts.append(brokerage)
        state.manualAssets = manual
        var ledger = Ledger(state: state, now: EngineFixture.now, calendar: Fixture.calendar)
        for account in ledger.accounts { ledger.reanchor(account.id) }
        return ledger
    }

    static func day(_ back: Int) -> String {
        let ledger = Ledger(state: .empty, now: EngineFixture.now, calendar: Fixture.calendar)
        return ledger.dayName(EngineFixture.day(back))
    }

    /// The point for the day `back` days before today.
    static func point(_ worth: NetWorth, _ back: Int) -> NetWorthPoint? {
        let day = Fixture.calendar.startOfDay(for: EngineFixture.day(back))
        return worth.points.first { $0.date == day }
    }

    /// A row that moves nothing, 25 days back, so the history reaches that far.
    static let early = [Rows.row("early", "sav", 25, 0, "INTEREST", "income")]

    static let rows = [
        Rows.row("a", "chk", 2, -100, "GROCER", "groceries"),
        Rows.row("b", "chk", 5, 1000, "PAYROLL", "income"),
        Rows.row("c", "card", 8, -50, "CAFE", "dining"),
        Rows.row("d", "chk", 20, -25, "BOOKS", "shopping"),
    ]
}

@Suite("Net worth history")
struct NetWorthTests {
    @Test("Today's figure is the balances' net worth, in every range; assets less debts on every day", arguments: NetWorthRange.allCases)
    func todayMatchesBalances(range: NetWorthRange) async throws {
        let api = Fixture.api()
        let worth = try await api.netWorth(range: range)
        let overview = try await api.overview()
        let balances = try #require(overview.balances)
        #expect(worth.netWorth == balances.netWorth)
        #expect(worth.points.last?.netWorth == worth.netWorth)
        #expect(worth.points.allSatisfy { $0.netWorth == $0.assets - $0.liabilities })
        #expect(worth.change == worth.netWorth - worth.points[0].netWorth)
        #expect(worth.assetLines.map(\.value).sum() == worth.assets)
        #expect(worth.liabilityLines.map(\.value).sum() == worth.liabilities)
        #expect(worth.points.count <= 122)
        #expect(zip(worth.points, worth.points.dropFirst()).allSatisfy { $0.date < $1.date })
    }

    @Test("Hand-kept items count in Balances: net worth = cash − cards + investments + other assets − other debts")
    func balancesIncludeManual() throws {
        let b = Fixture.ledger().balances()
        let other = try #require(b.otherAssets), debts = try #require(b.otherDebts)
        #expect(other == Money(18_400) && debts == Money(11_250))
        #expect(b.netWorth == b.cash - b.cardsOwed + b.investments + other - debts)
        // A ledger with none leaves them out, so older apps see what they always did.
        let plain = NetWorthFixture.ledger([]).balances()
        #expect(plain.otherAssets == nil && plain.otherDebts == nil)
    }

    @Test("Cash and cards walk back from today's balance through each day's rows")
    func walkBack() throws {
        let worth = NetWorthFixture.ledger(NetWorthFixture.rows).netWorth(range: .oneMonth, snapshots: [])
        // Today: 5,000 checking + 9,000 savings + 20,000 invested − 300 on the card.
        #expect(worth.netWorth == Money(33_700))
        #expect(NetWorthFixture.point(worth, 2)?.netWorth == Money(33_700))   // the grocery row is that day's
        #expect(NetWorthFixture.point(worth, 3)?.netWorth == Money(33_800))   // before it
        #expect(NetWorthFixture.point(worth, 5)?.netWorth == Money(33_800))
        #expect(NetWorthFixture.point(worth, 6)?.netWorth == Money(32_800))   // before the paycheck
        #expect(NetWorthFixture.point(worth, 8)?.liabilities == Money(300))
        #expect(NetWorthFixture.point(worth, 9)?.liabilities == Money(250))  // before the cafe charge
        #expect(NetWorthFixture.point(worth, 9)?.netWorth == Money(32_850))
        // The first day is the ledger's first (the books row's), at its end.
        #expect(worth.start == Fixture.calendar.startOfDay(for: EngineFixture.day(20)))
        #expect(NetWorthFixture.point(worth, 20)?.netWorth == Money(32_850))
        #expect(worth.change == Money(850))
        let checking = try #require(worth.assetLines.first { $0.id == "chk" })
        #expect(checking.change == Money(900) && checking.group == .cash)
        let card = try #require(worth.liabilityLines.first { $0.id == "card" })
        #expect(card.value == Money(300) && card.group == .cards)
        // The brokerage has no record yet, so its past holds today's balance and is marked estimated.
        #expect(worth.estimatedThrough == Fixture.calendar.startOfDay(for: EngineFixture.day(1)))
    }

    @Test("A balance a sync recorded is kept: the walk starts again from it")
    func snapshotAnchors() {
        let snapshots = [BalanceSnapshot(accountID: "chk", day: NetWorthFixture.day(3), balance: Money(4_500))]
        let worth = NetWorthFixture.ledger(NetWorthFixture.rows).netWorth(range: .oneMonth, snapshots: snapshots)
        // Without it the day ends at 5,100 in checking; the bank said 4,500.
        #expect(NetWorthFixture.point(worth, 3)?.netWorth == Money(33_200))
        #expect(NetWorthFixture.point(worth, 6)?.netWorth == Money(32_200))
        // After it, today's balance still rules.
        #expect(NetWorthFixture.point(worth, 2)?.netWorth == Money(33_700))
        #expect(worth.netWorth == Money(33_700))
    }

    @Test("Investments hold their latest record, and before the first are held at it and marked estimated")
    func investmentsHeld() throws {
        let snapshots = [BalanceSnapshot(accountID: "inv", day: NetWorthFixture.day(10), balance: Money(19_000)),
                         BalanceSnapshot(accountID: "inv", day: NetWorthFixture.day(5), balance: Money(19_500))]
        let worth = NetWorthFixture.ledger(NetWorthFixture.early).netWorth(range: .oneMonth, snapshots: snapshots)
        func invested(_ back: Int) -> Money? { NetWorthFixture.point(worth, back).map { $0.assets - Money(14_000) } }
        #expect(invested(20) == Money(19_000) && NetWorthFixture.point(worth, 20)?.isEstimated == true)
        #expect(invested(11) == Money(19_000) && NetWorthFixture.point(worth, 11)?.isEstimated == true)
        #expect(invested(10) == Money(19_000) && NetWorthFixture.point(worth, 10)?.isEstimated == nil)
        #expect(invested(6) == Money(19_000))
        #expect(invested(5) == Money(19_500))
        #expect(invested(1) == Money(19_500))
        #expect(invested(0) == Money(20_000))
        #expect(worth.estimatedThrough == Fixture.calendar.startOfDay(for: EngineFixture.day(11)))
        #expect(worth.note?.contains("estimated") == true)
        let line = try #require(worth.assetLines.first { $0.id == "inv" })
        #expect(line.isEstimated == true && line.change == Money(1_000) && line.group == .investments)
    }

    @Test("A record from before the range carries into it, so nothing in the range is a guess")
    func recordBeforeRange() {
        let snapshots = [BalanceSnapshot(accountID: "inv", day: NetWorthFixture.day(60), balance: Money(18_000))]
        let worth = NetWorthFixture.ledger([]).netWorth(range: .oneMonth, snapshots: snapshots)
        #expect(worth.estimatedThrough == nil && worth.note == nil)
        #expect(worth.points[0].assets == Money(32_000))
    }

    @Test("Hand-kept items count from the day they were added, at each value they were given; debts subtract")
    func manualHistory() throws {
        let car = ManualAsset(id: "car", name: "Car", kind: .asset, category: .vehicle, value: Money(1_200), updatedAt: EngineFixture.day(4),
                              createdAt: EngineFixture.day(10), history: [ManualAssetValue(date: EngineFixture.day(10), value: Money(1_000)),
                                                                          ManualAssetValue(date: EngineFixture.day(4), value: Money(1_200))])
        let loan = ManualAsset(id: "loan", name: "Loan", kind: .liability, category: .loan, value: Money(700), updatedAt: EngineFixture.day(7),
                               createdAt: EngineFixture.day(7), history: [ManualAssetValue(date: EngineFixture.day(7), value: Money(700))])
        let worth = NetWorthFixture.ledger(NetWorthFixture.early, manual: [car, loan]).netWorth(range: .oneMonth, snapshots: [])
        let base = Money(33_700)
        #expect(NetWorthFixture.point(worth, 11)?.netWorth == base)
        #expect(NetWorthFixture.point(worth, 10)?.netWorth == base + Money(1_000))
        #expect(NetWorthFixture.point(worth, 7)?.netWorth == base + Money(300))
        #expect(NetWorthFixture.point(worth, 4)?.netWorth == base + Money(500))
        #expect(worth.netWorth == base + Money(500))
        let line = try #require(worth.assetLines.first { $0.id == "car" })
        #expect(line.isManual == true && line.group == .vehicles && line.change == Money(1_200))
        #expect(worth.liabilityLines.first { $0.id == "loan" }?.group == .loans)
        #expect(worth.manualAssets.count == 2)
    }

    @Test("Ranges start where they say, but never before the ledger's first day")
    func rangeStarts() {
        let ledger = NetWorthFixture.ledger(NetWorthFixture.rows)
        let first = Fixture.calendar.startOfDay(for: EngineFixture.day(20))
        #expect(ledger.netWorth(range: .all, snapshots: []).start == first)
        #expect(ledger.netWorth(range: .oneYear, snapshots: []).start == first)
        #expect(ledger.netWorth(range: .oneMonth, snapshots: []).start == first)
        let older = ledger.netWorth(range: .oneMonth, snapshots: [BalanceSnapshot(accountID: "inv", day: NetWorthFixture.day(90), balance: Money(1))])
        #expect(older.start == Fixture.calendar.date(byAdding: .month, value: -1, to: Fixture.calendar.startOfDay(for: EngineFixture.now)))
        let demo = Fixture.ledger().netWorth(range: .yearToDate, snapshots: [])
        #expect(demo.start >= Fixture.calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!)
        let empty = Ledger(state: .empty, now: EngineFixture.now, calendar: Fixture.calendar).netWorth(range: .oneYear, snapshots: [])
        #expect(empty.points.count == 1 && empty.netWorth == .zero && empty.changePercent == nil)
    }

    @Test("Records left by an account that's gone don't count or stretch the history back")
    func goneAccounts() {
        let ledger = NetWorthFixture.ledger(NetWorthFixture.rows)
        let stale = [BalanceSnapshot(accountID: "unlinked", day: NetWorthFixture.day(200), balance: Money(50_000))]
        let worth = ledger.netWorth(range: .all, snapshots: stale)
        #expect(worth.start == Fixture.calendar.startOfDay(for: EngineFixture.day(20)))
        #expect(worth == ledger.netWorth(range: .all, snapshots: []))
    }

    @Test("Long ranges are thinned to about 120 points, keeping the first day and today")
    func thinning() {
        let ledger = Fixture.ledger()
        let all = ledger.netWorth(range: .all, snapshots: [])
        #expect(all.points.count <= 122 && all.points.count > 60)
        #expect(all.points.first?.date == all.start)
        #expect(all.points.last?.date == Fixture.calendar.startOfDay(for: EngineFixture.now))
        let monthAgo = Fixture.calendar.date(byAdding: .month, value: -1, to: Fixture.calendar.startOfDay(for: EngineFixture.now))!
        let days = Fixture.calendar.dateComponents([.day], from: monthAgo, to: Fixture.calendar.startOfDay(for: EngineFixture.now)).day! + 1
        #expect(ledger.netWorth(range: .oneMonth, snapshots: []).points.count == days)
    }

    @Test("The demo records two months of investment balances: a month back is all records, three months back starts estimated")
    func demoHistory() async throws {
        let api = Fixture.api()
        let month = try await api.netWorth(range: .oneMonth)
        #expect(month.estimatedThrough == nil)
        #expect(Set(month.points.map(\.netWorth)).count > 10)
        let quarter = try await api.netWorth(range: .threeMonths)
        #expect(quarter.estimatedThrough != nil && quarter.points.first?.isEstimated == true)
        #expect(quarter.assetLines.contains { $0.group == .vehicles } && quarter.liabilityLines.contains { $0.group == .loans })
    }

    @Test("A sync records today's balance of the accounts it reported; a statement file records nothing")
    func syncRecords() async throws {
        let api = EngineFixture.api()
        _ = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "b1")
        let recorded = try await api.balanceHistory.balanceSnapshots()
        #expect(recorded == [BalanceSnapshot(accountID: "plaid:summit-1", day: NetWorthFixture.day(0), balance: Money(-412.50))])
        // A second sync the same day replaces it.
        _ = try await api.ingest(EngineFixture.plaidSnapshot(), batchID: "b2")
        #expect(try await api.balanceHistory.balanceSnapshots().count == 1)

        let file = SourceSnapshot(source: .fileImport, accounts: [
            SourceAccount(externalID: "stmt", institution: "Keystone", institutionDomain: nil, name: "Card", kind: .credit, balance: Money(-10),
                          availableBalance: nil, balanceDate: EngineFixture.now, transactions: [], holdings: []),
        ], warnings: [])
        _ = try await api.ingest(file, batchID: "f1")
        #expect(try await api.balanceHistory.balanceSnapshots().count == 1)
    }

    @Test("Resetting the history clears it, or puts back the demo's")
    func reset() async throws {
        let api = Fixture.api()
        #expect(try await api.balanceHistory.balanceSnapshots().count > 100)
        try await api.resetBalanceHistory(seedDemo: false)
        #expect(try await api.balanceHistory.balanceSnapshots().isEmpty)
        try await api.resetBalanceHistory(seedDemo: true)
        #expect(try await api.balanceHistory.balanceSnapshots().count > 100)
    }
}

@Suite("Hand-kept assets and debts")
struct ManualAssetTests {
    @Test("Adding one counts it from today; undo takes it away")
    func add() async throws {
        let api = Fixture.api()
        let before = try await api.overview().balances!.netWorth
        let action = AppAction.saveManualAsset(SaveManualAsset(name: " Boat ", kind: .asset, category: .other, value: DecimalAmount(string: "4200")))
        let preview = try await api.preview(action)
        #expect(preview.title == "Add Boat as an asset of $4,200")
        #expect(preview.effects.first { $0.id == "after" }?.value == before + Money(4_200))
        let result = try await api.perform(action)
        #expect(result.message.hasPrefix("Added Boat."))
        let worth = try await api.netWorth(range: .oneMonth)
        let boat = try #require(worth.manualAssets.first { $0.name == "Boat" })
        #expect(boat.history == [ManualAssetValue(date: Fixture.now, value: Money(4_200))])
        #expect(worth.netWorth == before + Money(4_200))
        #expect(worth.points.dropLast().allSatisfy { $0.assets - $0.liabilities == $0.netWorth })
        #expect(worth.assetLines.first { $0.id == boat.id }?.change == Money(4_200))
        guard case .removeManualAsset(RemoveManualAsset(id: boat.id))? = result.undo else { Issue.record("undo should remove it"); return }
        _ = try await api.perform(result.undo!)
        #expect(try await api.overview().balances!.netWorth == before)
    }

    @Test("A debt with no kind given is a loan when its category says so")
    func debtDefaults() throws {
        var ledger = Fixture.ledger()
        _ = try ledger.perform(.saveManualAsset(SaveManualAsset(name: "Student loan", category: .loan, value: DecimalAmount(string: "9000"))))
        let loan = try #require(ledger.manualAssets.first { $0.name == "Student loan" })
        #expect(loan.kind == .liability && loan.category == .loan)
        #expect(ledger.balances().otherDebts == Money(11_250 + 9_000))
    }

    @Test("A new value is recorded in its history; a second change the same day replaces the first; undo restores it all")
    func update() throws {
        var ledger = Fixture.ledger()
        let original = try #require(ledger.manualAssets.first { $0.id == "asset-car" })
        let first = try ledger.perform(.saveManualAsset(SaveManualAsset(id: "asset-car", value: DecimalAmount(string: "18000"))))
        _ = try ledger.perform(.saveManualAsset(SaveManualAsset(id: "asset-car", name: "Family car", value: DecimalAmount(string: "17900"))))
        let car = try #require(ledger.manualAssets.first { $0.id == "asset-car" })
        #expect(car.name == "Family car" && car.value == Money(17_900))
        #expect(car.history?.count == (original.history?.count ?? 0) + 1)
        #expect(car.history?.last == ManualAssetValue(date: Fixture.now, value: Money(17_900)))
        #expect(first.undo == .saveManualAsset(SaveManualAsset(restore: original)))
        _ = try ledger.perform(first.undo!)
        #expect(ledger.manualAssets.first { $0.id == "asset-car" } == original)
    }

    @Test("Removing one takes its history out of net worth; undo puts it back exactly")
    func remove() throws {
        var ledger = Fixture.ledger()
        let loan = try #require(ledger.manualAssets.first { $0.id == "asset-car-loan" })
        let before = ledger.balances().netWorth
        let result = try ledger.perform(.removeManualAsset(RemoveManualAsset(id: loan.id)))
        #expect(ledger.balances().netWorth == before + Money(11_250))
        #expect(ledger.netWorth(range: .threeMonths, snapshots: []).liabilityLines.allSatisfy { $0.id != loan.id })
        _ = try ledger.perform(result.undo!)
        #expect(ledger.manualAssets.first { $0.id == loan.id } == loan)
        #expect(ledger.balances().netWorth == before)
    }

    @Test("Refused: no name, a negative value, nothing to change; an unknown id is not found", arguments: [
        SaveManualAsset(name: "  ", value: DecimalAmount(string: "5")),
        SaveManualAsset(name: "Art", value: DecimalAmount(string: "-5")),
        SaveManualAsset(name: "Art"),
        SaveManualAsset(id: "asset-car", value: DecimalAmount(string: "18400")),
    ])
    func refused(_ p: SaveManualAsset) {
        var ledger = Fixture.ledger()
        #expect(throws: BudgetAPIError.self) { try ledger.perform(.saveManualAsset(p)) }
    }

    @Test("Undo's put-back is checked too: a negative value or a blank name is refused")
    func restoreChecked() throws {
        var ledger = Fixture.ledger()
        var item = try #require(ledger.manualAssets.first)
        item.value = Money(-1)
        #expect(throws: BudgetAPIError.self) { try ledger.perform(.saveManualAsset(SaveManualAsset(restore: item))) }
        item.value = Money(1)
        item.name = " "
        #expect(throws: BudgetAPIError.self) { try ledger.perform(.saveManualAsset(SaveManualAsset(restore: item))) }
    }

    @Test("Unknown ids are not found")
    func unknown() {
        var ledger = Fixture.ledger()
        #expect(throws: BudgetAPIError.notFound) { try ledger.perform(.saveManualAsset(SaveManualAsset(id: "nope", value: DecimalAmount(string: "5")))) }
        #expect(throws: BudgetAPIError.notFound) { try ledger.perform(.removeManualAsset(RemoveManualAsset(id: "nope"))) }
    }

    @Test("The actions round-trip on the wire with their type")
    func wire() throws {
        let item = Fixture.ledger().manualAssets[0]
        for action in [AppAction.saveManualAsset(SaveManualAsset(name: "Boat", kind: .asset, category: .other, value: DecimalAmount(string: "10"))),
                       .saveManualAsset(SaveManualAsset(restore: item)), .removeManualAsset(RemoveManualAsset(id: "x"))] {
            let data = try RemoteBudgetAPI.encoder.encode(action)
            #expect(String(decoding: data, as: UTF8.self).contains("\"type\":\"\(action.toolName)\""))
            let back = try RemoteBudgetAPI.decoder.decode(AppAction.self, from: data)
            #expect(back.toolName == action.toolName)
        }
        // Not tools the assistant can call.
        #expect(ToolCatalog.spec(named: "saveManualAsset") == nil && ToolCatalog.spec(named: "removeManualAsset") == nil)
    }

    @Test("A ledger saved before hand-kept items decodes with none; one with them round-trips")
    func persistence() throws {
        let state = Fixture.ledger().state
        #expect(state.manualAssets.count == 2)
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(LedgerState.self, from: data) == state)
        guard case var .object(fields) = try JSONValue.parse(data) else { Issue.record("not an object"); return }
        fields["manualAssets"] = nil
        #expect(try JSONDecoder().decode(LedgerState.self, from: JSONValue.object(fields).data()).manualAssets.isEmpty)
    }

    @Test("Kinds, categories and groups a newer server adds still decode")
    func futureCases() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(ManualAssetKind.self, from: Data(#""crypto""#.utf8)) == .asset)
        #expect(try decoder.decode(ManualAssetCategory.self, from: Data(#""art""#.utf8)) == .other)
        #expect(try decoder.decode(NetWorthGroup.self, from: Data(#""collectibles""#.utf8)) == .otherAssets)
    }
}

@Suite("Ask about net worth")
struct NetWorthAskTests {
    @Test("The demo answers from the ledger, grounded, with a netWorth call that validates")
    func demoAnswer() async throws {
        let reply = try await Fixture.api().ask("What's my net worth?", conversationID: nil)
        let call = try #require(reply.toolCalls.first)
        #expect(call.name == "netWorth")
        try ToolCatalog.validateArguments(tool: call.name, json: Data(call.arguments.utf8), categoryIDs: nil)
        #expect(Grounding.ungroundedAmounts(in: reply.text, allowed: reply.figures.map(\.value)).isEmpty, "\(reply.text)")
        #expect(reply.figures.first?.value == Fixture.ledger().balances().netWorth)
        // It says how net worth moved over the range, from the recorded history, and that figure is grounded too.
        let worth = try await Fixture.api().netWorth(range: .threeMonths)
        #expect(reply.figures.contains { $0.id == "net-worth-change" && $0.value == worth.change })
        #expect(reply.text.contains(worth.change.magnitude.formatted()), "\(reply.text)")
    }

    @Test("The netWorth tool returns the screen's figures, formatted for grounding")
    func tool() async throws {
        let api = Fixture.api()
        let box = DemoToolbox(ledger: Fixture.ledger(), decisions: nil, balanceHistory: await api.balanceHistory)
        let (result, figures) = try await box.run(read: "netWorth", arguments: .object(["range": .string("1M")]))
        let worth = try await api.netWorth(range: .oneMonth)
        guard case let .object(o) = result else { Issue.record("not an object"); return }
        #expect(o["netWorth"] == .string(worth.netWorth.display))
        #expect(o["change"] == .string(worth.change.display))
        #expect(figures.contains { $0.id == "net-worth-change" && $0.value == worth.change })
        // The percent comes as text with its sign, so a model quoting it stays grounded; the range reads in any case.
        if case let .string(percent)? = o["changePercent"] {
            #expect(percent.hasSuffix("%") && (percent.hasPrefix("+") || percent.hasPrefix("-")))
            #expect(Grounding.ungroundedPercents(in: "up \(percent.dropFirst())", allowed: Grounding.percents(in: percent)).isEmpty)
        } else { Issue.record("changePercent should be text") }
        let (lower, _) = try await box.run(read: "netWorth", arguments: .object(["range": .string("1m")]))
        guard case let .object(l) = lower else { Issue.record("not an object"); return }
        #expect(l["range"] == .string("1M"))
    }
}
