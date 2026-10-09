import BudgetKit
import DesignSystem
import SwiftUI

/// Edits a monthly target through the same `AppAction` path the assistant uses. The fields scroll and the buttons
/// stay pinned at the bottom, so nothing is cut off at large text sizes.
struct TargetEditorSheet: View {
    let category: BudgetCategory
    let current: Money?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var amount: Decimal = 0
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpace.lg) {
                    VStack(alignment: .leading, spacing: DSSpace.xs) {
                        DSEyebrow("Monthly target")
                        Text(category.name).dsFont(.display).foregroundStyle(Color.ds.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    DSAmountField(currencySymbol: nil, alignment: .leading) {
                        TextField("Amount", value: $amount, format: .currency(code: "USD").precision(.fractionLength(0...2)))
                            .keyboardType(.decimalPad)
                            .accessibilityLabel("Monthly target for \(category.name)")
                    }
                    Text("Targets are flexible: going over is flagged, never blocked.")
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
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationBackground(Color.ds.canvas)
        .onAppear { amount = current?.decimal ?? 0 }
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            if let errorMessage {
                Text(errorMessage).dsFont(.callout).foregroundStyle(Color.ds.caution).fixedSize(horizontal: false, vertical: true)
            }
            Button(isSaving ? "Saving…" : "Save target") { Task { await run(.setCategoryTarget(SetCategoryTarget(categoryID: category.id, monthlyAmount: DecimalAmount(Money(amount))))) } }
                .buttonStyle(.ds(.primary, size: .large, fullWidth: true))
                .disabled(isSaving || amount <= 0)
            if current != nil {
                Button("Remove target") { Task { await run(.removeCategoryTarget(RemoveCategoryTarget(categoryID: category.id))) } }
                    .buttonStyle(.ds(.secondary, fullWidth: true))
                    .disabled(isSaving)
            }
        }
        .padding(.horizontal, DSSpace.gutter)
        .padding(.vertical, DSSpace.sm)
        .background { Color.ds.canvas.ignoresSafeArea(edges: .bottom) }
    }

    private func run(_ action: AppAction) async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await app.perform(action)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
