import SwiftUI

/// One day's spending for `DSWeekStrip`. The ledger computes the amount; the strip only draws it.
public struct DSDaySpend: Identifiable, Hashable, Sendable {
    public let date: Date
    public let amount: Decimal
    public var id: Date { date }

    public init(date: Date, amount: Decimal) {
        self.date = date
        self.amount = amount
    }
}

/// Seven days side by side, each cell filled cyan in proportion to the heaviest day, so the
/// busy days stand out at a glance. Today is outlined; with `onSelect`, tapping a day hands it back. The ink stays white on every fill:
/// the ramp stops at `maxFillOpacity`, where white still clears AA and black never would
/// (see `ContrastTests`). At accessibility text sizes the days stack as rows.
public struct DSWeekStrip: View {
    private let days: [DSDaySpend]
    private let currencyCode: String
    private let today: Date
    private let calendar: Calendar
    private let onSelect: ((Date) -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(days: [DSDaySpend], currencyCode: String = "USD", today: Date = .now, calendar: Calendar = .current,
                onSelect: ((Date) -> Void)? = nil) {
        self.days = days
        self.currencyCode = currencyCode
        self.today = today
        self.calendar = calendar
        self.onSelect = onSelect
    }

    /// The faintest non-zero fill and the strongest; white ink is AA across the whole range.
    nonisolated static let minFillOpacity: Double = 0.12
    nonisolated static let maxFillOpacity: Double = 0.6

    /// Accent opacity for a day, or nil for a day with no spending (drawn as `surfaceRaised`).
    nonisolated static func fillOpacity(for amount: Decimal, heaviest: Decimal) -> Double? {
        let value = abs(amount)
        let top = abs(heaviest)
        guard value > 0, top > 0 else { return nil }
        let ratio = min(NSDecimalNumber(decimal: value / top).doubleValue, 1)
        return minFillOpacity + (maxFillOpacity - minFillOpacity) * ratio
    }

    /// "$48", or "$1.2K" once a day passes a thousand, so seven cells fit a phone.
    nonisolated static func amountLabel(_ amount: Decimal, currencyCode: String, locale: Locale = .autoupdatingCurrent) -> String {
        let value = abs(amount)
        if value >= 1000 {
            return value.formatted(.currency(code: currencyCode).notation(.compactName).precision(.significantDigits(2)).locale(locale))
        }
        return DSAmountFormat.string(value, currencyCode: currencyCode, sign: .magnitude, fractionDigits: 0, locale: locale)
    }

    private var heaviest: Decimal { days.map { abs($0.amount) }.max() ?? 0 }

    private func style(_ base: Date.FormatStyle) -> Date.FormatStyle {
        var style = base
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return style
    }

    public var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: DSSpace.xs) {
                ForEach(days) { day in
                    HStack(spacing: DSSpace.sm) {
                        Text(day.date.formatted(style(Date.FormatStyle().weekday(.abbreviated).day())))
                            .dsFont(.body)
                            .foregroundStyle(Color.ds.inkSoft)
                        Spacer(minLength: DSSpace.xs)
                        Text(Self.amountLabel(day.amount, currencyCode: currencyCode))
                            .dsFont(.amountRow)
                            .foregroundStyle(Color.ds.ink)
                    }
                    .padding(.horizontal, DSSpace.sm)
                    .padding(.vertical, DSSpace.xs)
                    .background { cellBackground(day) }
                    .overlay { todayOutline(day) }
                    .modifier(DayAccessibility(label: accessibilityLabel(day), value: accessibilityValue(day)))
                    .selectable(day.date, onSelect)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 6) {
                ForEach(days) { day in
                    VStack(spacing: 6) {
                        Text(day.date.formatted(style(Date.FormatStyle().weekday(.abbreviated))))
                            .dsFont(.eyebrow)
                            .foregroundStyle(isToday(day) ? Color.ds.ink : Color.ds.inkSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        VStack(spacing: 2) {
                            Text(day.date.formatted(style(Date.FormatStyle().day())))
                                .dsFont(.caption)
                                .foregroundStyle(Color.ds.inkSoft)
                            Text(Self.amountLabel(day.amount, currencyCode: currencyCode))
                                .dsFont(.amountRow)
                                .foregroundStyle(day.amount == 0 ? Color.ds.inkSecondary : Color.ds.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.55)
                        }
                        .padding(.vertical, DSSpace.sm)
                        .padding(.horizontal, 2)
                        .frame(maxWidth: .infinity)
                        .background { cellBackground(day) }
                        .overlay { todayOutline(day) }
                    }
                    .frame(maxWidth: .infinity)
                    .modifier(DayAccessibility(label: accessibilityLabel(day), value: accessibilityValue(day)))
                    .selectable(day.date, onSelect)
                }
            }
        }
    }

    private func isToday(_ day: DSDaySpend) -> Bool { calendar.isDate(day.date, inSameDayAs: today) }

    private func cellBackground(_ day: DSDaySpend) -> some View {
        let shape = RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
        return Group {
            if let opacity = Self.fillOpacity(for: day.amount, heaviest: heaviest) {
                shape.fill(Color.ds.accent.opacity(opacity))
            } else {
                shape.fill(Color.ds.surfaceRaised)
            }
        }
    }

    @ViewBuilder
    private func todayOutline(_ day: DSDaySpend) -> some View {
        if isToday(day) {
            RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
                .strokeBorder(Color.ds.inkSecondary, lineWidth: 1.5)
        }
    }

    private func accessibilityLabel(_ day: DSDaySpend) -> String {
        let name = day.date.formatted(style(Date.FormatStyle().weekday(.wide).month(.wide).day()))
        return isToday(day) ? "Today, \(name)" : name
    }

    private func accessibilityValue(_ day: DSDaySpend) -> String {
        day.amount == 0 ? "Nothing spent" : DSAmountFormat.string(abs(day.amount), currencyCode: currencyCode, sign: .magnitude)
    }
}

private extension View {
    /// A day cell as a button when the strip takes taps.
    @ViewBuilder
    func selectable(_ date: Date, _ onSelect: ((Date) -> Void)?) -> some View {
        if let onSelect {
            Button { onSelect(date) } label: { contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the day's transactions")
                .accessibilityIdentifier("weekStripDay")
        } else {
            self
        }
    }
}

private struct DayAccessibility: ViewModifier {
    let label: String
    let value: String

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
    }
}

/// A 270° gauge — flexible spent against the flexible budget — with whatever the caller puts
/// in the middle (usually Safe to spend). Over is the full arc in caution plus an "Over" tag in
/// the gap at the bottom, since caution alone could be mistaken for a category tone.
public struct DSArcGauge<Center: View>: View {
    private let fraction: Double
    private let tint: Color
    private let lineWidth: CGFloat
    private let label: String
    private let center: Center

    /// - Parameters:
    ///   - fraction: 0...∞ where 1 is the whole budget. Above 1 renders as over.
    ///   - accessibilityLabel: what the arc measures, e.g. "Everyday spending".
    public init(fraction: Double, tint: Color = Color.ds.accent, lineWidth: CGFloat = 10, accessibilityLabel: String = "Progress",
                @ViewBuilder center: () -> Center) {
        self.fraction = fraction
        self.tint = tint
        self.lineWidth = lineWidth
        self.label = accessibilityLabel
        self.center = center()
    }

    /// The share of the circle the arc covers; the rest is the opening at the bottom.
    nonisolated static var sweep: Double { 0.75 }

    /// Finite only: a zero budget gives an infinite fraction, which draws as full rather than "over ∞%".
    private var isOver: Bool { DSProgressBar.isOver(fraction) && fraction.isFinite }

    public var body: some View {
        let filled = DSProgressBar.filled(for: fraction)
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        ZStack {
            Group {
                arc(to: 1).stroke(Color.ds.hairlineStrong, style: style)
                arc(to: filled).stroke(isOver ? Color.ds.caution : tint, style: style)
            }
            .animation(DSMotion.gentle, value: filled)
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue(isOver ? "Over, \(Int(fraction * 100)) percent" : "\(Int(filled * 100)) percent")
            center
                .padding(lineWidth * 2)
        }
        .overlay(alignment: .bottom) {
            if isOver { DSTag.over() }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func arc(to share: Double) -> some Shape {
        // Starts bottom-left (135°) and runs clockwise, leaving the opening at the bottom.
        Circle()
            .inset(by: lineWidth / 2)
            .trim(from: 0, to: Self.sweep * share)
            .rotation(.degrees(135))
    }
}
