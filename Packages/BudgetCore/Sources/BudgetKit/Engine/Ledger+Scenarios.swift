import Foundation

// Plan's "what if": scenarios of planned changes (a car payment, a bonus, a rent rise) laid over the forecast.
//
// The forecast carries cash after cards forward at the recent pace of income less spending (`projection`). A scenario
// adds each of its switched-on changes in the month it happens: the point `m` months out includes this month and the
// `m − 1` after it, as the pace does. A goal counts every month that starts before its date. Nothing here guesses:
// the changes are the person's, the pace is the ledger's.

extension Ledger {
    static let scenarioLimit = 12
    static let scenarioEventLimit = 24
    static let scenarioNameLimit = 60

    // MARK: Reading

    func planScenario(_ id: String) throws -> PlanScenario {
        guard let scenario = planScenarios.first(where: { $0.id == id }) else { throw BudgetAPIError.notFound }
        return scenario
    }

    /// Whether `event` happens in the month `key` ("2027-03").
    static func occurs(_ event: PlanEvent, in key: String) -> Bool {
        guard let since = PlanMonth.distance(from: event.startMonth, to: key), since >= 0 else { return false }
        switch event.cadence {
        case .once: return since == 0
        case .monthly: break
        case .yearly: guard since % 12 == 0 else { return false }
        }
        if let end = event.endMonth, let past = PlanMonth.distance(from: end, to: key), past > 0 { return false }
        return true
    }

    /// What the scenario's switched-on changes do to cash in each of `count` months, this one first.
    func scenarioMonthlyChanges(_ scenario: PlanScenario, months count: Int) -> [Money] {
        let current = monthKey(now)
        let events = scenario.events.filter(\.isEnabled)
        return (0..<max(count, 0)).map { offset in
            guard let key = PlanMonth.adding(offset, to: current) else { return .zero }
            return events.filter { Self.occurs($0, in: key) }.map(\.signedAmount).sum()
        }
    }

    /// How many months, this one first, start before `date`: the months whose changes land by then.
    func monthsStarting(before date: Date) -> Int {
        guard let start = calendar.dateInterval(of: .month, for: date)?.start else { return 0 }
        let whole = calendar.dateComponents([.month], from: startOfMonth, to: start).month ?? 0
        return max(0, whole + (date > start ? 1 : 0))
    }

    // MARK: Projection

    /// The forecast with `scenario`'s changes on top, beside the plain one; the plain forecast when there's none.
    func projection(horizonMonths: Int, goal: GoalQuery?, scenario: PlanScenario?) -> Projection {
        guard let scenario else { return projection(horizonMonths: horizonMonths, goal: goal) }
        var p = projection(horizonMonths: horizonMonths, goal: nil)
        let baseline = p.projected
        let changes = scenarioMonthlyChanges(scenario, months: p.horizonMonths)
        var running = Money.zero
        p.projected = baseline.enumerated().map { m, point in
            if m > 0 { running = running + changes[m - 1] }
            return ProjectedPoint(date: point.date, expected: point.expected + running, low: point.low + running, high: point.high + running)
        }
        p.endBalance = p.projected.last!.expected
        p.scenarioID = scenario.id
        p.scenarioName = scenario.name
        p.baseline = baseline
        p.baselineEndBalance = baseline.last!.expected
        p.scenarioEffect = p.endBalance - baseline.last!.expected
        if let goal { p.goal = goalCheck(goal, pace: spendingPace().mean, scenario: scenario) }
        return p
    }

    /// Whether `goal` fits at the recent pace (`mean`, minor units a month), with a scenario's changes when there is one.
    func goalCheck(_ goal: GoalQuery, pace mean: Double, scenario: PlanScenario?) -> GoalCheck {
        let months = max(goal.targetDate.timeIntervalSince(now) / (30.436875 * 86_400), 0.5)
        let effect = scenario.map { scenarioMonthlyChanges($0, months: monthsStarting(before: goal.targetDate)).sum() } ?? .zero
        let saved = Money(minorUnits: max(0, Int64((mean * months).rounded()) + effect.minorUnits))
        let shortfall = Money(minorUnits: max(0, goal.amount.minorUnits - saved.minorUnits))
        let needed = Money(minorUnits: Int64((Double(goal.amount.minorUnits) / months).rounded()))
        let onTrack = shortfall.minorUnits == 0
        let dateText = goal.targetDate.formatted(.dateTime.month(.wide).year())
        let lead = scenario.map { "With “\($0.name)”, at your recent pace" } ?? "At your recent pace"
        let summary = onTrack
            ? "\(lead) you'd set aside \(saved.formatted(fractionDigits: 0)) by \(dateText) — enough for \(goal.amount.formatted(fractionDigits: 0))."
            : "\(lead) you'd set aside \(saved.formatted(fractionDigits: 0)) by \(dateText), \(shortfall.formatted(fractionDigits: 0)) short. Setting aside \(needed.formatted(fractionDigits: 0)) a month closes the gap."
        return GoalCheck(query: goal, projectedSavings: saved, isOnTrack: onTrack, shortfall: shortfall, monthlyNeeded: needed, summary: summary,
                         scenarioID: scenario?.id)
    }

    /// Every scenario with where it leaves cash after cards at the end of the horizon, against the plain forecast.
    func scenarioList(horizonMonths: Int) -> ScenarioList {
        let base = projection(horizonMonths: horizonMonths, goal: nil)
        let outcomes = planScenarios.map { scenario in
            let effect = scenarioMonthlyChanges(scenario, months: base.horizonMonths).sum()
            return ScenarioList.Outcome(scenarioID: scenario.id, endBalance: base.endBalance + effect, effect: effect)
        }
        return ScenarioList(horizonMonths: base.horizonMonths, baselineEnd: base.endBalance, scenarios: planScenarios, outcomes: outcomes)
    }

    // MARK: Changing

    /// The scenario `p` describes, checked: a name, at most 24 changes, each with a name, an amount above zero and real
    /// months (an end no earlier than the start). A change or scenario without an id gets a new one.
    func validatedScenario(_ p: SavePlanScenario) throws -> PlanScenario {
        let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw BudgetAPIError.rejected("A scenario needs a name.") }
        guard name.count <= Self.scenarioNameLimit else { throw BudgetAPIError.rejected("Keep the scenario's name to \(Self.scenarioNameLimit) characters.") }
        if let id = p.scenarioID {
            guard (1...64).contains(id.count), !id.contains(where: \.isWhitespace) else { throw BudgetAPIError.rejected("That isn't a scenario id.") }
        }
        let existing = p.scenarioID.flatMap { id in planScenarios.first { $0.id == id } }
        if existing == nil, planScenarios.count >= Self.scenarioLimit {
            throw BudgetAPIError.rejected("You can keep up to \(Self.scenarioLimit) scenarios. Delete one to add another.")
        }
        if planScenarios.contains(where: { $0.id != p.scenarioID && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw BudgetAPIError.rejected("There's already a scenario called “\(name)”.")
        }
        guard p.events.count <= Self.scenarioEventLimit else {
            throw BudgetAPIError.rejected("A scenario holds up to \(Self.scenarioEventLimit) changes.")
        }
        var ids: Set<String> = []
        let events = try p.events.map { e -> PlanEvent in
            let label = e.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { throw BudgetAPIError.rejected("Each change needs a name, like “Car payment”.") }
            guard label.count <= Self.scenarioNameLimit else { throw BudgetAPIError.rejected("Keep “\(label.prefix(20))…” to \(Self.scenarioNameLimit) characters.") }
            guard e.amount.minorUnits > 0 else { throw BudgetAPIError.rejected("“\(label)” needs an amount above zero.") }
            guard PlanMonth.parse(e.startMonth) != nil else { throw BudgetAPIError.rejected("A month is written like 2027-03.") }
            let end = e.cadence == .once ? nil : e.endMonth
            if let last = end {
                guard let span = PlanMonth.distance(from: e.startMonth, to: last) else { throw BudgetAPIError.rejected("A month is written like 2027-03.") }
                guard span >= 0 else { throw BudgetAPIError.rejected("“\(label)” ends before it starts.") }
            }
            let id = e.id ?? Self.newPlanID("evt")
            guard ids.insert(id).inserted else { throw BudgetAPIError.rejected("Two changes share the id \(id).") }
            return PlanEvent(id: id, name: label, kind: e.kind, amount: e.amount.money(), startMonth: e.startMonth, endMonth: end,
                             cadence: e.cadence, isEnabled: e.isEnabled ?? true)
        }
        return PlanScenario(id: p.scenarioID ?? Self.newPlanID("scn"), name: name, events: events)
    }

    static func newPlanID(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    func scenarioPreview(_ p: SavePlanScenario) throws -> ActionPreview {
        let scenario = try validatedScenario(p)
        let isNew = p.scenarioID.map { id in !planScenarios.contains { $0.id == id } } ?? true
        let horizon = 12
        let base = projection(horizonMonths: horizon, goal: nil)
        let effect = scenarioMonthlyChanges(scenario, months: base.horizonMonths).sum()
        let on = scenario.events.filter(\.isEnabled).count
        return ActionPreview(
            title: isNew ? "Add the “\(scenario.name)” scenario" : "Save the “\(scenario.name)” scenario",
            detail: scenario.events.isEmpty ? "No changes yet." : "\(on) of \(scenario.events.count) change\(scenario.events.count == 1 ? "" : "s") on.",
            effects: [Figure(id: "with", label: "Cash after cards in \(horizon) months, with it", detail: nil, value: base.endBalance + effect),
                      Figure(id: "without", label: "Without it", detail: nil, value: base.endBalance),
                      Figure(id: "difference", label: "Difference", detail: nil, value: effect)])
    }

    func scenarioPreview(_ p: DeletePlanScenario) throws -> ActionPreview {
        let scenario = try planScenario(p.scenarioID)
        return ActionPreview(title: "Delete the “\(scenario.name)” scenario",
                             detail: "\(scenario.events.count) change\(scenario.events.count == 1 ? "" : "s") go with it. The forecast itself doesn't change.",
                             effects: [])
    }

    mutating func saveScenario(_ p: SavePlanScenario) throws -> ActionResult {
        let scenario = try validatedScenario(p)
        if let index = planScenarios.firstIndex(where: { $0.id == scenario.id }) {
            let before = planScenarios[index]
            planScenarios[index] = scenario
            return ActionResult(message: "Saved “\(scenario.name)”.", undo: .savePlanScenario(SavePlanScenario(before)))
        }
        planScenarios.append(scenario)
        return ActionResult(message: "Added “\(scenario.name)”.", undo: .deletePlanScenario(DeletePlanScenario(scenarioID: scenario.id)))
    }

    mutating func deleteScenario(_ p: DeletePlanScenario) throws -> ActionResult {
        let scenario = try planScenario(p.scenarioID)
        planScenarios.removeAll { $0.id == scenario.id }
        return ActionResult(message: "Deleted “\(scenario.name)”.", undo: .savePlanScenario(SavePlanScenario(scenario)))
    }
}
