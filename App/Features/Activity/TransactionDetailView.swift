import BudgetKit
import DesignSystem
import SwiftUI

/// One transaction: what it is, the answer it's waiting for (when it is), what you can change about it, and how
/// it was filed. Presented as a sheet from Activity, pushed from Home and Spending, and shown one group at a
/// time in review (`ReviewTriageView`). Reloads from the ledger after every change, so it never goes stale.
struct TransactionDetailView: View {
    /// Where it's shown decides the toolbar: a sheet gets Done, triage gets its position.
    enum Presentation: Equatable {
        case pushed
        case sheet
        /// "2 of 5" in the toolbar; filing calls `onFiled` so the next group comes up.
        case triage(position: String)
    }

    let transaction: LedgerTransaction
    var presentation: Presentation = .pushed
    /// Triage keeps the toast so it outlives the row it's about.
    var toast: Binding<DSToastMessage?>?
    var onFiled: (() -> Void)?
    var onSkip: (() -> Void)?
    /// Activity shows every row on an account from here; elsewhere the account line only informs.
    var onShowAccount: ((String) -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var loaded: LedgerTransaction?
    @State private var isGone = false
    @State private var peer: LedgerTransaction?
    @State private var recurring: Subscription?
    @State private var ownToast: DSToastMessage?
    /// The answer chosen in the review card; nil means the pipeline's guess.
    @State private var choice: String?
    @State private var filesGroup = true
    @State private var makesRule = false
    @State private var isWorking = false
    @State private var showsPicker = false
    @State private var showsRename = false
    @State private var showsNote = false
    @State private var editsRecurring = false

    private var row: LedgerTransaction { loaded?.id == transaction.id ? loaded! : transaction }
    private var toastBinding: Binding<DSToastMessage?> { toast ?? $ownToast }
    private var edits: RowEdits { RowEdits(app: app, toast: toastBinding) }
    private var category: BudgetCategory? { app.category(row.categorization?.categoryID) }
    private var needsReview: Bool { row.categorization?.needsReview == true }
    private var isTransfer: Bool { category?.id == "transfer" }
    private var reviewItem: ReviewItem? { app.reviewItems.first { $0.id == row.id } }
    private var group: ReviewGroup? { needsReview ? app.reviewGroups.first { $0.contains(row.id) } : nil }

    var body: some View {
        Group {
            if isGone {
                DSStateView(systemImage: "tray", title: "This transaction is gone",
                            message: "It was removed from the ledger, by an import that was undone or by your bank.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DSSpace.lg) {
                        header
                        if needsReview { reviewCard }
                        detailsCard
                        provenanceCard
                        footer
                    }
                    .padding(.horizontal, DSSpace.gutter)
                    .padding(.top, DSSpace.sm)
                    .padding(.bottom, DSSpace.xl)
                }
            }
        }
        .dsScreenBackground()
        // Inside the answer bar's inset, so a toast sits above the bar rather than over it.
        .dsToast(toastBinding)
        .safeAreaInset(edge: .bottom) {
            if needsReview, !isGone { answerBar }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .navigationDestination(isPresented: $showsPicker) {
            CategoryPickerView(title: needsReview ? "File as" : "Category", selected: needsReview ? currentChoice : category?.id,
                               suggestions: reviewItem?.suggestions ?? []) { picked in
                showsPicker = false
                if needsReview {
                    choice = picked.id
                } else if picked.id != category?.id {
                    Task { await edits.file([row.id], as: picked.id) }
                }
            }
        }
        .sheet(isPresented: $showsRename) {
            RenameMerchantSheet(transaction: row) { name, similar in await edits.rename([row.id], to: name, similar: similar) }
        }
        .sheet(isPresented: $showsNote) {
            NoteSheet(title: "Note", initial: row.note ?? "") { await edits.setNote([row.id], $0) }
        }
        .sheet(isPresented: $editsRecurring) { RecurringEditSheet(merchant: row.merchant, current: recurring, amount: row.amount.magnitude) }
        .task(id: "\(transaction.id)|\(app.revision)") { await reload() }
        .task(id: "\(row.merchant)|\(app.revision)") {
            recurring = try? await app.api.subscriptions().items.first { $0.covers(row.merchant) }
        }
        .task {
            if app.account(row.accountID) == nil { await app.refreshAccounts() }
        }
    }

    private func reload() async {
        do {
            let fresh = try await app.api.transaction(id: transaction.id)
            loaded = fresh
            isGone = false
            if let peerID = fresh.transferPeerID { peer = try? await app.api.transaction(id: peerID) } else { peer = nil }
        } catch BudgetAPIError.notFound {
            isGone = true
        } catch {
            // Offline or a blip: keep showing what we have.
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if case let .triage(position) = presentation {
            ToolbarItem(placement: .principal) {
                DSEyebrow(position)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Review, \(position)")
                    .accessibilityIdentifier("triagePosition")
            }
        }
        if presentation != .pushed {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            let tags = statusTags
            if !tags.isEmpty {
                DSFlowLayout(spacing: DSSpace.xs, lineSpacing: DSSpace.xs) {
                    ForEach(tags, id: \.text) { tag in
                        DSTag(tag.text, systemImage: tag.symbol, tint: tag.tint)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(tags.map(\.text).joined(separator: ", "))
            }
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                Text(row.merchant)
                    .dsFont(.title)
                    .foregroundStyle(Color.ds.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                DSAmountText(row.amount.decimal, currencyCode: row.amount.currencyCode, size: .display, sign: .inflowPlus, tintsInflow: true)
                    .accessibilityLabel("Amount")
                    .accessibilityValue(DSAmountFormat.string(row.amount.decimal, currencyCode: row.amount.currencyCode, sign: .inflowPlus))
                Text(row.postedAt.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                    .dsFont(.callout)
                    .foregroundStyle(Color.ds.inkSecondary)
            }
            Button { showsPicker = true } label: {
                DSChipLabel(category?.name ?? "Uncategorized", systemImage: category?.symbol ?? "questionmark", trailingSystemImage: "chevron.down")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Category")
            .accessibilityValue(category?.name ?? "Uncategorized")
            .accessibilityHint(needsReview ? "Choose the answer for this transaction" : "Changes the category")
            .accessibilityIdentifier("categoryChip")
        }
    }

    private struct StatusTag { let text: String; let symbol: String?; let tint: Color }

    private var statusTags: [StatusTag] {
        var tags: [StatusTag] = []
        if row.isPending { tags.append(StatusTag(text: "Pending", symbol: "clock", tint: Color.ds.inkSecondary)) }
        if needsReview { tags.append(StatusTag(text: "Needs review", symbol: "circle.fill", tint: Color.ds.orchid)) }
        if row.isHidden { tags.append(StatusTag(text: "Hidden", symbol: "eye.slash", tint: Color.ds.inkSecondary)) }
        if isTransfer, !needsReview { tags.append(StatusTag(text: "Transfer", symbol: "arrow.left.arrow.right", tint: Color.ds.lilac)) }
        return tags
    }

    // MARK: - Review

    /// What the review card's button files: the person's pick, else the pipeline's guess.
    private var currentChoice: String? { choice ?? row.categorization?.categoryID ?? reviewItem?.suggestions.first?.categoryID }

    /// The suggestions (at most three, best first), the current guess when it isn't one of them, and a pick
    /// from "Something else" (confidence -1: the person's, not the pipeline's).
    private var reviewOptions: [(categoryID: String, confidence: Double)] {
        var options = (reviewItem?.suggestions ?? []).prefix(3).map { (categoryID: $0.categoryID, confidence: $0.confidence) }
        if let guess = row.categorization?.categoryID, !options.contains(where: { $0.categoryID == guess }) {
            options.insert((categoryID: guess, confidence: row.categorization?.confidence ?? 0), at: 0)
        }
        if let choice, !options.contains(where: { $0.categoryID == choice }) {
            options.append((categoryID: choice, confidence: -1))
        }
        return options
    }

    private var reviewCard: some View {
        let others = (group?.count ?? 1) - 1
        return DSCard(padding: 0, elevation: .raised) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    DSEyebrow("Needs your answer", dot: Color.ds.orchid)
                    Text(reviewItem?.reason ?? "Budget wasn't sure about this one.")
                        .dsFont(.callout)
                        .foregroundStyle(Color.ds.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding([.horizontal, .top], DSSpace.md)
                .padding(.bottom, DSSpace.xs)

                ForEach(reviewOptions, id: \.categoryID) { option in
                    if let category = app.category(option.categoryID) {
                        DSDivider().padding(.leading, DSSpace.md)
                        suggestionRow(category, confidence: option.confidence)
                            .padding(.horizontal, DSSpace.md)
                    }
                }
                DSDivider().padding(.leading, DSSpace.md)
                Button { showsPicker = true } label: {
                    DSListRow("Something else", showsChevron: true)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DSSpace.md)

                if others > 0 || group?.isGeneric == true {
                    DSDivider()
                    VStack(spacing: 0) {
                        if others > 0 {
                            DSToggleRow(others == 1 ? "Also file the other one like it" : "Also file the \(others) others like it",
                                        detail: "Same account, same bank description, \(row.amount.isNegative ? "money out" : "money in").",
                                        isOn: $filesGroup)
                                .accessibilityIdentifier("filesGroup")
                        }
                        if let group, group.isGeneric {
                            if others > 0 { DSDivider() }
                            DSToggleRow("Always file these this way",
                                        detail: "\(group.scopeDescription(account: app.account(group.key.accountID))). A rule files new ones, so they won't need you.",
                                        isOn: $makesRule)
                                .accessibilityIdentifier("makesRule")
                        }
                    }
                    .padding(.horizontal, DSSpace.md)
                }

                DSDivider()
                Text(memoryNote)
                    .dsFont(.caption)
                    .foregroundStyle(Color.ds.inkSecondary) // inkTertiary is below AA on a raised card
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(DSSpace.md)
            }
        }
    }

    /// The answer stays in reach at the bottom while the card above explains it. Skip sits beside it, or under
    /// it at large text sizes.
    private var answerBar: some View {
        let others = (group?.count ?? 1) - 1
        let title = answerTitle(app.category(currentChoice), others: others)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: DSSpace.sm) {
                skipButton(fullWidth: false)
                answerButton(title, wraps: false)
            }
            VStack(spacing: DSSpace.xs) {
                answerButton(title, wraps: true)
                skipButton(fullWidth: true)
            }
        }
        .padding(.horizontal, DSSpace.gutter)
        .padding(.vertical, DSSpace.sm)
        .background {
            Color.ds.canvas.overlay(alignment: .top) { DSDivider() }.ignoresSafeArea(edges: .bottom)
        }
    }

    @ViewBuilder
    private func skipButton(fullWidth: Bool) -> some View {
        if let onSkip {
            Button(action: onSkip) { Text("Skip").fixedSize() }
                .buttonStyle(.ds(.secondary, fullWidth: fullWidth))
                .accessibilityLabel("Skip for now")
                .accessibilityIdentifier("skipButton")
        }
    }

    private func answerButton(_ title: String, wraps: Bool) -> some View {
        Button { Task { await answer() } } label: {
            Text(title).fixedSize(horizontal: !wraps, vertical: true)
        }
        .buttonStyle(.ds(.primary, fullWidth: true))
        .disabled(currentChoice == nil || isWorking)
        .accessibilityLabel(title)
        .accessibilityIdentifier("answerButton")
    }

    private func answerTitle(_ chosen: BudgetCategory?, others: Int) -> String {
        guard let chosen else { return "Choose a category" }
        if isWorking { return "Filing…" }
        let all = others > 0 && filesGroup
        if chosen.id == row.categorization?.categoryID {
            return all ? "Keep \(chosen.name) for all \(others + 1)" : "Keep \(chosen.name)"
        }
        return all ? "File all \(others + 1) as \(chosen.name)" : "File as \(chosen.name)"
    }

    private var memoryNote: String {
        if Descriptor.isGeneric(row.rawDescription) {
            return "“\(row.rawDescription)” doesn't name a merchant, so your answer can't teach merchant memory. Only a rule files the next one."
        }
        return "Your answer teaches merchant memory, so the next “\(row.merchant)” is filed on its own."
    }

    private func suggestionRow(_ category: BudgetCategory, confidence: Double) -> some View {
        let isSelected = currentChoice == category.id
        let percent = confidence >= 0 ? "\(Int((confidence * 100).rounded()))%" : nil
        return Button { choice = category.id } label: {
            DSListRow(category.name, systemImage: category.symbol, tone: CategoryStyle.tone(for: category)) {
                HStack(spacing: DSSpace.sm) {
                    if let percent { DSListValue(percent) }
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(isSelected ? Color.ds.accent : Color.ds.inkTertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.name)
        .accessibilityValue(percent.map { "\($0) sure" } ?? "Your pick")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func answer() async {
        guard let chosen = currentChoice else { return }
        let ids = filesGroup ? (group?.transactionIDs ?? [row.id]) : [row.id]
        let rule = makesRule && group?.isGeneric == true ? group?.scopedRule : nil
        isWorking = true
        defer { isWorking = false }
        let done = chosen == row.categorization?.categoryID && rule == nil && ids.count == 1
            ? await edits.keepGuess(ids)
            : await edits.file(ids, as: chosen, rule: rule)
        if done {
            choice = nil
            onFiled?()
        }
    }

    // MARK: - Details

    private var detailsCard: some View {
        DSCard(padding: 0) {
            VStack(spacing: 0) {
                Button { showsRename = true } label: {
                    DSListRow("Merchant", value: row.merchant, showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Renames it")
                DSDivider()
                DSListRow("Bank description") {
                    Text(row.rawDescription)
                        .dsFont(.mono)
                        .foregroundStyle(Color.ds.inkSecondary)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                DSDivider()
                accountRow
                DSDivider()
                Button { showsNote = true } label: {
                    DSListRow("Note", detail: row.note, value: row.note == nil ? "Add" : nil, showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("noteRow")
                DSDivider()
                countsRow
                if isSpending {
                    DSDivider()
                    yearlyRow
                    DSDivider()
                    Button { editsRecurring = true } label: {
                        DSListRow("Repeats", value: recurring.map(repeatsText) ?? "Mark as recurring", showsChevron: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(recurring == nil ? "Say how often it repeats" : "Change how it repeats, or take it off recurring")
                    .accessibilityIdentifier("repeatsRow")
                }
            }
            .padding(.horizontal, DSSpace.md)
        }
    }

    @ViewBuilder
    private var accountRow: some View {
        let account = app.account(row.accountID)
        let label = DSListRow("Account", detail: account?.institution, value: account?.shortLabel ?? "Unknown account",
                              showsChevron: onShowAccount != nil)
        if let onShowAccount {
            Button {
                onShowAccount(row.accountID)
                dismiss()
            } label: { label }
            .buttonStyle(.plain)
            .accessibilityHint("Shows every transaction on this account")
        } else {
            label
        }
    }

    /// Transfers say where the money went; everything else can be left out of the totals.
    @ViewBuilder
    private var countsRow: some View {
        if isTransfer, !row.isHidden {
            if let peer {
                NavigationLink(value: peer) {
                    DSListRow(row.amount.isNegative ? "Moved to" : "Moved from",
                              detail: peer.postedAt.formatted(.dateTime.month(.abbreviated).day()),
                              value: app.account(peer.accountID)?.shortLabel ?? peer.merchant, showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the other side of this transfer")
            } else {
                DSListRow("Not counted", detail: "Money moving between your own accounts isn't spending or income.")
            }
        } else {
            DSToggleRow("Count in your totals",
                        detail: row.isHidden ? "Hidden. Spending, income and budgets leave it out; balances still include it."
                                             : "Turn off to leave it out of spending, income and budgets. Balances still include it.",
                        isOn: Binding(get: { !row.isHidden }, set: { counted in
                            let before = row
                            loaded = before.withHidden(!counted)
                            Task { if !(await edits.setHidden([before.id], !counted)) { loaded = before } }
                        }))
                .accessibilityIdentifier("countsToggle")
        }
    }

    /// Money out that counts toward spending: what can be a yearly charge or a recurring one.
    private var isSpending: Bool {
        row.amount.isNegative && !row.isHidden && !isTransfer && row.categorization.flatMap { app.category($0.categoryID) }?.countsAsSpending != false
    }

    /// Spread over the year or counted in its month — Budget's call until the person makes it.
    private var yearlyRow: some View {
        let yearly = row.isYearly ?? row.countsAsYearly ?? false
        let twelfth = Money(minorUnits: row.amount.magnitude.minorUnits / 12).formatted()
        let found = row.isYearly == nil && row.countsAsYearly == true
        return DSToggleRow("Spread over the year",
                           detail: yearly ? "\(found ? "Budget took it for a yearly charge. " : "")Counts \(twelfth) a month for 12 months instead of all this month."
                                          : "For an annual fee, a yearly plan or a big trip: counts a twelfth a month for a year instead of all this month.",
                           isOn: Binding(get: { yearly }, set: { on in
                               let before = row
                               loaded = before.withYearly(on)
                               Task { if !(await edits.setYearly([before.id], on)) { loaded = before } }
                           }))
            .accessibilityIdentifier("yearlyToggle")
    }

    private func repeatsText(_ subscription: Subscription) -> String {
        let cadence = subscription.cadence.rawValue.capitalized
        let next = subscription.nextExpected.formatted(.dateTime.month(.abbreviated).day())
        return subscription.status == .missed ? "\(cadence) · missed" : "\(cadence) · next \(next)"
    }

    // MARK: - Provenance

    private var provenanceCard: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            DSEyebrow("How it was filed")
            DSCard(padding: 0) {
                VStack(spacing: 0) {
                    DSListRow("Filed by", detail: provenanceDetail, value: row.categorization?.tier.displayName ?? "Not filed yet")
                    DSDivider()
                    DSListRow("Came from", value: sourceText)
                }
                .padding(.horizontal, DSSpace.md)
            }
        }
    }

    /// How sure the model was, when a model made the call, and how it came about. Model ids and a rule's stamp are
    /// ids, not something to show.
    private var provenanceDetail: String? {
        guard let categorization = row.categorization, [.model, .embedding, .decisionModel].contains(categorization.tier) else { return nil }
        let sure = "\(Int((categorization.confidence * 100).rounded()))% sure"
        return [sure, categorization.modelNote].compactMap { $0 }.joined(separator: " · ")
    }

    private var sourceText: String {
        switch row.source {
        case .fileImport: "A statement you imported"
        case .financekit: "Apple Wallet"
        default: "\(row.source.displayName) sync"
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            Button("All from \(row.merchant)") {
                app.route(Navigate(screen: .activity, search: row.merchant))
                if presentation != .pushed { dismiss() }
            }
            .buttonStyle(.ds(.quiet))
            .frame(minHeight: 44)
            Text(app.isDemo ? "This is the demo ledger. Nothing here leaves the phone."
                            : "This transaction lives on your Olares. The phone keeps a copy for offline viewing only.")
                .dsFont(.caption)
                .foregroundStyle(Color.ds.inkTertiary)
        }
    }
}

extension LedgerTransaction {
    /// A copy with the hidden flag changed — for showing a toggle's new state before the ledger confirms it.
    func withHidden(_ hidden: Bool) -> LedgerTransaction {
        var copy = self
        copy.isHidden = hidden
        return copy
    }

    /// A copy marked yearly or not, the same way.
    func withYearly(_ yearly: Bool) -> LedgerTransaction {
        var copy = self
        copy.isYearly = yearly
        copy.countsAsYearly = yearly ? true : nil
        return copy
    }
}


/// A transaction's details as a sheet with Done — how every screen opens a row (Activity, Home, a category), so the
/// same screen always looks and closes the same way.
private struct TransactionDetailSheet: ViewModifier {
    @Binding var item: LedgerTransaction?
    let onShowAccount: ((String) -> Void)?

    func body(content: Content) -> some View {
        content.sheet(item: $item) { row in
            NavigationStack {
                TransactionDetailView(transaction: row, presentation: .sheet, onShowAccount: onShowAccount)
                    .navigationDestination(for: LedgerTransaction.self) { TransactionDetailView(transaction: $0) }
            }
            .presentationBackground(Color.ds.canvas)
        }
    }
}

extension View {
    /// Presents `item`'s details as a sheet; `onShowAccount` (Activity) narrows the list to the tapped account.
    func transactionDetailSheet(item: Binding<LedgerTransaction?>, onShowAccount: ((String) -> Void)? = nil) -> some View {
        modifier(TransactionDetailSheet(item: item, onShowAccount: onShowAccount))
    }
}
