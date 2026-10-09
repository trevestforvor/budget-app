import BudgetKit
import DesignSystem
import SwiftUI

/// Everything at once: the ledger's checkup, most urgent first. A finding opens what it's about (a category, the
/// review queue, a charge) or, in a list of merchants or categories, each figure does; each can hand a question to Ask.
struct CheckupView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var state: LoadState<Checkup> = .loading
    @State private var showsReview = false
    @State private var opened: LedgerTransaction?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.lg) {
                switch state {
                case .loading:
                    LoadingPlaceholder()
                case let .failed(message):
                    DSStateView(systemImage: "wifi.slash", title: "Couldn't run the checkup", message: message, actionTitle: "Try again") {
                        Task { await load() }
                    }
                case let .loaded(checkup):
                    header(checkup)
                    ForEach(checkup.sections.sorted { $0.status > $1.status }) { section in
                        sectionCard(section)
                    }
                    Text("Every figure comes from your ledger. Run it again any time — pull down, or tap ↻.")
                        .dsFont(.caption)
                        .foregroundStyle(Color.ds.inkTertiary)
                }
            }
            .padding(.horizontal, DSSpace.gutter)
            .padding(.bottom, DSSpace.xxl)
        }
        .dsScreenBackground()
        .reloadable("Run the checkup again") { await load() }
        .navigationTitle("Checkup")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: app.revision) { await load() }
        .sheet(isPresented: $showsReview) { ReviewTriageView() }
        .transactionDetailSheet(item: $opened)
    }

    @discardableResult
    private func load() async -> String? {
        let api = app.api
        let first = state.isLoading
        state = await state.orSaved(.checkup, app)
        let updating = app.beginUpdating(showingSaved: first && state.value != nil)
        let (next, error) = await state.refreshing { try await api.checkup() }
        app.endUpdating(updating)
        state = next
        return error
    }

    private func header(_ checkup: Checkup) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            DSEyebrow("Checkup · \(checkup.asOf.formatted(date: .abbreviated, time: .shortened))", dot: Color.ds.iris)
            Text(checkup.headline)
                .dsFont(.title)
                .foregroundStyle(Color.ds.ink)
                .fixedSize(horizontal: false, vertical: true)
            CheckupCountTags(checkup: checkup)
        }
        .padding(.top, DSSpace.sm)
    }

    private func sectionCard(_ section: Checkup.Section) -> some View {
        // A section to act on washes caution down from its top edge; its "Act" tag says so in words.
        DSCard(wash: section.status == .act ? .caution : nil) {
            VStack(alignment: .leading, spacing: DSSpace.md) {
                // The status tag sits beside the title, or under it at accessibility sizes so the title never breaks.
                let head = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: DSSpace.xs))
                                                               : AnyLayout(HStackLayout(spacing: DSSpace.sm))
                head {
                    HStack(spacing: DSSpace.sm) {
                        DSGlyph(systemImage: section.symbol, tone: Self.tone(section.status), size: 30)
                        Text(section.title).dsFont(.headline).foregroundStyle(Color.ds.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    DSTag(Self.label(section.status), systemImage: Self.symbol(section.status), tint: Self.tint(section.status))
                }
                ForEach(section.findings.sorted { $0.status > $1.status }) { finding in
                    findingRow(finding)
                    if finding.id != section.findings.sorted(by: { $0.status > $1.status }).last?.id { DSDivider() }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(section.title), \(Self.label(section.status))")
    }

    private func findingRow(_ finding: Checkup.Finding) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            // The whole finding opens its link; without one, a figure with its own (a merchant, a category) opens that.
            if let link = finding.link, link != .unknown {
                open(link) { findingBody(finding, figuresLink: false, chevron: true) }
                    .accessibilityHint(Self.hint(link))
                    .accessibilityIdentifier("checkupFinding-\(finding.id)")
            } else {
                findingBody(finding, figuresLink: true, chevron: false)
            }
            if let suggestion = finding.suggestion {
                AskLink(suggestion)
                    .padding(.leading, 15)
            }
        }
    }

    private func findingBody(_ finding: Checkup.Finding, figuresLink: Bool, chevron: Bool) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DSSpace.xs) {
                CheckupStatusMark(status: finding.status)
                Text(finding.title)
                    .dsFont(.body)
                    .foregroundStyle(Color.ds.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if chevron {
                    Spacer(minLength: DSSpace.xs)
                    Self.chevron
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(Self.spoken(finding.status)): \(finding.title)")
            if let detail = finding.detail {
                Text(detail).dsFont(.callout).foregroundStyle(Color.ds.inkSecondary).fixedSize(horizontal: false, vertical: true)
            }
            if !finding.metrics.isEmpty {
                VStack(spacing: 4) {
                    ForEach(Array(finding.metrics.enumerated()), id: \.offset) { _, metric in
                        if figuresLink, let link = metric.link, link != .unknown {
                            open(link) { metricRow(metric, chevron: true).frame(minHeight: 36) }
                                .accessibilityHint(Self.hint(link))
                                .accessibilityIdentifier(Self.figureID(link))
                        } else {
                            metricRow(metric, chevron: false)
                        }
                    }
                }
                .padding(.leading, 15)
            }
        }
        .contentShape(Rectangle())
    }

    private func metricRow(_ metric: Checkup.Metric, chevron: Bool) -> some View {
        HStack {
            Text(metric.label).dsFont(.callout).foregroundStyle(Color.ds.inkSecondary).lineLimit(1)
            Spacer()
            Text(metric.money.map { $0.formatted() } ?? metric.text ?? "")
                .dsFont(.amountRow)
                .foregroundStyle(Color.ds.ink)
            if chevron { Self.chevron }
        }
        .contentShape(Rectangle())
    }

    private static var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: DSIconSize.xs, weight: .semibold))
            .foregroundStyle(Color.ds.inkTertiary)
            .accessibilityHidden(true)
    }

    /// What a link opens: a screen pushed over the checkup (back returns here), a sheet, or another tab.
    @ViewBuilder
    private func open(_ link: Checkup.Link, @ViewBuilder label: () -> some View) -> some View {
        switch link {
        case let .category(id): NavigationLink { CategoryDetailView(categoryID: id) } label: { label() }.buttonStyle(.plain)
        case .recurring: NavigationLink { RecurringView() } label: { label() }.buttonStyle(.plain)
        case .accounts: NavigationLink { AccountsView() } label: { label() }.buttonStyle(.plain)
        case .review: Button { showsReview = true } label: { label() }.buttonStyle(.plain)
        case let .transaction(id):
            Button { Task { opened = try? await app.api.transaction(id: id) } } label: { label() }.buttonStyle(.plain)
        case .budget: Button { app.route(Navigate(screen: .spending)) } label: { label() }.buttonStyle(.plain)
        case let .merchant(name): Button { app.route(Navigate(screen: .activity, search: name)) } label: { label() }.buttonStyle(.plain)
        case .plan: Button { app.route(Navigate(screen: .plan)) } label: { label() }.buttonStyle(.plain)
        case .unknown: label()
        }
    }

    /// "checkupFigure-merchant", for UI tests.
    static func figureID(_ link: Checkup.Link) -> String {
        let kind = switch link {
        case .category: "category"
        case .merchant: "merchant"
        default: "other"
        }
        return "checkupFigure-\(kind)"
    }

    static func hint(_ link: Checkup.Link) -> String {
        switch link {
        case .review: "Opens the review queue"
        case .budget: "Opens this month's budget"
        case .category: "Opens the category"
        case let .merchant(name): "Shows \(name) charges in Activity"
        case .transaction: "Opens the transaction"
        case .recurring: "Opens subscriptions and bills"
        case .plan: "Opens Plan"
        case .accounts: "Opens linked accounts"
        case .unknown: ""
        }
    }

    /// The same colours as `tint`, as tones for glyphs: caution is orchid, fine is the cyan accent.
    static func tone(_ status: Checkup.Status) -> DSTone {
        switch status {
        case .act: .orchid
        case .watch: .amber
        case .good: .cyan
        }
    }

    static func tint(_ status: Checkup.Status) -> Color {
        switch status {
        case .act: Color.ds.caution
        case .watch: Color.ds.amber
        case .good: Color.ds.accent
        }
    }

    static func label(_ status: Checkup.Status) -> String {
        switch status {
        case .act: "Act"
        case .watch: "Watch"
        case .good: "Fine"
        }
    }

    /// The shape that goes with each colour, so a status never rests on colour alone (orchid is also Dining's tone).
    static func symbol(_ status: Checkup.Status) -> String {
        switch status {
        case .act: "exclamationmark"
        case .watch: "eye"
        case .good: "checkmark"
        }
    }

    /// What VoiceOver says before a finding.
    static func spoken(_ status: Checkup.Status) -> String {
        switch status {
        case .act: "Act on"
        case .watch: "Watch"
        case .good: "Fine"
        }
    }
}

/// A finding's status as a shape in its colour — the recap card and the checkup both lead findings with it.
struct CheckupStatusMark: View {
    let status: Checkup.Status

    var body: some View {
        Image(systemName: "\(CheckupView.symbol(status)).circle.fill")
            .imageScale(.small)
            .dsFont(.callout)
            .foregroundStyle(CheckupView.tint(status))
            .accessibilityHidden(true)
    }
}

/// "2 to act on · 3 to watch · 9 fine", in words as well as colour.
struct CheckupCountTags: View {
    let checkup: Checkup

    var body: some View {
        let counts = checkup.counts
        DSFlowLayout(spacing: DSSpace.xs, lineSpacing: DSSpace.xs) {
            if counts.act > 0 { DSTag("\(counts.act) to act on", systemImage: CheckupView.symbol(.act), tint: CheckupView.tint(.act)) }
            if counts.watch > 0 { DSTag("\(counts.watch) to watch", systemImage: CheckupView.symbol(.watch), tint: CheckupView.tint(.watch)) }
            DSTag("\(counts.good) fine", systemImage: CheckupView.symbol(.good), tint: CheckupView.tint(.good))
        }
    }
}
