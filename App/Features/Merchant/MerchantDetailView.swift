import BudgetKit
import DesignSystem
import SwiftUI

/// One merchant: what's gone there this month, over the last year and ever, how often and how much at a time, a year
/// month by month, whether it recurs, its category (with a way to re-file all of it), rename, a rule, its cap, and its
/// transactions. Pushed from a transaction's details, an Activity search, and Spending's "Most frequent".
struct MerchantDetailView: View {
    @Environment(AppModel.self) private var app
    /// Follows a rename made here.
    @State private var name: String
    @State private var state: LoadState<MerchantSummary> = .loading
    @State private var detail: LedgerTransaction?
    @State private var toast: DSToastMessage?
    @State private var picksCategory = false
    @State private var renames = false
    @State private var makesRule = false
    @State private var editsCap = false
    /// A new category found other rows like it: B1's "apply to similar" offer, shown before anything is filed.
    @State private var similarOffer: SimilarOffer?

    init(merchant: String) {
        _name = State(initialValue: merchant)
    }

    private var edits: RowEdits { RowEdits(app: app, toast: $toast) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.lg) {
                header
                switch state {
                case .loading:
                    LoadingPlaceholder()
                case let .failed(message):
                    DSStateView(systemImage: "storefront", title: "Can't show \(name)", message: message, actionTitle: "Try again") {
                        Task { await load() }
                    }
                case let .loaded(summary):
                    content(summary)
                }
            }
            .padding(.horizontal, DSSpace.gutter)
            .padding(.top, DSSpace.sm)
            .padding(.bottom, DSSpace.xxl)
        }
        .dsScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .reloadable { await load() }
        .dsToast($toast)
        .transactionDetailSheet(item: $detail)
        .task(id: "\(name)|\(app.revision)") { await load() }
        .sheet(isPresented: $picksCategory) {
            let summary = state.value
            CategoryPickerSheet(title: "File \(name) as", selected: summary?.categoryID,
                                footnote: "Shows how many of its transactions this reaches before filing. Undo puts them back.") { picked in
                // Apply to similar (B1): file the newest charge and offer the merchant's others, with the ledger's count
                // (refunds follow purchases; rows you filed yourself keep theirs).
                guard let newest = fileableRows(summary).first else { return }
                Task { similarOffer = await edits.fileOrOffer(newest, as: picked) }
            }
        }
        .sheet(item: $similarOffer) { FileSimilarSheet(offer: $0, edits: edits) }
        .sheet(isPresented: $renames) {
            if let row = state.value?.transactions.first {
                RenameMerchantSheet(transaction: row) { newName, similar in
                    let done = await edits.rename([row.id], to: newName, similar: similar)
                    if done { name = newName }
                    return done
                }
            }
        }
        .sheet(isPresented: $makesRule) {
            RuleEditorSheet(subject: .new(prefill: RuleMatch(merchantContains: name, direction: .moneyOut), categoryID: state.value?.categoryID))
        }
        .sheet(isPresented: $editsCap) {
            if let cap = state.value?.cap { MerchantCapSheet(subject: .edit(cap)) }
        }
    }

    @discardableResult
    private func load() async -> String? {
        guard let merchants = app.merchants else {
            state = .failed(MerchantSupport.unavailable)
            return MerchantSupport.unavailable
        }
        let merchant = name
        do {
            state = .loaded(try await merchants.merchantSummary(merchant))
            return nil
        } catch BudgetAPIError.notFound {
            let message = await app.serverPredates(ServerStatus.merchantsSince) ? MerchantSupport.unavailable
                : "Nothing from \(merchant) is in your ledger any more."
            if state.value == nil { state = .failed(message) }
            return message
        } catch {
            if Task.isCancelled { return nil }
            if state.value == nil { state = .failed(error.localizedDescription) }
            return error.localizedDescription
        }
    }

    /// Rows "change category" starts from, newest first: everything but transfers and money in, which aren't this
    /// merchant's spending.
    private func fileableRows(_ summary: MerchantSummary?) -> [LedgerTransaction] {
        (summary?.transactions ?? []).filter { row in
            let category = app.category(row.categorization?.categoryID)
            return category?.isMoneyIn != true && category?.id != BudgetCategory.transferID
        }.sorted { $0.postedAt > $1.postedAt }
    }

    // MARK: Header

    private var header: some View {
        let category = app.category(state.value?.categoryID)
        return HStack(alignment: .center, spacing: DSSpace.sm) {
            DSGlyph(systemImage: category?.symbol ?? "storefront", tone: CategoryStyle.tone(for: category), size: 44)
            VStack(alignment: .leading, spacing: DSSpace.xxs) {
                DSEyebrow("Merchant")
                Text(name)
                    .dsFont(.display)
                    .foregroundStyle(Color.ds.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("merchantName")
            }
            Spacer(minLength: DSSpace.xs)
            DSAskButton(label: name) { app.ask("Tell me about \(name)") }
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ m: MerchantSummary) -> some View {
        figures(m)
        bars(m)
        if let recurring = m.recurring {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                DSSectionHeader("Recurring")
                DSCard(padding: 0) {
                    RecurringRow(item: recurring, style: .all).padding(.horizontal, DSSpace.md)
                }
            }
        }
        manage(m)
        transactions(m)
    }

    private func figures(_ m: MerchantSummary) -> some View {
        DSCard {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                VStack(spacing: 0) {
                    DSFigureRow(label: "This month", detail: "So far", value: m.thisMonth.decimal, currencyCode: m.thisMonth.currencyCode)
                    DSFigureRow(label: "Last 12 months", detail: "\(m.chargesLastTwelveMonths) charge\(m.chargesLastTwelveMonths == 1 ? "" : "s")",
                                value: m.lastTwelveMonths.decimal, currencyCode: m.lastTwelveMonths.currencyCode)
                    DSFigureRow(label: "All time", detail: m.firstCharge.map { "Since \($0.formatted(.dateTime.month(.abbreviated).year()))" },
                                value: m.lifetime.decimal, currencyCode: m.lifetime.currencyCode)
                }
                DSDivider()
                HStack(alignment: .top, spacing: DSSpace.md) {
                    stat("How often", m.frequency)
                    if let average = m.averageCharge { stat("Average charge", average.formatted()) }
                }
                Text("Spending net of refunds. Hidden transactions and transfers are left out.")
                    .dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("merchantFigures")
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xxs) {
            DSEyebrow(label)
            Text(value).dsFont(.bodyEmphasis).foregroundStyle(Color.ds.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func bars(_ m: MerchantSummary) -> some View {
        let bars = m.months.compactMap { spend in MonthKey.date(spend.month).map { DSMonthBar(month: $0, value: spend.spent.doubleValue) } }
        if bars.count > 1 {
            DSCard(padding: DSSpace.md) {
                VStack(alignment: .leading, spacing: DSSpace.sm) {
                    DSEyebrow("Month by month")
                    DSMonthBars(bars: bars, target: m.cap?.target.doubleValue, tone: CategoryStyle.tone(for: app.category(m.categoryID)),
                                accessibilityName: "\(m.merchant) by month",
                                accessibilitySummary: "\(m.merchant) over the last \(bars.count) months, \(m.lastTwelveMonths.formatted(fractionDigits: 0)) in all")
                        .frame(height: 150)
                    if let cap = m.cap {
                        Text("The line is your \(cap.target.formatted(fractionDigits: 0)) monthly cap.")
                            .dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                    }
                }
            }
        }
    }

    private func manage(_ m: MerchantSummary) -> some View {
        let category = app.category(m.categoryID)
        return DSCard(padding: 0) {
            VStack(spacing: 0) {
                Button { picksCategory = true } label: {
                    DSListRow("Category", detail: m.categoryIDs.count > 1 ? "Some of its transactions are filed elsewhere" : nil,
                              value: category?.name ?? "Not filed", showsChevron: true)
                }
                .buttonStyle(.plain)
                .disabled(fileableRows(m).isEmpty)
                .accessibilityHint("Files all of its transactions under another category")
                .accessibilityIdentifier("merchantCategory")
                DSDivider()
                Button { renames = true } label: { DSListRow("Rename", value: m.merchant, showsChevron: true) }
                    .buttonStyle(.plain)
                    .disabled(m.transactions.isEmpty)
                    .accessibilityIdentifier("merchantRename")
                DSDivider()
                Button { makesRule = true } label: {
                    DSListRow("Make a rule", detail: "File new \(m.merchant) charges the same way, always", showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("merchantRule")
                if let cap = m.cap {
                    DSDivider()
                    Button { editsCap = true } label: {
                        DSListRow("Monthly cap", detail: "\(cap.spent.formatted(fractionDigits: 0)) of \(cap.target.formatted(fractionDigits: 0)) this month") {
                            HStack(spacing: DSSpace.xs) {
                                if cap.spent > cap.target { DSTag.over() }
                                DSListValue(cap.target.shortString, showsChevron: true)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("merchantCap")
                }
            }
            .padding(.horizontal, DSSpace.md)
        }
    }

    @ViewBuilder
    private func transactions(_ m: MerchantSummary) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            DSSectionHeader("Transactions", actionTitle: "In Activity") { app.route(Navigate(screen: .activity, search: m.merchant)) }
            DSCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(m.transactions.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { DSDivider() }
                        Button { detail = row } label: { LedgerRow(transaction: row) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("merchantRow-\(row.id)")
                    }
                }
                .padding(.horizontal, DSSpace.md)
                .padding(.vertical, DSSpace.xxs)
            }
            if m.transactionCount > m.transactions.count {
                Text("The newest \(m.transactions.count) of \(m.transactionCount). Activity has them all.")
                    .dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
            }
        }
    }
}
