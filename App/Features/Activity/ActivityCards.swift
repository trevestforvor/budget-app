import BudgetKit
import DesignSystem
import SwiftUI

/// The top of Activity while answers are waiting: up to three decisions, each filed in one tap with its best
/// guess, or opened to answer properly; then "Review all".
struct ActivityReviewCard: View {
    let groups: [ReviewGroup]
    /// Group ids being filed right now.
    let working: Set<String>
    let onOpen: (ReviewGroup) -> Void
    let onFile: (ReviewGroup, BudgetCategory) -> Void
    let onReviewAll: () -> Void

    @Environment(AppModel.self) private var app
    static let shown = 3

    var body: some View {
        let rows = groups.map(\.count).reduce(0, +)
        DSCard(padding: 0, elevation: .raised) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    DSEyebrow("Needs review · \(groups.count)", dot: Color.ds.orchid)
                    Text(rows == groups.count ? "Budget wasn't sure about these." : "One answer files each group.")
                        .dsFont(.headline)
                        .foregroundStyle(Color.ds.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if rows > groups.count {
                        Text("\(rows) transactions in \(groups.count) groups. Rows from one account with the same bank description are grouped.")
                            .dsFont(.callout)
                            .foregroundStyle(Color.ds.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding([.horizontal, .top], DSSpace.md)
                .padding(.bottom, DSSpace.xs)
                .accessibilityElement(children: .combine)

                ForEach(groups.prefix(Self.shown)) { group in
                    DSDivider().padding(.leading, DSSpace.md)
                    groupRow(group)
                        .padding(.horizontal, DSSpace.md)
                }

                Button(groups.count == 1 ? "Answer it" : "Review all \(groups.count)", action: onReviewAll)
                    .buttonStyle(.ds(.secondary, fullWidth: true))
                    .padding(DSSpace.md)
                    .accessibilityIdentifier("reviewAll")
            }
        }
    }

    private func groupRow(_ group: ReviewGroup) -> some View {
        let guess = app.category(group.bestGuess)
        let account = app.account(group.key.accountID)?.shortLabel
        let subtitle = group.count > 1
            ? ["\(group.count) transactions", account].compactMap { $0 }.joined(separator: " · ")
            : [guess?.name ?? "Uncategorized", account].compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 0) {
            Button { onOpen(group) } label: {
                DSTransactionRow(title: group.merchant, subtitle: subtitle, amount: group.total.decimal, currencyCode: group.total.currencyCode,
                                 systemImage: guess?.symbol ?? "questionmark", tone: CategoryStyle.tone(for: guess),
                                 isPending: group.count == 1 && group.first.transaction.isPending, needsReview: true)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens it to answer")
            .accessibilityIdentifier("reviewRow")
            if let guess {
                DSChip(working.contains(group.id) ? "Filing…" : (group.count > 1 ? "File all \(group.count) as \(guess.name)" : "Keep \(guess.name)"),
                       systemImage: "checkmark") {
                    onFile(group, guess)
                }
                .disabled(working.contains(group.id))
                .padding(.leading, 36 + DSSpace.sm)
                .padding(.bottom, DSSpace.sm)
                .accessibilityIdentifier("fileGroup")
            }
        }
    }
}

/// Totals over everything the filters and search match, by the ledger's own rules — so the spent figure
/// agrees with Spending to the cent. Folds down to its first line.
struct ActivitySummaryCard: View {
    let summary: TransactionSummary?
    /// The totals couldn't be loaded: say so rather than leave the card a placeholder.
    var failed = false
    /// With money out (or in) chosen, the other side's figure is always zero, so it's left out.
    var direction: TransactionFilter.Direction?
    @Binding var isCollapsed: Bool
    let onNeedsReview: () -> Void

    var body: some View {
        let shown = summary ?? TransactionSummary(count: 0, earliest: nil, latest: nil, spent: .zero, income: .zero, notCountedCount: 0,
                                                  notCountedTotal: .zero, hiddenCount: 0, needsReviewCount: 0, pendingCount: 0)
        DSCard(padding: DSSpace.md) {
            VStack(alignment: .leading, spacing: DSSpace.md) {
                HStack(alignment: .top, spacing: DSSpace.sm) {
                    VStack(alignment: .leading, spacing: DSSpace.xxs) {
                        DSEyebrow("Summary")
                        Text(shown.count == 1 ? "1 transaction" : "\(shown.count.formatted()) transactions")
                            .dsFont(.headline)
                            .foregroundStyle(Color.ds.ink)
                        if failed {
                            Text("Couldn't total these. Pull down to try again.").dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if let range = dateRange(shown) {
                            Text(range).dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(DSMotion.standard) { isCollapsed.toggle() }
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: DSIconSize.sm, weight: .semibold))
                            .foregroundStyle(Color.ds.inkSecondary)
                            .rotationEffect(.degrees(isCollapsed ? 180 : 0))
                            .frame(width: DSSize.hitTarget, height: DSSize.hitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isCollapsed ? "Show totals" : "Hide totals")
                }
                if !isCollapsed, !failed {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: DSSpace.md) { figures(shown) }
                        VStack(alignment: .leading, spacing: DSSpace.md) { figures(shown) }
                    }
                    if shown.notCountedCount > 0 {
                        DSDivider()
                        DSFigureRow(label: "Not counted, money out", detail: notCountedDetail(shown), value: shown.notCountedTotal.decimal,
                                    currencyCode: shown.notCountedTotal.currencyCode)
                    }
                    if shown.needsReviewCount > 0 {
                        // Counted in transactions, and said so: the tab badge counts decisions, which can file several.
                        DSChip(shown.needsReviewCount == 1 ? "Show the 1 transaction waiting for review"
                                                           : "Show the \(shown.needsReviewCount) transactions waiting for review",
                               action: onNeedsReview)
                    }
                }
            }
        }
        .dsLoading(summary == nil && !failed)
    }

    @ViewBuilder
    private func figures(_ summary: TransactionSummary) -> some View {
        if direction != .moneyIn {
            DSStatBlock(label: "Spent", value: summary.spent.decimal, currencyCode: summary.spent.currencyCode, footnote: "Net of refunds")
        }
        if direction != .moneyOut {
            DSStatBlock(label: "Income", value: summary.income.decimal, currencyCode: summary.income.currencyCode,
                        tint: summary.income.minorUnits > 0 ? Color.ds.inflow : Color.ds.ink)
        }
    }

    private func dateRange(_ summary: TransactionSummary) -> String? {
        guard let earliest = summary.earliest, let latest = summary.latest else { return nil }
        let calendar = Calendar.current
        if calendar.isDate(earliest, inSameDayAs: latest) { return latest.formatted(.dateTime.month(.abbreviated).day().year()) }
        let sameYear = calendar.isDate(earliest, equalTo: latest, toGranularity: .year)
        let start = sameYear ? earliest.formatted(.dateTime.month(.abbreviated).day()) : earliest.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(start) – \(latest.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    private func notCountedDetail(_ summary: TransactionSummary) -> String {
        let transfers = summary.notCountedCount - summary.hiddenCount
        var parts: [String] = []
        if transfers > 0 { parts.append(transfers == 1 ? "1 transfer" : "\(transfers) transfers") }
        if summary.hiddenCount > 0 { parts.append("\(summary.hiddenCount) hidden") }
        return parts.joined(separator: " · ")
    }
}

/// The bar that replaces the tab bar while rows are selected: how many and how much, then what to do with them.
struct ActivitySelectionBar: View {
    let count: Int
    let outflow: Money
    let isWorking: Bool
    let onCategorize: () -> Void
    let onHide: () -> Void
    let onKeep: () -> Void
    let onCount: () -> Void
    let onNote: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            Text(summary)
                .dsFont(.callout)
                .foregroundStyle(count == 0 ? Color.ds.inkSecondary : Color.ds.ink)
                .accessibilityIdentifier("selectionSummary")
            // One row; then Categorize over the other two; then all three stacked at the largest text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DSSpace.xs) {
                    categorize
                    hide(fullWidth: false)
                    more(fullWidth: false)
                }
                VStack(spacing: DSSpace.xs) {
                    categorize
                    HStack(spacing: DSSpace.xs) {
                        hide(fullWidth: true)
                        more(fullWidth: true)
                    }
                }
                VStack(spacing: DSSpace.xs) {
                    categorize
                    hide(fullWidth: true)
                    more(fullWidth: true)
                }
            }
            .disabled(count == 0 || isWorking)
        }
        .padding(.horizontal, DSSpace.gutter)
        .padding(.vertical, DSSpace.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Color.ds.surfaceRaised
                .overlay(alignment: .top) { DSDivider() }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var summary: String {
        guard count > 0 else { return "Tap transactions to select them" }
        let selected = count == 1 ? "1 selected" : "\(count) selected"
        return outflow.minorUnits > 0 ? "\(selected) · \(outflow.formatted()) out" : selected
    }

    private var categorize: some View {
        Button(action: onCategorize) { Text("Categorize").fixedSize() }
            .buttonStyle(.ds(.primary, fullWidth: true))
            .accessibilityIdentifier("bulkCategorize")
    }

    private func hide(fullWidth: Bool) -> some View {
        Button(action: onHide) { Text("Hide").fixedSize() }
            .buttonStyle(.ds(.secondary, fullWidth: fullWidth))
            .accessibilityLabel("Hide from totals")
            .accessibilityIdentifier("bulkHide")
    }

    private func more(fullWidth: Bool) -> some View {
        Menu {
            Button("Keep their categories", systemImage: "checkmark", action: onKeep)
            Button("Count in totals again", systemImage: "eye", action: onCount)
            Button("Add a note…", systemImage: "note.text", action: onNote)
        } label: {
            Text("More").fixedSize()
        }
        .buttonStyle(.ds(.secondary, fullWidth: fullWidth))
        .accessibilityIdentifier("bulkMore")
    }
}
