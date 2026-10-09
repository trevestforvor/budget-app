import BudgetKit
import DesignSystem
import SwiftUI

// What's coming up (`GET /v1/upcoming`): expected paychecks, bills, subscriptions and card bills. The ledger works out
// every date and amount; these views only show them. Shared by Home, Spending's "Coming up", Recurring and Plan.

/// The window every screen asks for, so they share one saved copy.
enum UpcomingWindow {
    static let days = 30
    /// The calendar reaches into next month.
    static let calendarDays = 62
}

extension UpcomingItem.Kind {
    var symbol: String {
        switch self {
        case .income: "arrow.down.circle"
        case .bill: "doc.text"
        case .subscription: "repeat"
        case .cardBill: "creditcard"
        }
    }
}

extension UpcomingItem {
    /// The glyph's tone: money in is cyan (data), a card bill azure, a bill or subscription its category's.
    @MainActor
    func tone(_ app: AppModel) -> DSTone {
        switch kind {
        case .income: .cyan
        case .cardBill: .azure
        case .bill, .subscription: CategoryStyle.tone(for: app.category(categoryID) ?? app.category(kind == .bill ? "utilities" : "subscriptions"))
        }
    }

    @MainActor
    func symbol(_ app: AppModel) -> String {
        kind == .income || kind == .cardBill ? kind.symbol : app.category(categoryID)?.symbol ?? kind.symbol
    }

    /// "Thu, Oct 1".
    var dayLabel: String { date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }

    /// What it is and when, in a few words: "Paycheck · twice a month", "Card bill · minimum $35", "Expected any day".
    func detail(showsDate: Bool, cadence payCadence: String? = nil) -> String {
        var parts: [String] = []
        if showsDate { parts.append(dayLabel) }
        if isLate == true {
            parts.append(kind == .cardBill ? "Past due" : "Expected any day")
        }
        switch kind {
        case .income: parts.append(payCadence.map { "Paycheck · \($0)" } ?? "Paycheck")
        case .cardBill: parts.append(minimumPayment.map { "Card bill · minimum \($0.formatted())" } ?? "Card bill")
        case .bill: parts.append("Bill")
        case .subscription: parts.append("Subscription")
        }
        return parts.joined(separator: " · ")
    }
}

/// One expected thing: glyph, title, when and what it is, and the amount ("+$3,850" in cyan for money in).
struct UpcomingRow: View {
    let item: UpcomingItem
    var showsDate = true
    var payCadence: String?
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let large = dynamicTypeSize.isAccessibilitySize
        HStack(alignment: large ? .top : .center, spacing: DSSpace.sm) {
            DSGlyph(systemImage: item.symbol(app), tone: item.tone(app))
            let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: DSSpace.xxs)) : AnyLayout(HStackLayout(spacing: DSSpace.xs))
            layout {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).dsFont(.body).foregroundStyle(Color.ds.ink)
                    Text(item.detail(showsDate: showsDate, cadence: payCadence))
                        .dsFont(.caption)
                        .foregroundStyle(item.isLate == true && item.kind == .cardBill ? Color.ds.caution : Color.ds.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !large { Spacer(minLength: DSSpace.xs) }
                UpcomingAmount(item: item)
            }
            if large { Spacer(minLength: 0) }
        }
        .padding(.vertical, DSSpace.sm)
        .frame(minHeight: DSSize.listRow)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Money in with a plus in cyan; money out plain, no sign.
struct UpcomingAmount: View {
    let item: UpcomingItem
    var size: DSAmountText.Size = .row

    var body: some View {
        if item.kind == .income {
            DSAmountText(item.amount.decimal, currencyCode: item.amount.currencyCode, size: size, sign: .inflowPlus, tintsInflow: true)
        } else {
            DSAmountText(item.amount.decimal, currencyCode: item.amount.currencyCode, size: size, sign: .magnitude)
        }
    }
}

/// One card's statement: what's left and when it's due, or that it's paid, from the card issuer.
struct CardBillRow: View {
    let bill: CardBill
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let large = dynamicTypeSize.isAccessibilitySize
        let settled = bill.status == .paid || bill.status == .nothingDue
        HStack(alignment: large ? .top : .center, spacing: DSSpace.sm) {
            DSGlyph(systemImage: "creditcard", tone: .azure, emphasis: settled ? .muted : .normal)
            let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: DSSpace.xxs)) : AnyLayout(HStackLayout(spacing: DSSpace.xs))
            layout {
                VStack(alignment: .leading, spacing: 3) {
                    Text(bill.accountName ?? "Card").dsFont(.body).foregroundStyle(Color.ds.ink)
                    Text(detail).dsFont(.caption).foregroundStyle(Color.ds.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
                if !large { Spacer(minLength: DSSpace.xs) }
                VStack(alignment: large ? .leading : .trailing, spacing: 3) {
                    if let shown = settled ? bill.statementBalance : bill.remaining {
                        DSAmountText(shown.decimal, currencyCode: shown.currencyCode, sign: .magnitude, emphasis: settled ? .muted : .normal)
                    }
                    tag
                }
            }
            if large { Spacer(minLength: 0) }
        }
        .padding(.vertical, DSSpace.sm)
        .frame(minHeight: DSSize.listRow)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var tag: some View {
        switch bill.status {
        case .overdue: DSTag.over("Past due")
        case .paid: DSTag("Paid", systemImage: "checkmark")
        default: EmptyView()
        }
    }

    private var detail: String {
        let day = Date.FormatStyle.dateTime.month(.abbreviated).day()
        switch bill.status {
        case .paid:
            return ["Statement paid", bill.dueDate.map { "was due \($0.formatted(day))" }].compactMap { $0 }.joined(separator: " · ")
        case .nothingDue:
            return "Nothing due on the last statement"
        case .overdue:
            return ["Past due", bill.minimumPayment.map { "minimum \($0.formatted())" }].compactMap { $0 }.joined(separator: " · ")
        default:
            return [bill.dueDate.map { "Due \($0.formatted(day))" }, bill.minimumPayment.map { "minimum \($0.formatted())" }]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }
}

/// Every card with a statement from its issuer, soonest due first.
struct CardBillsCard: View {
    let bills: [CardBill]

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            DSSectionHeader("Card bills")
            DSCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(bills.enumerated()), id: \.element.id) { index, bill in
                        if index > 0 { DSDivider() }
                        CardBillRow(bill: bill)
                    }
                }
                .padding(.horizontal, DSSpace.md)
            }
            .accessibilityIdentifier("cardBills")
            if let updated = bills.map(\.updatedAt).max() {
                Text("From your card issuer, updated \(updated.formatted(.dateTime.month(.abbreviated).day())). What's left counts payments made since the statement.")
                    .dsFont(.caption).foregroundStyle(Color.ds.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Home: the next paycheck, and what the next seven days hold.
struct NextPaycheckCard: View {
    let upcoming: Upcoming
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            DSCard {
                VStack(alignment: .leading, spacing: DSSpace.sm) {
                    HStack {
                        DSEyebrow("Next paycheck", dot: Color.ds.inflow)
                        Spacer(minLength: DSSpace.xs)
                        Image(systemName: "chevron.right")
                            .font(.system(size: DSIconSize.xs, weight: .semibold))
                            .foregroundStyle(Color.ds.inkTertiary)
                            .accessibilityHidden(true)
                    }
                    if let pay = upcoming.nextPaycheck {
                        UpcomingAmount(item: pay, size: .title)
                        Text([pay.dayLabel, pay.title, upcoming.payCadence].compactMap { $0 }.joined(separator: " · "))
                            .dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    let week = upcoming.nextSevenDays
                    if week.charges.minorUnits > 0 || week.cardBills.minorUnits > 0 {
                        DSDivider()
                        DSFigureRow(label: "Bills and subscriptions", detail: "Next 7 days", value: week.charges.decimal)
                        if week.cardBills.minorUnits > 0 {
                            DSFigureRow(label: "Card bills", detail: "Next 7 days", value: week.cardBills.decimal)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens what's coming up")
        .accessibilityIdentifier("nextPaycheck")
    }
}

/// Plan: the next 30 days as the ledger expects them — paychecks in, bills and subscriptions out, card bills apart
/// (they pay for spending already made).
struct NextThirtyDaysCard: View {
    let upcoming: Upcoming
    @Environment(AppModel.self) private var app

    var body: some View {
        let t = upcoming.totals
        DSCard {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                DSEyebrow("Next \(upcoming.days) days")
                VStack(spacing: 0) {
                    if t.income.minorUnits > 0 {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Paychecks").dsFont(.callout).foregroundStyle(Color.ds.inkSoft)
                            Spacer()
                            DSAmountText(t.income.decimal, currencyCode: t.income.currencyCode, sign: .inflowPlus, tintsInflow: true)
                        }
                        .padding(.vertical, DSSpace.xxs)
                        .accessibilityElement(children: .combine)
                    }
                    DSFigureRow(label: "Bills and subscriptions", detail: "From your recurring charges", value: t.charges.decimal)
                    if t.cardBills.minorUnits > 0 {
                        DSFigureRow(label: "Card bills", detail: "Paying for spending already made", value: t.cardBills.decimal)
                    }
                }
                Button("See what's coming up") { app.route(Navigate(screen: .recurring)) }
                    .buttonStyle(.ds(.quiet))
                    .accessibilityHint("Opens Recurring")
            }
        }
        .accessibilityIdentifier("nextThirtyDays")
    }
}

/// The weekly recap's "Coming up next": the next seven days of income, bills and card bills, a few lines.
struct RecapComingUp: View {
    let items: [UpcomingItem]

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            DSEyebrow("Coming up next")
            ForEach(items.prefix(4)) { item in
                HStack(alignment: .firstTextBaseline, spacing: DSSpace.xs) {
                    Text(item.date.formatted(.dateTime.weekday(.abbreviated)))
                        .dsFont(.caption).foregroundStyle(Color.ds.inkTertiary)
                        .frame(minWidth: DSSpace.xl, alignment: .leading)
                    Text(item.title).dsFont(.callout).foregroundStyle(Color.ds.inkSoft).lineLimit(1)
                    Spacer(minLength: DSSpace.xs)
                    UpcomingAmount(item: item)
                }
                .accessibilityElement(children: .combine)
            }
            if items.count > 4 {
                Text("and \(items.count - 4) more").dsFont(.caption).foregroundStyle(Color.ds.inkTertiary)
            }
        }
    }
}
