import BudgetKit
import DesignSystem
import SwiftUI

/// Home: cash on hand and what needs you, this month's safe to spend, the last week day by day, the checkup,
/// what the ledger found, every balance, and the latest rows.
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var state: LoadState<Overview> = .loading
    /// The weekly recap: the checkup's headline, shown until dismissed for the week.
    @State private var recap: Checkup?
    /// What's coming up: the next paycheck, and the recap's next seven days (`GET /v1/upcoming`).
    @State private var upcoming: Upcoming?
    @State private var showsAccounts = false
    /// A recent row's details, as a sheet (as Activity opens them).
    @State private var detail: LedgerTransaction?
    /// The week ("2026-39") whose recap was put away.
    @AppStorage("home.recapDismissedWeek") private var dismissedRecapWeek = ""
    /// Last month's recap, in the first week of a month (`MonthlyRecap.isFresh`) until put away.
    @State private var monthlyRecap: MonthlyRecap?
    @State private var showsMonthlyRecap = false
    /// The month ("2026-09") whose recap was put away.
    @AppStorage("home.monthlyRecapDismissed") private var dismissedMonthlyRecap = ""

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpace.xl) {
                    header
                    switch state {
                    case .loading:
                        LoadingPlaceholder()
                    case let .failed(message):
                        DSStateView(systemImage: "wifi.slash", title: "Can't reach your ledger", message: message, actionTitle: "Try again") {
                            Task { await load() }
                        }
                    case let .loaded(overview):
                        content(overview)
                    }
                }
                .padding(.horizontal, DSSpace.gutter)
                .padding(.bottom, DSSpace.xxl)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .dsScreenBackground(bloom: .data)
            .reloadable(button: false) { await load() }
            .toolbarVisibility(.hidden, for: .navigationBar)
            .transactionDetailSheet(item: $detail)
            .navigationDestination(isPresented: $app.showsCheckup) { CheckupView() }
            .navigationDestination(isPresented: $showsAccounts) { AccountsView() }
            .navigationDestination(isPresented: $app.showsNetWorth) { NetWorthView() }
            .sheet(isPresented: $app.showsSettings) { SettingsView() }
            // The recap's Ask link goes to Ask: the sheet closes so it shows.
            .onChange(of: app.navigationToken) { showsMonthlyRecap = false }
            .sheet(isPresented: $showsMonthlyRecap) {
                if let monthlyRecap { MonthlyRecapSheet(recap: monthlyRecap) }
            }
        }
        .task(id: app.revision) { await load() }
    }

    @discardableResult
    private func load() async -> String? {
        let api = app.api
        let first = state.isLoading
        state = await state.orSaved(.overview, app)
        if first, recap == nil, let saved = state.value, showsRecap(saved) { recap = await app.saved(.checkup) }
        if first, upcoming == nil { upcoming = await app.saved(.upcoming(days: UpcomingWindow.days)) }
        let updating = app.beginUpdating(showingSaved: first && state.value != nil)
        let (next, error) = await state.refreshing { try await api.overview() }
        app.endUpdating(updating)
        state = next
        if let overview = next.value, showsRecap(overview) {
            recap = (try? await api.checkup()) ?? recap
        }
        await loadMonthlyRecap()
        upcoming = (try? await api.upcoming(days: UpcomingWindow.days)) ?? upcoming
        return error
    }

    /// The wordmark, the badge and the gear in a row; at accessibility sizes the badge moves under the wordmark and the
    /// wordmark stays on one line, so nothing breaks mid-word.
    private var header: some View {
        let large = dynamicTypeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: DSSpace.xs) {
            HStack(alignment: .center) {
                Text("budget.")
                    .dsFont(.title)
                    .foregroundStyle(Color.ds.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .accessibilityLabel("Budget")
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !large { DSPrivacyBadge(app.privacyState) }
                Button {
                    app.showsSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: DSIconSize.md, weight: .regular))
                        .foregroundStyle(Color.ds.inkSecondary)
                        .frame(width: DSSize.hitTarget, height: DSSize.hitTarget)
                }
                .accessibilityLabel("Settings")
            }
            if large { DSPrivacyBadge(app.privacyState) }
        }
        .padding(.top, DSSpace.xs)
    }

    // MARK: Weekly recap

    /// "2026-39": the ledger's week, so the recap comes back once a week.
    private func week(of overview: Overview) -> String {
        let parts = Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: overview.asOf)
        return "\(parts.yearForWeekOfYear ?? 0)-\(parts.weekOfYear ?? 0)"
    }

    private func showsRecap(_ overview: Overview) -> Bool { dismissedRecapWeek != week(of: overview) }

    // MARK: Monthly recap

    /// Asked for only in the first days of a month; a server without it (404) shows nothing.
    private func loadMonthlyRecap() async {
        guard Calendar.current.component(.day, from: AppClock.now) <= 8, let api = app.api as? any MonthlyRecapAPI else {
            monthlyRecap = nil
            return
        }
        if let fresh = try? await api.monthlyRecap(month: nil) { monthlyRecap = fresh }
    }

    /// Fresh by the clock, not by when it was worked out: a saved copy read offline weeks later is old news.
    private var shownMonthlyRecap: MonthlyRecap? {
        monthlyRecap.flatMap { recap in
            guard let until = recap.showsUntil, AppClock.now < until, recap.month != dismissedMonthlyRecap else { return nil }
            return recap
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ overview: Overview) -> some View {
        let recapShown = showsRecap(overview) && recap != nil
        if recapShown, let recap {
            WeeklyRecapCard(checkup: recap, days: overview.lastSevenDays ?? [], comingUp: upcoming?.items(within: 7, calendar: .current) ?? []) {
                app.showsCheckup = true
            } onDismiss: {
                withAnimation(DSMotion.standard) { dismissedRecapWeek = week(of: overview) }
            }
            .transition(.opacity)
        }

        if let monthly = shownMonthlyRecap {
            MonthlyRecapCard(recap: monthly) {
                showsMonthlyRecap = true
            } onDismiss: {
                withAnimation(DSMotion.standard) { dismissedMonthlyRecap = monthly.month }
            }
            .transition(.opacity)
        }

        cashHero(overview)

        MonthCard(overview: overview)

        if let upcoming, upcoming.nextPaycheck != nil {
            NextPaycheckCard(upcoming: upcoming) { app.route(Navigate(screen: .recurring)) }
        }

        if let days = overview.lastSevenDays, !days.isEmpty {
            LastSevenDaysCard(days: days, spent: overview.lastSevenDaysSpent, asOf: overview.asOf)
        }

        // Decisions, like the Activity badge: one answer files every row in a group.
        if app.reviewCount > 0 {
            ReviewCallout(decisions: app.reviewCount, transactions: app.reviewItems.count)
        }

        // This week the recap leads to the checkup; otherwise it has its standing place here.
        if !recapShown {
            CheckupEntryCard { app.showsCheckup = true }
        }

        if !overview.insights.isEmpty {
            insights(overview.insights)
        }

        if let balances = overview.balances {
            BalancesCard(balances: balances, onOpenAccounts: { showsAccounts = true }, onOpenNetWorth: { app.showsNetWorth = true })
        }

        recent(overview.recent)
    }

    private func cashHero(_ overview: Overview) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.md) {
            DSHeroAmount(
                label: "Cash on hand",
                value: overview.cashOnHand.decimal,
                currencyCode: overview.cashOnHand.currencyCode,
                caption: "\(overview.cashChange30Days.signedWhole) in the last 30 days",
                captionTint: overview.cashChange30Days.isNegative ? Color.ds.inkSecondary : Color.ds.inflow
            )
            if let attention = overview.attention, !attention.isEmpty {
                DSAttentionPill(Self.attentionTitle(attention)) { showsAccounts = true }
                    .accessibilityHint("Opens your accounts")
                    .accessibilityIdentifier("attentionPill")
            }
            Button { app.selectedTab = .plan } label: {
                DSLineChart(actual: overview.cashTrend.map(\.chartPoint),
                            accessibilitySummary: "Cash over the last 90 days, now \(overview.cashOnHand.formatted())")
                    .frame(height: 92)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens Plan")
        }
    }

    /// One item says itself ("Tidewater needs you to sign in again"); several are counted.
    static func attentionTitle(_ items: [DataAttention]) -> String {
        guard items.count > 1 else {
            let title = items.first?.title ?? ""
            return title.hasSuffix(".") ? String(title.dropLast()) : title
        }
        return "\(items.count) accounts need attention"
    }

    private func insights(_ insights: [Insight]) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            DSSectionHeader("Found for you")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: DSSpace.sm) {
                    ForEach(insights) { insight in
                        InsightTile(insight: insight)
                            .frame(width: dynamicTypeSize.isAccessibilitySize ? 340 : 280)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, DSSpace.gutter, for: .scrollContent)
            .padding(.horizontal, -DSSpace.gutter)
        }
    }

    private func recent(_ rows: [LedgerTransaction]) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            DSSectionHeader("Recent", actionTitle: "See all") { app.selectedTab = .activity }
            if rows.isEmpty {
                DSCard {
                    Text("Nothing yet. Transactions show up here as your banks sync or you import a statement.")
                        .dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                DSCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, transaction in
                            Button { detail = transaction } label: { LedgerRow(transaction: transaction) }
                                .buttonStyle(.plain)
                            if index < rows.count - 1 { DSDivider() }
                        }
                    }
                    .padding(.horizontal, DSSpace.md)
                    .padding(.vertical, DSSpace.xxs)
                }
            }
        }
    }
}
