import CoreGraphics
import Foundation
import Testing
@testable import DesignSystem

@Suite("Sankey layout")
struct SankeyLayoutTests {
    static func node(_ id: String, _ value: Double, _ column: Int) -> DSSankeyNode {
        DSSankeyNode(id: id, label: id, valueText: "$\(Int(value))", value: value, column: column, tone: .azure)
    }

    static let nodes = [
        node("pay", 7000, 0), node("cash", 500, 0),
        node("bills", 3000, 1), node("everyday", 4000, 1), node("saved", 500, 1),
        node("rent", 2400, 2), node("power", 600, 2), node("food", 2500, 2), node("fun", 1000, 2), node("other", 500, 2),
    ]
    static let links = [
        DSSankeyLink(source: "pay", target: "bills", value: 3000), DSSankeyLink(source: "pay", target: "everyday", value: 4000),
        DSSankeyLink(source: "cash", target: "saved", value: 500),
        DSSankeyLink(source: "bills", target: "rent", value: 2400), DSSankeyLink(source: "bills", target: "power", value: 600),
        DSSankeyLink(source: "everyday", target: "food", value: 2500), DSSankeyLink(source: "everyday", target: "fun", value: 1000),
        DSSankeyLink(source: "everyday", target: "other", value: 500),
    ]

    @Test("Bars share one scale, stay inside the frame, and bands fill each bar exactly at both ends")
    func bands() throws {
        let layout = DSSankeyLayout(nodes: Self.nodes, links: Self.links, size: CGSize(width: 340, height: 300), labelHeight: 34, trailingLabelWidth: 110)
        let bars = Dictionary(uniqueKeysWithValues: layout.bars.map { ($0.node.id, $0) })
        for bar in layout.bars {
            #expect(bar.rect.minY >= -0.001 && bar.rect.maxY <= 300.001, "\(bar.node.id)")
            #expect(bar.rect.maxX <= 340 - 110 + 0.001)
        }
        // pay is 7000 of the same scale on which bills is 3000.
        let scale = try #require(bars["pay"]).rect.height / 7000
        #expect(abs(try #require(bars["bills"]).rect.height - 3000 * scale) < 0.001)
        for id in ["bills", "everyday"] {
            let bar = try #require(bars[id])
            let incoming = layout.bands.filter { $0.link.target == id }
            let outgoing = layout.bands.filter { $0.link.source == id }
            #expect(abs(incoming.map(\.thickness).reduce(0, +) - bar.rect.height) < 0.001)
            #expect(abs(outgoing.map(\.thickness).reduce(0, +) - bar.rect.height) < 0.001)
            #expect(abs((outgoing.map(\.sourceTop).min() ?? 0) - bar.rect.minY) < 0.001)
        }
        // Bands don't cross where they leave a bar: in target order, each starts where the last ended.
        let fromEveryday = layout.bands.filter { $0.link.source == "everyday" }.sorted { $0.sourceTop < $1.sourceTop }
        #expect(fromEveryday.map(\.link.target) == ["food", "fun", "other"])
    }

    @Test("Labels in a column are kept a label apart and inside the frame, even for slivers")
    func labels() {
        var nodes = Self.nodes
        nodes += (0..<4).map { Self.node("tiny\($0)", 1, 2) }
        let layout = DSSankeyLayout(nodes: nodes, links: Self.links, size: CGSize(width: 340, height: 330), labelHeight: 34, trailingLabelWidth: 110)
        let column = layout.bars.filter { $0.node.column == 2 }.map(\.labelY)
        for (a, b) in zip(column, column.dropFirst()) { #expect(b - a >= 34 - 0.001) }
        #expect((column.last ?? 0) <= 330 - 17 + 0.001)
        #expect(layout.labelWidth[0]! > 40 && layout.labelX[2]! + layout.labelWidth[2]! <= 340.001)
    }
}
