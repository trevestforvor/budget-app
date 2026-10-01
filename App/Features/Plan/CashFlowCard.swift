import BudgetKit
import DesignSystem
import SwiftUI

/// Money in against money out, month by month: the past behind the projection. Its three-month average net is
/// "Can save" exactly; the footnote squares that with how much cash actually grew.
struct CashFlowCard: View {
    let plan: SavingsPlan
    let history: [MonthFlow]
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var complete: [MonthFlow] { history.filter { !$0.isPartial } }

    var body: some View {
        let points = history.compactMap { flow in
            MonthKey.date(flow.month).map {
                DSCashFlowPoint(month: $0, income: flow.income.doubleValue, spending: flow.spending.magnitude.doubleValue,
                                net: flow.net.doubleValue, isPartial: flow.isPartial)
            }
        }
        let income = complete.map(\.income).sum()
        let spending = complete.map(\.spending).sum()
        let net = complete.map(\.net).sum()
        DSCard {
            VStack(alignment: .leading, spacing: DSSpace.md) {
                HStack(alignment: .center) {
                    DSEyebrow("Cash flow · last \(complete.count) months", dot: Color.ds.inflow)
                    Spacer(minLength: DSSpace.xs)
                    DSAskButton(label: "cash flow") { app.ask("How has my cash flow changed over the last six months?") }
                }
                .padding(.top, -DSSpace.sm)
                DSCashFlowChart(points: points, accessibilitySummary: summary(income: income, spending: spending, net: net))
                    .frame(height: 200)
                // Two by two; one column at accessibility sizes.
                LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())]
                                                                       : [GridItem(.flexible(), spacing: DSSpace.md), GridItem(.flexible())],
                          alignment: .leading, spacing: DSSpace.md) {
                    DSStatBlock(label: "Income", value: income.decimal, footnote: span)
                    DSStatBlock(label: "Spending", value: spending.magnitude.decimal, footnote: span)
                    DSStatBlock(label: "Net", value: net.decimal, footnote: span,
                                tint: net.isNegative ? Color.ds.caution : Color.ds.ink)
                    DSStatBlock(label: "Average net", value: plan.canSaveTypical.decimal,
                                footnote: "a month over the last 3 — your Can save", tint: Color.ds.inflow)
                }
                if let reconciliation {
                    Text(reconciliation)
                        .dsFont(.caption)
                        .foregroundStyle(Color.ds.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// "Mar – Aug".
    private var span: String {
        guard let first = complete.first.flatMap({ MonthKey.date($0.month) }),
              let last = complete.last.flatMap({ MonthKey.date($0.month) }) else { return "" }
        return "\(first.formatted(.dateTime.month(.abbreviated))) – \(last.formatted(.dateTime.month(.abbreviated)))"
    }

    /// Income less spending isn't the same as cash growth: some of it goes to investments or card balances.
    private var reconciliation: String? {
        guard let cash = plan.averageCashChange else { return nil }
        let gap = plan.canSaveTypical - cash
        let moved = cash.isNegative ? "fell \(cash.magnitude.formatted(fractionDigits: 0))" : "grew \(cash.formatted(fractionDigits: 0))"
        if gap.magnitude.minorUnits < 5_000 {
            return "Your cash \(moved) a month over the same three months — about what income less spending says."
        }
        if gap.isNegative {
            return "Your cash \(moved) a month over the same three months — \(gap.magnitude.formatted(fractionDigits: 0)) more than income less spending, from money moved in or card balances not yet paid."
        }
        return "Your cash \(moved) a month over the same three months; the other \(gap.formatted(fractionDigits: 0)) went to investments or paying down cards."
    }

    private func summary(income: Money, spending: Money, net: Money) -> String {
        "Over the last \(complete.count) months, \(income.formatted(fractionDigits: 0)) came in and \(spending.magnitude.formatted(fractionDigits: 0)) went out, \(net.isNegative ? "a shortfall" : "a net") of \(net.magnitude.formatted(fractionDigits: 0))"
    }
}
