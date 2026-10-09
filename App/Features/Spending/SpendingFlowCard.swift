import BudgetKit
import DesignSystem
import SwiftUI

/// What the top of a Spending month shows: the largest categories as tiles, or the month as a flow.
enum SpendingBreakdown: String, CaseIterable, Hashable {
    case categories, flow

    var title: String {
        switch self {
        case .categories: "Top categories"
        case .flow: "Flow"
        }
    }
}

/// Spending's Flow view: one month's money left to right — where it came from, what Bills, Subscriptions and
/// Everyday took and what was left, then each bucket's top categories (`GET /v1/flow`, the ledger's figures).
struct SpendingFlowCard: View {
    /// "2026-09".
    let month: String
    let isCurrent: Bool
    @Environment(AppModel.self) private var app
    @State private var state: LoadState<CashFlowSankey> = .loading
    @State private var unavailable = false

    var body: some View {
        DSCard(padding: DSSpace.md) {
            VStack(alignment: .leading, spacing: DSSpace.md) {
                DSEyebrow(isCurrent ? "Where it went · so far" : "Where it went", dot: Color.ds.accent)
                content
            }
        }
        .task(id: "\(month)|\(app.revision)") { await load() }
        .accessibilityIdentifier("spendingFlow")
    }

    @ViewBuilder
    private var content: some View {
        if unavailable {
            Text("The flow view needs a newer Budget server. Update the server on your Olares to see it.")
                .dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            switch state {
            case .loading:
                LoadingPlaceholder()
            case let .failed(message):
                DSStateView(systemImage: "wifi.slash", title: "Can't load the flow", message: message, actionTitle: "Try again") {
                    Task { await load() }
                }
            case let .loaded(flow):
                if flow.nodes.isEmpty {
                    Text("Nothing came in or went out this month yet.")
                        .dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                } else {
                    flowBody(flow)
                        .dsLoading(flow.month != month)
                }
            }
        }
    }

    @ViewBuilder
    private func flowBody(_ flow: CashFlowSankey) -> some View {
        DSSankeyChart(nodes: flow.nodes.map(Self.node), links: flow.links.map(Self.link), accessibilitySummary: Self.summary(flow))
        DSDivider()
        DSFigureRow(label: "Came in", value: flow.income.decimal)
        DSFigureRow(label: "Went out", detail: "Yearly charges count a twelfth", value: (-flow.spending).decimal)
        if flow.drawnFromCash.minorUnits > 0 {
            DSFigureRow(label: "From cash", detail: "Spending past income", value: (-flow.drawnFromCash).decimal)
        } else {
            DSFigureRow(label: "Saved", detail: "Income left after spending", value: flow.saved.decimal)
        }
    }

    private func load() async {
        guard let api = app.api as? any CashFlowSankeyAPI else { unavailable = true; return }
        let key = month
        state = await state.orSaved(.cashFlowSankey(month: isCurrent ? nil : key), app)
        do {
            let flow = try await api.cashFlowSankey(month: isCurrent ? nil : key)
            unavailable = false
            state = .loaded(flow)
        } catch BudgetAPIError.notFound {
            // A server before 0.5.0 has no /v1/flow.
            unavailable = true
        } catch {
            // Keep a figure only when it's this month's (a saved copy); another month's under this header would mislead.
            if !Task.isCancelled, state.value?.month != key { state = .failed(error.localizedDescription) }
        }
    }

    static func node(_ node: CashFlowSankey.Node) -> DSSankeyNode {
        DSSankeyNode(id: node.id, label: node.label, valueText: node.value.formatted(fractionDigits: 0), value: node.value.doubleValue,
                     column: node.column, tone: DSTone(token: node.color))
    }

    static func link(_ link: CashFlowSankey.Link) -> DSSankeyLink {
        DSSankeyLink(source: link.source, target: link.target, value: link.value.doubleValue)
    }

    /// What VoiceOver reads for the chart: every node, column by column.
    static func summary(_ flow: CashFlowSankey) -> String {
        let columns = (0...2).map { c in flow.nodes.filter { $0.column == c }.map { "\($0.label) \($0.value.formatted(fractionDigits: 0))" } }
        return ["In: " + columns[0].joined(separator: ", "), "Out: " + columns[1].joined(separator: ", "), "By category: " + columns[2].joined(separator: ", ")]
            .joined(separator: ". ")
    }
}
