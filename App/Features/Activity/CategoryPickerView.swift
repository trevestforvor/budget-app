import BudgetKit
import DesignSystem
import SwiftUI

/// Choose a category: "New category…" first (the same editor as Settings → Categories, named after the search), then
/// the pipeline's suggestions (with how sure it was), then every category: spending, then money in (Income and any
/// like card rewards), then Transfer. Pushed from a transaction's details, or presented on its own
/// (`CategoryPickerSheet`) for several rows at once, a rule, a memory entry or a merge.
struct CategoryPickerView: View {
    let title: String
    /// The categories offered; every active one when nil (merging offers all but the one being merged).
    var categories: [BudgetCategory]?
    var selected: String?
    var suggestions: [CategorySuggestion] = []
    /// Shown above the list: what picking does ("Files 12 transactions").
    var footnote: String?
    /// Offers "New category…"; a category made there counts as picked. Off for a merge.
    var allowsNew = true
    /// The type a new category starts as: money in for a rule on money coming in. Spending when nil.
    var newKind: CategoryKind?
    let onPick: (BudgetCategory) -> Void

    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var makesNew = false
    /// The category the editor just made, picked once its sheet has gone (so the two sheets never close together).
    @State private var made: BudgetCategory?

    var body: some View {
        let query = self.query.trimmingCharacters(in: .whitespaces)
        let categories = (self.categories ?? app.sortedCategories).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        let suggested = query.isEmpty ? suggestions.compactMap { suggestion in app.category(suggestion.categoryID).map { ($0, suggestion.confidence) } }
            .filter { !$0.0.isArchived } : []
        List {
            if allowsNew {
                DSListSection {
                    Button { makesNew = true } label: {
                        DSListRow("New category…", detail: query.isEmpty ? nil : "Named “\(query)”", systemImage: "plus", tone: .cyan)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Makes a category and files under it")
                    .accessibilityIdentifier("newCategory")
                }
            }
            if !suggested.isEmpty {
                DSListSection("Suggested", footer: footnote) {
                    ForEach(suggested, id: \.0.id) { category, confidence in
                        row(category, trailing: "\(Int((confidence * 100).rounded()))%", accessibility: "\(Int((confidence * 100).rounded())) percent sure")
                    }
                }
            }
            let spending = categories.filter(\.countsAsSpending)
            if !spending.isEmpty {
                DSListSection(suggested.isEmpty ? "Spending" : "All categories", footer: suggested.isEmpty ? footnote : nil) {
                    ForEach(spending) { row($0) }
                }
            }
            let moneyIn = categories.filter(\.isMoneyIn)
            if !moneyIn.isEmpty {
                DSListSection("Money in", footer: "Counts as money coming in, like income, never as spending.") {
                    ForEach(moneyIn) { row($0) }
                }
            }
            let other = categories.filter { !$0.countsAsSpending && !$0.isMoneyIn }
            if !other.isEmpty {
                DSListSection("Not spending", footer: "Moves between your own accounts count as neither spending nor money in.") {
                    ForEach(other) { row($0) }
                }
            }
            if categories.isEmpty, !query.isEmpty {
                DSStateView(systemImage: "magnifyingglass", title: "No category called “\(query)”",
                            message: allowsNew ? "Make it with New category… above." : "Categories are added and renamed in Settings.")
                    .listRowBackground(Color.clear)
            }
        }
        .dsGroupedList()
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Categories")
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $makesNew, onDismiss: {
            guard let made else { return }
            self.made = nil
            onPick(made)
        }) {
            CategoryEditorSheet(subject: .new, all: Array(app.categories.values), target: nil,
                                initialName: query, initialKind: newKind) { made = $0 }
        }
    }

    private func row(_ category: BudgetCategory, trailing: String? = nil, accessibility: String? = nil) -> some View {
        let isSelected = category.id == selected
        return Button {
            onPick(category)
        } label: {
            DSListRow(category.name, systemImage: category.symbol, tone: CategoryStyle.tone(for: category)) {
                HStack(spacing: DSSpace.xs) {
                    if let trailing { DSListValue(trailing) }
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.ds.accent)
                        .opacity(isSelected ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.name)
        .accessibilityValue([isSelected ? "Current" : nil, accessibility].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("category-\(category.id)")
    }
}

/// The picker presented on its own: for several rows at once, a row's menu, a rule, a memory entry or a merge.
struct CategoryPickerSheet: View {
    let title: String
    var categories: [BudgetCategory]?
    var selected: String?
    var suggestions: [CategorySuggestion] = []
    var footnote: String?
    var allowsNew = true
    var newKind: CategoryKind?
    let onPick: (BudgetCategory) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CategoryPickerView(title: title, categories: categories, selected: selected, suggestions: suggestions, footnote: footnote,
                               allowsNew: allowsNew, newKind: newKind) { category in
                dismiss()
                onPick(category)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationBackground(Color.ds.canvas)
    }
}
