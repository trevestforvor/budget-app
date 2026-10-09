import Foundation
import Testing
@testable import BudgetKit

/// Fixture now is 2026-09-25, so this month is "2026-09" and offset 1 is "2026-10".
@Suite("Plan scenarios")
struct PlanScenarioTests {
    static func event(_ id: String, _ kind: PlanEvent.Kind, _ amount: Decimal, from start: String, to end: String? = nil,
                      _ cadence: PlanEvent.Cadence, on: Bool = true) -> PlanEvent {
        PlanEvent(id: id, name: id, kind: kind, amount: Money(amount), startMonth: start, endMonth: end, cadence: cadence, isEnabled: on)
    }

    /// A $450 car payment from November and a $5,000 bonus in December.
    static let car = PlanScenario(id: "s1", name: "Car and bonus", events: [
        event("car", .expense, 450, from: "2026-11", .monthly),
        event("bonus", .income, 5000, from: "2026-12", .once),
        event("off", .expense, 999, from: "2026-10", .monthly, on: false),
    ])

    @Test("An event happens in its months: once in its start, monthly through its end, yearly every twelve months")
    func occurrences() {
        let monthly = Self.event("m", .expense, 10, from: "2026-11", to: "2027-01", .monthly)
        #expect(["2026-10", "2026-11", "2026-12", "2027-01", "2027-02"].map { Ledger.occurs(monthly, in: $0) } == [false, true, true, true, false])
        let once = Self.event("o", .income, 10, from: "2026-12", to: "2027-06", .once)
        #expect(["2026-11", "2026-12", "2027-01"].map { Ledger.occurs(once, in: $0) } == [false, true, false])
        let yearly = Self.event("y", .expense, 10, from: "2026-06", .yearly)
        #expect(["2026-06", "2026-07", "2027-06", "2028-06", "2027-05"].map { Ledger.occurs(yearly, in: $0) } == [true, false, true, true, false])
    }

    @Test("Each month's change counts only switched-on events, this month first")
    func monthlyChanges() {
        let changes = Fixture.ledger().scenarioMonthlyChanges(Self.car, months: 5)
        #expect(changes == [.zero, .zero, Money(-450), Money(4550), Money(-450)])
    }

    @Test("A scenario shifts the forecast by its running total, keeps the plain one beside it, and leaves today's point alone")
    func projection() throws {
        let ledger = Fixture.ledger()
        let plain = ledger.projection(horizonMonths: 6, goal: nil)
        let p = ledger.projection(horizonMonths: 6, goal: nil, scenario: Self.car)
        let running = [0, 0, 0, -450, 4100, 3650, 3200].map { Money(Decimal($0)) }
        #expect(p.baseline == plain.projected)
        for (m, point) in p.projected.enumerated() {
            #expect(point.expected - plain.projected[m].expected == running[m])
            #expect(point.low - plain.projected[m].low == running[m])
            #expect(point.high - plain.projected[m].high == running[m])
        }
        #expect(p.endBalance == plain.endBalance + Money(3200))
        #expect(p.baselineEndBalance == plain.endBalance)
        #expect(p.scenarioEffect == Money(3200))
        #expect(p.scenarioID == "s1" && p.scenarioName == "Car and bonus")
        #expect(p.monthlyNet == plain.monthlyNet && p.history == plain.history)
        #expect(plain.scenarioID == nil && plain.baseline == nil)
    }

    @Test("A goal counts the scenario's changes in every month that starts before its date")
    func goal() throws {
        let ledger = Fixture.ledger()
        // Jan 1 2027: September through December land; January doesn't.
        let goal = GoalQuery(amount: Money(20_000), targetDate: Fixture.calendar.date(from: DateComponents(year: 2027, month: 1, day: 1))!)
        #expect(ledger.monthsStarting(before: goal.targetDate) == 4)
        let plain = try #require(ledger.projection(horizonMonths: 6, goal: goal).goal)
        let with = try #require(ledger.projection(horizonMonths: 6, goal: goal, scenario: Self.car).goal)
        #expect(with.projectedSavings == Money(minorUnits: max(0, plain.projectedSavings.minorUnits + 410_000)))
        #expect(with.scenarioID == "s1" && plain.scenarioID == nil)
        #expect(with.summary.hasPrefix("With “Car and bonus”, at your recent pace"))
        #expect(plain.summary.hasPrefix("At your recent pace"))
        #expect(with.monthlyNeeded == plain.monthlyNeeded)
        // A day into January, January's car payment lands too.
        let later = GoalQuery(amount: goal.amount, targetDate: goal.targetDate.addingTimeInterval(86_400))
        #expect(ledger.monthsStarting(before: later.targetDate) == 5)
    }

    @Test("The list compares each scenario's end with the plain forecast, as its projection does")
    func list() {
        var ledger = Fixture.ledger()
        let list = ledger.scenarioList(horizonMonths: 12)
        #expect(list.scenarios.map(\.id) == ["scn-car", "scn-bonus", "scn-move"])
        for scenario in list.scenarios {
            let p = ledger.projection(horizonMonths: 12, goal: nil, scenario: scenario)
            #expect(list.outcome(for: scenario.id)?.endBalance == p.endBalance)
            #expect(list.outcome(for: scenario.id)?.effect == p.scenarioEffect)
            #expect(list.baselineEnd == p.baselineEndBalance)
        }
        ledger.planScenarios = []
        #expect(ledger.scenarioList(horizonMonths: 12).outcomes.isEmpty)
    }

    @Test("The demo's scenarios all lie ahead, and the switched-off change adds nothing")
    func demo() throws {
        let ledger = Fixture.ledger()
        let current = ledger.monthKey(ledger.now)
        for event in ledger.planScenarios.flatMap(\.events) {
            #expect(try #require(PlanMonth.distance(from: current, to: event.startMonth)) > 0, "\(event.name)")
        }
        let move = try ledger.planScenario("scn-move")
        var on = move
        on.events = on.events.filter(\.isEnabled)
        #expect(ledger.scenarioMonthlyChanges(move, months: 24) == ledger.scenarioMonthlyChanges(on, months: 24))
        #expect(move.events.contains { !$0.isEnabled })
    }

    @Test("Saving creates or replaces a scenario, deleting removes it, and each undoes")
    func saveAndDelete() async throws {
        let api = Fixture.api()
        let draft = SavePlanScenario(scenarioID: "trip", name: "  Trip  ", events: [
            .init(name: "Flights", kind: .expense, amount: DecimalAmount(string: "1200")!, startMonth: "2027-04", cadence: .once),
        ])
        let preview = try await api.preview(.savePlanScenario(draft))
        #expect(preview.title == "Add the “Trip” scenario")
        #expect(preview.effects.first { $0.id == "difference" }?.value == Money(-1200))
        let added = try await api.perform(.savePlanScenario(draft))
        #expect(added.message == "Added “Trip”.")
        var list = try await api.scenarios(horizonMonths: 12)
        let trip = try #require(list.scenarios.last)
        #expect(trip.id == "trip" && trip.name == "Trip" && trip.events.first?.id.hasPrefix("evt-") == true)
        #expect(list.outcome(for: "trip")?.effect == Money(-1200))

        // Toggling a change off is a save of the whole scenario.
        var toggled = SavePlanScenario(trip)
        toggled.events[0].isEnabled = false
        let saved = try await api.perform(.savePlanScenario(toggled))
        #expect(saved.message == "Saved “Trip”.")
        #expect(try await api.scenarios(horizonMonths: 12).outcome(for: "trip")?.effect == .zero)
        _ = try await api.perform(try #require(saved.undo))
        #expect(try await api.scenarios(horizonMonths: 12).outcome(for: "trip")?.effect == Money(-1200))

        let deleted = try await api.perform(.deletePlanScenario(DeletePlanScenario(scenarioID: "trip")))
        #expect(deleted.message == "Deleted “Trip”.")
        #expect(try await api.scenarios(horizonMonths: 12).scenarios.contains { $0.id == "trip" } == false)
        _ = try await api.perform(try #require(deleted.undo))
        list = try await api.scenarios(horizonMonths: 12)
        #expect(list.scenarios.last == trip)

        _ = try await api.perform(try #require(added.undo))
        #expect(try await api.scenarios(horizonMonths: 12).scenarios.map(\.id) == ["scn-car", "scn-bonus", "scn-move"])
    }

    @Test("A projection against a scenario comes from the API; an unknown one is not found")
    func apiProjection() async throws {
        let api = Fixture.api()
        let p = try await api.projection(horizonMonths: 12, goal: nil, scenarioID: "scn-bonus")
        #expect(p.scenarioName == "Bonus and raise" && p.scenarioEffect.map { $0.minorUnits > 0 } == true)
        let plain = try await api.projection(horizonMonths: 12, goal: nil, scenarioID: nil)
        #expect(plain.scenarioID == nil && plain.endBalance == p.baselineEndBalance)
        await #expect(throws: BudgetAPIError.notFound) { try await api.projection(horizonMonths: 12, goal: nil, scenarioID: "nope") }
    }

    @Test("A scenario needs a name, real months, amounts above zero and an end no earlier than its start", arguments: [
        (SavePlanScenario(name: " "), "A scenario needs a name."),
        (SavePlanScenario(name: "New car"), "There's already a scenario called “New car”."),
        (SavePlanScenario(name: "X", events: [.init(name: "A", kind: .expense, amount: DecimalAmount(minorUnits: 0), startMonth: "2027-01", cadence: .once)]),
         "“A” needs an amount above zero."),
        (SavePlanScenario(name: "X", events: [.init(name: "A", kind: .expense, amount: DecimalAmount(minorUnits: 100), startMonth: "2027-13", cadence: .once)]),
         "A month is written like 2027-03."),
        (SavePlanScenario(name: "X", events: [.init(name: "A", kind: .expense, amount: DecimalAmount(minorUnits: 100), startMonth: "2027-05",
                                                    endMonth: "2027-04", cadence: .monthly)]), "“A” ends before it starts."),
        (SavePlanScenario(name: "X", events: [.init(name: "", kind: .income, amount: DecimalAmount(minorUnits: 100), startMonth: "2027-05", cadence: .once)]),
         "Each change needs a name, like “Car payment”."),
        (SavePlanScenario(name: "X", events: [.init(id: "has space", name: "A", kind: .income, amount: DecimalAmount(minorUnits: 100), startMonth: "2027-05", cadence: .once)]),
         "That isn't a change id."),
    ])
    func refused(draft: SavePlanScenario, message: String) {
        #expect(throws: BudgetAPIError.rejected(message)) { try Fixture.ledger().validatedScenario(draft) }
    }

    @Test("At most twelve scenarios")
    func limit() throws {
        var ledger = Fixture.ledger()
        for n in ledger.planScenarios.count..<Ledger.scenarioLimit { _ = try ledger.saveScenario(SavePlanScenario(name: "S\(n)")) }
        #expect(throws: BudgetAPIError.self) { try ledger.saveScenario(SavePlanScenario(name: "One more")) }
        // Replacing one that's there is still fine.
        _ = try ledger.saveScenario(SavePlanScenario(scenarioID: "scn-car", name: "Car", events: []))
        #expect(try ledger.planScenario("scn-car").name == "Car")
    }

    @Test("A one-time change drops its end month")
    func onceHasNoEnd() throws {
        let s = try Fixture.ledger().validatedScenario(SavePlanScenario(name: "X", events: [
            .init(name: "A", kind: .income, amount: DecimalAmount(minorUnits: 100), startMonth: "2027-05", endMonth: "2027-09", cadence: .once),
        ]))
        #expect(s.events[0].endMonth == nil)
    }

    @Test("Scenarios round-trip with the ledger; older stored JSON and newer kinds still decode")
    func decoding() throws {
        let state = Fixture.ledger().state
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(LedgerState.self, from: data).planScenarios == state.planScenarios)
        // A ledger saved before scenarios.
        guard case var .object(fields) = try JSONValue.parse(data) else { Issue.record("not an object"); return }
        fields["planScenarios"] = nil
        #expect(try JSONDecoder().decode(LedgerState.self, from: JSONValue.object(fields).data()).planScenarios.isEmpty)
        // An event without the later fields, and a cadence and kind from a newer version.
        let event = try JSONDecoder().decode(PlanEvent.self, from: Data(#"{"id":"e","name":"E","kind":"gift","amount":{"minor":100,"currency":"USD"},"startMonth":"2027-01","cadence":"fortnightly"}"#.utf8))
        #expect(event.kind == .expense && event.cadence == .once && event.isEnabled && event.endMonth == nil)
        // A projection from a server before 0.5.0.
        let old = try RemoteBudgetAPI.decoder.decode(Projection.self, from: Data(#"{"horizonMonths":3,"history":[],"projected":[],"monthlyNet":{"minor":0,"currency":"USD"},"endBalance":{"minor":0,"currency":"USD"}}"#.utf8))
        #expect(old.scenarioID == nil && old.baseline == nil && old.scenarioEffect == nil)
        // The actions travel on the wire and aren't assistant tools.
        for action in [AppAction.savePlanScenario(SavePlanScenario(state.planScenarios[0])), .deletePlanScenario(DeletePlanScenario(scenarioID: "scn-car"))] {
            #expect(try JSONDecoder().decode(AppAction.self, from: JSONEncoder().encode(action)) == action)
            #expect(ToolCatalog.spec(named: action.toolName) == nil)
        }
    }

    @Test("An event reads as a sentence")
    func summary() {
        let c = Fixture.calendar
        #expect(Self.event("a", .expense, 450, from: "2027-03", .monthly).summary(calendar: c) == "$450 a month from March 2027")
        #expect(Self.event("b", .income, 5000, from: "2026-12", .once).summary(calendar: c) == "$5,000 in December 2026")
        #expect(Self.event("c", .expense, 180.5, from: "2027-06", to: "2029-06", .yearly).summary(calendar: c) == "$180.50 a year from June 2027 to June 2029")
    }

    @Test("Ask reads scenarios through planScenarios, grounded in the ledger's figures")
    func ask() async throws {
        let reply = try await Fixture.api().ask("What if scenarios do I have?", conversationID: nil)
        #expect(reply.toolCalls.first?.name == "planScenarios")
        for call in reply.toolCalls {
            try ToolCatalog.validateArguments(tool: call.name, json: Data(call.arguments.utf8))
        }
        #expect(reply.text.contains("New car"))
        #expect(Grounding.ungroundedAmounts(in: reply.text, allowed: reply.figures.map(\.value)).isEmpty, "\(reply.text)")

        let toolbox = DemoToolbox(ledger: Fixture.ledger(), decisions: nil)
        let goal = GoalQuery(amount: Money(8000), targetDate: Fixture.calendar.date(from: DateComponents(year: 2027, month: 6, day: 30))!)
        let out = try toolbox.planScenarios(scenarioID: "scn-car", horizon: 12, goal: goal)
        guard case let .object(o) = out.result, case let .object(g)? = o["goal"], case let .array(months)? = (o["projection"].flatMap { if case let .object(p) = $0 { p["months"] } else { nil } }) else {
            Issue.record("no projection or goal"); return
        }
        #expect(months.count == 12)
        #expect(g["scenario"] == .string("New car"))
        #expect(out.figures.contains { $0.id == "goal-saved" })
    }

    @Test("projectBalance takes a scenario: its end, the plain forecast's and the difference are the projection's")
    func projectBalanceTool() async throws {
        let ledger = Fixture.ledger()
        let toolbox = DemoToolbox(ledger: ledger, decisions: nil)
        func run(_ json: String) async throws -> (result: JSONValue, figures: [Figure]) {
            try await toolbox.run(read: "projectBalance", arguments: try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
        }
        let goal = #"{"amount": "8000", "targetDate": "2027-06-30"}"#
        let args = #"{"account": "cash", "horizonMonths": 12, "scenarioID": "scn-car", "goal": \#(goal)}"#
        try ToolCatalog.validateArguments(tool: "projectBalance", json: Data(args.utf8))
        let out = try await run(args)
        let p = ledger.projection(horizonMonths: 12, goal: nil, scenario: try ledger.planScenario("scn-car"))
        guard case let .object(o) = out.result else { Issue.record("not an object"); return }
        #expect(o["scenario"] == .string("New car"))
        #expect(o["projectedEnd"] == .string(p.endBalance.display))
        #expect(o["plainForecastEnd"] == .string(p.baselineEndBalance!.display))
        #expect(o["differenceFromPlainForecast"] == .string(p.scenarioEffect!.display))
        #expect(out.figures.contains { $0.id == "scenario-effect" && $0.value == p.scenarioEffect })
        guard case let .object(g)? = o["goal"] else { Issue.record("no goal"); return }
        let check = ledger.projection(horizonMonths: 12, goal: GoalQuery(amount: Money(8000), targetDate: Fixture.calendar.date(from: DateComponents(year: 2027, month: 6, day: 30))!),
                                      scenario: try ledger.planScenario("scn-car")).goal!
        #expect(check.scenarioID == "scn-car" && g["projectedSavings"] == .string(check.projectedSavings.display))

        // Without one it's the plain forecast, as before.
        let plain = try await run(#"{"account": "cash", "horizonMonths": 12}"#)
        guard case let .object(po) = plain.result else { Issue.record("not an object"); return }
        #expect(po["scenario"] == nil && po["projectedEnd"] == .string(p.baselineEndBalance!.display))
        await #expect(throws: BudgetAPIError.notFound) { try await run(#"{"account": "cash", "horizonMonths": 12, "scenarioID": "nope"}"#) }
    }
}
