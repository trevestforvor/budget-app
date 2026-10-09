import Foundation
import Testing
@testable import BudgetKit

/// Pace alerts: the everyday budget, category targets and merchant caps against the month so far.
@Suite("Pace alerts")
struct PaceAlertsTests {
    static func money(_ dollars: Int64) -> Money { Money(minorUnits: dollars * 100) }

    static func at(_ day: Int) -> Date { Fixture.calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12))! }

    static func row(_ id: String, _ merchant: String, _ amount: Decimal, _ category: String, on day: Int) -> LedgerTransaction {
        LedgerTransaction(id: id, accountID: "chk", postedAt: at(day), merchant: merchant, rawDescription: merchant.uppercased(), amount: Money(amount),
                          categorization: Categorization(categoryID: category, confidence: 0.99, tier: .merchantMemory, needsReview: false),
                          isPending: false, source: .plaid)
    }

    /// A ledger with a Dining target of $450 and a DoorDash cap of $150, on `day` of October.
    static func ledger(day: Int, rows: [LedgerTransaction]) -> Ledger {
        var state = LedgerState.empty
        state.accounts = [Account(id: "chk", name: "Checking", institution: "Bank", kind: .checking, balance: Money(4_000), source: .plaid)]
        state.transactions = rows
        state.monthlyTargets = ["dining": money(450)]
        state.merchantTargets = ["DoorDash": money(150)]
        return Ledger(state: state, now: at(day), calendar: Fixture.calendar)
    }

    // MARK: The arithmetic

    @Test("The pace is the month so far spread over the month, and only from the second week")
    func pace() {
        let early = Ledger.paceStatus(spent: Self.money(300), limit: Self.money(450), day: 7, days: 31, accrues: true)
        #expect(early.projected == nil && early.usedPercent == 67)
        // $300 in 10 days of 31 → $930; $150 left over 22 days (today included) is $6.81 a day.
        let tenth = Ledger.paceStatus(spent: Self.money(300), limit: Self.money(450), day: 10, days: 31, accrues: true)
        #expect(tenth.projected == Self.money(930) && tenth.projectedOver == Self.money(480))
        #expect(tenth.perDayLeft == Money(minorUnits: 681))
        // A bill lands once: its projection is what it is.
        let bill = Ledger.paceStatus(spent: Self.money(300), limit: Self.money(450), day: 10, days: 31, accrues: false)
        #expect(bill.projected == Self.money(300) && bill.projectedOver == nil)
        // Past the limit, nothing's left per day.
        #expect(Ledger.paceStatus(spent: Self.money(500), limit: Self.money(450), day: 10, days: 31, accrues: true).perDayLeft == nil)
    }

    @Test("Thresholds: 80% used, on pace to finish over by a margin, or over by a dollar")
    func thresholds() {
        func threshold(_ spent: Int64, _ limit: Int64, day: Int, kind: PaceAlert.Kind = .category, accrues: Bool = true) -> PaceAlert.Threshold? {
            Ledger.threshold(Ledger.paceStatus(spent: Money(minorUnits: spent), limit: Money(minorUnits: limit), day: day, days: 30, accrues: accrues),
                             kind: kind, accrues: accrues)
        }
        #expect(threshold(35_900, 45_000, day: 25) == nil)           // 79.8%, on pace for $430.80
        #expect(threshold(36_000, 45_000, day: 25) == .used80)       // exactly 80%, on pace for $432
        #expect(threshold(36_000, 45_000, day: 7) == .used80)        // too early to project; 80% still counts
        #expect(threshold(15_500, 45_000, day: 10) == .projectedOver) // on pace for $465: $15 over clears $10 (and 2% is $9)
        #expect(threshold(15_200, 45_000, day: 10) == nil)           // on pace for $456: $6 over is noise
        #expect(threshold(45_100, 45_000, day: 3) == .projectedOver) // over by a dollar counts at any point
        #expect(threshold(45_050, 45_000, day: 3) == .used80)        // fifty cents over is only "used"
        // The everyday budget alerts on its pace, never on 80% (safe to spend already says how much is used).
        #expect(threshold(180_000, 200_000, day: 28, kind: .everyday) == nil)
        #expect(threshold(80_000, 200_000, day: 10, kind: .everyday) == .projectedOver)
        // A bill's target: only once it's over.
        #expect(threshold(44_000, 45_000, day: 10, accrues: false) == nil)
        #expect(threshold(46_000, 45_000, day: 10, accrues: false) == .projectedOver)
    }

    @Test("The words state the projection and what a day can take", arguments: [
        (PaceAlert.Kind.everyday, Int64(1_330_00), Int64(2_200_00), 18, "Everyday is on pace to go over",
         "Everyday is on pace to finish about $91 over. $62/day keeps you on budget."),
        (.category, 382_00, 450_00, 28, "Dining: 85% of its target", "Dining has used $382 of its $450 target, with 4 days left. $17/day keeps it on target."),
        (.merchant, 160_00, 150_00, 19, "DoorDash is over its cap", "DoorDash is $10 past its $150 cap, with 13 days left."),
        (.category, 300_00, 450_00, 10, "Dining is on pace to go over", "Dining is on pace to finish about $480 over its $450 target. $6.81/day keeps it on target."),
        (.everyday, 2_300_00, 2_200_00, 31, "Everyday is over budget", "Everyday spending is $100 past this month's $2,200 budget, on the last day of the month."),
    ])
    func words(kind: PaceAlert.Kind, spent: Int64, limit: Int64, day: Int, title: String, body: String) throws {
        let status = Ledger.paceStatus(spent: Money(minorUnits: spent), limit: Money(minorUnits: limit), day: day, days: 31, accrues: true)
        let threshold = try #require(Ledger.threshold(status, kind: kind, accrues: true))
        let name = kind == .everyday ? "Everyday" : kind == .merchant ? "DoorDash" : "Dining"
        let alert = Ledger.alert(kind, threshold, id: name, name: name, status: status, daysLeft: 31 - day + 1, link: .budget)
        #expect(alert.title == title)
        #expect(alert.body == body)
    }

    @Test("About: to the $10 from $100, whole dollars below")
    func approximately() {
        #expect(Ledger.approximately(Money(minorUnits: 21_840)) == "$220")
        #expect(Ledger.approximately(Money(minorUnits: 21_490)) == "$210")
        #expect(Ledger.approximately(Money(minorUnits: 4_449)) == "$44")
        #expect(Ledger.approximately(Money(minorUnits: 9_960)) == "$100")
    }

    // MARK: From the ledger

    @Test("A category target and a merchant cap from the ledger's own totals, each with where a tap goes")
    func fromTheLedger() throws {
        // October 15: $380 at restaurants (84% of $450, on pace for $785) and $130 of DoorDash (87% of $150).
        let rows = [Self.row("a", "Bistro", -250, "dining", on: 3), Self.row("b", "Taqueria", -130, "dining", on: 12),
                    Self.row("c", "DoorDash", -70, "shopping", on: 5), Self.row("d", "DoorDash", -60, "shopping", on: 14),
                    Self.row("e", "Bistro", 20, "dining", on: 13), Self.row("f", "Bistro", -20, "dining", on: 13)]
        let report = Self.ledger(day: 15, rows: rows).paceAlerts()
        #expect(report.month == "2026-10" && report.day == 15 && report.daysInMonth == 31 && report.projecting)
        let dining = try #require(report.alerts.first { $0.kind == .category })
        #expect(dining.targetID == "dining" && dining.threshold == .projectedOver && dining.link == .category("dining"))
        // Net of the refund: $380, not $400.
        #expect(dining.status.spent == Self.money(380) && dining.status.limit == Self.money(450))
        let doordash = try #require(report.alerts.first { $0.kind == .merchant })
        #expect(doordash.targetID == "DoorDash" && doordash.link == .merchant("DoorDash"))
        #expect(doordash.status.spent == Self.money(130))
        // Most pressing first: on pace to go over before 80% used.
        #expect(report.alerts.map(\.threshold) == report.alerts.map(\.threshold).sorted { $0.rank > $1.rank })
        #expect(dining.id == "category:dining:projectedOver" && dining.targetKey == "category:dining")
    }

    @Test("Early in the month only what's spent counts; hidden rows and transfers never do")
    func earlyAndUncounted() {
        var hidden = Self.row("h", "Bistro", -300, "dining", on: 2)
        hidden.isHidden = true
        let rows = [Self.row("a", "Bistro", -100, "dining", on: 2), hidden, Self.row("t", "Savings", -900, "transfer", on: 2)]
        let report = Self.ledger(day: 4, rows: rows).paceAlerts()
        #expect(!report.projecting)
        // $100 in 4 days would be on pace for $775, but it's too early to say so.
        #expect(report.alerts.isEmpty)
    }

    @Test("The everyday budget's pace is safe to spend's month at the checkup's pace")
    func everyday() throws {
        let ledger = Fixture.ledger()
        let report = ledger.paceAlerts()
        let flex = ledger.flexBudget()
        let status = try #require(report.everyday)
        #expect(status.spent == flex.flexSpent && status.limit == flex.flexNumber)
        let projected = Money(minorUnits: Int64((Double(flex.flexSpent.minorUnits) * 30 / 25).rounded()))
        #expect(status.projected == projected)
        if flex.safeToSpend.minorUnits > 0 { #expect(status.perDayLeft == flex.perDayLeft) }
        if ProcessInfo.processInfo.environment["PRINT_PACE"] != nil {
            for day in [Fixture.now, Fixture.calendar.date(from: DateComponents(year: 2026, month: 9, day: 20, hour: 10))!] {
                let l = DemoLedger(now: day, calendar: Fixture.calendar, seed: 7)
                let r = l.paceAlerts()
                print("== \(r.month) day \(r.day): everyday \(r.everyday.map { "\($0.spent.formatted()) of \($0.limit.formatted()), on pace \($0.projected?.formatted() ?? "-")" } ?? "none")")
                for a in r.alerts { print("  [\(a.id)] \(a.title) — \(a.body)") }
            }
        }
    }

    @Test("The demo has something to show: the everyday pace, targets past a threshold, and a cap once one is set")
    func demo() async throws {
        let api = Fixture.api()
        let report = try await api.paceAlerts()
        #expect(report.everyday?.projected != nil)
        #expect(report.alerts.contains { $0.kind == .category && $0.link == .category($0.targetID) }, "\(report.alerts.map(\.id))")
        _ = try await api.perform(.setMerchantTarget(SetMerchantTarget(merchant: "doordash", monthlyAmount: DecimalAmount(string: "60")!)))
        let capped = try await api.paceAlerts()
        let cap = try #require(capped.alerts.first { $0.kind == .merchant })
        #expect(cap.targetID == "DoorDash" && cap.link == .merchant("DoorDash"))
    }

    // MARK: Ask

    @Test("Ask: \"Am I on pace?\" reads checkPace and says only what it returned")
    func ask() async throws {
        let reply = try await Fixture.api().ask("Am I on pace this month?", conversationID: nil)
        #expect(reply.toolCalls.map(\.name) == ["checkPace"])
        #expect(reply.text.hasPrefix("Everyday is on pace for "), "\(reply.text)")
        #expect(Grounding.ungroundedAmounts(in: reply.text, allowed: reply.figures.map(\.value)).isEmpty, "\(reply.text)")
        #expect(ToolCatalog.specs.contains { $0.name == "checkPace" && $0.kind == .read })
        let (result, figures) = try await DemoToolbox(ledger: Fixture.ledger(), decisions: nil).run(read: "checkPace", arguments: .object([:]))
        guard case let .object(o) = result, case let .array(past)? = o["pastAThreshold"] else { Issue.record("no list"); return }
        #expect(!past.isEmpty && !figures.isEmpty)
    }

    // MARK: On the wire

    @Test("Round trip, and kinds or thresholds a later server sends read as unknown")
    func wire() throws {
        let report = Fixture.ledger().paceAlerts()
        #expect(try JSONDecoder().decode(PaceAlerts.self, from: JSONEncoder().encode(report)) == report)
        #expect(try JSONDecoder().decode(PaceAlert.Kind.self, from: Data(#""goal""#.utf8)) == .unknown)
        #expect(try JSONDecoder().decode(PaceAlert.Threshold.self, from: Data(#""used50""#.utf8)) == .unknown)
    }

    @Test("Preferences: everyday on and the rest off unless said; an older app's registration carries none")
    func preferences() throws {
        let empty = try JSONDecoder().decode(PaceAlertPreferences.self, from: Data("{}".utf8))
        #expect(empty == .defaults && empty.everyday && !empty.categories && !empty.merchants)
        #expect(empty.wants(.everyday) && !empty.wants(.category) && !empty.wants(.unknown))
        let old = #"{"token":"ab","environment":"sandbox","timeZone":"UTC","enabled":true,"hour":9,"minute":30}"#
        #expect(try JSONDecoder().decode(DeviceRegistration.self, from: Data(old.utf8)).paceAlerts == nil)
        let status = #"{"enabled":true,"timeZone":"UTC","hour":9,"minute":30,"pushConfigured":true}"#
        #expect(try JSONDecoder().decode(DeviceStatus.self, from: Data(status.utf8)).paceAlerts == nil)
    }
}
