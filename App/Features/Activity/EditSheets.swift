import BudgetKit
import DesignSystem
import SwiftUI

/// Give a merchant a better name, on this row or on every row with its bank descriptor (and new ones).
struct RenameMerchantSheet: View {
    let transaction: LedgerTransaction
    /// Saves; returns whether it went through (the sheet stays open to try again when it didn't).
    let onSave: (_ name: String, _ similar: Bool) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var renamesSimilar = true
    @State private var isSaving = false
    @FocusState private var focused: Bool

    private var isGeneric: Bool { Descriptor.isGeneric(transaction.rawDescription) }
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var merchantFooter: String? {
        let original = transaction.originalMerchant.map { "Your bank calls it “\($0)”." }
        let generic = isGeneric ? "“\(transaction.rawDescription)” doesn't name a merchant, so only this transaction gets the name." : nil
        let text = [original, generic].compactMap { $0 }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    var body: some View {
        NavigationStack {
            List {
                DSListSection("Merchant", footer: merchantFooter) {
                    TextField("Name", text: $name)
                        .dsFont(.body)
                        .foregroundStyle(Color.ds.ink)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($focused)
                        .frame(minHeight: 52)
                        .accessibilityIdentifier("merchantName")
                }
                if !isGeneric {
                    DSListSection(footer: "Every “\(transaction.rawDescription)” transaction, and new ones as they arrive.") {
                        DSToggleRow("Rename all like it", isOn: $renamesSimilar)
                    }
                }
            }
            .dsGroupedList()
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task {
                            isSaving = true
                            if await onSave(trimmed, renamesSimilar && !isGeneric) { dismiss() }
                            isSaving = false
                        }
                    }
                    .disabled(trimmed.isEmpty || trimmed == transaction.merchant || isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.ds.canvas)
        .onAppear {
            name = transaction.merchant
            focused = true
        }
    }
}

/// A note on one row or several. Search matches notes.
struct NoteSheet: View {
    let title: String
    let initial: String
    let onSave: (String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isSaving = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            List {
                DSListSection(footer: "Only you see notes. Search finds them.") {
                    TextField("What was this for?", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .dsFont(.body)
                        .foregroundStyle(Color.ds.ink)
                        .focused($focused)
                        .padding(.vertical, DSSpace.sm)
                        .accessibilityIdentifier("noteField")
                }
                if !initial.isEmpty {
                    DSListSection {
                        Button("Remove note", role: .destructive) { save("") }
                            .frame(minHeight: 52)
                    }
                }
            }
            .dsGroupedList()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save(text) }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == initial || isSaving)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.ds.canvas)
        .onAppear {
            text = initial
            focused = true
        }
    }

    private func save(_ value: String) {
        Task {
            isSaving = true
            if await onSave(value) { dismiss() }
            isSaving = false
        }
    }
}
