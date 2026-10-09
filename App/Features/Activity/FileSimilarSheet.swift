import BudgetKit
import DesignSystem
import SwiftUI

/// Re-filing one transaction whose merchant has other rows filed some other way: the ledger's count of them, offered
/// alongside "Always file these this way". Everything is one write with one Undo.
struct SimilarOffer: Identifiable {
    let id = UUID()
    let transaction: LedgerTransaction
    let category: BudgetCategory
    /// Rows beyond this one that filing similar ones reaches.
    let similar: Int
    /// "The 2 you filed yourself keep their category.", from the ledger's preview.
    let note: String?
}

extension RowEdits {
    /// Files `row` under `category`, or — when the ledger finds other rows like it filed some other way — returns the
    /// offer to show first. A server too old to file similar rows previews just this one, so it's filed straight away.
    func fileOrOffer(_ row: LedgerTransaction, as category: BudgetCategory) async -> SimilarOffer? {
        let action = AppAction.editTransactions(EditTransactions(transactionIDs: [row.id], categoryID: category.id, fileSimilar: true))
        if let preview = try? await app.api.preview(action), let reach = preview.matchCount, reach > 1 {
            let note = preview.detail?.firstMatch(of: /The \d+ you filed yourself[^.]*\./).map { String($0.0) }
            return SimilarOffer(transaction: row, category: category, similar: reach - 1, note: note)
        }
        await file([row.id], as: category.id)
        return nil
    }
}

struct FileSimilarSheet: View {
    let offer: SimilarOffer
    let edits: RowEdits

    @Environment(\.dismiss) private var dismiss
    @State private var filesSimilar = true
    @State private var makesRule = false
    @State private var isSaving = false

    private var row: LedgerTransaction { offer.transaction }
    private var others: String { offer.similar == 1 ? "the other one" : "the \(offer.similar) others" }
    /// New rows from this merchant going the same way, filed by a rule.
    private var rule: RuleMatch {
        RuleMatch(merchantContains: row.merchant, direction: row.amount.isNegative ? .moneyOut : .moneyIn)
    }

    var body: some View {
        NavigationStack {
            List {
                DSListSection(footer: "Undo puts every one back.") {
                    DSToggleRow("Also file \(others) as \(offer.category.name)",
                                detail: [similarText, offer.note].compactMap { $0 }.joined(separator: " "),
                                isOn: $filesSimilar)
                        .accessibilityIdentifier("filesSimilar")
                    DSToggleRow("Always file these this way",
                                detail: "A rule files new ones from \(row.merchant) as \(offer.category.name), so they won't need you.",
                                isOn: $makesRule)
                        .accessibilityIdentifier("makesRule")
                }
            }
            .dsGroupedList()
            .navigationTitle("File as \(offer.category.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    Task {
                        isSaving = true
                        if await edits.file([row.id], as: offer.category.id, similar: filesSimilar, rule: makesRule ? rule : nil) { dismiss() }
                        isSaving = false
                    }
                } label: {
                    Text(title).fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.ds(.primary, size: .large, fullWidth: true, isLoading: isSaving))
                .disabled(isSaving)
                .padding(.horizontal, DSSpace.gutter)
                .padding(.vertical, DSSpace.sm)
                .background {
                    Color.ds.canvas.overlay(alignment: .top) { DSDivider() }.ignoresSafeArea(edges: .bottom)
                }
                .accessibilityIdentifier("fileSimilarButton")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.ds.canvas)
    }

    /// Which rows those are: a purchase filed as spending takes its refunds along, so the category stays net of them.
    private var similarText: String {
        let refunds = row.amount.isNegative && offer.category.countsAsSpending
        return "\(row.merchant), \(row.amount.isNegative ? "money out" : "money in")\(refunds ? " and its refunds" : ""), filed some other way now. Same merchant or bank description."
    }

    private var title: String {
        filesSimilar ? "File all \(offer.similar + 1) as \(offer.category.name)" : "File this one as \(offer.category.name)"
    }
}
