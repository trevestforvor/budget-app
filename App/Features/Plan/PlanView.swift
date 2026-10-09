import BudgetKit
import DesignSystem
import SwiftUI

/// Multi-month projection and "can I afford X by Y". The server's `projectBalance` does the math.
struct PlanView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var horizon = 6
    @State private var state: LoadState<Projection> = .loading
    @State private var goalAmount: Decimal = 5000
    @State private var goalDate = Calendar.current.date(byAdding: .month, value: 6, to: AppClock.now)!
    @State private var goalCheck: GoalCheck?
    @State private var isChecking = false
    @State private var savings: SavingsPlan?
    @State private var editsSavings = false
    /// The scenario laid over the forecast; nil is the plain forecast. Remembered on this phone.
    @AppStorage("plan.scenario") private var scenarioID: String?
    /// Nil until loaded, and on a server without scenarios.
    @State private var scenarios: ScenarioList?
    @State private var scenarioEdit: ScenarioEdit?
    @State private var eventEdit: EventEdit?

    private struct ScenarioEdit: Identifiable {
        var scenario: PlanScenario?
        var id: String { scenario?.id ?? "new" }
    }

    private struct EventEdit: Identifiable {
        var scenario: PlanScenario
        var event: PlanEvent?
        var id: String { "\(scenario.id)/\(event?.id ?? "new")" }
    }

    private var selectedScenario: PlanScenario? { scenarios?.scenarios.first { $0.id == scenarioID } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpace.xl) {
                    PageTitle("Plan", eyebrow: "Forecast")
                    // Scrolls sideways rather than breaking a word when large text won't fit three chips.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DSSpace.xs) {
                            ForEach([3, 6, 12], id: \.self) { months in
                                DSChip("\(months) months", isSelected: horizon == months) { horizon = months }
                                    .fixedSize()
                            }
                        }
                    }
                    .contentMargins(.horizontal, DSSpace.gutter, for: .scrollContent)
                    .padding(.horizontal, -DSSpace.gutter)
                    if let scenarios {
                        ScenarioPicker(list: scenarios, selection: $scenarioID) { scenarioEdit = ScenarioEdit(scenario: nil) }
                    }
                    switch state {
                    case .loading:
                        LoadingPlaceholder(text: "Projecting…")
                    case let .failed(message):
                        DSStateView(systemImage: "wifi.slash", title: "Can't project", message: message, actionTitle: "Try again") {
                            Task { await load() }
                        }
                    case let .loaded(projection):
                        projectionSection(projection)
                    }
                    if let scenarios {
                        ScenarioCard(list: scenarios, scenario: selectedScenario, selection: $scenarioID,
                                     onEditEvent: { eventEdit = EventEdit(scenario: $0, event: $1) },
                                     onEditScenario: { scenarioEdit = ScenarioEdit(scenario: $0) },
                                     onNew: { scenarioEdit = ScenarioEdit(scenario: nil) })
                    }
                    if let savings {
                        if let history = savings.history, history.count > 1 { CashFlowCard(plan: savings, history: history) }
                        savingsCard(savings)
                    }
                    goalCard
                }
                .padding(.horizontal, DSSpace.gutter)
                .padding(.bottom, DSSpace.xxl)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .dsScreenBackground(bloom: .data)
            .scrollDismissesKeyboard(.interactively)
            .reloadable(button: false) { await load() }
            .toolbarVisibility(.hidden, for: .navigationBar)
        }
        .onChange(of: app.planHorizon, initial: true) {
            if let months = app.planHorizon {
                horizon = months
                app.planHorizon = nil
            }
        }
        .task(id: "\(horizon)|\(scenarioID ?? "")|\(app.revision)") { await load() }
        .onChange(of: scenarioID) { goalCheck = nil }
        .sheet(isPresented: $editsSavings) { MonthlySavingsSheet(current: savings?.plannedSavings, suggested: savings?.twentyPercentOfIncome) }
        .sheet(item: $scenarioEdit) { edit in
            ScenarioSheet(scenario: edit.scenario) { saved in scenarioID = saved }
        }
        .sheet(item: $eventEdit) { PlanEventSheet(scenario: $0.scenario, event: $0.event) }
    }

    @discardableResult
    private func load() async -> String? {
        let api = app.api
        let horizon = horizon
        let first = state.isLoading
        let scenarioID = scenarioID
        let planning = api as? any PlanScenariosAPI
        if scenarioID == nil { state = await state.orSaved(.projection(horizonMonths: horizon), app) }
        if savings == nil { savings = await app.saved(.savings) }
        if scenarios == nil { scenarios = await app.saved(.scenarios(horizonMonths: horizon)) }
        async let plan = try? api.savingsPlan()
        // A server before 0.5.0 has no scenarios: the list is a 404 and the picker stays away.
        let list = Task { try? await planning?.scenarios(horizonMonths: horizon) }
        let updating = app.beginUpdating(showingSaved: first && state.value != nil)
        let (next, error) = await state.refreshing {
            if let scenarioID, let planning { try await planning.projection(horizonMonths: horizon, goal: nil, scenarioID: scenarioID) }
            else { try await api.projection(horizonMonths: horizon, goal: nil) }
        }
        app.endUpdating(updating)
        state = next
        savings = await plan
        scenarios = await list.value
        // A scenario deleted elsewhere falls back to the plain forecast.
        if let id = self.scenarioID, let scenarios, !scenarios.scenarios.contains(where: { $0.id == id }) { self.scenarioID = nil }
        return error
    }

    @ViewBuilder
    private func projectionSection(_ projection: Projection) -> some View {
        // No complete month to take a pace from (a new ledger): say so, rather than "grows about $0" in a made-up range.
        let hasPace = projection.monthlyNet.minorUnits != 0
        // A server from before 0.3.1 projects cash alone, at the pace cash itself moved.
        let afterCards = projection.cardsOwed != nil
        let pace = projection.monthlyNet.magnitude.formatted(fractionDigits: 0)
        DSHeroAmount(
            label: afterCards ? "Cash after cards · in \(projection.horizonMonths) months" : "Projected cash · \(projection.horizonMonths) months",
            value: projection.endBalance.decimal,
            currencyCode: projection.endBalance.currencyCode,
            caption: projection.scenarioName.map { Self.scenarioCaption($0, effect: projection.scenarioEffect ?? .zero, months: projection.horizonMonths) }
                ?? (!hasPace ? "Not enough history to project a pace yet"
                : afterCards
                ? (projection.monthlyNet.isNegative ? "Spending ran about \(pace) a month over income — the last three months"
                                                    : "Income beat spending by about \(pace) a month — the last three months")
                : projection.monthlyNet.isNegative
                ? "Cash shrinks about \(pace) a month — the last three months' pace"
                : "Cash grows about \(pace) a month — the last three months' pace"),
            captionTint: projection.scenarioName == nil && projection.monthlyNet.isNegative ? Color.ds.caution : Color.ds.inkSecondary
        )
        DSCard(padding: DSSpace.md) {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                DSLineChart(
                    actual: projection.history.map(\.chartPoint),
                    projected: projection.projected.map { DSChartPoint(date: $0.date, value: $0.expected.doubleValue) },
                    band: hasPace ? projection.projected.map { DSBandPoint(date: $0.date, low: $0.low.doubleValue, high: $0.high.doubleValue) } : [],
                    style: .full,
                    comparison: (projection.baseline ?? []).map { DSChartPoint(date: $0.date, value: $0.expected.doubleValue) },
                    accessibilitySummary: "\(afterCards ? "Cash after cards" : "Cash"), history and projection, ending near \(projection.endBalance.formatted(fractionDigits: 0))"
                        + (projection.baselineEndBalance.map { ", against \($0.formatted(fractionDigits: 0)) without the scenario" } ?? "")
                )
                .frame(height: 220)
                // Side by side, wrapping onto a second line when they don't fit; one per line at large text sizes.
                let legends = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: DSSpace.xs))
                                                                  : AnyLayout(DSFlowLayout(spacing: DSSpace.md, lineSpacing: DSSpace.xs))
                legends {
                    legend("Actual", color: Color.ds.accent)
                    legend(projection.scenarioName ?? "Projected", color: Color.ds.iris)
                    if projection.baseline != nil { legend("Plain forecast", color: Color.ds.inkTertiary) }
                    if hasPace { legend("Likely range", color: Color.ds.iris.opacity(0.35)) }
                }
                if let owed = projection.cardsOwed, owed.minorUnits > 0 {
                    Text("Your cash less the \(owed.formatted(fractionDigits: 0)) owed on cards, so paying a card bill doesn't move it. A yearly charge counts a twelfth a month.")
                        .dsFont(.caption)
                        .foregroundStyle(Color.ds.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// "New car: $6,240 less than the plain forecast in 12 months".
    static func scenarioCaption(_ name: String, effect: Money, months: Int) -> String {
        guard effect.minorUnits != 0 else { return "\(name): the same as the plain forecast in \(months) months" }
        return "\(name): \(effect.magnitude.formatted(fractionDigits: 0)) \(effect.isNegative ? "less" : "more") than the plain forecast in \(months) months"
    }

    private func legend(_ label: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Capsule().fill(color).frame(width: 14, height: 3)
            Text(label).dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
        }
    }

    /// "How much can I save / should I save" — ledger math plus sourced rules of thumb.
    private func savingsCard(_ s: SavingsPlan) -> some View {
        DSCard {
            VStack(alignment: .leading, spacing: DSSpace.md) {
                DSEyebrow("Savings", dot: Color.ds.accent)
                let stats = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: DSSpace.md))
                                                                : AnyLayout(HStackLayout(alignment: .top, spacing: DSSpace.md))
                stats {
                    DSStatBlock(label: "Can save / mo", value: s.canSaveTypical.decimal,
                                footnote: "up to \(s.canSaveStretch.formatted(fractionDigits: 0)) at a lean month", tint: Color.ds.inflow)
                    DSStatBlock(label: "Saved first", value: s.plannedSavings.decimal,
                                footnote: s.plannedSavingsIsSet ? "your plan" : "from your transfers")
                }
                DSDivider()
                DSFigureRow(label: "Emergency fund", detail: String(format: "Cash covers %.1f months of essentials · rule: 3–6 months", s.monthsCovered),
                            value: s.emergencyTargetLow.decimal)
                DSFigureRow(label: "20% of take-home", detail: "50/30/20 rule", value: s.twentyPercentOfIncome.decimal)
                Button(s.plannedSavingsIsSet ? "Change monthly savings" : "Set monthly savings") { editsSavings = true }
                    .buttonStyle(.ds(.secondary))
                DSToolTrace(name: "savingsCapacity · savingsGuidance")
            }
        }
    }

    private var goalCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: DSSpace.md) {
                DSEyebrow("Can I afford it?", dot: Color.ds.iris)
                Text("Set aside").dsFont(.headline).foregroundStyle(Color.ds.ink)
                DSAmountField(currencySymbol: nil, style: .amount, alignment: .leading) {
                    TextField("Amount", value: $goalAmount, format: .currency(code: "USD").precision(.fractionLength(0)))
                        .keyboardType(.decimalPad)
                }
                DatePicker("By", selection: $goalDate, in: AppClock.now.addingTimeInterval(86_400)..., displayedComponents: .date)
                    .dsFont(.body)
                    .foregroundStyle(Color.ds.inkSoft)
                Button(isChecking ? "Checking…" : "Check with the ledger") { Task { await checkGoal() } }
                    .buttonStyle(.ds(.primary, fullWidth: true))
                    .disabled(isChecking || goalAmount <= 0)

                if let goalCheck { goalResult(goalCheck) }
            }
        }
    }

    @ViewBuilder
    private func goalResult(_ check: GoalCheck) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            DSDivider()
            DSTag(check.isOnTrack ? "On track" : "Short", systemImage: check.isOnTrack ? "checkmark" : "exclamationmark",
                  tint: check.isOnTrack ? Color.ds.accent : Color.ds.caution)
            Text(check.summary).dsFont(.callout).foregroundStyle(Color.ds.inkSoft).fixedSize(horizontal: false, vertical: true)
            DSFigureRow(label: "Projected by then", value: check.projectedSavings.decimal)
            if !check.isOnTrack { DSFigureRow(label: "Shortfall", value: check.shortfall.decimal) }
            DSFigureRow(label: "Needed per month", value: check.monthlyNeeded.decimal)
            DSToolTrace(name: check.scenarioID == nil ? "projectBalance" : "planScenarios",
                        arguments: "goal: \(check.query.amount.formatted(fractionDigits: 0))" + (selectedScenario.map { " · \($0.name)" } ?? ""))
        }
    }

    private func checkGoal() async {
        isChecking = true
        defer { isChecking = false }
        let api = app.api
        let query = GoalQuery(amount: Money(goalAmount), targetDate: goalDate)
        let months = max(horizon, (Calendar.current.dateComponents([.month], from: AppClock.now, to: goalDate).month ?? 0) + 1)
        // Against the scenario on the chart, when there is one.
        if let scenarioID, let planning = api as? any PlanScenariosAPI {
            goalCheck = (try? await planning.projection(horizonMonths: months, goal: query, scenarioID: scenarioID))?.goal
        } else if let projection = try? await api.projection(horizonMonths: months, goal: query) {
            goalCheck = projection.goal
        }
    }
}

/// Pay yourself first: the monthly amount set aside before the flex number.
struct MonthlySavingsSheet: View {
    let current: Money?
    let suggested: Money?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var amount: Decimal = 0
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DSSpace.lg) {
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    DSEyebrow("Pay yourself first")
                    Text("Monthly savings").dsFont(.display).foregroundStyle(Color.ds.ink)
                }
                DSAmountField(currencySymbol: nil, alignment: .leading) {
                    TextField("Amount", value: $amount, format: .currency(code: "USD").precision(.fractionLength(0...2)))
                        .keyboardType(.decimalPad)
                }
                if let suggested {
                    Button("Use 20% of take-home (\(suggested.formatted(fractionDigits: 0)))") { amount = suggested.decimal }
                        .buttonStyle(.ds(.quiet))
                }
                Text("This comes off the top; safe to spend is what's left after bills and subscriptions.")
                    .dsFont(.caption).foregroundStyle(Color.ds.inkTertiary)
                if let errorMessage { Text(errorMessage).dsFont(.callout).foregroundStyle(Color.ds.caution) }
                Spacer()
                Button(isSaving ? "Saving…" : "Save plan") { Task { await save() } }
                    .buttonStyle(.ds(.primary, size: .large, fullWidth: true))
                    .disabled(isSaving || amount <= 0)
            }
            .padding(DSSpace.gutter)
            .dsScreenBackground()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.ds.canvas)
        .onAppear { amount = current?.decimal ?? 0 }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await app.perform(.setMonthlySavings(SetMonthlySavings(monthlyAmount: DecimalAmount(Money(amount)))))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
