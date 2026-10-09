import BudgetKit
import DesignSystem
import SwiftUI

/// Adds or edits an asset or debt no bank reports — a home, a car, a loan — through the one write path
/// (`saveManualAsset` / `removeManualAsset`), with Undo in the toast. A new value is recorded from today, so net worth
/// history keeps the old one before it.
struct ManualAssetSheet: View {
    enum Target: Identifiable {
        case new
        case edit(ManualAsset)

        var id: String {
            switch self {
            case .new: "new"
            case let .edit(item): item.id
            }
        }
    }

    let target: Target
    let toast: Binding<DSToastMessage?>
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ManualAssetKind = .asset
    @State private var category: ManualAssetCategory = .realEstate
    @State private var name = ""
    @State private var amount: Decimal?
    @State private var isSaving = false
    @State private var removeArmed = false
    @State private var errorMessage: String?

    private var existing: ManualAsset? {
        if case let .edit(item) = target { return item }
        return nil
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpace.lg) {
                    VStack(alignment: .leading, spacing: DSSpace.xs) {
                        DSEyebrow(existing == nil ? "Add to net worth" : "Kept by hand")
                        Text(existing?.name ?? (kind == .asset ? "Something you own" : "Something you owe"))
                            .dsFont(.display).foregroundStyle(Color.ds.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    DSSegmented("Asset or debt", selection: $kind, options: ManualAssetKind.allCases) { $0 == .asset ? "I own it" : "I owe it" }
                    DSField("Name", text: $name, prompt: kind == .asset ? "Home, car, art" : "Car loan, student loan")
                    VStack(alignment: .leading, spacing: DSSpace.xs) {
                        Text("Type").dsFont(.label).foregroundStyle(Color.ds.inkSecondary).accessibilityHidden(true)
                        DSSegmented("Type", selection: $category, options: Self.categories(for: kind)) { $0.label }
                    }
                    VStack(alignment: .leading, spacing: DSSpace.xs) {
                        Text(kind == .asset ? "What it's worth" : "What's owed").dsFont(.label).foregroundStyle(Color.ds.inkSecondary)
                            .accessibilityHidden(true)
                        DSAmountField(currencySymbol: nil, alignment: .leading, isEmpty: amount == nil) {
                            TextField("0", value: $amount, format: .currency(code: "USD").precision(.fractionLength(0...2)))
                                .keyboardType(.decimalPad)
                                .accessibilityLabel(kind == .asset ? "What it's worth" : "What's owed")
                        }
                    }
                    Text(existing == nil
                         ? "It counts in your net worth from today. Change the value whenever it moves; the history keeps each one."
                         : "A new value counts from today; your net worth history keeps the old one before it.")
                        .dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DSSpace.gutter)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { buttons }
            .dsScreenBackground()
            .announcesProblem(errorMessage)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Color.ds.canvas)
        .onAppear(perform: fill)
        .onChange(of: kind) { _, next in
            if !Self.categories(for: next).contains(category) { category = Self.categories(for: next)[0] }
        }
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            if let errorMessage {
                Text(errorMessage).dsFont(.callout).foregroundStyle(Color.ds.caution).fixedSize(horizontal: false, vertical: true)
            }
            Button(isSaving ? "Saving…" : existing == nil ? "Add" : "Save") { Task { await save() } }
                .buttonStyle(.ds(.primary, size: .large, fullWidth: true, isLoading: isSaving))
                .disabled(isSaving || trimmedName.isEmpty || amount == nil || (amount ?? 0) < 0)
            if let existing {
                Button(removeArmed ? "Tap again to remove \(existing.name)" : "Remove") {
                    if removeArmed { Task { await remove(existing) } } else { removeArmed = true }
                }
                .buttonStyle(.ds(removeArmed ? .destructiveArmed : .destructive, fullWidth: true))
                .disabled(isSaving)
            }
        }
        .padding(.horizontal, DSSpace.gutter)
        .padding(.vertical, DSSpace.sm)
        .background { Color.ds.canvas.ignoresSafeArea(edges: .bottom) }
    }

    /// Debts are loans or something else; assets a home, a vehicle or something else.
    static func categories(for kind: ManualAssetKind) -> [ManualAssetCategory] {
        kind == .asset ? [.realEstate, .vehicle, .other] : [.loan, .other]
    }

    private func fill() {
        guard let existing else { return }
        kind = existing.kind
        category = existing.category
        name = existing.name
        amount = existing.value.decimal
    }

    private func save() async {
        guard let amount else { return }
        let value = DecimalAmount(Money(amount))
        let action: SaveManualAsset
        if let existing {
            action = SaveManualAsset(id: existing.id, name: trimmedName == existing.name ? nil : trimmedName,
                                     kind: kind == existing.kind ? nil : kind, category: category == existing.category ? nil : category,
                                     value: value.money() == existing.value ? nil : value)
            guard action.name != nil || action.kind != nil || action.category != nil || action.value != nil else { dismiss(); return }
        } else {
            action = SaveManualAsset(name: trimmedName, kind: kind, category: category, value: value)
        }
        await run(.saveManualAsset(action))
    }

    private func remove(_ item: ManualAsset) async {
        await run(.removeManualAsset(RemoveManualAsset(id: item.id)))
    }

    /// Saves, then closes with the ledger's sentence and Undo in the screen's toast; a refusal stays here, in the sheet.
    private func run(_ action: AppAction) async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await app.checkServer(for: action)
            let result = try await app.api.perform(action)
            await app.didWrite()
            let edits = RowEdits(app: app, toast: toast)
            toast.wrappedValue = result.undo.map { undo in .undo(result.message) { Task { await edits.run(undo) } } } ?? DSToastMessage(result.message)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            removeArmed = false
        }
    }
}
