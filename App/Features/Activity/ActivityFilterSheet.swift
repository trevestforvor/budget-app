import BudgetKit
import DesignSystem
import SwiftUI

/// Every way to narrow Activity, with a live count on the button so there are no empty surprises.
/// Changes stay in the sheet until "Show N transactions".
struct ActivityFilterSheet: View {
    let onApply: (TransactionFilter) -> Void
    @State private var draft: TransactionFilter
    @State private var count: Int?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    init(filter: TransactionFilter, onApply: @escaping (TransactionFilter) -> Void) {
        self.onApply = onApply
        _draft = State(initialValue: filter)
    }

    var body: some View {
        NavigationStack {
            List {
                DSListSection("Filter by") {
                    NavigationLink { PeriodPicker(filter: $draft) } label: {
                        DSListRow("Date", value: periodText)
                    }
                    NavigationLink { AccountPicker(selection: accountBinding) } label: {
                        DSListRow("Accounts", value: accountsText)
                    }
                    NavigationLink { CategoryFilterPicker(selection: categoryBinding) } label: {
                        DSListRow("Categories", value: categoriesText)
                    }
                    NavigationLink { AmountEditor(filter: $draft) } label: {
                        DSListRow("Amount", value: amountText)
                    }
                }
                DSListSection("Show", footer: "Not counted means moves between your own accounts and anything you've hidden. Balances always include them.") {
                    DSListRow("Visibility") {
                        Picker("Visibility", selection: $draft.visibility) {
                            ForEach(TransactionFilter.Visibility.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .tint(Color.ds.inkSecondary)
                    }
                    DSToggleRow("Needs review", isOn: $draft.needsReviewOnly)
                    DSToggleRow("Pending", isOn: $draft.pendingOnly)
                    DSToggleRow("Filed by the model", detail: "What the decision model filed on its own, to check or overrule", isOn: $draft.modelFiledOnly)
                }
            }
            .dsGroupedList()
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) { footer }
        }
        .presentationBackground(Color.ds.canvas)
        .task(id: draft) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            count = try? await app.api.transactionSummary(draft).count
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DSSpace.sm) {
                clearButton(fullWidth: false)
                showButton
            }
            VStack(spacing: DSSpace.xs) {
                showButton
                clearButton(fullWidth: true)
            }
        }
        .padding(.horizontal, DSSpace.gutter)
        .padding(.vertical, DSSpace.sm)
        .background {
            Color.ds.canvas.overlay(alignment: .top) { DSDivider() }.ignoresSafeArea(edges: .bottom)
        }
    }

    private func clearButton(fullWidth: Bool) -> some View {
        Button { draft = draft.clearingChoices } label: { Text("Clear").fixedSize() }
            .buttonStyle(.ds(.secondary, fullWidth: fullWidth))
            .disabled(draft.choiceCount == 0)
    }

    private var showButton: some View {
        Button {
            onApply(draft)
            dismiss()
        } label: {
            Text(showTitle).fixedSize()
        }
        .buttonStyle(.ds(.primary, fullWidth: true))
        .disabled(count == 0)
        .accessibilityLabel(showTitle)
        .accessibilityIdentifier("applyFilters")
    }

    private var showTitle: String {
        guard let count else { return "Show transactions" }
        switch count {
        case 0: return "Nothing matches"
        case 1: return "Show 1 transaction"
        default: return "Show \(count.formatted()) transactions"
        }
    }

    // MARK: - Values in the rows

    private var periodText: String {
        guard draft.activePeriod == .custom else { return draft.activePeriod.title }
        let from = draft.since?.formatted(.dateTime.month(.abbreviated).day()) ?? "Start"
        let to = draft.until.flatMap { Calendar.current.date(byAdding: .day, value: -1, to: $0) }?.formatted(.dateTime.month(.abbreviated).day()) ?? "Today"
        return "\(from) – \(to)"
    }

    private var accountBinding: Binding<Set<String>> {
        Binding(get: { Set(draft.accountIDs ?? []) }, set: { draft.accountIDs = $0.isEmpty ? nil : $0.sorted() })
    }

    private var categoryBinding: Binding<Set<String>> {
        Binding(get: { Set(draft.categoryIDs ?? []) }, set: { draft.categoryIDs = $0.isEmpty ? nil : $0.sorted() })
    }

    private var accountsText: String {
        let ids = draft.accountIDs ?? []
        if ids.isEmpty { return "All" }
        if ids.count == 1 { return app.account(ids[0])?.shortLabel ?? "1 account" }
        return "\(ids.count) accounts"
    }

    private var categoriesText: String {
        let ids = draft.categoryIDs ?? []
        if ids.isEmpty { return "All" }
        if ids.count == 1 { return app.category(ids[0])?.name ?? "1 category" }
        return "\(ids.count) categories"
    }

    private var amountText: String {
        var parts: [String] = []
        switch draft.direction {
        case .moneyOut?: parts.append("Money out")
        case .moneyIn?: parts.append("Money in")
        case nil: break
        }
        switch (draft.minAmount, draft.maxAmount) {
        case let (min?, max?): parts.append("\(min.formatted(fractionDigits: 0))–\(max.formatted(fractionDigits: 0))")
        case let (min?, nil): parts.append("\(min.formatted(fractionDigits: 0)) or more")
        case let (nil, max?): parts.append("Up to \(max.formatted(fractionDigits: 0))")
        default: break
        }
        return parts.isEmpty ? "Any" : parts.joined(separator: " · ")
    }
}

// MARK: - Pages

private struct PeriodPicker: View {
    @Binding var filter: TransactionFilter

    var body: some View {
        List {
            DSListSection {
                ForEach(ActivityPeriod.allCases) { choice in
                    Button { filter.setPeriod(choice) } label: {
                        DSListRow(choice.title) { CheckMark(isOn: filter.activePeriod == choice) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter.activePeriod == choice ? .isSelected : [])
                }
            }
            if filter.activePeriod == .custom {
                DSListSection("Custom dates", footer: "Both days are included.") {
                    DatePicker("From", selection: sinceBinding, in: ...lastDayBinding.wrappedValue, displayedComponents: .date)
                        .dsFont(.body)
                        .frame(minHeight: 52)
                    DatePicker("To", selection: lastDayBinding, in: sinceBinding.wrappedValue...AppClock.now, displayedComponents: .date)
                        .dsFont(.body)
                        .frame(minHeight: 52)
                }
            }
        }
        .dsGroupedList()
        .navigationTitle("Date")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sinceBinding: Binding<Date> {
        Binding(get: { filter.since ?? AppClock.now }, set: { filter.since = Calendar.current.startOfDay(for: $0) })
    }

    /// The last day shown; the filter stores the start of the day after (`until` is exclusive).
    private var lastDayBinding: Binding<Date> {
        let calendar = Calendar.current
        return Binding(get: { filter.until.flatMap { calendar.date(byAdding: .day, value: -1, to: $0) } ?? AppClock.now },
                       set: { filter.until = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) })
    }
}

private struct AccountPicker: View {
    @Binding var selection: Set<String>
    @Environment(AppModel.self) private var app

    var body: some View {
        // Balance-only investment accounts have no transactions to filter.
        let accounts = app.accounts.values.filter { $0.kind != .investment }
        let institutions = Dictionary(grouping: accounts, by: \.institution)
        List {
            DSListSection {
                Button { selection = [] } label: {
                    DSListRow("All accounts") { CheckMark(isOn: selection.isEmpty) }
                }
                .buttonStyle(.plain)
            }
            ForEach(institutions.keys.sorted(), id: \.self) { institution in
                DSListSection(institution) {
                    ForEach(institutions[institution]!.sorted { $0.name < $1.name }) { account in
                        Button { toggle(account.id) } label: {
                            DSListRow(account.shortLabel, detail: account.kind.title) { CheckMark(isOn: selection.contains(account.id)) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection.contains(account.id) ? .isSelected : [])
                    }
                }
            }
        }
        .dsGroupedList()
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.inline)
        .task { if app.accounts.isEmpty { await app.refreshAccounts() } }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
}

private struct CategoryFilterPicker: View {
    @Binding var selection: Set<String>
    @Environment(AppModel.self) private var app

    var body: some View {
        List {
            DSListSection {
                Button { selection = [] } label: {
                    DSListRow("All categories") { CheckMark(isOn: selection.isEmpty) }
                }
                .buttonStyle(.plain)
            }
            DSListSection("Categories") {
                ForEach(app.sortedCategories) { category in
                    Button { toggle(category.id) } label: {
                        DSListRow(category.name, systemImage: category.symbol, tone: CategoryStyle.tone(for: category)) {
                            CheckMark(isOn: selection.contains(category.id))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection.contains(category.id) ? .isSelected : [])
                }
            }
        }
        .dsGroupedList()
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
}

private struct AmountEditor: View {
    @Binding var filter: TransactionFilter
    @State private var minText = ""
    @State private var maxText = ""

    var body: some View {
        List {
            DSListSection("Direction") {
                Picker("Direction", selection: $filter.direction) {
                    Text("Both").tag(TransactionFilter.Direction?.none)
                    Text("Money out").tag(TransactionFilter.Direction?.some(.moneyOut))
                    Text("Money in").tag(TransactionFilter.Direction?.some(.moneyIn))
                }
                .segmentedUnlessLargeText()
                .frame(minHeight: 52)
            }
            DSListSection("Size", footer: "Whichever way the money went. Leave a side empty for no limit.") {
                DSListRow("At least") { field("0", text: $minText) }
                DSListRow("At most") { field("No limit", text: $maxText) }
            }
        }
        .dsGroupedList()
        .navigationTitle("Amount")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            minText = filter.minAmount.map { "\($0.decimal)" } ?? ""
            maxText = filter.maxAmount.map { "\($0.decimal)" } ?? ""
        }
        .onChange(of: minText) { filter.minAmount = Self.amount(minText) }
        .onChange(of: maxText) { filter.maxAmount = Self.amount(maxText) }
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        HStack(spacing: DSSpace.xxs) {
            Text("$").dsFont(.body).foregroundStyle(Color.ds.inkSecondary).accessibilityHidden(true)
            TextField(prompt, text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .dsFont(.body)
                .foregroundStyle(Color.ds.ink)
                .frame(maxWidth: 140)
        }
    }

    static func amount(_ text: String) -> Money? {
        let cleaned = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let value = Decimal(string: cleaned), value > 0 else { return nil }
        return Money(value)
    }
}

/// The trailing check on a choice row; takes its space either way so labels don't shift.
private struct CheckMark: View {
    let isOn: Bool
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.ds.accent)
            .opacity(isOn ? 1 : 0)
            .accessibilityHidden(true)
    }
}

