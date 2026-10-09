import BudgetKit
import DesignSystem
import SwiftUI

/// Spending → Recurring. What's coming up in the next 30 days, week by week, and every recurring charge — found from
/// repeat charges, then corrected by the person: tap one to change how it repeats or take it off, + to add one Budget
/// can't know yet (a first yearly charge), and put back what was taken off.
struct RecurringView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case upcoming, all
        var id: String { rawValue }
        var title: String { self == .upcoming ? "Upcoming" : "All" }
    }

    @Environment(AppModel.self) private var app
    @State private var state: LoadState<SubscriptionSummary> = .loading
    @State private var mode: Mode = .upcoming
    /// List or calendar (`UpcomingCalendar`).
    @State private var layout: RecurringLayout = .launched
    /// Paychecks, bills and card bills by day (`GET /v1/upcoming`); nil from a server without it.
    @State private var expected: Upcoming?
    @State private var adding = false
    @State private var toast: DSToastMessage?

    var body: some View {
        List {
            switch state {
            case .loading:
                LoadingPlaceholder().plainRow()
            case let .failed(message):
                DSStateView(systemImage: "wifi.slash", title: "Couldn't load recurring charges", message: message, actionTitle: "Try again") {
                    Task { await load() }
                }
                .plainRow()
            case let .loaded(found):
                content(found)
            }
        }
        .dsGroupedList()
        .reloadable { await load() }
        .navigationTitle("Recurring")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add a recurring charge")
                    .accessibilityIdentifier("addRecurring")
            }
        }
        .sheet(isPresented: $adding) { AddRecurringSheet(listed: Set(state.value?.items.map(\.merchant) ?? [])) }
        .dsToast($toast)
        .task(id: app.revision) { await load() }
    }

    /// Swipe to delete: takes the charge off recurring (its transactions stay), with Undo on the toast. It leaves the
    /// list at once; the ledger's answer follows.
    private func remove(_ item: Subscription) {
        if case var .loaded(found) = state {
            found.items.removeAll { $0.merchant == item.merchant }
            withAnimation(DSMotion.standard) { state = .loaded(found) }
        }
        Task {
            if !(await RowEdits(app: app, toast: $toast).setRecurring(item.merchant, false)) { await load() }
        }
    }

    @discardableResult
    private func load() async -> String? {
        let api = app.api
        let first = state.isLoading
        state = await state.orSaved(.subscriptions, app)
        let updating = app.beginUpdating(showingSaved: first && state.value != nil)
        let (next, error) = await state.refreshing { try await api.subscriptions() }
        app.endUpdating(updating)
        state = next
        if let fresh = try? await api.upcoming(days: UpcomingWindow.calendarDays) { expected = fresh }
        return error
    }

    @ViewBuilder
    private func content(_ found: SubscriptionSummary) -> some View {
        let upcoming = Self.upcoming(found)
        DSHeroAmount(label: "Due in the next 30 days",
                     value: (found.dueNext30Days ?? upcoming.map(\.amount).sum()).decimal,
                     caption: "Subscriptions \(found.subscriptionsMonthly.formatted(fractionDigits: 0)) a month · bills \(found.billsMonthly.formatted(fractionDigits: 0)) a month")
            .padding(.top, DSSpace.sm)
            .plainRow()

        DSSegmented("Show", selection: $layout, options: RecurringLayout.allCases) { $0.title }
            .plainRow()
            .accessibilityIdentifier("recurringLayout")

        if layout == .calendar {
            RecurringCalendarContent(upcoming: expected).plainRow()
        } else if found.items.isEmpty {
            DSStateView(systemImage: "repeat", title: "No repeat charges yet",
                        message: found.monthsSearched < 3 ? "They show up once there are a few months of history." : "Nothing charges you on a schedule.")
                .plainRow()
        } else {
            HStack(spacing: DSSpace.xs) {
                ForEach(Mode.allCases) { option in
                    DSChip(option.title, isSelected: mode == option) {
                        withAnimation(DSMotion.standard) { mode = option }
                    }
                }
            }
            .plainRow()
            switch mode {
            case .upcoming: upcomingList(upcoming, asOf: found.asOf)
            case .all: allList(found)
            }
            if found.items.contains(where: { $0.kind == .subscription }) {
                AskLink("Which of these could I cancel?", question: "Which of my subscriptions could I cancel?").plainRow()
            }
        }
        if let bills = expected?.cardBills, !bills.isEmpty { CardBillsCard(bills: bills).plainRow() }
        if let off = found.notRecurring, !off.isEmpty { notRecurring(off) }
        Text("Found from repeat charges in your ledger. Tap one to change how it repeats, or swipe it away if it isn't recurring; + adds one Budget can't know yet, like a first yearly charge.")
            .dsFont(.caption)
            .foregroundStyle(Color.ds.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .plainRow()
    }

    /// Merchants taken off recurring, each with a way back.
    private func notRecurring(_ merchants: [String]) -> some View {
        Section {
            ForEach(merchants, id: \.self) { merchant in
                DSListRow(merchant, detail: "You took it off") {
                    Button("Put back") {
                        Task { await RowEdits(app: app, toast: $toast).setRecurring(merchant, nil) }
                    }
                    .buttonStyle(.ds(.quiet))
                }
                .cardRow()
            }
        } header: {
            DSSectionHeader("Not recurring").sectionHeader()
        }
    }

    /// Active charges expected within 30 days (a late one counts as due now), soonest first.
    static func upcoming(_ found: SubscriptionSummary, calendar: Calendar = .current) -> [Subscription] {
        let horizon = calendar.date(byAdding: .day, value: 30, to: found.asOf) ?? found.asOf
        return found.items
            .filter { $0.status == .active && $0.nextExpected <= horizon }
            .sorted { $0.nextExpected < $1.nextExpected }
    }

    /// "Due now", "This week", "Next week", "Later this month" … by calendar week.
    static func weekTitle(_ date: Date, asOf: Date, calendar: Calendar = .current) -> String {
        if date < calendar.startOfDay(for: asOf) { return "Due now" }
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: asOf) else { return "Later" }
        if thisWeek.contains(date) { return "This week" }
        if let next = calendar.date(byAdding: .weekOfYear, value: 1, to: thisWeek.start),
           calendar.dateInterval(of: .weekOfYear, for: next)?.contains(date) == true { return "Next week" }
        return "Later"
    }

    @ViewBuilder
    private func upcomingList(_ items: [Subscription], asOf: Date) -> some View {
        if items.isEmpty {
            DSStateView(systemImage: "calendar", title: "Nothing due soon", message: "No recurring charge is expected in the next 30 days.")
                .plainRow()
        } else {
            let groups = Dictionary(grouping: items) { Self.weekTitle($0.nextExpected, asOf: asOf) }
            ForEach(["Due now", "This week", "Next week", "Later"], id: \.self) { title in
                if let rows = groups[title] {
                    group(title, rows, style: .upcoming, total: rows.map(\.amount).sum())
                }
            }
        }
    }

    @ViewBuilder
    private func allList(_ found: SubscriptionSummary) -> some View {
        let subs = found.items.filter { $0.kind == .subscription }
        let bills = found.items.filter { $0.kind == .bill }
        if !subs.isEmpty { group("Subscriptions", subs, style: .all, total: found.subscriptionsMonthly, perMonth: true) }
        if !bills.isEmpty { group("Bills", bills, style: .all, total: found.billsMonthly, perMonth: true) }
    }

    private func group(_ title: String, _ items: [Subscription], style: RecurringRow.Style, total: Money, perMonth: Bool = false) -> some View {
        Section {
            ForEach(items) { item in
                RecurringRow(item: item, style: style)
                    .cardRow()
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { remove(item) } label: { Label("Delete", systemImage: "trash") }
                    }
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                DSSectionHeader(title)
                Text(perMonth ? "\(total.formatted(fractionDigits: 0)) a month" : total.formatted(fractionDigits: 0))
                    .dsFont(.amountRow)
                    .foregroundStyle(Color.ds.inkSecondary)
            }
            .sectionHeader()
        }
    }
}

private extension View {
    /// Content that sits on the canvas between the list's cards: the hero, the chips, a note.
    func plainRow() -> some View {
        listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: DSSpace.xs, leading: 0, bottom: DSSpace.xs, trailing: 0))
            .listRowSeparator(.hidden)
    }

    /// A row on a section's card, as `DSListSection` lays them.
    func cardRow() -> some View {
        listRowBackground(Color.ds.surface)
            .listRowSeparatorTint(Color.ds.hairlineStrong)
            .listRowInsets(EdgeInsets(top: 0, leading: DSSpace.md, bottom: 0, trailing: DSSpace.md))
    }

    /// A section title in the screen's own type, not the list's small caps.
    func sectionHeader() -> some View {
        textCase(nil)
            .listRowInsets(EdgeInsets(top: DSSpace.sm, leading: 0, bottom: DSSpace.xs, trailing: 0))
    }
}

/// One recurring charge: what it is, when it's next due (or that it stopped), and what it costs. Tapping it opens
/// `RecurringEditSheet`. Shared by Recurring, the Spending tab's "Coming up", and a category's detail.
struct RecurringRow: View {
    enum Style { case upcoming, all }

    let item: Subscription
    var style: Style = .upcoming
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: { label }
            .buttonStyle(.plain)
            .accessibilityHint("Change how it repeats, or take it off recurring")
            .sheet(isPresented: $editing) { RecurringEditSheet(merchant: item.merchant, current: item) }
    }

    private var label: some View {
        let category = app.category(item.categoryID)
        let missed = item.status == .missed
        let large = dynamicTypeSize.isAccessibilitySize
        return HStack(alignment: large ? .top : .center, spacing: DSSpace.sm) {
            DSGlyph(systemImage: category?.symbol ?? "repeat",
                    tone: CategoryStyle.tone(for: category ?? app.category("subscriptions")),
                    emphasis: missed ? .muted : .normal)
            // At accessibility sizes the amount moves under the name instead of squeezing it.
            let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: DSSpace.xxs)) : AnyLayout(HStackLayout(spacing: DSSpace.xs))
            layout {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.merchant).dsFont(.body).foregroundStyle(Color.ds.ink)
                    Text(detail).dsFont(.caption).foregroundStyle(missed ? Color.ds.amber : Color.ds.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !large { Spacer(minLength: DSSpace.xs) }
                cost(missed: missed, alignment: large ? .leading : .trailing)
            }
            if large { Spacer(minLength: 0) }
        }
        .padding(.vertical, DSSpace.sm)
        .frame(minHeight: DSSize.listRow)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func cost(missed: Bool, alignment: HorizontalAlignment) -> some View {
            VStack(alignment: alignment, spacing: 3) {
                DSAmountText(item.amount.decimal, currencyCode: item.amount.currencyCode, sign: .magnitude, emphasis: missed ? .muted : .normal)
                if let previous = item.previousAmount, previous != item.amount {
                    DSTag(item.amount > previous ? "Up from \(previous.formatted())" : "Down from \(previous.formatted())",
                          systemImage: item.amount > previous ? "arrow.up" : "arrow.down",
                          tint: item.amount > previous ? Color.ds.caution : Color.ds.accent)
                } else if item.cadence != .monthly {
                    Text("\(item.monthlyCost.formatted()) a month").dsFont(.caption).foregroundStyle(Color.ds.inkTertiary)
                }
            }
    }

    private var cadence: String {
        switch item.cadence {
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .quarterly: "Every 3 months"
        case .yearly: "Yearly"
        }
    }

    private var detail: String {
        base + (item.setByPerson == true ? " · set by you" : "")
    }

    private var base: String {
        if item.status == .missed {
            return "\(cadence) · no charge since \(item.lastCharged.formatted(.dateTime.month(.abbreviated).day())) — cancelled?"
        }
        switch style {
        case .upcoming:
            let late = item.nextExpected < Calendar.current.startOfDay(for: AppClock.now)
            return late ? "\(cadence) · expected any day" : "\(item.nextExpected.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(cadence)"
        case .all:
            return "\(cadence) · next around \(item.nextExpected.formatted(.dateTime.month(.abbreviated).day()))"
        }
    }
}
