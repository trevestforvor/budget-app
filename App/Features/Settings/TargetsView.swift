import BudgetKit
import DesignSystem
import SwiftUI

/// Settings → Targets & caps: every spending category's monthly target and every merchant cap, in one place.
/// Category targets open the same editor as Spending; caps have their own small one.
struct TargetsView: View {
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<SpendingSummary> = .loading
    @State private var editingTarget: TargetLine?
    @State private var editingCap: MerchantCapSheet.Subject?

    var body: some View {
        Group {
            switch state {
            case .loading:
                LoadingPlaceholder(text: "Reading your targets…")
            case let .failed(message):
                DSStateView(systemImage: "wifi.slash", title: "Can't load targets", message: message, actionTitle: "Try again") {
                    Task { await load() }
                }
            case let .loaded(summary):
                list(summary)
            }
        }
        // Every state fills the page, so a loading or error state never sits in a band of another colour.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dsScreenBackground()
        .navigationTitle("Targets & caps")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: app.revision) { await load() }
        .sheet(item: $editingTarget) { total in
            TargetEditorSheet(category: total.category, current: total.target)
        }
        .sheet(item: $editingCap) { MerchantCapSheet(subject: $0) }
    }

    private func list(_ summary: SpendingSummary) -> some View {
        let totals = allCategories(summary)
        let targeted = totals.filter { $0.target != nil }
        let open = totals.filter { $0.target == nil }
        return List {
            Section {
                SettingsCaption("Monthly targets and caps flag spending that runs past them. Nothing is ever blocked.")
            }
            if !targeted.isEmpty {
                DSListSection("Monthly targets") {
                    ForEach(targeted) { targetRow($0) }
                }
            }
            if !open.isEmpty {
                DSListSection("No target yet", footer: "Without a target a category is still tracked; it just isn't measured against a plan.") {
                    ForEach(open) { targetRow($0) }
                }
            }
            DSListSection("Merchant caps", footer: "A cap watches one merchant across categories, like takeout from one app.") {
                ForEach(summary.merchantCaps) { cap in
                    Button { editingCap = .edit(cap) } label: {
                        DSListRow(cap.merchant, detail: "\(cap.spent.shortString) of \(cap.target.shortString) this month",
                                  systemImage: "storefront", tone: .coral) {
                            HStack(spacing: DSSpace.xs) {
                                if cap.spent > cap.target { DSTag.over() }
                                DSListValue(cap.target.shortString)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                Button { editingCap = .new } label: {
                    Label("Add a cap", systemImage: "plus")
                        .dsFont(.body)
                        .foregroundStyle(Color.ds.accent)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("addCap")
            }
        }
        .dsGroupedList()
    }

    private func targetRow(_ total: TargetLine) -> some View {
        Button { editingTarget = total } label: {
            DSListRow(total.category.name, detail: "\(total.spent.shortString) spent this month",
                      systemImage: total.category.symbol, tone: CategoryStyle.tone(for: total.category)) {
                HStack(spacing: DSSpace.xs) {
                    if let target = total.target, total.spent > target { DSTag.over() }
                    DSListValue(total.target?.shortString ?? "Set")
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(total.target == nil ? "Set a target" : "Change the target")
    }

    /// One spending category's line: this month's spend and its target.
    struct TargetLine: Identifiable {
        let category: BudgetCategory
        let spent: Money
        let target: Money?
        var id: String { category.id }
    }

    /// Every active spending category, with this month's spend and target where the summary has them.
    private func allCategories(_ summary: SpendingSummary) -> [TargetLine] {
        let byID = Dictionary(summary.categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let zero = Money(minorUnits: 0, currencyCode: summary.total.currencyCode)
        return app.sortedCategories.filter(\.countsAsSpending).map { category in
            TargetLine(category: category, spent: byID[category.id]?.spent ?? zero, target: byID[category.id]?.target)
        }
    }

    private func load() async {
        let api = app.api
        state = await state.refreshed { try await api.spending(.thisMonth) }
    }
}

/// Sets, changes or removes one merchant's monthly cap, through the same actions the assistant proposes.
struct MerchantCapSheet: View {
    enum Subject: Identifiable {
        case new
        case edit(MerchantCap)
        var id: String {
            switch self {
            case .new: "new"
            case let .edit(cap): cap.merchant
            }
        }
    }

    let subject: Subject
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var merchant = ""
    @State private var amount: Decimal = 0
    @State private var isSaving = false
    @State private var problem: String?

    private var existing: MerchantCap? {
        if case let .edit(cap) = subject { return cap }
        return nil
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: DSSpace.lg) {
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    DSEyebrow("Monthly cap")
                    if let existing {
                        Text(existing.merchant).dsFont(.display).foregroundStyle(Color.ds.ink)
                    } else {
                        TextField("Merchant", text: $merchant, prompt: Text("DoorDash, Amazon…"))
                            .dsFont(.title)
                            .foregroundStyle(Color.ds.ink)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .overlay(alignment: .bottom) { DSDivider() }
                            .accessibilityIdentifier("capMerchant")
                    }
                }
                TextField("Amount", value: $amount, format: .currency(code: "USD").precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .dsFont(.amountXL)
                    .foregroundStyle(Color.ds.ink)
                    .overlay(alignment: .bottom) { DSDivider() }
                    .accessibilityLabel("Monthly cap amount")
                Text(existing.map { "\($0.spent.shortString) spent there this month. Going over is flagged, never blocked." }
                     ?? "Use the merchant's name as it shows in Activity. Going over is flagged, never blocked.")
                    .dsFont(.caption)
                    .foregroundStyle(Color.ds.inkTertiary)
                if let problem { Text(problem).dsFont(.callout).foregroundStyle(Color.ds.caution) }
                Spacer()
                Button(isSaving ? "Saving…" : "Save cap") { Task { await save() } }
                    .buttonStyle(.ds(.primary, fullWidth: true))
                    .disabled(isSaving || amount <= 0 || name.isEmpty)
                if let existing {
                    Button("Remove cap") { Task { await run(.removeMerchantTarget(RemoveMerchantTarget(merchant: existing.merchant))) } }
                        .buttonStyle(.ds(.secondary, fullWidth: true))
                        .disabled(isSaving)
                }
            }
            .padding(DSSpace.gutter)
            .dsScreenBackground()
            .announcesProblem(problem)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.ds.canvas)
        .onAppear { amount = existing?.target.decimal ?? 0 }
    }

    private var name: String { existing?.merchant ?? merchant.trimmingCharacters(in: .whitespaces) }

    private func save() async {
        await run(.setMerchantTarget(SetMerchantTarget(merchant: name, monthlyAmount: DecimalAmount(Money(amount)))))
    }

    private func run(_ action: AppAction) async {
        isSaving = true
        problem = nil
        defer { isSaving = false }
        do {
            try await app.perform(action)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
