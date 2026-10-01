import BudgetKit
import DesignSystem
import SwiftUI

/// One category: a year month by month against today's target, the selected month's spending and
/// transactions, and the recurring charges coming up in it. Tap a bar to look at that month. A money-in category
/// (Income, card rewards) shows what it received instead.
struct CategoryDetailView: View {
    let categoryID: String
    @Environment(AppModel.self) private var app
    @State private var month: Date
    @State private var history: LoadState<CategoryHistory> = .loading
    @State private var rows: LoadState<[LedgerTransaction]> = .loading
    /// The month `rows` belongs to; another month's rows stay redacted until the new ones arrive.
    @State private var rowsMonth = ""
    /// The rows came from the phone's offline copy (its newest page), not the server.
    @State private var rowsOffline = false
    /// What a money-in category received in a month (`TransactionSummary.income`), and which month.
    @State private var received: (month: String, amount: Money)?
    @State private var recurring: [Subscription] = []
    @State private var editsTarget = false
    /// A row's details, as a sheet (as Activity opens them).
    @State private var detail: LedgerTransaction?

    init(categoryID: String, month: String? = nil) {
        self.categoryID = categoryID
        _month = State(initialValue: MonthKey.date(month) ?? MonthKey.start(of: AppClock.now))
    }

    private var monthKey: String { MonthKey.string(month) }
    private var monthName: String { MonthKey.name(month) }
    private var isThisMonth: Bool { monthKey == MonthKey.string(AppClock.now) }
    private var isMoneyIn: Bool { app.category(categoryID)?.isMoneyIn == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.lg) {
                if let category = app.category(categoryID) {
                    content(category)
                } else {
                    LoadingPlaceholder()
                }
            }
            .padding(.horizontal, DSSpace.gutter)
            .padding(.bottom, DSSpace.xxl)
        }
        .dsScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .reloadable { await loadAll() }
        .transactionDetailSheet(item: $detail)
        .task(id: "\(categoryID)|\(app.revision)") { await loadHistory() }
        .task(id: "\(categoryID)|\(monthKey)|\(app.revision)") { await loadRows() }
        // Keyed on the kind too: opened before the categories arrive, it only learns it's money in once they do.
        .task(id: "\(categoryID)|\(monthKey)|\(app.revision)|\(isMoneyIn)") { await loadReceived() }
        .sheet(isPresented: $editsTarget) {
            if let category = app.category(categoryID) {
                TargetEditorSheet(category: category, current: selected?.target ?? history.value?.months.last?.target)
            }
        }
    }

    // MARK: Loading

    @discardableResult
    private func loadAll() async -> String? {
        async let history: String? = loadHistory()
        async let rows: String? = loadRows()
        async let received: String? = loadReceived()
        let errors = await [history, rows, received]
        return errors.compactMap { $0 }.first
    }

    @discardableResult
    private func loadHistory() async -> String? {
        let api = app.api
        let id = categoryID
        async let found = try? api.subscriptions()
        guard app.category(id)?.countsAsSpending ?? true else {
            recurring = []
            return nil
        }
        let first = history.isLoading
        history = await history.orSaved(.categoryHistory(id: id, months: 12), app)
        if first, recurring.isEmpty, let saved: SubscriptionSummary = await app.saved(.subscriptions) {
            recurring = RecurringView.upcoming(saved).filter { $0.categoryID == id }
        }
        let updating = app.beginUpdating(showingSaved: first && history.value != nil)
        let (next, error) = await history.refreshing { try await api.categoryHistory(id: id, months: 12) }
        app.endUpdating(updating)
        history = next
        recurring = (await found).map { RecurringView.upcoming($0).filter { $0.categoryID == id } } ?? []
        return error
    }

    /// A money-in category's month: the ledger's own income figure, so it matches Home and cash flow to the cent.
    @discardableResult
    private func loadReceived() async -> String? {
        guard isMoneyIn else { return nil }
        let key = monthKey
        do {
            received = (key, try await app.api.transactionSummary(TransactionFilter(categoryIDs: [categoryID], period: key)).income)
            return nil
        } catch {
            return Task.isCancelled ? nil : error.localizedDescription
        }
    }

    @discardableResult
    private func loadRows() async -> String? {
        let api = app.api
        let filter = TransactionFilter(categoryIDs: [categoryID], period: monthKey, limit: 200)
        let key = monthKey
        do {
            let list = try await api.transactions(filter)
            (rows, rowsMonth, rowsOffline) = (.loaded(list), key, false)
            return nil
        } catch {
            if Task.isCancelled { return nil }
            // Offline, the saved newest page still has this category's recent rows.
            if (error as? BudgetAPIError)?.isNoAnswer == true, let saved = try? await api.transactions(TransactionFilter()),
               let start = MonthKey.date(key), let end = Calendar.current.date(byAdding: .month, value: 1, to: start) {
                let list = saved.filter { $0.categorization?.categoryID == categoryID && $0.postedAt >= start && $0.postedAt < end }
                (rows, rowsMonth, rowsOffline) = (.loaded(list), key, true)
                return nil
            }
            // Another month's rows would sit behind a placeholder for good; this month's failure is said instead.
            if rowsMonth != key || rows.value == nil { rows = .failed(error.localizedDescription) }
            return error.localizedDescription
        }
    }

    /// The selected month in the history, when it's there.
    private var selected: MonthSpend? {
        history.value?.months.first { $0.month == monthKey }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ category: BudgetCategory) -> some View {
        let tone = CategoryStyle.tone(for: category)
        HStack(alignment: .center, spacing: DSSpace.sm) {
            DSGlyph(systemImage: category.symbol, tone: tone, size: 44)
            Text(category.name)
                .dsFont(.display)
                .foregroundStyle(Color.ds.ink)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: DSSpace.xs)
            if category.countsAsSpending {
                DSAskButton(label: category.name) {
                    app.ask("How has my \(category.name.lowercased()) spending changed over the last year?")
                }
            }
        }
        .padding(.top, DSSpace.sm)

        if category.countsAsSpending {
            switch history {
            case .loading:
                LoadingPlaceholder()
            case let .failed(message):
                DSStateView(systemImage: "wifi.slash", title: "Can't load this category", message: message, actionTitle: "Try again") {
                    Task { await loadAll() }
                }
            case let .loaded(history):
                figures(history, category: category)
                bars(history, tone: tone, category: category)
            }
        } else if category.isMoneyIn {
            receivedCard
        }

        if isThisMonth, !recurring.isEmpty {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                DSSectionHeader("Coming up")
                DSCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(recurring.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { DSDivider() }
                            RecurringRow(item: item)
                        }
                    }
                    .padding(.horizontal, DSSpace.md)
                }
            }
        }

        transactions(category)
    }

    /// A money-in category's month: what came in, never "spent".
    private var receivedCard: some View {
        DSCard {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                DSFigureRow(label: "Received in \(monthName)", detail: isThisMonth ? "So far" : nil,
                            value: (received?.month == monthKey ? received?.amount : nil)?.decimal ?? 0)
                Text("Counts as money coming in, like income. It's never spending and has no target.")
                    .dsFont(.caption)
                    .foregroundStyle(Color.ds.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dsLoading(received?.month != monthKey)
        // One element, so VoiceOver never reads the placeholder amount while the month loads.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Received in \(monthName)\(isThisMonth ? " so far" : ""). Counts as money coming in, like income.")
        .accessibilityValue(received.flatMap { $0.month == monthKey ? $0.amount.formatted() : nil } ?? "Loading")
        .accessibilityIdentifier("categoryReceived")
    }

    private func figures(_ history: CategoryHistory, category: BudgetCategory) -> some View {
        let spent = selected?.spent ?? .zero
        let target = selected?.target ?? history.months.last?.target
        let fraction = target.map { $0.minorUnits > 0 ? spent.doubleValue / $0.doubleValue : 0 } ?? 0
        let over = target != nil && DSProgressBar.isOver(fraction)
        return DSCard {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                VStack(spacing: 0) {
                    DSFigureRow(label: history.monthsAveraged == 12 ? "12-month average" : "Monthly average",
                                detail: history.monthsAveraged > 0 ? "Over \(history.monthsAveraged) full month\(history.monthsAveraged == 1 ? "" : "s")" : "Not enough history yet",
                                value: history.averageMonthly.decimal)
                    DSFigureRow(label: "Spent in \(monthName)", detail: isThisMonth ? "So far" : nil, value: spent.decimal)
                    if let target {
                        DSFigureRow(label: "Monthly target", value: target.decimal)
                    }
                }
                if let target, target.minorUnits > 0 {
                    HStack(spacing: DSSpace.xs) {
                        if over { DSTag.over() }
                        Text(over ? "Over by \((spent - target).formatted(fractionDigits: 0)) in \(monthName)"
                                  : "\((target - spent).formatted(fractionDigits: 0)) left in \(monthName)")
                            .dsFont(.callout)
                            .foregroundStyle(over ? Color.ds.caution : Color.ds.inkSecondary)
                    }
                    DSProgressBar(fraction: fraction, tint: CategoryStyle.tone(for: category).onCanvas)
                }
                Button(target == nil ? "Set target" : "Edit target") { editsTarget = true }
                    .buttonStyle(.ds(.secondary))
                    .padding(.top, DSSpace.xxs)
            }
        }
    }

    @ViewBuilder
    private func bars(_ history: CategoryHistory, tone: DSTone, category: BudgetCategory) -> some View {
        let bars = history.months.compactMap { spend in
            MonthKey.date(spend.month).map { DSMonthBar(month: $0, value: spend.spent.doubleValue) }
        }
        if bars.count > 1 {
            let target = history.months.last?.target?.doubleValue
            DSCard(padding: DSSpace.md) {
                VStack(alignment: .leading, spacing: DSSpace.sm) {
                    DSEyebrow("Month by month")
                    DSMonthBars(bars: bars, target: target, tone: tone, selection: month, accessibilityName: "\(category.name) by month",
                                accessibilitySummary: "\(category.name) spending over the last \(bars.count) months, averaging \(history.averageMonthly.formatted(fractionDigits: 0))") { picked in
                        withAnimation(DSMotion.standard) { month = MonthKey.start(of: picked) }
                    }
                    .frame(height: 170)
                    Text(target == nil ? "Tap a month to see its transactions." : "Every month is measured against today's target. Tap a month to see its transactions.")
                        .dsFont(.caption).foregroundStyle(Color.ds.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func transactions(_ category: BudgetCategory) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            DSSectionHeader("Transactions in \(monthName)")
            switch rows {
            case .loading:
                LoadingPlaceholder()
            case let .failed(message):
                // One error per screen: when the category itself couldn't load, its message above covers this too.
                if history.value != nil || !category.countsAsSpending {
                    DSCard {
                        VStack(alignment: .leading, spacing: DSSpace.xs) {
                            Text("Couldn't load \(monthName)'s transactions. \(message)")
                                .dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Try again") { Task { await loadRows() } }
                                .buttonStyle(.ds(.quiet))
                                .frame(minHeight: 44)
                        }
                    }
                }
            case let .loaded(list) where list.isEmpty:
                DSCard {
                    Text("Nothing filed under \(category.name) in \(monthName).")
                        .dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case let .loaded(list):
                DSCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, transaction in
                            if index > 0 { DSDivider() }
                            Button { detail = transaction } label: { LedgerRow(transaction: transaction) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, DSSpace.md)
                    .padding(.vertical, DSSpace.xxs)
                }
                .dsLoading(rowsMonth != monthKey)
                if rowsOffline {
                    Text("From the offline copy, which keeps only your newest transactions.")
                        .dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
