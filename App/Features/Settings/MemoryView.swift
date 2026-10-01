import BudgetKit
import DesignSystem
import SwiftUI

/// Settings → What Budget has learned: every merchant it now files on its own, and why — your answer, a rule,
/// the model, a statement. Change one, turn it into a rule, or make Budget forget it.
struct MemoryView: View {
    /// Where the remembered answer came from. The chips cover every entry, so their counts add up to All.
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", you = "You", model = "Model", rules = "Rules", learned = "Learned"
        var id: String { rawValue }

        func includes(_ source: CategorizationTier) -> Bool {
            switch self {
            case .all: true
            case .you: source == .user
            case .model: source == .decisionModel
            case .rules: source == .rule
            // Repeated from earlier rows, or from a statement: everything the other chips don't claim.
            case .learned: ![.user, .decisionModel, .rule].contains(source)
            }
        }
    }

    @Environment(AppModel.self) private var app
    @State private var state: LoadState<[RememberedMerchant]> = .loading
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var selected: RememberedMerchant?
    @State private var forgetting: RememberedMerchant?
    @State private var changing: RememberedMerchant?
    @State private var makingRule: RuleEditorSheet.Subject?
    @State private var toast: DSToastMessage?
    @State private var problem: String?

    var body: some View {
        Group {
            switch state {
            case .loading:
                LoadingPlaceholder(text: "Reading what Budget has learned…")
            case let .failed(message):
                DSStateView(systemImage: "wifi.slash", title: "Can't load this", message: message, actionTitle: "Try again") {
                    Task { await load() }
                }
            case let .loaded(entries) where entries.isEmpty:
                DSStateView(systemImage: "brain", title: "Nothing learned yet",
                            message: "When you file a merchant, Budget remembers and files the next one the same way. Those show up here.")
                    .frame(maxHeight: .infinity)
            case let .loaded(entries):
                list(entries)
            }
        }
        // Every state fills the page, so a loading or error state never sits in a band of another colour.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dsScreenBackground()
        .navigationTitle("What Budget has learned")
        .announcesProblem(problem)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: app.revision) { await load() }
        .dsToast($toast)
        .confirmationDialog(selected.map(title) ?? "", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }),
                            titleVisibility: .visible, presenting: selected) { entry in
            Button("Change category") { changing = entry }
            Button("Make a rule") {
                makingRule = .new(prefill: RuleMatch(descriptorContains: entry.descriptor), categoryID: entry.categoryID)
            }
            Button("Forget", role: .destructive) { forgetting = entry }
        } message: { entry in
            Text("Transactions from “\(entry.descriptor)” are filed under \(categoryName(entry)) without asking. \(sourceSentence(entry))")
        }
        .confirmationDialog(forgetting.map { "Forget \($0.merchant)?" } ?? "", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            titleVisibility: .visible, presenting: forgetting) { entry in
            Button("Forget", role: .destructive) { Task { await forget(entry) } }
        } message: { entry in
            Text("The next \(entry.merchant) charge comes to you in Review. Past transactions keep their category.")
        }
        .sheet(item: $changing) { entry in
            CategoryPickerSheet(title: "File \(entry.merchant) under", categories: app.sortedCategories, selected: entry.categoryID) { category in
                Task { await change(entry, to: category) }
            }
        }
        .sheet(item: $makingRule) { RuleEditorSheet(subject: $0) }
    }

    private func list(_ entries: [RememberedMerchant]) -> some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = entries.filter { entry in
            filter.includes(entry.source)
                && (q.isEmpty || entry.merchant.localizedCaseInsensitiveContains(q) || entry.descriptor.localizedCaseInsensitiveContains(q))
        }
        return List {
            Section {
                VStack(alignment: .leading, spacing: DSSpace.sm) {
                    Text("When you file a merchant, Budget remembers and files the next one the same way. Change anything here, or make it forget.")
                        .dsFont(.callout)
                        .foregroundStyle(Color.ds.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, DSSpace.sm)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: DSSpace.xs) {
                            ForEach(Filter.allCases) { option in
                                DSChip(chipTitle(option, entries), isSelected: filter == option) {
                                    withAnimation(DSMotion.standard) { filter = option }
                                }
                            }
                        }
                    }
                }
                .settingsCardRow()
                if let problem {
                    SettingsNote(text: problem, tint: Color.ds.caution, systemImage: "exclamationmark.triangle.fill").settingsCardRow()
                }
            }
            // Money moving between your own accounts isn't a merchant; it gets its own section after them.
            let moves = shown.filter { $0.categoryID == "transfer" }
            let merchants = shown.filter { $0.categoryID != "transfer" }
            let names = Dictionary(grouping: entries, by: \.merchant).mapValues(\.count)
            DSListSection("\(merchants.count) merchant\(merchants.count == 1 ? "" : "s")") {
                if merchants.isEmpty {
                    SettingsNote(text: q.isEmpty ? "None filed this way yet." : "Nothing matches “\(q)”.")
                }
                ForEach(merchants) { entry in entryButton(entry, sharesName: (names[entry.merchant] ?? 0) > 1) }
            }
            if !moves.isEmpty {
                DSListSection("Moves between your accounts", footer: "Filed as transfers, so they count as neither spending nor income.") {
                    ForEach(moves) { entry in entryButton(entry, sharesName: (names[entry.merchant] ?? 0) > 1) }
                }
            }
        }
        .dsGroupedList()
        .searchable(text: $query, prompt: "Merchants")
    }

    private func entryButton(_ entry: RememberedMerchant, sharesName: Bool) -> some View {
        Button { selected = entry } label: { row(entry, sharesName: sharesName) }
            .buttonStyle(.plain)
            .accessibilityHint("Change, make a rule, or forget")
    }

    /// Two entries with one name ("Payment — Thank You" on two cards) are told apart by the bank description.
    private func row(_ entry: RememberedMerchant, sharesName: Bool) -> some View {
        let category = app.category(entry.categoryID)
        let parts = [category?.name ?? "A category that's gone", "\(entry.rowCount) transaction\(entry.rowCount == 1 ? "" : "s")",
                     sharesName ? "“\(entry.descriptor)”" : nil].compactMap { $0 }
        return DSListRow(entry.merchant, detail: parts.joined(separator: " · "),
                         systemImage: category?.symbol ?? "questionmark", tone: CategoryStyle.tone(for: category)) {
            sourceTag(entry)
        }
    }

    @ViewBuilder
    private func sourceTag(_ entry: RememberedMerchant) -> some View {
        switch entry.source {
        case .user: DSTag("You", tint: Color.ds.accent)
        case .decisionModel: DSTag(entry.confidence.map { "Model \(Int(($0 * 100).rounded()))%" } ?? "Model", tint: Color.ds.iris)
        case .rule: DSTag("Rule", tint: Color.ds.azure)
        case .statement: DSTag("Statement")
        default: DSTag("Learned")
        }
    }

    private func chipTitle(_ option: Filter, _ entries: [RememberedMerchant]) -> String {
        option == .all ? "All" : "\(option.rawValue) · \(entries.filter { option.includes($0.source) }.count)"
    }

    private func title(_ entry: RememberedMerchant) -> String { "\(entry.merchant) → \(categoryName(entry))" }

    private func categoryName(_ entry: RememberedMerchant) -> String { app.category(entry.categoryID)?.name ?? "a category that's gone" }

    private func sourceSentence(_ entry: RememberedMerchant) -> String {
        switch entry.source {
        case .user: "You filed it that way."
        case .rule: "A rule filed it that way."
        case .decisionModel: entry.confidence.map { "The model was \(Int(($0 * 100).rounded()))% sure." } ?? "The model filed it."
        case .statement: "Your statement said so."
        default: "It was filed that way before."
        }
    }

    // MARK: Actions

    private func load() async {
        let api = app.api
        state = await state.refreshed { try await api.rememberedMerchants() }
    }

    private func forget(_ entry: RememberedMerchant) async {
        problem = nil
        do {
            try await app.perform(.forgetMerchant(ForgetMerchant(descriptor: entry.descriptor)))
            toast = DSToastMessage("Forgot \(entry.merchant). The next one comes to you.")
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Re-files the newest transaction with this descriptor as your answer, which is what memory learns from.
    private func change(_ entry: RememberedMerchant, to category: BudgetCategory) async {
        problem = nil
        do {
            let api = app.api
            func lookup(_ search: String) async throws -> LedgerTransaction? {
                try await api.transactions(TransactionFilter(search: search, limit: 50)).first { Descriptor.normalize($0.rawDescription) == entry.descriptor }
            }
            // The descriptor usually finds it; a renamed merchant's rows are found by name.
            let found = try await lookup(entry.descriptor)
            let newest = if let found { found } else { try await lookup(entry.merchant) }
            guard let newest else {
                problem = "Couldn't find a \(entry.merchant) transaction to change."
                return
            }
            try await app.perform(.editTransactions(EditTransactions(transactionIDs: [newest.id], categoryID: category.id)))
            toast = DSToastMessage("\(entry.merchant) is filed under \(category.name) from now on.")
        } catch {
            problem = error.localizedDescription
        }
    }
}
