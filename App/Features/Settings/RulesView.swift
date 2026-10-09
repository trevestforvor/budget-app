import BudgetKit
import DesignSystem
import SwiftUI

/// Settings → Rules: "always file these under that", newest first — the order they're tried in. Rules that
/// disagree, or that can't file anything any more, say so.
struct RulesView: View {
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<[RuleSummary]> = .loading
    @State private var editing: RuleEditorSheet.Subject?
    @State private var deleting: RuleSummary?
    @State private var problem: String?

    var body: some View {
        Group {
            switch state {
            case .loading:
                LoadingPlaceholder(text: "Reading your rules…")
            case let .failed(message):
                DSStateView(systemImage: "wifi.slash", title: "Can't load rules", message: message, actionTitle: "Try again") {
                    Task { await load() }
                }
            case let .loaded(rules) where rules.isEmpty:
                DSStateView(systemImage: "arrow.triangle.branch", title: "No rules yet",
                            message: "Most merchants file themselves after you answer once. A rule is for the ones that need a firmer hand: a paycheck, a transfer, one account's withdrawals.",
                            actionTitle: "Add a rule") { editing = .new() }
                    .frame(maxHeight: .infinity)
            case let .loaded(rules):
                list(rules)
            }
        }
        // Every state fills the page, so a loading or error state never sits in a band of another colour.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dsScreenBackground()
        .navigationTitle("Rules")
        .announcesProblem(problem)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Only once the rules loaded: a server that can't list them (an older one) can't save the editor's rules either.
            if state.value != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button { editing = .new() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add a rule")
                }
            }
        }
        .task(id: app.revision) { await load() }
        .sheet(item: $editing) { RuleEditorSheet(subject: $0) }
        .confirmationDialog("Delete this rule?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { summary in
            Button("Delete rule", role: .destructive) { Task { await delete(summary) } }
        } message: { summary in
            Text(summary.hitCount == 0 ? "It hasn't filed anything yet."
                 : "The \(summary.hitCount) transaction\(summary.hitCount == 1 ? "" : "s") it filed keep\(summary.hitCount == 1 ? "s" : "") \(summary.hitCount == 1 ? "its" : "their") category.")
        }
    }

    private func list(_ rules: [RuleSummary]) -> some View {
        List {
            Section {
                SettingsCaption("Rules run first, before what Budget has learned and the model. When two match the same transaction, the newer one wins.")
                if let notice = conflictNotice(rules) {
                    DSNoticeCard(notice.title, message: notice.message, actionTitle: "Edit the newer rule") { editing = .edit(notice.newer) }
                        .settingsCardRow()
                }
                if let problem {
                    SettingsNote(text: problem, tint: Color.ds.caution, systemImage: "exclamationmark.triangle.fill")
                        .settingsCardRow()
                }
            }
            DSListSection(footer: "Swipe a rule to turn it off or delete it.") {
                ForEach(rules) { summary in
                    Button { editing = .edit(summary) } label: {
                        RuleRow(summary: summary, category: app.category(summary.rule.categoryID))
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button { deleting = summary } label: { Label("Delete", systemImage: "trash") }
                            .tint(Color.ds.cautionFill)
                    }
                    .swipeActions(edge: .leading) {
                        Button { Task { await toggle(summary) } } label: {
                            Label(summary.rule.isEnabled ? "Turn off" : "Turn on", systemImage: summary.rule.isEnabled ? "pause" : "play")
                        }
                        .tint(Color.ds.irisDeep)
                    }
                    .accessibilityActions {
                        Button(summary.rule.isEnabled ? "Turn off" : "Turn on") { Task { await toggle(summary) } }
                        Button("Delete") { deleting = summary }
                    }
                }
            }
        }
        .dsGroupedList()
    }

    /// The first pair of rules that disagree, said in words, and the newer of the two (the one that wins).
    private func conflictNotice(_ rules: [RuleSummary]) -> (title: String, message: String, newer: RuleSummary)? {
        let conflicted = rules.filter { !$0.conflicts.isEmpty }
        // Newest first, so the first conflicted rule is the newer of its pair.
        guard let newer = conflicted.first, let other = rules.first(where: { newer.conflicts.contains($0.id) }) else { return nil }
        let pairs = Set(conflicted.flatMap { rule in rule.conflicts.map { [rule.id, $0].sorted().joined(separator: "|") } }).count
        func name(_ summary: RuleSummary) -> String { app.category(summary.rule.categoryID)?.name ?? "a category that's gone" }
        return (pairs == 1 ? "2 rules disagree" : "\(pairs) pairs of rules disagree",
                "\(newer.matchDescription) files under \(name(newer)); \(other.matchDescription) files under \(name(other)). "
                    + "They both match some of the same transactions, and the newer one, \(name(newer)), wins them.",
                newer)
    }

    private func load() async {
        let api = app.api
        state = await state.refreshed { try await api.rules() }
    }

    private func toggle(_ summary: RuleSummary) async {
        problem = nil
        do {
            try await app.perform(.updateBudgetRule(UpdateBudgetRule(ruleID: summary.id, isEnabled: !summary.rule.isEnabled)))
        } catch {
            problem = error.localizedDescription
        }
    }

    private func delete(_ summary: RuleSummary) async {
        problem = nil
        do {
            try await app.perform(.deleteBudgetRule(DeleteBudgetRule(ruleID: summary.id)))
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// One rule: what it matches, where it files, and what it has done.
private struct RuleRow: View {
    let summary: RuleSummary
    let category: BudgetCategory?

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text(summary.matchDescription)
                .dsFont(.body)
                .foregroundStyle(summary.rule.isEnabled ? Color.ds.ink : Color.ds.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: DSSpace.xs) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: DSIconSize.xs, weight: .semibold))
                    .foregroundStyle(Color.ds.inkTertiary)
                DSGlyph(systemImage: category?.symbol ?? "questionmark", tone: CategoryStyle.tone(for: category), size: 22,
                        emphasis: summary.rule.isEnabled && !summary.isDead ? .normal : .muted)
                Text(category?.name ?? "A category that's gone")
                    .dsFont(.callout)
                    .foregroundStyle(Color.ds.inkSoft)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Files under \(category?.name ?? "a category that's gone")")
            DSFlowLayout(spacing: DSSpace.xs, lineSpacing: DSSpace.xxs) {
                Text(caption).dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                if !summary.rule.isEnabled { DSTag("Off") }
                if summary.isDead { DSTag("Files nothing", systemImage: "exclamationmark", tint: Color.ds.amber) }
                if !summary.conflicts.isEmpty { DSTag("Disagrees", systemImage: "exclamationmark", tint: Color.ds.caution) }
            }
        }
        .padding(.vertical, DSSpace.sm)
        .frame(maxWidth: .infinity, minHeight: DSSize.listRow, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edit")
    }

    private var caption: String {
        var parts = [summary.hitCount == 0 ? "Hasn't filed anything" : "Filed \(summary.hitCount)"]
        parts.append(summary.rule.createdBy == .assistant ? "added by Ask" : "added by you")
        if let created = summary.rule.createdAt { parts.append(created.formatted(.dateTime.month(.abbreviated).day())) }
        return parts.joined(separator: " · ")
    }
}

/// Adds or changes a rule, with a live preview of what it matches in the ledger now (debounced), the rules it
/// would disagree with, and whether to re-file what's already there.
struct RuleEditorSheet: View {
    enum Subject: Identifiable {
        case new(prefill: RuleMatch? = nil, categoryID: String? = nil)
        case edit(RuleSummary)

        var id: String {
            switch self {
            case let .new(prefill, _): "new-\(prefill?.descriptorContains ?? "")"
            case let .edit(summary): summary.id
            }
        }
    }

    let subject: Subject

    private enum RangeEnd: Hashable { case min, max }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var descriptor = ""
    @State private var merchant = ""
    @State private var direction: TransactionFilter.Direction?
    @State private var minText = ""
    @State private var maxText = ""
    /// Which end of the amount range is being typed, so the row shows one focus bar for both.
    @FocusState private var rangeFocus: RangeEnd?
    @State private var accountID: String?
    @State private var categoryID: String?
    @State private var isEnabled = true
    @State private var applyToExisting = false
    @State private var accounts: [Account] = []
    @State private var rules: [RuleSummary] = []
    @State private var preview: ActionPreview?
    @State private var previewProblem: String?
    @State private var isPreviewing = false
    @State private var picksCategory = false
    @State private var isSaving = false
    @State private var problem: String?
    @State private var confirmsDelete = false

    private var editing: RuleSummary? {
        if case let .edit(summary) = subject { return summary }
        return nil
    }

    var body: some View {
        NavigationStack {
            List {
                conditions
                fileUnder
                if editing != nil {
                    DSListSection {
                        DSToggleRow("Rule is on", detail: "A rule that's off files nothing. It's kept so you can turn it back on.", isOn: $isEnabled)
                    }
                }
                existing
                previewSection
                if editing != nil {
                    DSListSection {
                        SettingsDestructiveRow(title: "Delete rule") { confirmsDelete = true }
                    }
                }
            }
            .dsGroupedList()
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { saveBar }
            .navigationTitle(editing == nil ? "New rule" : "Edit rule")
            .announcesProblem(problem)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationBackground(Color.ds.canvas)
        .onAppear(perform: fill)
        .task { await loadContext() }
        .task(id: draftKey) {
            // Typing settles for a moment before the ledger is asked.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await runPreview()
        }
        .sheet(isPresented: $picksCategory) {
            // A category made from here for a rule on money coming in starts as money in.
            CategoryPickerSheet(title: "File it under", categories: app.sortedCategories, selected: categoryID,
                                newKind: direction == .moneyIn ? .moneyIn : nil) { picked in
                categoryID = picked.id
                // A rule for money in only ever takes money coming in, and the ledger saves it that way.
                if picked.isMoneyIn { direction = .moneyIn }
            }
        }
        .confirmationDialog("Delete this rule?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete rule", role: .destructive) { Task { await delete() } }
        } message: {
            Text("The transactions it filed keep their category.")
        }
    }

    // MARK: Sections

    private var conditions: some View {
        DSListSection("When a transaction matches",
                      footer: "Capitals, spaces, punctuation and numbers are ignored, so “Google Fi” also catches “GOOGLE*FI 4DFLFD”. Fill in only what you need; everything you fill in has to match.") {
            DSField("Bank description contains", style: .inline, isCode: true) {
                TextField("Bank description contains", text: $descriptor, prompt: Text("PAYROLL, UBER, WITHDRAWAL…"))
                    .textInputAutocapitalization(.characters)
                    .accessibilityIdentifier("ruleDescriptor")
            }
            DSField("Merchant name contains", style: .inline) {
                TextField("Merchant name contains", text: $merchant, prompt: Text("Any merchant"))
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ruleMerchant")
            }
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                Text("Money").dsFont(.label).foregroundStyle(Color.ds.inkSecondary).accessibilityHidden(true)
                DSSegmented("Money", selection: $direction, options: [
                    (value: TransactionFilter.Direction?.none, title: "Either way"),
                    (value: .some(.moneyOut), title: "Going out"),
                    (value: .some(.moneyIn), title: "Coming in"),
                ])
            }
            .padding(.vertical, DSSpace.xs)
            DSField("Amount", style: .inline, isFocused: rangeFocus != nil) {
                HStack(spacing: DSSpace.sm) {
                    TextField("At least", text: $minText, prompt: Text("At least $"))
                        .keyboardType(.decimalPad)
                        .focused($rangeFocus, equals: .min)
                    Text("to").foregroundStyle(Color.ds.inkTertiary)
                    TextField("At most", text: $maxText, prompt: Text("At most $"))
                        .keyboardType(.decimalPad)
                        .focused($rangeFocus, equals: .max)
                }
            }
            DSListRow("Account") {
                Picker("Account", selection: $accountID) {
                    Text("Any account").tag(String?.none)
                    ForEach(accounts) { Text("\($0.institution) \($0.shortLabel)").tag(String?.some($0.id)) }
                }
                .labelsHidden()
                .tint(Color.ds.inkSecondary)
            }
        }
    }

    private var fileUnder: some View {
        DSListSection("File it under") {
            Button { picksCategory = true } label: {
                let category = app.category(categoryID)
                DSListRow(category?.name ?? "Choose a category", systemImage: category?.symbol ?? "square.grid.2x2",
                          tone: category.map { CategoryStyle.tone(for: $0) } ?? .irisDeep) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: DSIconSize.xs, weight: .semibold))
                        .foregroundStyle(Color.ds.inkTertiary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ruleCategory")
        }
    }

    private var existing: some View {
        DSListSection("Already in the ledger") {
            DSToggleRow("Also re-file the ones it matches", detail: existingDetail, isOn: $applyToExisting)
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        DSListSection(previewHeader) {
            if let previewProblem {
                SettingsNote(text: previewProblem, tint: Color.ds.amber, systemImage: "info.circle")
            } else if let preview {
                if let otherID = preview.conflicts.first, let other = rules.first(where: { $0.id == otherID }) {
                    DSNoticeCard("Overlaps another rule",
                                 message: "“\(other.matchDescription)” → \(app.category(other.rule.categoryID)?.name ?? "a category that's gone") also matches some of these. Where both match, the newer rule wins.",
                                 actionTitle: "Turn that rule off") { Task { await turnOff(other) } }
                        .settingsCardRow()
                }
                if preview.sample.isEmpty {
                    SettingsNote(text: "Nothing in the ledger matches yet. It files new transactions as they arrive.")
                } else {
                    ForEach(preview.sample.prefix(5)) { row in
                        LedgerRow(transaction: row)
                    }
                    if let count = preview.matchCount, count > 5 {
                        SettingsNote(text: "And \(count - 5) more.")
                    }
                }
            } else {
                SettingsNote(text: isPreviewing ? "Checking the ledger…" : "Add some text or an account to match, and a category, to see what it catches.")
            }
        }
    }

    private var saveBar: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            if let problem {
                Text(problem).dsFont(.callout).foregroundStyle(Color.ds.caution).fixedSize(horizontal: false, vertical: true)
            }
            Button(isSaving ? "Saving…" : "Save rule") { Task { await save() } }
                .buttonStyle(.ds(.primary, size: .large, fullWidth: true))
                // A preview the server couldn't make (an older server, a rule it refuses) means Save would fail or
                // save something else; it waits for a good one.
                .disabled(isSaving || action == nil || previewProblem != nil)
                .accessibilityIdentifier("saveRule")
        }
        .padding(.horizontal, DSSpace.gutter)
        .padding(.vertical, DSSpace.sm)
        .background { Color.ds.canvas.ignoresSafeArea(edges: .bottom) }
        .overlay(alignment: .top) { DSDivider() }
    }

    // MARK: Values

    private struct DraftKey: Hashable {
        var descriptor, merchant, minText, maxText: String
        var direction: TransactionFilter.Direction?
        var accountID, categoryID: String?
        var isEnabled, applyToExisting: Bool
    }

    private var draftKey: DraftKey {
        DraftKey(descriptor: descriptor, merchant: merchant, minText: minText, maxText: maxText, direction: direction,
                 accountID: accountID, categoryID: categoryID, isEnabled: isEnabled, applyToExisting: applyToExisting)
    }

    /// "“" and "$1,000" typed as people type them; blank is no bound.
    private static func amount(_ text: String) -> DecimalAmount?? {
        let cleaned = text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return .some(nil) }
        return DecimalAmount(string: cleaned).map { .some($0) }
    }

    private var match: RuleMatch? {
        guard let min = Self.amount(minText), let max = Self.amount(maxText) else { return nil }
        return RuleMatch(merchantContains: merchant, descriptorContains: descriptor, direction: direction,
                         minAmount: min, maxAmount: max, accountID: accountID).normalized
    }

    /// What Save would do, or nil while the rule isn't complete.
    private var action: AppAction? {
        guard let match, let categoryID else { return nil }
        guard match.merchantContains != nil || match.descriptorContains != nil || match.accountID != nil else { return nil }
        if let editing {
            return .updateBudgetRule(UpdateBudgetRule(ruleID: editing.id, match: match, categoryID: categoryID, isEnabled: isEnabled,
                                                      applyToExisting: applyToExisting ? true : nil))
        }
        return .createBudgetRule(CreateBudgetRule(match: match, categoryID: categoryID, applyToExisting: applyToExisting))
    }

    private var previewHeader: String {
        guard let preview, previewProblem == nil, let count = preview.matchCount else { return "Preview" }
        guard count > 0 else { return "Preview · no matches" }
        let moving = preview.changeCount ?? 0
        return "\(count) match\(count == 1 ? "es" : "") · \(moving == 0 ? "all already there" : "\(moving) would be filed")"
    }

    private var existingDetail: String {
        guard let preview, let count = preview.matchCount, count > 0 else {
            return "Rows already in the ledger keep their category unless you turn this on."
        }
        let moving = preview.changeCount ?? 0
        let name = app.category(categoryID)?.name ?? "the category"
        return moving == 0 ? "All \(count) are already under \(name)." : "\(moving) of \(count) would be filed under \(name)."
    }

    // MARK: Actions

    private func fill() {
        switch subject {
        case let .new(prefill, categoryID):
            descriptor = prefill?.descriptorContains ?? ""
            merchant = prefill?.merchantContains ?? ""
            direction = prefill?.direction
            accountID = prefill?.accountID
            self.categoryID = categoryID
        case let .edit(summary):
            let m = summary.rule.match
            descriptor = m.descriptorContains ?? ""
            merchant = m.merchantContains ?? ""
            direction = m.direction
            minText = m.minAmount.map { $0.money().shortString } ?? ""
            maxText = m.maxAmount.map { $0.money().shortString } ?? ""
            accountID = m.accountID
            categoryID = summary.rule.categoryID
            isEnabled = summary.rule.isEnabled
        }
    }

    private func loadContext() async {
        let api = app.api
        async let overview = try? api.overview()
        async let rules = try? api.rules()
        accounts = await overview?.accounts ?? []
        self.rules = await rules ?? []
    }

    private func runPreview() async {
        guard let action else {
            preview = nil
            previewProblem = Self.amount(minText) == nil || Self.amount(maxText) == nil ? "Amounts are plain numbers, like 30 or 1,250." : nil
            return
        }
        isPreviewing = true
        defer { isPreviewing = false }
        do {
            preview = try await app.api.preview(action)
            previewProblem = nil
        } catch {
            // The ledger's own checks, in words: "Money going out is never income."
            previewProblem = error.localizedDescription
        }
    }

    private func save() async {
        guard let action else { return }
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

    private func turnOff(_ other: RuleSummary) async {
        do {
            try await app.perform(.updateBudgetRule(UpdateBudgetRule(ruleID: other.id, isEnabled: false)))
            rules = (try? await app.api.rules()) ?? rules
            await runPreview()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func delete() async {
        guard let editing else { return }
        do {
            try await app.perform(.deleteBudgetRule(DeleteBudgetRule(ruleID: editing.id)))
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
