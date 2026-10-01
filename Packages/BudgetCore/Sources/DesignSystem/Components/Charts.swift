import Charts
import SwiftUI

public struct DSChartPoint: Identifiable, Hashable, Sendable {
    public let date: Date
    public let value: Double
    public var id: Date { date }

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

public struct DSBandPoint: Identifiable, Hashable, Sendable {
    public let date: Date
    public let low: Double
    public let high: Double
    public var id: Date { date }

    public init(date: Date, low: Double, high: Double) {
        self.date = date
        self.low = low
        self.high = high
    }
}

/// Low, wide line chart: cyan for what happened, dashed iris for what the ledger projects,
/// a soft band for the projection's range, and an optional goal rule.
public struct DSLineChart: View {
    public enum Style: Sendable { case sparkline, full }

    private let actual: [DSChartPoint]
    private let projected: [DSChartPoint]
    private let band: [DSBandPoint]
    private let goal: Double?
    private let style: Style
    private let currencyCode: String
    private let summary: String

    public init(actual: [DSChartPoint], projected: [DSChartPoint] = [], band: [DSBandPoint] = [], goal: Double? = nil, style: Style = .sparkline, currencyCode: String = "USD", accessibilitySummary: String) {
        self.actual = actual
        self.projected = projected
        self.band = band
        self.goal = goal
        self.style = style
        self.currencyCode = currencyCode
        self.summary = accessibilitySummary
    }

    private var domain: ClosedRange<Double> {
        let values = actual.map(\.value) + projected.map(\.value) + band.flatMap { [$0.low, $0.high] } + (goal.map { [$0] } ?? [])
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.12, 1)
        return (lo - pad)...(hi + pad)
    }

    public var body: some View {
        let floor = domain.lowerBound
        Chart {
            ForEach(band) { point in
                AreaMark(
                    x: .value("Date", point.date),
                    yStart: .value("Low", point.low),
                    yEnd: .value("High", point.high),
                    series: .value("Series", "Band")
                )
                .foregroundStyle(Color.ds.iris.opacity(0.14))
                .interpolationMethod(.catmullRom)
            }
            ForEach(actual) { point in
                AreaMark(
                    x: .value("Date", point.date),
                    yStart: .value("Floor", floor),
                    yEnd: .value("Balance", point.value),
                    series: .value("Series", "ActualArea")
                )
                .foregroundStyle(LinearGradient(colors: [Color.ds.accent.opacity(0.28), Color.ds.accent.opacity(0)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            }
            ForEach(actual) { point in
                LineMark(x: .value("Date", point.date), y: .value("Balance", point.value), series: .value("Series", "Actual"))
                    .foregroundStyle(Color.ds.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.catmullRom)
            }
            ForEach(projected) { point in
                LineMark(x: .value("Date", point.date), y: .value("Balance", point.value), series: .value("Series", "Projected"))
                    .foregroundStyle(Color.ds.iris)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 5]))
                    .interpolationMethod(.catmullRom)
            }
            if let last = actual.last {
                PointMark(x: .value("Date", last.date), y: .value("Balance", last.value))
                    .foregroundStyle(Color.ds.accent)
                    .symbolSize(style == .sparkline ? 36 : 48)
            }
            if let goal {
                RuleMark(y: .value("Goal", goal))
                    .foregroundStyle(Color.ds.inkTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Goal").dsFont(.eyebrow).foregroundStyle(Color.ds.inkTertiary)
                    }
            }
        }
        .chartYScale(domain: domain)
        .chartLegend(.hidden)
        .chartXAxis {
            if style == .full {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.ds.inkTertiary)
                }
            }
        }
        .chartYAxis {
            if style == .full {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Color.ds.hairline)
                    AxisValueLabel {
                        if let amount = value.as(Double.self) {
                            Text(amount.formatted(.currency(code: currencyCode).notation(.compactName)))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.ds.inkTertiary)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chart")
        .accessibilityValue(summary)
    }
}
