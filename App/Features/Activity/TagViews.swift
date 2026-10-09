import BudgetKit
import DesignSystem
import SwiftUI

// Tags: the person's own labels on transactions (a trip, a project, what work pays back). Edited from a transaction's
// details and from Select in Activity, filtered on in Activity's Filters, and added up in a tag's own screen.

extension AppModel {
    /// Tags and the CSV export, when this connection can answer them (the server, the demo; not "no server yet").
    var transactionTools: (any TransactionToolsAPI)? { api as? any TransactionToolsAPI }
}

/// A tag to open, for `navigationDestination(item:)`.
struct TagRoute: Hashable, Identifiable {
    let tag: String
    var id: String { tag.lowercased() }
}

// MARK: - Editing

/// Tags on one row, or on several at once: the ones there now (any of them taken off every row), a field to add one,
/// and the tags already in use to add with a tap. Saves what changed as one edit.
struct TagSheet: View {
    let title: String
    /// Tags on the rows now (on any of them, for several).
    let current: [String]
    /// How many rows the edit reaches, for the footer.
    var rowCount = 1
    /// Saves; returns whether it went through (the sheet stays open to try again when it didn't).
    let onSave: (_ add: [String], _ remove: [String]) async -> Bool

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var tags: [String] = []
    @State private var text = ""
    @State private var inUse: [TagSummary] = []
    @State private var isSaving = false
    @FocusState private var focused: Bool

    private var added: [String] { tags.filter { !TransactionTags.contains(current, $0) } }
    private var removed: [String] { current.filter { !TransactionTags.contains(tags, $0) } }
    private var pending: String? { TransactionTags.normalize(text) }
    private var tooLong: Bool { (pending?.count ?? 0) > TransactionTags.maxLength }
    private var full: Bool { tags.count >= TransactionTags.maxPerTransaction }

    var body: some View {
        NavigationStack {
            List {
                DSListSection(footer: footer) {
                    DSField(nil, style: .inline, error: tooLong ? "Keep a tag to \(TransactionTags.maxLength) characters." : nil,
                            isFocused: focused) {
                        TextField(full ? "That's \(TransactionTags.maxPerTransaction) tags" : "Add a tag, like Austin trip", text: $text)
                            .textInputAutocapitalization(.sentences)
                            .submitLabel(.done)
                            .focused($focused)
                            .onSubmit(addTyped)
                            .disabled(full)
                            .accessibilityIdentifier("tagField")
                    }
                    ForEach(tags, id: \.self) { tag in
                        DSListRow(tag, systemImage: "tag", tone: .cyan) {
                            Button { tags.removeAll { $0 == tag } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: DSIconSize.lg))
                                    .foregroundStyle(Color.ds.inkTertiary)
                                    .frame(width: DSSize.hitTarget, height: DSSize.hitTarget)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(tag)")
                        }
                        .accessibilityAction(named: "Remove") { tags.removeAll { $0 == tag } }
                    }
                }
                let suggestions = inUse.filter { !TransactionTags.contains(tags, $0.tag) }
                if !suggestions.isEmpty, !full {
                    DSListSection("Used before") {
                        DSFlowLayout(spacing: DSSpace.xs, lineSpacing: DSSpace.xs) {
                            ForEach(suggestions) { summary in
                                DSChip(summary.tag, systemImage: "plus") { tags.append(summary.tag) }
                                    .accessibilityHint("Adds the tag")
                            }
                        }
                        .padding(.vertical, DSSpace.sm)
                    }
                }
            }
            .dsGroupedList()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { save() }
                        .disabled((added.isEmpty && removed.isEmpty && pending == nil) || tooLong || isSaving)
                        .accessibilityIdentifier("saveTags")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.ds.canvas)
        .onAppear { tags = current }
        .task { inUse = (try? await app.transactionTools?.tags(period: nil)) ?? [] }
    }

    private var footer: String {
        let reach = rowCount == 1 ? "this transaction" : "all \(rowCount)"
        return "Your own labels for a trip, a project or what work pays back. Changes reach \(reach). Search and Filters find them."
    }

    /// The typed tag joins the list, spelled as the ledger already spells it.
    private func addTyped() {
        guard let tag = pending, !tooLong, !full else { return }
        if !TransactionTags.contains(tags, tag) {
            tags.append(inUse.first { $0.tag.lowercased() == tag.lowercased() }?.tag ?? tag)
        }
        text = ""
        focused = true
    }

    private func save() {
        addTyped()
        Task {
            isSaving = true
            if await onSave(added, removed) { dismiss() }
            isSaving = false
        }
    }
}

// MARK: - Filtering

/// Filters → Tags: any of the chosen tags.
struct TagFilterPicker: View {
    @Binding var selection: [String]
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<[TagSummary]> = .loading

    var body: some View {
        List {
            switch state {
            case .loading:
                LoadingPlaceholder(text: "Finding your tags…")
            case let .failed(message):
                DSStateView(systemImage: "tag", title: "Tags aren't available", message: message)
            case let .loaded(tags) where tags.isEmpty:
                DSStateView(systemImage: "tag", title: "No tags yet",
                            message: "Tag transactions from their details, or select several and tag them together.")
            case let .loaded(tags):
                DSListSection {
                    Button { selection = [] } label: {
                        DSListRow("Any tag") { CheckMark(isOn: selection.isEmpty) }
                    }
                    .buttonStyle(.plain)
                }
                DSListSection("Tags", footer: "Shows transactions with any of the tags you pick.") {
                    ForEach(tags) { summary in
                        let isOn = TransactionTags.contains(selection, summary.tag)
                        Button { toggle(summary.tag) } label: {
                            DSListRow(summary.tag, detail: summary.count == 1 ? "1 transaction" : "\(summary.count) transactions",
                                      systemImage: "tag", tone: .cyan) { CheckMark(isOn: isOn) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isOn ? .isSelected : [])
                    }
                }
            }
        }
        .dsGroupedList()
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let tools = app.transactionTools else {
                state = .failed("This connection can't list tags.")
                return
            }
            do { state = .loaded(try await tools.tags(period: nil)) } catch BudgetAPIError.notFound {
                state = .failed("Your Budget server is older than this app. Update it to tag transactions.")
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func toggle(_ tag: String) {
        if TransactionTags.contains(selection, tag) { selection.removeAll { $0.lowercased() == tag.lowercased() } } else { selection.append(tag) }
    }
}

// MARK: - A tag's own screen

/// What one tag adds up to, by the Spending tab's rules (net of refunds; hidden rows and transfers left out), by
/// category, and its transactions.
struct TagDetailView: View {
    let tag: String
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<(summary: TagSummary, rows: [LedgerTransaction])> = .loading

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.lg) {
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    DSEyebrow("Tag")
                    Text(tag)
                        .dsFont(.title)
                        .foregroundStyle(Color.ds.ink)
                        .accessibilityAddTraits(.isHeader)
                }
                switch state {
                case .loading:
                    LoadingPlaceholder()
                case let .failed(message):
                    DSStateView(systemImage: "tag", title: "Can't add this tag up", message: message, actionTitle: "Try again") {
                        Task { await load() }
                    }
                case let .loaded(value):
                    totals(value.summary)
                    if let categories = value.summary.byCategory, !categories.isEmpty { byCategory(categories) }
                    transactions(value.rows)
                }
            }
            .padding(.horizontal, DSSpace.gutter)
            .padding(.top, DSSpace.sm)
            .padding(.bottom, DSSpace.xl)
        }
        .dsScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(tag)|\(app.revision)") { await load() }
    }

    private func totals(_ summary: TagSummary) -> some View {
        DSCard(padding: DSSpace.md) {
            VStack(alignment: .leading, spacing: DSSpace.md) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: DSSpace.md) { figures(summary) }
                    VStack(alignment: .leading, spacing: DSSpace.md) { figures(summary) }
                }
                Text(caption(summary))
                    .dsFont(.callout)
                    .foregroundStyle(Color.ds.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func figures(_ summary: TagSummary) -> some View {
        DSStatBlock(label: "Spent", value: summary.spent.decimal, currencyCode: summary.spent.currencyCode, footnote: "Net of refunds")
        if summary.income.minorUnits != 0 {
            DSStatBlock(label: "Money in", value: summary.income.decimal, currencyCode: summary.income.currencyCode, tint: Color.ds.inflow)
        }
    }

    private func caption(_ summary: TagSummary) -> String {
        let count = summary.count == 1 ? "1 transaction" : "\(summary.count) transactions"
        guard let first = summary.earliest, let last = summary.latest else { return count }
        let range = Calendar.current.isDate(first, inSameDayAs: last) ? last.formatted(.dateTime.month(.abbreviated).day().year())
            : "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day().year()))"
        return "\(count), \(range). Hidden ones and transfers aren't counted."
    }

    private func byCategory(_ categories: [TagSummary.CategorySpend]) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            DSEyebrow("By category")
            DSCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(categories.enumerated()), id: \.element.categoryID) { index, spend in
                        let category = app.category(spend.categoryID)
                        DSListRow(category?.name ?? spend.categoryID, value: spend.spent.formatted(), systemImage: category?.symbol ?? "questionmark",
                                  tone: CategoryStyle.tone(for: category))
                        if index < categories.count - 1 { DSDivider() }
                    }
                }
                .padding(.horizontal, DSSpace.md)
            }
        }
    }

    private func transactions(_ rows: [LedgerTransaction]) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            DSEyebrow("Transactions")
            DSCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        NavigationLink(value: row) { LedgerRow(transaction: row, detail: .day) }
                            .buttonStyle(.plain)
                        if index < rows.count - 1 { DSDivider() }
                    }
                }
                .padding(.horizontal, DSSpace.md)
                .padding(.vertical, DSSpace.xxs)
            }
        }
    }

    private func load() async {
        guard let tools = app.transactionTools else {
            state = .failed("This connection can't add up tags.")
            return
        }
        do {
            async let summary = tools.tag(tag, period: nil)
            async let rows = app.api.transactions(TransactionFilter(limit: 500, tags: [tag]))
            state = .loaded((try await summary, try await rows))
        } catch BudgetAPIError.notFound {
            state = .failed("No transaction carries “\(tag)” now.")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

/// A transaction's tags as chips that open each tag, under its Tags row.
struct TagChips: View {
    let tags: [String]
    let onOpen: (String) -> Void

    var body: some View {
        DSFlowLayout(spacing: DSSpace.xs, lineSpacing: DSSpace.xs) {
            ForEach(tags, id: \.self) { tag in
                DSChip(tag, systemImage: "tag") { onOpen(tag) }
                    .accessibilityHint("Shows everything tagged \(tag)")
            }
        }
    }
}

// MARK: - Export

/// The rows a filter matches as a CSV file, written only when the person picks where it goes (ShareLink).
struct TransactionsCSV: Transferable {
    let filter: TransactionFilter
    let tools: any TransactionToolsAPI

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { export in
            let data = try await export.tools.exportCSV(export.filter)
            let day = Date.now.formatted(.iso8601.year().month().day())
            let url = FileManager.default.temporaryDirectory.appending(path: "Budget transactions \(day).csv")
            try data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
