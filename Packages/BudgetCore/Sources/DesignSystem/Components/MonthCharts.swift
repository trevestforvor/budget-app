import Charts
import SwiftUI

/// Axis labels are `DSTextStyle.axis` (caption 2, monospaced, tabular); each chart caps its text at accessibility 2,
/// so twelve month letters and the value ticks still fit under the bars.
private let axisLimit = DynamicTypeSize.accessibility2

/// The middle of `date`'s month — where a `unit: .month` bar is drawn, so an axis mark there
/// sits under its bar. (Marks at the data's own dates land between bars.)
func monthMidpoint(_ date: Date, calendar: Calendar) -> Date {
    guard let month = calendar.dateInterval(of: .month, for: date) else { return date }
    return month.start.addingTimeInterval(month.duration / 2)
}

/// One month's total for `DSMonthBars`.
public struct DSMonthBar: Identifiable, Hashable, Sendable {
    /// Any date in the month; bars group by calendar month.
    public let month: Date
    public let value: Double
    public var id: Date { month }

    public init(month: Date, value: Double) {
        self.month = month
        self.value = value
    }
}

/// A year of one category, month by month: every month in the category's tone, the selected one
/// at full strength and the rest at 55%, and a dashed target rule. A month over target is caution **and** carries an
/// exclamation mark above the bar, because caution is also a category tone.
public struct DSMonthBars: View {
    private let bars: [DSMonthBar]
    private let target: Double?
    private let tone: DSTone
    private let selection: Date?
    private let currencyCode: String
    private let calendar: Calendar
    private let summary: String
    private let name: String
    private let onSelect: ((Date) -> Void)?

    /// - Parameters:
    ///   - target: today's target; each bar is judged against it (there's no target history).
    ///   - accessibilityName: what VoiceOver calls the chart ("Dining by month").
    ///   - onSelect: tap a bar (or swipe up/down in VoiceOver) to pick its month.
    public init(bars: [DSMonthBar], target: Double? = nil, tone: DSTone, selection: Date? = nil, currencyCode: String = "USD",
                calendar: Calendar = .current, accessibilityName: String = "Month by month", accessibilitySummary: String,
                onSelect: ((Date) -> Void)? = nil) {
        self.bars = bars
        self.target = target
        self.tone = tone
        self.selection = selection
        self.currencyCode = currencyCode
        self.calendar = calendar
        self.summary = accessibilitySummary
        self.name = accessibilityName
        self.onSelect = onSelect
    }

    nonisolated static func isOver(_ value: Double, target: Double?) -> Bool {
        guard let target, target > 0 else { return false }
        return value > target
    }

    /// The bar for the month containing `date`, else the one closest to it.
    nonisolated static func bar(nearest date: Date, in bars: [DSMonthBar], calendar: Calendar) -> DSMonthBar? {
        if let exact = bars.first(where: { calendar.isDate($0.month, equalTo: date, toGranularity: .month) }) { return exact }
        return bars.min { abs($0.month.timeIntervalSince(date)) < abs($1.month.timeIntervalSince(date)) }
    }

    private func isSelected(_ month: Date) -> Bool {
        selection.map { calendar.isDate($0, equalTo: month, toGranularity: .month) } ?? false
    }

    private func color(for bar: DSMonthBar) -> Color {
        let opacity = Self.opacity(selected: isSelected(bar.month), hasSelection: selection != nil)
        if Self.isOver(bar.value, target: target) { return Color.ds.caution.opacity(opacity) }
        if bar.value <= 0 { return Palette.steel.color }
        // Every month keeps its tone at full strength; only once a month is picked do the others step back
        // (opacity is fine on a mark that isn't text). Nothing picked, nothing dims: the tone stays saturated.
        return tone.onCanvas.opacity(opacity)
    }

    /// Full strength unless another month is selected.
    nonisolated static func opacity(selected: Bool, hasSelection: Bool) -> Double {
        hasSelection && !selected ? 0.55 : 1
    }

    private var domain: ClosedRange<Double> {
        let top = max(bars.map(\.value).max() ?? 0, target ?? 0)
        return 0...max(top * 1.18, 1)
    }

    private func monthLabel(_ date: Date) -> String {
        var style = Date.FormatStyle().month(bars.count > 6 ? .narrow : .abbreviated)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    public var body: some View {
        Chart {
            ForEach(bars) { bar in
                BarMark(x: .value("Month", bar.month, unit: .month, calendar: calendar), y: .value("Spent", bar.value), width: .fixed(10))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4, style: .continuous))
                    .foregroundStyle(color(for: bar))
                    .annotation(position: .top, spacing: 3) {
                        if Self.isOver(bar.value, target: target) {
                            Image(systemName: "exclamationmark")
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(Color.ds.caution)
                        }
                    }
            }
            if let target {
                RuleMark(y: .value("Target", target))
                    .foregroundStyle(Color.ds.inkTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
        }
        .chartYScale(domain: domain)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: bars.map { monthMidpoint($0.month, calendar: calendar) }) { value in
                AxisValueLabel(centered: false, anchor: .top) {
                    if let date = value.as(Date.self) {
                        Text(monthLabel(date))
                            .dsFont(.axis)
                            .foregroundStyle(isSelected(date) ? Color.ds.ink : Color.ds.inkTertiary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if onSelect != nil {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let plot = proxy.plotFrame else { return }
                            let x = location.x - geometry[plot].origin.x
                            guard let date: Date = proxy.value(atX: x),
                                  let bar = Self.bar(nearest: date, in: bars, calendar: calendar) else { return }
                            onSelect?(bar.month)
                        }
                }
            }
        }
        .dynamicTypeSize(...axisLimit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            guard let onSelect, !bars.isEmpty else { return }
            let index = bars.firstIndex { isSelected($0.month) } ?? bars.count - 1
            let next = direction == .increment ? min(index + 1, bars.count - 1) : max(index - 1, 0)
            onSelect(bars[next].month)
        }
    }

    private var accessibilityValue: String {
        guard let selected = bars.first(where: { isSelected($0.month) }) else { return summary }
        var style = Date.FormatStyle().month(.wide)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        let amount = DSAmountFormat.string(Decimal(selected.value), currencyCode: currencyCode, sign: .magnitude, fractionDigits: 0)
        let over = Self.isOver(selected.value, target: target) ? ", over target" : ""
        return "\(summary). \(selected.month.formatted(style)): \(amount)\(over)"
    }
}

/// One month of money in and out for `DSCashFlowChart`. All three figures come from the
/// ledger — the design system never computes money, so `net` is passed in, not derived.
public struct DSCashFlowPoint: Identifiable, Hashable, Sendable {
    public let month: Date
    public let income: Double
    /// Magnitude of what went out; drawn below zero.
    public let spending: Double
    public let net: Double
    /// The month in progress, drawn at half strength.
    public let isPartial: Bool
    public var id: Date { month }

    public init(month: Date, income: Double, spending: Double, net: Double, isPartial: Bool = false) {
        self.month = month
        self.income = income
        self.spending = spending
        self.net = net
        self.isPartial = isPartial
    }
}

/// Monthly cash flow as diverging bars: money in rises in cyan, money out falls in soft white,
/// and a dashed iris line joins each month's net. The month in progress is half strength.
public struct DSCashFlowChart: View {
    private let points: [DSCashFlowPoint]
    private let currencyCode: String
    private let showsLegend: Bool
    private let calendar: Calendar
    private let summary: String
    private let name: String

    public init(points: [DSCashFlowPoint], currencyCode: String = "USD", showsLegend: Bool = true, calendar: Calendar = .current,
                accessibilityName: String = "Cash flow", accessibilitySummary: String) {
        self.points = points
        self.currencyCode = currencyCode
        self.showsLegend = showsLegend
        self.calendar = calendar
        self.summary = accessibilitySummary
        self.name = accessibilityName
    }

    private var domain: ClosedRange<Double> {
        let top = max(points.map { max($0.income, $0.net) }.max() ?? 0, 1)
        let bottom = min(points.map { min(-abs($0.spending), $0.net) }.min() ?? 0, -1)
        return (bottom * 1.1)...(top * 1.1)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            chart
            if showsLegend { legend }
        }
    }

    private var chart: some View {
        Chart {
            RuleMark(y: .value("Zero", 0))
                .foregroundStyle(Color.ds.hairlineStrong)
                .lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(points) { point in
                BarMark(x: .value("Month", point.month, unit: .month, calendar: calendar), y: .value("In", point.income), width: .ratio(0.5))
                    .foregroundStyle(Color.ds.inflow)
                    .opacity(point.isPartial ? 0.5 : 1)
                    .cornerRadius(3)
                BarMark(x: .value("Month", point.month, unit: .month, calendar: calendar), y: .value("Out", -abs(point.spending)), width: .ratio(0.5))
                    .foregroundStyle(Color.ds.inkSoft.opacity(0.7))
                    .opacity(point.isPartial ? 0.5 : 1)
                    .cornerRadius(3)
            }
            ForEach(points) { point in
                LineMark(x: .value("Month", point.month, unit: .month, calendar: calendar), y: .value("Net", point.net), series: .value("Series", "Net"))
                    .foregroundStyle(Color.ds.iris)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 5]))
                PointMark(x: .value("Month", point.month, unit: .month, calendar: calendar), y: .value("Net", point.net))
                    .foregroundStyle(Color.ds.iris)
                    .opacity(point.isPartial ? 0.5 : 1)
                    .symbolSize(28)
            }
        }
        .chartYScale(domain: domain)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: points.map { monthMidpoint($0.month, calendar: calendar) }) { value in
                AxisValueLabel(centered: false, anchor: .top) {
                    if let date = value.as(Date.self) {
                        Text(monthLabel(date))
                            .dsFont(.axis)
                            .foregroundStyle(Color.ds.inkTertiary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Color.ds.hairline)
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(amount.formatted(.currency(code: currencyCode).notation(.compactName)))
                            .dsFont(.axis)
                            .foregroundStyle(Color.ds.inkTertiary)
                    }
                }
            }
        }
        .dynamicTypeSize(...axisLimit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(summary)
    }

    private func monthLabel(_ date: Date) -> String {
        var style = Date.FormatStyle().month(.abbreviated)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    private var legend: some View {
        HStack(spacing: DSSpace.md) {
            legendItem("In") { RoundedRectangle(cornerRadius: 2).fill(Color.ds.inflow).frame(width: 8, height: 8) }
            legendItem("Out") { RoundedRectangle(cornerRadius: 2).fill(Color.ds.inkSoft.opacity(0.7)).frame(width: 8, height: 8) }
            legendItem("Net") {
                Capsule().fill(Color.ds.iris).frame(width: 12, height: 2)
            }
        }
        .accessibilityHidden(true)
    }

    private func legendItem<Swatch: View>(_ title: String, @ViewBuilder swatch: () -> Swatch) -> some View {
        HStack(spacing: 6) {
            swatch()
            Text(title).dsFont(.eyebrow).foregroundStyle(Color.ds.inkSecondary)
        }
    }
}
