import BudgetKit
import DesignSystem
import SwiftUI

/// Recurring's calendar: a month grid with a dot for each kind expected on a day (cyan for money in) and the day's
/// biggest amount, then the chosen day's items. The months it shows are the ones `upcoming` reaches.
struct UpcomingCalendar: View {
    let upcoming: Upcoming
    @State private var month: Date
    @State private var selected: Date?
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var calendar: Calendar { .current }

    init(upcoming: Upcoming) {
        self.upcoming = upcoming
        let cal = Calendar.current
        _month = State(initialValue: cal.date(from: cal.dateComponents([.year, .month], from: upcoming.asOf)) ?? upcoming.asOf)
        _selected = State(initialValue: upcoming.byDay.first.map { cal.startOfDay(for: $0.date) })
    }

    /// Days with something on them, by the start of the day on this phone.
    private var days: [Date: UpcomingDay] {
        Dictionary(upcoming.byDay.map { (calendar.startOfDay(for: $0.date), $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var lastMonth: Date {
        let end = upcoming.byDay.last?.date ?? upcoming.asOf
        return calendar.date(from: calendar.dateComponents([.year, .month], from: end)) ?? month
    }

    private var firstMonth: Date { calendar.date(from: calendar.dateComponents([.year, .month], from: upcoming.asOf)) ?? month }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.md) {
            DSCard(padding: DSSpace.md) {
                VStack(spacing: DSSpace.sm) {
                    header
                    weekdays
                    grid
                }
            }
            .accessibilityIdentifier("upcomingCalendar")
            dayList
        }
    }

    private var header: some View {
        HStack {
            Text(month.formatted(.dateTime.month(.wide).year()))
                .dsFont(.headline).foregroundStyle(Color.ds.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            DSIconButton(systemImage: "chevron.left", label: "Previous month", tint: month > firstMonth ? Color.ds.ink : Color.ds.inkDisabled) {
                step(-1)
            }
            .disabled(month <= firstMonth)
            DSIconButton(systemImage: "chevron.right", label: "Next month", tint: month < lastMonth ? Color.ds.ink : Color.ds.inkDisabled) {
                step(1)
            }
            .disabled(month >= lastMonth)
        }
    }

    private func step(_ months: Int) {
        guard let next = calendar.date(byAdding: .month, value: months, to: month) else { return }
        withAnimation(DSMotion.standard) {
            month = next
            selected = upcoming.byDay.map { calendar.startOfDay(for: $0.date) }.first { calendar.isDate($0, equalTo: next, toGranularity: .month) }
        }
    }

    private var weekdays: some View {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let ordered = Array(symbols[first...] + symbols[..<first])
        return HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, symbol in
                Text(symbol).dsFont(.axis).foregroundStyle(Color.ds.inkTertiary).frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    /// Leading blanks, then each day of the month.
    private var cells: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead) + range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
    }

    private var grid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
        let today = calendar.startOfDay(for: upcoming.asOf)
        let byDay = days
        return LazyVGrid(columns: columns, spacing: DSSpace.xxs) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                if let date {
                    DayCell(date: date, day: byDay[date], items: byDay[date].map(upcoming.items(on:)) ?? [], isPast: date < today,
                            isToday: date == today, isSelected: selected == date, large: dynamicTypeSize.isAccessibilitySize) {
                        withAnimation(DSMotion.standard) { selected = byDay[date] == nil ? nil : date }
                    }
                } else {
                    Color.clear.frame(minHeight: DSSize.hitTarget).accessibilityHidden(true)
                }
            }
        }
    }

    @ViewBuilder
    private var dayList: some View {
        if let selected, let day = days[selected] {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                DSSectionHeader(selected.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                DSCard(padding: 0) {
                    VStack(spacing: 0) {
                        let items = upcoming.items(on: day)
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { DSDivider() }
                            UpcomingRow(item: item, showsDate: false, payCadence: upcoming.payCadence)
                        }
                    }
                    .padding(.horizontal, DSSpace.md)
                }
            }
            .accessibilityIdentifier("upcomingDay")
        } else {
            Text("Tap a day with a dot to see what's expected.")
                .dsFont(.caption).foregroundStyle(Color.ds.inkTertiary)
        }
    }
}

/// One day: its number, a dot per kind expected (money in cyan, a card bill azure, charges in ink), and the day's
/// biggest total. Past days are quieter; today has a ring; the chosen day is lit.
private struct DayCell: View {
    let date: Date
    let day: UpcomingDay?
    let items: [UpcomingItem]
    let isPast: Bool
    let isToday: Bool
    let isSelected: Bool
    let large: Bool
    let onTap: () -> Void
    /// The design system's dot (6pt, as on tags and eyebrows).
    static let dot: CGFloat = 6

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: DSSpace.xxs) {
                Text(date.formatted(.dateTime.day()))
                    .dsFont(.label)
                    .foregroundStyle(isPast ? Color.ds.inkDisabled : Color.ds.ink)
                if let day, !large {
                    HStack(spacing: DSSpace.xxs / 2) {
                        ForEach(kinds, id: \.self) { kind in
                            Circle().fill(color(kind)).frame(width: Self.dot, height: Self.dot)
                        }
                    }
                    .frame(height: Self.dot)
                    headline(day)
                } else if day != nil {
                    Circle().fill(Color.ds.accent).frame(width: Self.dot, height: Self.dot)
                }
            }
            .frame(maxWidth: .infinity, minHeight: DSSize.hitTarget)
            .padding(.vertical, DSSpace.xxs)
            .background {
                RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
                    .fill(isSelected ? DSState.selected : Color.clear)
            }
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
                        .strokeBorder(Color.ds.inkSecondary, lineWidth: DSState.focusRingWidth)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(day == nil)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var kinds: [UpcomingItem.Kind] {
        UpcomingItem.Kind.allCases.filter { kind in items.contains { $0.kind == kind } }.prefix(3).map { $0 }
    }

    private func color(_ kind: UpcomingItem.Kind) -> Color {
        switch kind {
        case .income: Color.ds.inflow
        case .cardBill: DSTone.azure.onCanvas
        case .bill, .subscription: Color.ds.inkSecondary
        }
    }

    /// The day's biggest total, compact: a card bill or the charges, else the money in.
    @ViewBuilder
    private func headline(_ day: UpcomingDay) -> some View {
        let t = day.totals
        let out = t.cardBills > t.charges ? t.cardBills : t.charges
        if out.minorUnits > 0 {
            Text(Self.compact(out)).dsFont(.axis).foregroundStyle(isPast ? Color.ds.inkTertiary : Color.ds.inkSoft)
                .lineLimit(1).minimumScaleFactor(0.7)
        } else if t.income.minorUnits > 0 {
            Text("+" + Self.compact(t.income)).dsFont(.axis).foregroundStyle(Color.ds.inflow)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    /// "$2.4K", "$15".
    static func compact(_ money: Money) -> String {
        money.decimal.formatted(.currency(code: money.currencyCode).notation(.compactName).precision(.significantDigits(1...2)))
    }

    private var accessibilityText: String {
        let when = date.formatted(.dateTime.weekday(.wide).month(.wide).day())
        guard !items.isEmpty else { return when }
        let said = items.map { item in
            "\(item.title), \(item.kind == .income ? "in " : "")\(item.amount.magnitude.formatted())"
        }
        return "\(when): " + said.joined(separator: "; ")
    }
}
