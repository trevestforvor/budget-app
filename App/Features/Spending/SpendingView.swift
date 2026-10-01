import BudgetKit
import DesignSystem
import SwiftUI

/// A category's detail, on a budget month ("2026-09"; nil is this month). Carries the id so the screen
/// always shows the category as it is now (renamed, recoloured) and can open before categories load.
struct CategoryRoute: Hashable {
    let categoryID: String
    var month: String?
}

/// Spending → Recurring.
struct RecurringRoute: Hashable {}

/// Spending is the budget month: how the everyday budget is figured, how much of it is left, and every budget
/// type's categories against their targets — for this month or any month before it. Longer periods (90 days,
/// year to date) sit beside the months as totals.
struct SpendingView: View {
    enum Period: Hashable, CaseIterable, Identifiable {
        case month, last90Days, yearToDate
        var id: Self { self }
        var title: String {
            switch self {
            case .month: "Month"
            case .last90Days: "90 days"
            case .yearToDate: "Year to date"
            }
        }
        var range: SpendingRange? {
            switch self {
            case .month: nil
            case .last90Days: .last90Days
            case .yearToDate: .yearToDate
            }
        }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var period: Period = .month
    @State private var month = MonthKey.start(of: AppClock.now)
    @State private var state: LoadState<BudgetMonth> = .loading
    @State private var rangeState: LoadState<SpendingSummary> = .loading
    /// This month's extras: what's due soon, and merchant caps.
    @State private var recurring: SubscriptionSummary?
    @State private var caps: [MerchantCap] = []
    /// The ledger's first row, so the switcher stops where the data does.
    @State private var earliest: Date?
    @State private var path = NavigationPath()
    @State private var targetEdit: TargetEdit?
    @State private var savings: SavingsPlan?
    @State private var editsSavings = false

    private struct TargetEdit: Identifiable {
        let category: BudgetCategory
        let current: Money?
        var id: String { category.id }
    }

    private var monthKey: String { MonthKey.string(month) }
    private var isThisMonth: Bool { monthKey == MonthKey.string(AppClock.now) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpace.xl) {
                    VStack(alignment: .leading, spacing: DSSpace.md) {
                        PageTitle("Spending", eyebrow: "Your budget")
                        periodPicker
                        if period == .month {
                            DSMonthSwitcher(month: $month, earliest: earliest, latest: AppClock.now)
                                .accessibilityIdentifier("monthSwitcher")
                        }
                    }
                    switch period {
                    case .month: monthContent
                    case .last90Days, .yearToDate: rangeContent
                    }
                }
                .padding(.horizontal, DSSpace.gutter)
                .padding(.bottom, DSSpace.xxl)
            }
            .dsScreenBackground()
            // Pull to refresh; the page starts with its own title, like every tab, with no bar above it.
            .reloadable(button: false) { await load() }
            .toolbarVisibility(.hidden, for: .navigationBar)
            .navigationDestination(for: CategoryRoute.self) { CategoryDetailView(categoryID: $0.categoryID, month: $0.month) }
            .navigationDestination(for: RecurringRoute.self) { _ in RecurringView() }
        }
        .onChange(of: app.spendingRoute, initial: true) { follow(app.spendingRoute) }
        .task(id: "\(period.title)|\(monthKey)|\(app.revision)") { await load() }
        .task(id: app.revision) {
            let api = app.api
            earliest = (try? await api.transactionSummary(TransactionFilter(limit: 1)))?.earliest
        }
        .sheet(item: $targetEdit) { TargetEditorSheet(category: $0.category, current: $0.current) }
        .sheet(isPresented: $editsSavings) { MonthlySavingsSheet(current: savings?.plannedSavings, suggested: savings?.twentyPercentOfIncome) }
    }

    /// Where a `navigate` action (or a card elsewhere) asked Spending to go.
    private func follow(_ route: AppModel.SpendingRoute?) {
        guard let route else { return }
        switch route.range {
        case .thisMonth?: (period, month) = (.month, MonthKey.start(of: AppClock.now))
        case .lastMonth?:
            period = .month
            month = Calendar.current.date(byAdding: .month, value: -1, to: MonthKey.start(of: AppClock.now)) ?? month
        case .last90Days?: period = .last90Days
        case .yearToDate?: period = .yearToDate
        case nil: break
        }
        if let requested = MonthKey.date(route.month) { (period, month) = (.month, requested) }
        path = NavigationPath()
        if let categoryID = route.categoryID {
            path.append(CategoryRoute(categoryID: categoryID, month: period == .month ? MonthKey.string(month) : nil))
        }
        if route.showsRecurring { path.append(RecurringRoute()) }
        app.spendingRoute = nil
    }

    @discardableResult
    private func load() async -> String? {
        let api = app.api
        if let range = period.range {
            let first = rangeState.isLoading
            rangeState = await rangeState.orSaved(.spending(range), app)
            let updating = app.beginUpdating(showingSaved: first && rangeState.value != nil)
            let (next, error) = await rangeState.refreshing { try await api.spending(range) }
            app.endUpdating(updating)
            rangeState = next
            return error
        }
        let key = monthKey
        let current = isThisMonth
        let first = state.isLoading
        state = await state.orSaved(.budget(month: key), app)
        if first, current {
            if recurring == nil { recurring = await app.saved(.subscriptions) }
            if caps.isEmpty, let saved: SpendingSummary = await app.saved(.spending(.thisMonth)) { caps = saved.merchantCaps }
        }
        async let found = current ? try? api.subscriptions() : nil
        async let summary = current ? try? api.spending(.thisMonth) : nil
        let updating = app.beginUpdating(showingSaved: first && state.value != nil)
        let (next, error) = await state.refreshing { try await api.budget(month: key) }
        app.endUpdating(updating)
        state = next
        recurring = await found
        caps = await summary?.merchantCaps ?? []
        return error
    }

    private var periodPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DSSpace.xs) {
                ForEach(Period.allCases) { option in
                    DSChip(option.title, isSelected: period == option) {
                        withAnimation(DSMotion.standard) { period = option }
                    }
                }
            }
        }
        .contentMargins(.horizontal, DSSpace.gutter, for: .scrollContent)
        .padding(.horizontal, -DSSpace.gutter)
    }

    // MARK: The month

    @ViewBuilder
    private var monthContent: some View {
        switch state {
        case .loading:
            LoadingPlaceholder()
        case let .failed(message):
            DSStateView(systemImage: "wifi.slash", title: "Can't load the budget", message: message, actionTitle: "Try again") {
                Task { await load() }
            }
        case let .loaded(budget):
            // While another month loads, the last one stays in place, redacted, so the page doesn't jump.
            monthBody(budget)
                .dsLoading(budget.month != monthKey)
        }
    }

    @ViewBuilder
    private func monthBody(_ budget: BudgetMonth) -> some View {
        let name = MonthKey.name(MonthKey.date(budget.month) ?? month)
        if budget.hasBudget {
            gaugeCard(budget, name: name)
            planTable(budget)
        } else {
            noHistoryCard(budget, name: name)
        }

        let totals = budget.groups.flatMap(\.categories)
        let top = Array(totals.filter { $0.spent.minorUnits > 0 }.sorted { $0.spent > $1.spent }.prefix(4))
        if top.isEmpty {
            DSStateView(systemImage: "tray", title: budget.isCurrent ? "No spending yet" : "No spending",
                        message: budget.isCurrent ? "Spending in \(name) shows up here as it happens." : "Nothing was spent in \(name).")
        } else {
            tiles(top, monthKey: budget.month)
        }

        // Everyday first: it's what safe to spend is made of.
        ForEach(budget.groups.filter { !$0.categories.isEmpty }.sorted { ($0.group == .everyday ? 0 : 1) < ($1.group == .everyday ? 0 : 1) },
                id: \.group) { group in
            groupSection(group, budget: budget)
        }

        if budget.isCurrent {
            if let recurring { comingUpCard(recurring) }
            if !caps.isEmpty { capsSection(caps) }
        }
        Text("Targets are monthly and flexible: going over is flagged, never blocked.")
            .dsFont(.caption).foregroundStyle(Color.ds.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func gaugeCard(_ budget: BudgetMonth, name: String) -> some View {
        let flex = budget.flex
        let fraction = flex.flexNumber.minorUnits > 0 ? flex.flexSpent.doubleValue / flex.flexNumber.doubleValue : 0
        let label = budget.isCurrent ? "Safe to spend" : (flex.safeToSpend.isNegative ? "Went over by" : "Left over")
        return DSCard {
            VStack(spacing: DSSpace.md) {
                HStack(alignment: .center) {
                    DSEyebrow(budget.isCurrent ? "Everyday budget" : "Everyday budget · \(name)")
                    Spacer(minLength: DSSpace.xs)
                    DSAskButton(label: "safe to spend") {
                        app.ask(budget.isCurrent ? "How much is safe to spend for the rest of \(name)?"
                                                 : "How did my everyday spending go in \(name)?")
                    }
                }
                .padding(.top, -DSSpace.sm)
                DSArcGauge(fraction: fraction, accessibilityLabel: "Everyday spending") {
                    VStack(spacing: DSSpace.xxs) {
                        DSEyebrow(label)
                        Text(flex.safeToSpend.magnitude.formatted(fractionDigits: 0))
                            .dsFont(.amount)
                            .foregroundStyle(flex.safeToSpend.isNegative ? Color.ds.caution : Color.ds.ink)
                            .lineLimit(1)
                        Text("of \(flex.flexNumber.formatted(fractionDigits: 0))")
                            .dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                    }
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .accessibilityElement(children: .combine)
                }
                .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 320 : 230)
                .padding(.bottom, DSProgressBar.isOver(fraction) ? DSSpace.xs : 0)
                Text(budget.summary)
                    .dsFont(.body)
                    .foregroundStyle(Color.ds.inkSoft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if budget.isCurrent, let line = MonthCard.perDayLine(flex) {
                    Text("\(line).")
                        .dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// A month early in the ledger: there weren't three full months before it to work out a budget from, so it shows
    /// what was spent, never a made-up overspend.
    private func noHistoryCard(_ budget: BudgetMonth, name: String) -> some View {
        let spent = budget.groups.map(\.spent).sum()
        return DSCard {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                DSEyebrow("Budget · \(name)")
                Text("Not enough history to budget \(name)")
                    .dsFont(.headline).foregroundStyle(Color.ds.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A month's budget comes from the three full months before it, and your ledger starts too late for that. Here's what was spent.")
                    .dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                DSFigureRow(label: "Spent in \(name)", value: (-spent).decimal)
                DSFigureRow(label: "Everyday spending", value: (-budget.flex.flexSpent).decimal)
            }
        }
        .accessibilityIdentifier("noHistoryCard")
    }

    /// Which figure the budget counts on: a month of the latest paychecks when that's lower than the 3-month average.
    private func incomeDetail(_ flex: FlexBudget) -> String {
        guard flex.incomeSource == .recentPaychecks, let average = flex.averageIncome else { return "Average of the last 3 months" }
        return "Your last \(flex.paycheckCount ?? 2) paychecks · the 3-month average is \(average.formatted(fractionDigits: 0))"
    }

    /// The budget, top to bottom: income, less what's saved first and a usual month of bills and subscriptions, is the
    /// everyday budget.
    private func planTable(_ budget: BudgetMonth) -> some View {
        let flex = budget.flex
        return VStack(alignment: .leading, spacing: DSSpace.sm) {
            DSSectionHeader("How it's figured")
            DSCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    DSFigureRow(label: "Expected income", detail: incomeDetail(flex), value: flex.expectedIncome.decimal)
                    DSFigureRow(label: "Saved first", detail: flex.plannedSavingsIsSet ? "Your plan" : "What you already move to savings",
                                value: (-flex.plannedSavings).decimal)
                    DSFigureRow(label: "Bills", detail: "A usual month", value: (-flex.bills).decimal)
                    DSFigureRow(label: "Subscriptions", detail: "A usual month · yearly ones a twelfth", value: (-flex.subscriptions).decimal)
                    if budget.stillToCome.minorUnits > 0 {
                        Text("\(budget.stillToCome.formatted(fractionDigits: 0)) of these still to come this month.")
                            .dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                            .padding(.bottom, DSSpace.xs)
                    }
                    DSDivider().padding(.vertical, DSSpace.xs)
                    DSFigureRow(label: "Everyday budget", value: flex.flexNumber.decimal)
                    DSFigureRow(label: "Everyday spending", detail: budget.isCurrent ? "So far" : nil, value: (-flex.flexSpent).decimal)
                    DSDivider().padding(.vertical, DSSpace.xs)
                    DSFigureRow(label: budget.isCurrent ? "Safe to spend" : "Left over", value: flex.safeToSpend.decimal)
                    if budget.isCurrent {
                        Button(flex.plannedSavingsIsSet ? "Change monthly savings" : "Set monthly savings") {
                            Task {
                                savings = try? await app.api.savingsPlan()
                                editsSavings = true
                            }
                        }
                        .buttonStyle(.ds(.quiet))
                        .padding(.top, DSSpace.xxs)
                    }
                }
                .padding(.horizontal, DSSpace.md)
                .padding(.vertical, DSSpace.sm)
            }
        }
    }

    private func tiles(_ top: [CategoryTotal], monthKey: String) -> some View {
        // Two across; one at accessibility sizes, so a tile's name and figures never break mid-word.
        let columns = dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())]
                                                          : [GridItem(.flexible(), spacing: DSSpace.sm), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: DSSpace.sm) {
            ForEach(top) { total in
                NavigationLink(value: CategoryRoute(categoryID: total.category.id, month: monthKey)) {
                    DSCategoryTile(title: total.category.name, systemImage: total.category.symbol, amount: total.spent.decimal,
                                   currencyCode: total.spent.currencyCode, footnote: Self.tileFootnote(total),
                                   tone: CategoryStyle.tone(for: total.category))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// "of $450", or "over $450 target" when the month's total passes it.
    static func tileFootnote(_ total: CategoryTotal) -> String {
        guard let target = total.target else { return "\(total.transactionCount) transaction\(total.transactionCount == 1 ? "" : "s")" }
        return total.spent > target ? "over \(target.formatted(fractionDigits: 0)) target" : "of \(target.formatted(fractionDigits: 0))"
    }

    // MARK: Budget types

    private func groupSection(_ group: BudgetGroup, budget: BudgetMonth) -> some View {
        let targeted = group.categories.filter { $0.target != nil }
        let untargeted = group.categories.filter { $0.target == nil }
        return VStack(alignment: .leading, spacing: DSSpace.sm) {
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                // Bills and subscriptions are mostly the recurring list: its way in, where the charges are.
                if group.group == .everyday {
                    DSSectionHeader(group.group.label)
                } else {
                    DSSectionHeader(group.group.label, actionTitle: "Recurring") { path.append(RecurringRoute()) }
                }
                Text(Self.groupLine(group, budget: budget))
                    .dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DSCard(padding: 0) {
                VStack(spacing: 0) {
                    let rows = group.group == .everyday ? targeted : group.categories
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, total in
                        if index > 0 { DSDivider() }
                        categoryLink(total, monthKey: budget.month)
                    }
                    if group.group == .everyday {
                        if !targeted.isEmpty { DSDivider() }
                        everythingElse(budget)
                        ForEach(untargeted) { total in
                            DSDivider()
                            // The chip sits beside the row, or under it at accessibility sizes.
                            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                                                                             : AnyLayout(HStackLayout(spacing: DSSpace.xs))
                            layout {
                                categoryLink(total, monthKey: budget.month)
                                DSChip("Target", systemImage: "plus") { targetEdit = TargetEdit(category: total.category, current: nil) }
                                    .accessibilityLabel("Set a target for \(total.category.name)")
                                    .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 36 + DSSpace.sm : 0)
                                    .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? DSSpace.xs : 0)
                            }
                        }
                    }
                }
                .padding(.horizontal, DSSpace.md)
                .padding(.vertical, DSSpace.xxs)
            }
        }
    }

    /// "$1,213 of $3,958 spent" for everyday; bills and subscriptions say what a usual month comes to. A month with no
    /// budget says what was spent.
    static func groupLine(_ group: BudgetGroup, budget: BudgetMonth) -> String {
        let spent = group.spent.formatted(fractionDigits: 0)
        guard budget.hasBudget else { return "\(spent) spent" }
        let planned = group.planned.formatted(fractionDigits: 0)
        switch group.group {
        case .everyday: return "\(spent) of \(planned) spent"
        case .bills, .subscriptions: return "\(spent) of about \(planned) a month"
        }
    }

    private func categoryLink(_ total: CategoryTotal, monthKey: String) -> some View {
        NavigationLink(value: CategoryRoute(categoryID: total.category.id, month: monthKey)) {
            BudgetCategoryRow(total: total)
        }
        .buttonStyle(.plain)
    }

    /// The everyday budget no target claims, against spending in categories without one.
    @ViewBuilder
    private func everythingElse(_ budget: BudgetMonth) -> some View {
        let room = budget.hasBudget ? budget.unallocatedFlex : .zero
        let spent = budget.everythingElseSpent
        let fraction = room.minorUnits > 0 ? spent.doubleValue / room.doubleValue : 0
        let over = room.minorUnits > 0 && DSProgressBar.isOver(fraction)
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            BudgetLine(systemImage: "ellipsis", tone: .irisDeep, title: "Everything else",
                       detail: room.minorUnits > 0 ? "Categories without a target share \(room.formatted(fractionDigits: 0))" : "Categories without a target",
                       amount: spent, isOver: over)
            if room.minorUnits > 0 {
                DSProgressBar(fraction: fraction, tint: DSTone.irisDeep.onCanvas)
                    .padding(.leading, 36 + DSSpace.sm)
            } else if room.isNegative {
                Text("Your everyday targets add up to \(room.magnitude.formatted(fractionDigits: 0)) more than the everyday budget.")
                    .dsFont(.caption).foregroundStyle(Color.ds.caution)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 36 + DSSpace.sm)
            }
        }
        .padding(.vertical, DSSpace.sm)
        .accessibilityElement(children: .combine)
    }

    // MARK: This month's extras

    private func comingUpCard(_ found: SubscriptionSummary) -> some View {
        let upcoming = RecurringView.upcoming(found)
        return VStack(alignment: .leading, spacing: DSSpace.sm) {
            DSSectionHeader("Coming up", actionTitle: "See all") { path.append(RecurringRoute()) }
                .accessibilityIdentifier("recurring")
            DSCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if upcoming.isEmpty {
                        Text("Nothing recurring is due in the next 30 days.")
                            .dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                            .padding(.vertical, DSSpace.md)
                    } else {
                        ForEach(Array(upcoming.prefix(3).enumerated()), id: \.element.id) { index, item in
                            if index > 0 { DSDivider() }
                            RecurringRow(item: item)
                        }
                    }
                    DSDivider()
                    Button { path.append(RecurringRoute()) } label: {
                        HStack {
                            Text("Due in the next 30 days").dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                            Spacer()
                            DSAmountText((found.dueNext30Days ?? upcoming.map(\.amount).sum()).decimal, sign: .magnitude)
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.ds.inkTertiary).accessibilityHidden(true)
                        }
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("subscriptions")
                    .accessibilityHint("Opens every recurring charge")
                }
                .padding(.horizontal, DSSpace.md)
            }
        }
    }

    private func capsSection(_ caps: [MerchantCap]) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            DSSectionHeader("Merchant caps")
            DSCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(caps.enumerated()), id: \.element.id) { index, cap in
                        if index > 0 { DSDivider() }
                        let fraction = cap.spent.doubleValue / max(cap.target.doubleValue, 1)
                        let over = DSProgressBar.isOver(fraction)
                        VStack(alignment: .leading, spacing: DSSpace.xs) {
                            let trailing = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: DSSpace.xxs))
                                                                               : AnyLayout(HStackLayout(spacing: DSSpace.xs))
                            trailing {
                                Text(cap.merchant).dsFont(.body).foregroundStyle(Color.ds.ink)
                                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: DSSpace.xs) }
                                HStack(spacing: DSSpace.xs) {
                                    if over { DSTag.over() }
                                    Text("\(cap.spent.formatted(fractionDigits: 0)) of \(cap.target.formatted(fractionDigits: 0))")
                                        .dsFont(.amountRow)
                                        .foregroundStyle(over ? Color.ds.caution : Color.ds.inkSoft)
                                }
                            }
                            DSProgressBar(fraction: fraction)
                        }
                        .padding(.vertical, DSSpace.sm)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, DSSpace.md)
                .padding(.vertical, DSSpace.xxs)
            }
        }
    }

    // MARK: Longer periods

    @ViewBuilder
    private var rangeContent: some View {
        switch rangeState {
        case .loading:
            LoadingPlaceholder()
        case let .failed(message):
            DSStateView(systemImage: "wifi.slash", title: "Can't load spending", message: message, actionTitle: "Try again") {
                Task { await load() }
            }
        case let .loaded(summary):
            VStack(alignment: .leading, spacing: DSSpace.xl) {
                DSHeroAmount(label: "Spent · \(summary.range.title)", value: summary.total.decimal, currencyCode: summary.total.currencyCode,
                             caption: summary.comparison)
                let spent = summary.categories.filter { $0.spent.minorUnits > 0 }
                if spent.isEmpty {
                    DSStateView(systemImage: "tray", title: "No spending", message: "Nothing was spent in this period.")
                } else {
                    tiles(Array(spent.prefix(4)), monthKey: MonthKey.string(AppClock.now))
                    VStack(alignment: .leading, spacing: DSSpace.sm) {
                        DSSectionHeader("By category")
                        DSCard(padding: 0) {
                            VStack(spacing: 0) {
                                ForEach(Array(spent.enumerated()), id: \.element.id) { index, total in
                                    if index > 0 { DSDivider() }
                                    categoryLink(total, monthKey: MonthKey.string(AppClock.now))
                                }
                            }
                            .padding(.horizontal, DSSpace.md)
                            .padding(.vertical, DSSpace.xxs)
                        }
                    }
                }
            }
            .dsLoading(summary.range != period.range)
        }
    }
}

/// A category's month: its glyph, how it stands against its target, and the amount. Over target is said in
/// words (an "Over" tag and "over by $X") as well as caution, since caution is also a category tone.
struct BudgetCategoryRow: View {
    let total: CategoryTotal

    var body: some View {
        let tone = CategoryStyle.tone(for: total.category)
        let target = total.target.flatMap { $0.minorUnits > 0 ? $0 : nil }
        let fraction = target.map { total.spent.doubleValue / $0.doubleValue } ?? 0
        let over = target != nil && DSProgressBar.isOver(fraction)
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            BudgetLine(systemImage: total.category.symbol, tone: tone, title: total.category.name,
                       detail: detail(target: target, over: over), amount: total.spent, isOver: over)
            if target != nil {
                DSProgressBar(fraction: fraction, tint: tone.onCanvas)
                    .padding(.leading, 36 + DSSpace.sm)
            }
        }
        .padding(.vertical, DSSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func detail(target: Money?, over: Bool) -> String {
        let count = "\(total.transactionCount) transaction\(total.transactionCount == 1 ? "" : "s")"
        // Its charges spread over the year, at this month's twelfth.
        if total.isYearly == true { return "Spread over the year · \(count)" }
        guard let target else { return count }
        if over { return "Over by \((total.spent - target).formatted(fractionDigits: 0)) of \(target.formatted(fractionDigits: 0))" }
        let left = target - total.spent
        if left.minorUnits < 100 { return "On target · \(target.formatted(fractionDigits: 0))" }
        return "\(left.formatted(fractionDigits: 0)) left of \(target.formatted(fractionDigits: 0))"
    }
}

/// The line every budget row shares: glyph, name over a detail, then an "Over" tag and the amount. At accessibility
/// text sizes the tag and amount move under the name, so nothing is squeezed into breaking mid-word.
struct BudgetLine: View {
    let systemImage: String
    let tone: DSTone
    let title: String
    let detail: String
    let amount: Money
    var isOver = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: DSSpace.sm) {
            DSGlyph(systemImage: systemImage, tone: tone)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: DSSpace.xxs) {
                    titles
                    trailing
                }
                Spacer(minLength: 0)
            } else {
                titles
                Spacer(minLength: DSSpace.xs)
                trailing
            }
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).dsFont(.body).foregroundStyle(Color.ds.ink)
            Text(detail)
                .dsFont(.caption)
                .foregroundStyle(isOver ? Color.ds.caution : Color.ds.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var trailing: some View {
        HStack(spacing: DSSpace.xs) {
            if isOver { DSTag.over().fixedSize() }
            DSAmountText(amount.decimal, currencyCode: amount.currencyCode, sign: .magnitude)
        }
    }
}
