import BudgetKit
import DesignSystem
import SwiftUI

/// Settings → Categories: "Add a category" first, then every spending category by how it's budgeted, with its colour,
/// icon and monthly target; then money in (Income and any like card rewards) and Transfer. Tap one to edit it; the row
/// at the top and "+" add one (named after the search, when there is one).
struct CategoriesView: View {
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<[BudgetCategory]> = .loading
    @State private var targets: [String: Money] = [:]
    @State private var query = ""
    @State private var showsArchived = false
    @State private var editing: CategoryEditorSheet.Subject?
    @State private var restoring: BudgetCategory?
    @State private var problem: String?

    var body: some View {
        Group {
            switch state {
            case .loading:
                LoadingPlaceholder(text: "Reading your categories…")
            case let .failed(message):
                DSStateView(systemImage: "wifi.slash", title: "Can't load categories", message: message, actionTitle: "Try again") {
                    Task { await load() }
                }
            case let .loaded(categories):
                list(categories)
            }
        }
        // Every state fills the page, so a loading or error state never sits in a band of another colour.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dsScreenBackground()
        .navigationTitle("Categories")
        .announcesProblem(problem)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = .new } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add a category")
                    .accessibilityIdentifier("addCategoryToolbar")
            }
        }
        .task(id: app.revision) { await load() }
        .sheet(item: $editing) { subject in
            CategoryEditorSheet(subject: subject, all: state.value ?? [], target: subject.category.flatMap { targets[$0.id] },
                                initialName: subject.category == nil ? query.trimmingCharacters(in: .whitespaces) : "")
        }
        .confirmationDialog(restoring.map { "Bring back \($0.name)?" } ?? "", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
                            titleVisibility: .visible, presenting: restoring) { category in
            Button("Bring it back") { Task { await restore(category) } }
        } message: { _ in
            Text("New transactions can be filed under it again. Transactions that moved to another category stay there.")
        }
    }

    private func list(_ categories: [BudgetCategory]) -> some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = categories.filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
        let active = shown.filter { !$0.isArchived }
        let archived = shown.filter(\.isArchived)
        return List {
            if let problem {
                Section { SettingsNote(text: problem, tint: Color.ds.caution, systemImage: "exclamationmark.triangle.fill") }
                    .listRowBackground(Color.ds.surface)
            }
            DSListSection {
                Button { editing = .new } label: {
                    DSListRow("Add a category", detail: q.isEmpty ? nil : "Named “\(q)”", systemImage: "plus", tone: .cyan)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("addCategory")
            }
            ForEach(CategoryGroup.allCases, id: \.self) { group in
                let rows = active.filter { $0.countsAsSpending && $0.group == group }
                if !rows.isEmpty {
                    DSListSection(group.label, footer: CategoryEditorSheet.explanation(group)) {
                        ForEach(rows) { row($0) }
                    }
                }
            }
            let moneyIn = active.filter(\.isMoneyIn)
            if !moneyIn.isEmpty {
                DSListSection("Money in", footer: "Counts as money coming in, like income: never spending, never budgeted. Income keeps its name.") {
                    ForEach(moneyIn) { row($0) }
                }
            }
            let neither = active.filter { !$0.countsAsSpending && !$0.isMoneyIn }
            if !neither.isEmpty {
                DSListSection("Not spending", footer: "Moves between your own accounts count as neither spending nor money in. Transfer keeps its name; you can change its color and icon.") {
                    ForEach(neither) { row($0) }
                }
            }
            if active.isEmpty, !q.isEmpty {
                Section { SettingsNote(text: "No category called “\(q)”. Add it with the row above.") }
                    .listRowBackground(Color.ds.surface)
            }
            if !categories.filter(\.isArchived).isEmpty {
                DSListSection(footer: "Merged and deleted categories stay out of every picker. Bring one back to file under it again.") {
                    DSToggleRow("Show categories no longer in use", isOn: $showsArchived.animation(DSMotion.standard))
                    if showsArchived {
                        ForEach(archived) { category in
                            Button { restoring = category } label: {
                                DSListRow(category.name, detail: "Not in use", systemImage: category.symbol, tone: CategoryStyle.tone(for: category)) {
                                    DSListValue("Bring back")
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .dsGroupedList()
        .searchable(text: $query, prompt: "Categories")
    }

    private func row(_ category: BudgetCategory) -> some View {
        Button { editing = .edit(category) } label: {
            DSListRow(category.name, systemImage: category.symbol, tone: CategoryStyle.tone(for: category)) {
                HStack(spacing: DSSpace.xs) {
                    if category.isSystem {
                        DSTag("Built in")
                    } else if let target = targets[category.id] {
                        DSListValue("\(target.shortString) a month")
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.ds.inkTertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Edit")
        .accessibilityIdentifier("category-\(category.id)")
    }

    private func load() async {
        let api = app.api
        async let spending = try? api.spending(.thisMonth)
        state = await state.refreshed { try await api.categories() }
        if let totals = await spending?.categories {
            targets = Dictionary(uniqueKeysWithValues: totals.compactMap { total in total.target.map { (total.id, $0) } })
        }
    }

    private func restore(_ category: BudgetCategory) async {
        problem = nil
        do {
            try await app.perform(.createCategory(CreateCategory(name: category.name)))
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Adds a category, or edits one: its name, how it's budgeted, its colour and icon. Merging (or deleting an
/// empty one) is at the bottom. Everything goes through `AppModel.perform`, like the assistant's proposals.
struct CategoryEditorSheet: View {
    enum Subject: Identifiable {
        case new
        case edit(BudgetCategory)

        var id: String {
            switch self {
            case .new: "new"
            case let .edit(category): category.id
            }
        }

        var category: BudgetCategory? {
            if case let .edit(category) = self { return category }
            return nil
        }
    }

    let subject: Subject
    /// Every category, archived ones included, for colours in use and merge targets.
    let all: [BudgetCategory]
    let target: Money?
    /// A new category's starting name: what was typed in the search it was made from.
    var initialName = ""
    /// A new category's starting type: money in when the picker it came from is for money coming in.
    var initialKind: CategoryKind?
    /// Called with a new category once the ledger has it, before the sheet closes: a picker files under it.
    var onCreated: ((BudgetCategory) -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var filled = false
    @State private var name = ""
    @State private var kind: CategoryKind = .spending
    @State private var group: CategoryGroup = .everyday
    @State private var tone: DSTone = .amber
    @State private var symbol = "tag"
    @State private var symbolQuery = ""
    @State private var isSaving = false
    @State private var problem: String?
    /// Rows and rules filed under the category: merging moves them, and with none it can simply go.
    @State private var usage: (rows: Int, rules: Int)?
    /// The count couldn't be had (offline): merging waits, and says why instead of counting forever.
    @State private var usageFailed = false
    @State private var picksMergeTarget = false
    @State private var mergePlan: MergePlan?
    @State private var confirmsDelete = false

    struct MergePlan: Identifiable {
        let into: BudgetCategory
        let preview: ActionPreview
        var id: String { into.id }
    }

    private var original: BudgetCategory? { subject.category }
    /// Income and Transfer: their names stay, and they aren't merged.
    private var isSystem: Bool { original?.isSystem ?? false }
    /// Transfer: neither spending nor money in.
    private var isNeither: Bool { original.map { !$0.countsAsSpending && !$0.isMoneyIn } ?? false }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpace.xl) {
                    header
                    type
                    if kind == .spending, !isNeither { budgetType }
                    colour
                    icon
                    if let original, !isSystem { mergeSection(original) }
                    if let problem {
                        Text(problem)
                            .dsFont(.callout)
                            .foregroundStyle(Color.ds.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, DSSpace.gutter)
                .padding(.top, DSSpace.md)
                .padding(.bottom, DSSpace.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .dsScreenBackground()
            .safeAreaInset(edge: .bottom) { saveBar }
            .navigationTitle(original == nil ? "New category" : "Edit category")
            .announcesProblem(problem)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationBackground(Color.ds.canvas)
        .onAppear(perform: fill)
        .task { await loadUsage() }
        .sheet(isPresented: $picksMergeTarget) {
            CategoryPickerSheet(title: "Merge into", categories: mergeTargets, allowsNew: false) { into in
                Task { await planMerge(into: into) }
            }
        }
        .confirmationDialog(mergePlan?.preview.title ?? "", isPresented: Binding(get: { mergePlan != nil }, set: { if !$0 { mergePlan = nil } }),
                            titleVisibility: .visible, presenting: mergePlan) { plan in
            if target != nil {
                Button("Merge and add its target to \(plan.into.name)", role: .destructive) { Task { await merge(into: plan.into, combineTargets: true) } }
                Button("Merge and drop its target", role: .destructive) { Task { await merge(into: plan.into, combineTargets: false) } }
            } else {
                Button("Merge", role: .destructive) { Task { await merge(into: plan.into, combineTargets: false) } }
            }
        } message: { plan in
            Text(mergeMessage(plan))
        }
        .confirmationDialog("Delete \(original?.name ?? "")?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Nothing is filed under it and no rule uses it.")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: DSSpace.md) {
            DSGlyph(systemImage: symbol, tone: tone, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("Name").dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                if isSystem {
                    Text(name).dsFont(.headline).foregroundStyle(Color.ds.ink)
                    Text("Built in, so its name stays.").dsFont(.caption).foregroundStyle(Color.ds.inkTertiary)
                } else {
                    TextField("Name", text: $name, prompt: Text("Pets, Gifts, Kids…"))
                        .dsFont(.headline)
                        .foregroundStyle(Color.ds.ink)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .accessibilityIdentifier("categoryName")
                    DSDivider()
                }
            }
        }
    }

    /// Spending or money in: chosen when the category is made, shown (not changed) after.
    @ViewBuilder
    private var type: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            DSEyebrow("Type")
            if original == nil {
                Picker("Type", selection: $kind.animation(DSMotion.standard)) {
                    ForEach(CategoryKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .segmentedUnlessLargeText()
                .accessibilityIdentifier("categoryType")
            } else {
                Text(isNeither ? "Not spending" : kind.label)
                    .dsFont(.headline)
                    .foregroundStyle(Color.ds.ink)
                    .accessibilityIdentifier("categoryType")
            }
            if let line = typeExplanation {
                Text(line)
                    .dsFont(.caption)
                    .foregroundStyle(Color.ds.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One line under the type: what money in does, and what Transfer is.
    private var typeExplanation: String? {
        if isNeither { return "Money moving between your own accounts: neither spending nor money in." }
        if original?.id == BudgetCategory.incomeID { return "Pay, interest and other money you receive." }
        return kind == .moneyIn ? "Counts as money coming in, like income." : nil
    }

    private var budgetType: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            DSEyebrow("Budget type")
            Picker("Budget type", selection: $group) {
                ForEach(CategoryGroup.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .segmentedUnlessLargeText()
            Text(Self.explanation(group))
                .dsFont(.caption)
                .foregroundStyle(Color.ds.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .animation(nil, value: group)
        }
    }

    private var colour: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            DSEyebrow("Color · \(tone.displayName)")
            DSSwatchGrid(selection: $tone, inUse: coloursInUse)
            Text("A dot marks colors other categories already use.")
                .dsFont(.caption)
                .foregroundStyle(Color.ds.inkTertiary)
        }
    }

    private var icon: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            DSEyebrow("Icon")
            HStack(spacing: DSSpace.xs) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.ds.inkTertiary).accessibilityHidden(true)
                TextField("Search icons", text: $symbolQuery, prompt: Text("Search: coffee, pets, gym…"))
                    .dsFont(.body)
                    .foregroundStyle(Color.ds.ink)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, DSSpace.sm)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous).fill(Color.ds.surface))
            let found = DSSymbol.search(symbolQuery, in: symbols)
            if found.isEmpty {
                Text("No icon matches “\(symbolQuery)”.").dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
            } else {
                DSSymbolGrid(selection: $symbol, symbols: found, tone: tone)
            }
        }
    }

    @ViewBuilder
    private func mergeSection(_ category: BudgetCategory) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            DSEyebrow("Merge or delete")
            if let usage {
                if usage.rows == 0, usage.rules == 0 {
                    Button("Delete \(category.name)") { confirmsDelete = true }
                        .buttonStyle(.ds(.secondary, fullWidth: true))
                    Text("Nothing is filed under it, so it can simply go.")
                        .dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                } else {
                    Button("Merge into another category…") { picksMergeTarget = true }
                        .buttonStyle(.ds(.secondary, fullWidth: true))
                    Text(usageLine(usage) + " Merging moves them, then \(category.name) goes away.")
                        .dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if usageFailed {
                Text("Couldn't count what's filed under it, so merging waits until your Olares answers.")
                    .dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { Task { await loadUsage() } }
                    .buttonStyle(.ds(.quiet))
                    .frame(minHeight: 44)
            } else {
                Text("Counting what's filed under it…").dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
            }
        }
    }

    private var saveBar: some View {
        VStack(spacing: 0) {
            Button(isSaving ? "Saving…" : original == nil ? "Add category" : "Save") { Task { await save() } }
                .buttonStyle(.ds(.primary, fullWidth: true))
                .disabled(isSaving || !canSave)
                .accessibilityIdentifier("saveCategory")
        }
        .padding(.horizontal, DSSpace.gutter)
        .padding(.vertical, DSSpace.sm)
        .background { Color.ds.canvas.ignoresSafeArea(edges: .bottom) }
        .overlay(alignment: .top) { DSDivider() }
    }

    // MARK: Values

    /// Plain words for what a budget type does to safe to spend. Also the Categories list's section footers.
    static func explanation(_ group: CategoryGroup) -> String {
        switch group {
        case .bills: "What you owe each month: rent, utilities, insurance. A usual month is set aside before safe to spend."
        case .subscriptions: "What you pay for on a schedule and choose to keep: streaming, apps, memberships. Set aside like bills."
        case .everyday: "Comes out of safe to spend as you go: groceries, dining, shopping, trips."
        }
    }

    /// The 48 budget symbols, plus the category's own when it wears one from elsewhere (an assistant-made category).
    private var symbols: [DSSymbol] {
        let base = DSSymbol.budgetCategories
        guard let original, !base.contains(where: { $0.systemName == original.symbol }) else { return base }
        return [DSSymbol(original.symbol, label: original.name)] + base
    }

    private var coloursInUse: Set<DSTone> {
        Set(all.filter { !$0.isArchived && $0.id != original?.id }.map { CategoryStyle.tone(for: $0) })
    }

    /// The same kind only: spending into spending, money in into money in (Transfer never merges).
    private var mergeTargets: [BudgetCategory] {
        all.filter { !$0.isArchived && $0.id != original?.id && $0.kind == kind && ($0.countsAsSpending || $0.isMoneyIn) }.sorted { $0.name < $1.name }
    }

    private var canSave: Bool {
        guard !trimmedName.isEmpty else { return false }
        guard let original else { return true }
        return original.name != trimmedName || original.group != group || original.symbol != symbol || CategoryStyle.tone(for: original) != tone
    }

    /// "Moves 38 transactions and 2 rules to Groceries, then Health goes away." — and what happens to its target.
    private func mergeMessage(_ plan: MergePlan) -> String {
        let name = original?.name ?? "It"
        var text = "Moves \(usage.map { usageList($0) } ?? "everything filed under it") to \(plan.into.name), then \(name) goes away."
        if let target { text += " Its \(target.shortString) target can join \(plan.into.name)'s or be dropped." }
        return text
    }

    private func usageList(_ usage: (rows: Int, rules: Int)) -> String {
        var parts: [String] = []
        if usage.rows > 0 { parts.append("\(usage.rows) transaction\(usage.rows == 1 ? "" : "s")") }
        if usage.rules > 0 { parts.append("\(usage.rules) rule\(usage.rules == 1 ? "" : "s")") }
        return parts.joined(separator: " and ")
    }

    private func usageLine(_ usage: (rows: Int, rules: Int)) -> String {
        usageList(usage) + " \(usage.rows + usage.rules == 1 ? "is" : "are") filed under it."
    }

    // MARK: Actions

    private func fill() {
        guard !filled else { return }
        filled = true
        guard let original else {
            name = initialName
            kind = initialKind ?? .spending
            // A new category starts on the colour the others use least, as the ledger would pick.
            let used = Dictionary(grouping: all.filter { !$0.isArchived }.map { CategoryStyle.tone(for: $0) }, by: { $0 }).mapValues(\.count)
            tone = DSTone.swatches.min { used[$0, default: 0] < used[$1, default: 0] } ?? .amber
            return
        }
        name = original.name
        kind = original.kind
        group = original.group
        symbol = original.symbol
        tone = CategoryStyle.tone(for: original)
    }

    private func loadUsage() async {
        guard let original, !original.isSystem, original.countsAsSpending || original.isMoneyIn else { return }
        let api = app.api
        async let summary = try? api.transactionSummary(TransactionFilter(categoryID: original.id))
        async let rules = try? api.rules()
        let rows = await summary?.count
        let ruleCount = await rules?.filter { $0.rule.categoryID == original.id }.count
        if let rows, let ruleCount { usage = (rows, ruleCount) }
        usageFailed = usage == nil
    }

    private func save() async {
        isSaving = true
        problem = nil
        defer { isSaving = false }
        let action: AppAction
        if let original {
            action = .updateCategory(UpdateCategory(
                categoryID: original.id,
                name: !isSystem && trimmedName != original.name ? trimmedName : nil,
                symbol: symbol != original.symbol ? symbol : nil,
                color: tone != CategoryStyle.tone(for: original) ? tone.token : nil,
                group: !isSystem && kind == .spending && group != original.group ? group : nil))
        } else {
            // Money in isn't budgeted, so it's made without a budget type.
            action = .createCategory(CreateCategory(name: trimmedName, symbol: symbol, group: kind == .spending ? group : nil, color: tone.token, kind: kind))
        }
        do {
            try await app.perform(action)
            if original == nil, let onCreated, let made = await createdCategory() { onCreated(made) }
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The category the ledger just made (or brought back, under its old spelling). Found by name: a new category's id
    /// is the ledger's to choose.
    private func createdCategory() async -> BudgetCategory? {
        let name = trimmedName
        let isIt = { (c: BudgetCategory) in !c.isArchived && c.name.caseInsensitiveCompare(name) == .orderedSame }
        if let made = app.sortedCategories.first(where: isIt) { return made }
        return try? await app.api.categories().first(where: isIt)
    }

    private func planMerge(into: BudgetCategory) async {
        guard let original else { return }
        problem = nil
        do {
            // The preview runs the ledger's own checks, so a merge it would refuse says why before anything is asked.
            let preview = try await app.api.preview(.mergeCategory(MergeCategory(from: original.id, into: into.id)))
            mergePlan = MergePlan(into: into, preview: preview)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func merge(into: BudgetCategory, combineTargets: Bool) async {
        guard let original else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await app.perform(.mergeCategory(MergeCategory(from: original.id, into: into.id, combineTargets: combineTargets)))
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// A category with nothing filed under it goes the one way the ledger removes categories: merged, moving nothing.
    private func delete() async {
        guard let into = mergeTargets.first else { return }
        await merge(into: into, combineTargets: false)
    }
}
