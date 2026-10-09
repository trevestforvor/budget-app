import BudgetKit
import DesignSystem
import SwiftUI

// Plan's "what if": pick a scenario to lay over the forecast, switch its changes on and off, and edit them. Every
// change goes through `app.perform` as a `savePlanScenario` / `deletePlanScenario` action; the ledger does the math.

/// The plain forecast, then each scenario, then a chip to make one.
struct ScenarioPicker: View {
    let list: ScenarioList
    @Binding var selection: String?
    let onNew: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSSpace.xs) {
                DSChip("Plain forecast", isSelected: selection == nil) { select(nil) }
                    .fixedSize()
                ForEach(list.scenarios) { scenario in
                    DSChip(scenario.name, systemImage: "wand.and.stars", isSelected: selection == scenario.id) { select(scenario.id) }
                        .fixedSize()
                }
                if list.scenarios.count < 12 {
                    DSChip("New scenario", systemImage: "plus", action: onNew)
                        .fixedSize()
                        .accessibilityIdentifier("newScenario")
                }
            }
        }
        .contentMargins(.horizontal, DSSpace.gutter, for: .scrollContent)
        .padding(.horizontal, -DSSpace.gutter)
        .accessibilityIdentifier("scenarioPicker")
    }

    private func select(_ id: String?) {
        withAnimation(DSMotion.standard) { selection = id }
    }
}

/// The chosen scenario's changes, each switchable, and how every scenario compares with the plain forecast.
struct ScenarioCard: View {
    let list: ScenarioList
    let scenario: PlanScenario?
    @Binding var selection: String?
    let onEditEvent: (PlanScenario, PlanEvent?) -> Void
    let onEditScenario: (PlanScenario) -> Void
    let onNew: () -> Void
    @Environment(AppModel.self) private var app
    @State private var problem: String?
    @State private var busy = false

    var body: some View {
        DSCard {
            VStack(alignment: .leading, spacing: DSSpace.md) {
                if let scenario {
                    header(scenario)
                    if scenario.events.isEmpty {
                        Text("No changes yet. Add the ones you expect: a car payment, a bonus, a rent rise.")
                            .dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(scenario.events.enumerated()), id: \.element.id) { index, event in
                                if index > 0 { DSDivider() }
                                eventRow(event, in: scenario)
                            }
                        }
                    }
                    if scenario.events.count < 24 {
                        Button("Add a change") { onEditEvent(scenario, nil) }
                            .buttonStyle(.ds(.secondary, fullWidth: true))
                            .accessibilityIdentifier("addPlanEvent")
                    }
                    if let problem {
                        Text(problem).dsFont(.callout).foregroundStyle(Color.ds.caution).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    DSEyebrow("What if", dot: Color.ds.iris)
                    Text(list.scenarios.isEmpty ? "Plan for changes you can see coming" : "Compare your scenarios")
                        .dsFont(.headline).foregroundStyle(Color.ds.ink)
                    Text(list.scenarios.isEmpty
                         ? "A scenario is a set of changes — a new car payment from March, a bonus in December, rent up $200 from June — laid over the forecast."
                         : "Where each leaves cash after cards in \(list.horizonMonths) months. Pick one to see it on the chart.")
                        .dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if list.scenarios.isEmpty {
                        Button("Make a scenario", action: onNew)
                            .buttonStyle(.ds(.secondary, fullWidth: true))
                    }
                }
                if !list.scenarios.isEmpty { comparison }
            }
        }
        .announcesProblem(problem)
        .accessibilityIdentifier("scenarioCard")
    }

    private func header(_ scenario: PlanScenario) -> some View {
        HStack(alignment: .center, spacing: DSSpace.sm) {
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                DSEyebrow("Scenario", dot: Color.ds.iris)
                Text(scenario.name).dsFont(.headline).foregroundStyle(Color.ds.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DSSpace.xs)
            DSIconButton(systemImage: "pencil", label: "Rename or delete \(scenario.name)") { onEditScenario(scenario) }
        }
    }

    private func eventRow(_ event: PlanEvent, in scenario: PlanScenario) -> some View {
        HStack(spacing: DSSpace.sm) {
            Button { onEditEvent(scenario, event) } label: {
                HStack(spacing: DSSpace.sm) {
                    DSGlyph(systemImage: event.kind == .income ? "arrow.down" : "arrow.up", tone: event.kind == .income ? .cyan : .orchid)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.name).dsFont(.body)
                            .foregroundStyle(event.isEnabled ? Color.ds.ink : Color.ds.inkSecondary)
                        Text(event.summary()).dsFont(.caption)
                            .foregroundStyle(event.isEnabled ? Color.ds.inkSecondary : Color.ds.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: DSSpace.xs)
                    Text(event.kind == .income ? "+\(event.amount.formatted(fractionDigits: 0))" : event.amount.formatted(fractionDigits: 0))
                        .dsFont(.amountRow)
                        .foregroundStyle(!event.isEnabled ? Color.ds.inkTertiary : event.kind == .income ? Color.ds.inflow : Color.ds.ink)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edits this change")
            Toggle(isOn: Binding(get: { event.isEnabled }, set: { on in Task { await toggle(event, in: scenario, on: on) } })) {
                Text("Count \(event.name)")
            }
            .labelsHidden()
            .tint(Color.ds.accent)
            .disabled(busy)
        }
        .padding(.vertical, DSSpace.sm)
        .frame(minHeight: DSSize.listRow)
    }

    private var comparison: some View {
        VStack(alignment: .leading, spacing: 0) {
            DSDivider().padding(.bottom, DSSpace.xs)
            DSEyebrow("In \(list.horizonMonths) months")
                .padding(.bottom, DSSpace.xxs)
            row(title: "Plain forecast", detail: nil, value: list.baselineEnd, isSelected: selection == nil) { selection = nil }
            ForEach(list.scenarios) { scenario in
                if let outcome = list.outcome(for: scenario.id) {
                    let gap = outcome.effect.minorUnits == 0 ? "Same as the plain forecast"
                        : "\(outcome.effect.magnitude.formatted(fractionDigits: 0)) \(outcome.effect.isNegative ? "less" : "more")"
                    row(title: scenario.name, detail: gap, value: outcome.endBalance, isSelected: selection == scenario.id) { selection = scenario.id }
                }
            }
        }
    }

    private func row(title: String, detail: String?, value: Money, isSelected: Bool, select: @escaping () -> Void) -> some View {
        Button { withAnimation(DSMotion.standard) { select() } } label: {
            HStack(spacing: DSSpace.sm) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: DSIconSize.md))
                    .foregroundStyle(isSelected ? Color.ds.accent : Color.ds.inkTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).dsFont(.body).foregroundStyle(Color.ds.ink)
                    if let detail { Text(detail).dsFont(.caption).foregroundStyle(Color.ds.inkSecondary) }
                }
                Spacer(minLength: DSSpace.xs)
                DSAmountText(value.decimal, currencyCode: value.currencyCode, sign: .magnitude)
            }
            .frame(minHeight: DSSize.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func toggle(_ event: PlanEvent, in scenario: PlanScenario, on: Bool) async {
        busy = true
        defer { busy = false }
        var save = SavePlanScenario(scenario)
        guard let index = save.events.firstIndex(where: { $0.id == event.id }) else { return }
        save.events[index].isEnabled = on
        do {
            try await app.perform(.savePlanScenario(save))
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: - Sheets

/// Names a new scenario, or renames or deletes one.
struct ScenarioSheet: View {
    /// Nil makes a new one.
    let scenario: PlanScenario?
    /// Called with the id saved (a new one's), or nil after a delete.
    let onDone: (String?) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isSaving = false
    @State private var armed = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpace.lg) {
                    VStack(alignment: .leading, spacing: DSSpace.xs) {
                        DSEyebrow("Scenario")
                        Text(scenario == nil ? "New scenario" : "Rename").dsFont(.display).foregroundStyle(Color.ds.ink)
                    }
                    DSField("Name", text: $name, prompt: "New car, Bonus, Moving…", helper: "You'll add its changes next.")
                        .accessibilityIdentifier("scenarioName")
                }
                .padding(DSSpace.gutter)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { buttons }
            .dsScreenBackground()
            .announcesProblem(problem)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.ds.canvas)
        .onAppear { name = scenario?.name ?? "" }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            if let problem {
                Text(problem).dsFont(.callout).foregroundStyle(Color.ds.caution).fixedSize(horizontal: false, vertical: true)
            }
            Button(isSaving ? "Saving…" : scenario == nil ? "Make scenario" : "Save name") { Task { await save() } }
                .buttonStyle(.ds(.primary, size: .large, fullWidth: true))
                .disabled(isSaving || trimmed.isEmpty)
                .accessibilityIdentifier("saveScenario")
            if let scenario {
                Button(armed ? "Delete “\(scenario.name)” and its changes" : "Delete scenario") {
                    if armed { Task { await delete(scenario) } } else { armed = true }
                }
                .buttonStyle(.ds(armed ? .destructiveArmed : .destructive, fullWidth: true))
                .disabled(isSaving)
            }
        }
        .padding(.horizontal, DSSpace.gutter)
        .padding(.vertical, DSSpace.sm)
        .background { Color.ds.canvas.ignoresSafeArea(edges: .bottom) }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        var payload = scenario.map(SavePlanScenario.init) ?? SavePlanScenario(scenarioID: PlanScenario.newID(), name: trimmed)
        payload.name = trimmed
        do {
            try await app.perform(.savePlanScenario(payload))
            onDone(payload.scenarioID)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func delete(_ scenario: PlanScenario) async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await app.perform(.deletePlanScenario(DeletePlanScenario(scenarioID: scenario.id)))
            onDone(nil)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Adds or edits one change in a scenario: what it is, which way the money goes, how much, how often and when.
struct PlanEventSheet: View {
    let scenario: PlanScenario
    /// Nil adds one.
    let event: PlanEvent?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var name = ""
    @State private var kind: PlanEvent.Kind = .expense
    @State private var amount: Decimal = 0
    @State private var cadence: PlanEvent.Cadence = .monthly
    @State private var start = Calendar.current.date(byAdding: .month, value: 1, to: MonthKey.start(of: AppClock.now))!
    @State private var hasEnd = false
    @State private var end = Calendar.current.date(byAdding: .month, value: 12, to: MonthKey.start(of: AppClock.now))!
    @State private var isSaving = false
    @State private var armed = false
    @State private var problem: String?

    private var latest: Date { Calendar.current.date(byAdding: .year, value: 10, to: AppClock.now)! }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpace.lg) {
                    VStack(alignment: .leading, spacing: DSSpace.xs) {
                        DSEyebrow(scenario.name)
                        Text(event == nil ? "Add a change" : "Edit change").dsFont(.display).foregroundStyle(Color.ds.ink)
                    }
                    DSField("What is it", text: $name, prompt: "Car payment, Bonus, Rent goes up…")
                        .accessibilityIdentifier("planEventName")
                    DSSegmented("Money", selection: $kind, options: [(value: PlanEvent.Kind.expense, title: "Money out"), (value: .income, title: "Money in")])
                    DSAmountField(currencySymbol: nil, style: .amount, alignment: .leading) {
                        TextField("Amount", value: $amount, format: .currency(code: "USD").precision(.fractionLength(0...2)))
                            .keyboardType(.decimalPad)
                            .accessibilityLabel("Amount")
                            .accessibilityIdentifier("planEventAmount")
                    }
                    DSSegmented("How often", selection: $cadence, options: PlanEvent.Cadence.allCases) { $0.label }
                    VStack(alignment: .leading, spacing: DSSpace.xs) {
                        Text(cadence == .once ? "When" : "Starts").dsFont(.label).foregroundStyle(Color.ds.inkSecondary)
                        DSMonthSwitcher(month: $start, earliest: MonthKey.start(of: AppClock.now), latest: latest)
                    }
                    if cadence != .once {
                        DSToggleRow("Ends", detail: hasEnd ? nil : "Runs on with no end", isOn: $hasEnd.animation(DSMotion.standard))
                        if hasEnd {
                            DSMonthSwitcher(month: $end, earliest: start, latest: latest)
                        }
                    }
                    Text(preview)
                        .dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DSSpace.gutter)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { buttons }
            .dsScreenBackground()
            .announcesProblem(problem)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: start) { if end < start { end = start } }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.large])
        .presentationBackground(Color.ds.canvas)
        .onAppear(perform: fill)
    }

    /// The change in a sentence, as the scenario will list it.
    private var preview: String {
        let draft = PlanEvent(id: "draft", name: name, kind: kind, amount: Money(amount), startMonth: MonthKey.string(start),
                              endMonth: cadence != .once && hasEnd ? MonthKey.string(end) : nil, cadence: cadence)
        return (kind == .income ? "Money in: " : "Money out: ") + draft.summary()
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            if let problem {
                Text(problem).dsFont(.callout).foregroundStyle(Color.ds.caution).fixedSize(horizontal: false, vertical: true)
            }
            Button(isSaving ? "Saving…" : event == nil ? "Add change" : "Save change") { Task { await save() } }
                .buttonStyle(.ds(.primary, size: .large, fullWidth: true))
                .disabled(isSaving || amount <= 0 || name.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("savePlanEvent")
            if let event {
                Button(armed ? "Remove “\(event.name)”" : "Remove change") {
                    if armed { Task { await remove(event) } } else { armed = true }
                }
                .buttonStyle(.ds(armed ? .destructiveArmed : .destructive, fullWidth: true))
                .disabled(isSaving)
            }
        }
        .padding(.horizontal, DSSpace.gutter)
        .padding(.vertical, DSSpace.sm)
        .background { Color.ds.canvas.ignoresSafeArea(edges: .bottom) }
    }

    private func fill() {
        guard let event else { return }
        name = event.name
        kind = event.kind
        amount = event.amount.decimal
        cadence = event.cadence
        start = MonthKey.date(event.startMonth) ?? start
        if let last = MonthKey.date(event.endMonth) {
            hasEnd = true
            end = last
        }
    }

    private func save() async {
        let draft = SavePlanScenario.Event(id: event?.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind,
                                           amount: DecimalAmount(Money(amount)), startMonth: MonthKey.string(start),
                                           endMonth: cadence != .once && hasEnd ? MonthKey.string(end) : nil, cadence: cadence,
                                           isEnabled: event?.isEnabled ?? true)
        var payload = SavePlanScenario(scenario)
        if let index = payload.events.firstIndex(where: { $0.id == event?.id }) {
            payload.events[index] = draft
        } else {
            payload.events.append(draft)
        }
        await run(.savePlanScenario(payload))
    }

    private func remove(_ event: PlanEvent) async {
        var payload = SavePlanScenario(scenario)
        payload.events.removeAll { $0.id == event.id }
        await run(.savePlanScenario(payload))
    }

    private func run(_ action: AppAction) async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await app.perform(action)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
