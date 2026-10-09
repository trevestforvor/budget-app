import SwiftUI

/// One node of a `DSSankeyChart`: a bar in its column, labelled with its name and amount.
public struct DSSankeyNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    /// The amount as shown ("$1,240").
    public let valueText: String
    public let value: Double
    /// 0 on the left.
    public let column: Int
    /// Nil draws a neutral (steel) node, for "Other".
    public let tone: DSTone?

    public init(id: String, label: String, valueText: String, value: Double, column: Int, tone: DSTone?) {
        self.id = id; self.label = label; self.valueText = valueText; self.value = value; self.column = column; self.tone = tone
    }
}

public struct DSSankeyLink: Hashable, Sendable {
    public let source: String
    public let target: String
    public let value: Double

    public init(source: String, target: String, value: Double) {
        self.source = source; self.target = target; self.value = value
    }
}

/// Where everything goes in a Sankey of a given size: bars stacked per column on one scale, each link a band leaving
/// its source and entering its target in the order of the other ends (so bands don't cross at a bar), and labels
/// beside their bars, nudged apart so they never overlap.
public struct DSSankeyLayout: Sendable {
    public struct Bar: Sendable {
        public var node: DSSankeyNode
        public var rect: CGRect
        /// The label's centre line, after nudging.
        public var labelY: CGFloat
    }

    public struct Band: Sendable {
        public var link: DSSankeyLink
        /// Top of the band where it leaves the source bar and where it enters the target bar.
        public var sourceTop: CGFloat
        public var targetTop: CGFloat
        public var thickness: CGFloat
        public var sourceX: CGFloat
        public var targetX: CGFloat
        /// The tone it's drawn in: its target's (an income source flows in the bucket's colour).
        public var tone: DSTone?
    }

    public static let barWidth: CGFloat = 8
    public static let gap: CGFloat = 10

    public var bars: [Bar]
    public var bands: [Band]
    public var size: CGSize
    /// Where each column's labels start, and how wide they may run (to the next column's bar, or the edge).
    public var labelX: [Int: CGFloat]
    public var labelWidth: [Int: CGFloat]

    /// - Parameters:
    ///   - labelHeight: the room one label needs; labels in a column are kept this far apart.
    ///   - trailingLabelWidth: room kept right of the last column for its labels.
    public init(nodes: [DSSankeyNode], links: [DSSankeyLink], size: CGSize, labelHeight: CGFloat, trailingLabelWidth: CGFloat) {
        self.size = size
        let columns = Dictionary(grouping: nodes, by: \.column)
        let order = columns.keys.sorted()
        let last = order.last ?? 0
        let barWidth = Self.barWidth
        let plotRight = max(barWidth * 3, size.width - trailingLabelWidth)
        func x(_ column: Int) -> CGFloat {
            guard last > 0 else { return 0 }
            return (plotRight - barWidth) * CGFloat(column) / CGFloat(last)
        }
        // One scale for every column, so a dollar is as tall on the left as on the right.
        let scale = order.compactMap { c -> CGFloat? in
            let list = columns[c] ?? []
            let total = list.map(\.value).reduce(0, +)
            guard total > 0 else { return nil }
            return max(0, size.height - Self.gap * CGFloat(max(list.count - 1, 0))) / CGFloat(total)
        }.min() ?? 0

        var bars: [String: Bar] = [:]
        var barOrder: [String] = []
        var labelX: [Int: CGFloat] = [:]
        var labelWidth: [Int: CGFloat] = [:]
        for (index, c) in order.enumerated() {
            let list = columns[c] ?? []
            let heights = list.map { max(2, CGFloat($0.value) * scale) }
            let used = heights.reduce(0, +)
            // The space left over spreads between the bars (up to three gaps' worth), and the column is centred.
            let spare = max(0, size.height - used - Self.gap * CGFloat(max(list.count - 1, 0)))
            let between = Self.gap + (list.count > 1 ? min(spare / CGFloat(list.count - 1), Self.gap * 3) : 0)
            let stack = used + between * CGFloat(max(list.count - 1, 0))
            var y = max(0, (size.height - stack) / 2)
            for (node, height) in zip(list, heights) {
                bars[node.id] = Bar(node: node, rect: CGRect(x: x(c), y: y, width: barWidth, height: height), labelY: y + height / 2)
                barOrder.append(node.id)
                y += height + between
            }
            labelX[c] = x(c) + barWidth + 6
            labelWidth[c] = max(0, (index + 1 < order.count ? x(order[index + 1]) - 4 : size.width) - labelX[c]!)
            // Labels: in bar order, pushed down to keep `labelHeight` apart, then back up from the bottom edge.
            var centres = list.map { bars[$0.id]!.labelY }
            for i in centres.indices.dropFirst() { centres[i] = max(centres[i], centres[i - 1] + labelHeight) }
            if let lastCentre = centres.last, lastCentre > size.height - labelHeight / 2 {
                centres[centres.count - 1] = size.height - labelHeight / 2
                for i in centres.indices.reversed().dropFirst() { centres[i] = min(centres[i], centres[i + 1] - labelHeight) }
            }
            for (node, centre) in zip(list, centres) { bars[node.id]?.labelY = centre }
        }

        // Bands leave a source in the order of their targets and enter a target in the order of their sources.
        var outTop: [String: CGFloat] = [:]
        var inTop: [String: CGFloat] = [:]
        var bands: [Band] = []
        let ordered = links.filter { bars[$0.source] != nil && bars[$0.target] != nil && $0.value > 0 }
        let bySource = ordered.sorted { (bars[$0.source]!.rect.minY, bars[$0.target]!.rect.minY) < (bars[$1.source]!.rect.minY, bars[$1.target]!.rect.minY) }
        let byTarget = ordered.sorted { (bars[$0.target]!.rect.minY, bars[$0.source]!.rect.minY) < (bars[$1.target]!.rect.minY, bars[$1.source]!.rect.minY) }
        var sourceTops: [DSSankeyLink: CGFloat] = [:]
        for link in bySource {
            let top = outTop[link.source] ?? bars[link.source]!.rect.minY
            sourceTops[link] = top
            outTop[link.source] = top + CGFloat(link.value) * scale
        }
        for link in byTarget {
            let top = inTop[link.target] ?? bars[link.target]!.rect.minY
            inTop[link.target] = top + CGFloat(link.value) * scale
            let source = bars[link.source]!, target = bars[link.target]!
            bands.append(Band(link: link, sourceTop: sourceTops[link]!, targetTop: top, thickness: CGFloat(link.value) * scale,
                              sourceX: source.rect.maxX, targetX: target.rect.minX, tone: target.node.tone))
        }
        self.bars = barOrder.compactMap { bars[$0] }
        self.bands = bands
        self.labelX = labelX
        self.labelWidth = labelWidth
    }

    /// A band as a closed shape: a smooth S from source to target along the top, and back along the bottom.
    public static func path(_ band: Band) -> Path {
        var p = Path()
        let mid = (band.sourceX + band.targetX) / 2
        p.move(to: CGPoint(x: band.sourceX, y: band.sourceTop))
        p.addCurve(to: CGPoint(x: band.targetX, y: band.targetTop),
                   control1: CGPoint(x: mid, y: band.sourceTop), control2: CGPoint(x: mid, y: band.targetTop))
        p.addLine(to: CGPoint(x: band.targetX, y: band.targetTop + band.thickness))
        p.addCurve(to: CGPoint(x: band.sourceX, y: band.sourceTop + band.thickness),
                   control1: CGPoint(x: mid, y: band.targetTop + band.thickness), control2: CGPoint(x: mid, y: band.sourceTop + band.thickness))
        p.closeSubpath()
        return p
    }
}

/// Money flowing left to right: bars in tone colours, bands at a translucent wash of their target's tone, each bar
/// labelled with its name and amount. Drawn with `Canvas`; VoiceOver reads `accessibilitySummary`.
public struct DSSankeyChart: View {
    private let nodes: [DSSankeyNode]
    private let links: [DSSankeyLink]
    private let summary: String
    @ScaledMetric(relativeTo: .caption) private var labelHeight: CGFloat = 34
    @ScaledMetric(relativeTo: .caption) private var trailingLabelWidth: CGFloat = 112

    public init(nodes: [DSSankeyNode], links: [DSSankeyLink], accessibilitySummary: String) {
        self.nodes = nodes
        self.links = links
        self.summary = accessibilitySummary
    }

    /// Tall enough that the busiest column's labels each get their own line.
    private var height: CGFloat {
        let busiest = Dictionary(grouping: nodes, by: \.column).values.map(\.count).max() ?? 1
        return max(240, CGFloat(busiest) * labelHeight + DSSankeyLayout.gap)
    }

    private static func color(_ tone: DSTone?) -> Color { tone?.fill ?? Palette.steel.color }

    public var body: some View {
        GeometryReader { proxy in
            let layout = DSSankeyLayout(nodes: nodes, links: links, size: CGSize(width: proxy.size.width, height: height),
                                        labelHeight: labelHeight, trailingLabelWidth: min(trailingLabelWidth, proxy.size.width * 0.42))
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    // Translucent bands under the bars (opacity is fine on a non-text mark).
                    for band in layout.bands {
                        context.fill(DSSankeyLayout.path(band), with: .color(Self.color(band.tone).opacity(band.tone == nil ? 0.5 : 0.3)))
                    }
                    for bar in layout.bars {
                        context.fill(Path(roundedRect: bar.rect, cornerRadius: 2), with: .color(Self.color(bar.node.tone)))
                    }
                }
                ForEach(layout.bars, id: \.node.id) { bar in
                    let width = layout.labelWidth[bar.node.column] ?? 0
                    VStack(alignment: .leading, spacing: 0) {
                        Text(bar.node.label).dsFont(.label).foregroundStyle(Color.ds.ink)
                        Text(bar.node.valueText).dsFont(.caption).monospacedDigit().foregroundStyle(Color.ds.inkSecondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: width, alignment: .leading)
                    .position(x: (layout.labelX[bar.node.column] ?? 0) + width / 2, y: bar.labelY)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cash flow")
        .accessibilityValue(summary)
    }
}
