import BudgetKit
import DesignSystem
import SwiftUI

/// Investments by holding (server 0.6.0), under what you own: one card per investment account with its positions as the
/// broker last reported them, the largest five first, and what the balance holds beyond them. The gain since cost is in
/// neutral ink, like the net worth change lines: no red or green verdict on investments.
struct HoldingsSection: View {
    let report: HoldingsReport
    /// The net worth line for each account, by id, for its name and institution.
    let lines: [String: NetWorthLine]
    @State private var expanded: Set<String> = []
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Positions shown before "Show all".
    static let shown = 5

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            DSSectionHeader("Investments by holding")
            ForEach(report.accounts) { account in
                card(account)
                    .id(Self.anchor(account.id))
            }
        }
        .accessibilityIdentifier("holdingsSection")
    }

    /// Where a tap on the account's net worth line scrolls to.
    static func anchor(_ accountID: String) -> String { "holdings-\(accountID)" }

    private func card(_ account: AccountHoldings) -> some View {
        let all = account.holdings
        let open = expanded.contains(account.id)
        let visible = open ? all : Array(all.prefix(Self.shown))
        return DSCard(padding: 0) {
            VStack(spacing: 0) {
                header(account)
                ForEach(visible) { holding in
                    DSDivider()
                    row(holding)
                }
                if all.isEmpty {
                    DSDivider()
                    Text("The broker listed no positions.")
                        .dsFont(.callout)
                        .foregroundStyle(Color.ds.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, DSSpace.sm)
                }
                if all.count > Self.shown {
                    DSDivider()
                    Button(open ? "Show fewer" : "Show all \(all.count)") {
                        withAnimation(.snappy) {
                            if open { expanded.remove(account.id) } else { expanded.insert(account.id) }
                        }
                    }
                    .buttonStyle(.ds(.quiet))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, DSSpace.xs)
                    .accessibilityIdentifier("holdingsShowAll-\(account.id)")
                }
                if let unitemized = account.unitemized {
                    DSDivider()
                    DSListRow("Not itemized by the broker", detail: "Cash or positions it didn't list") {
                        DSAmountText(unitemized.decimal, currencyCode: unitemized.currencyCode)
                    }
                    .accessibilityLabel("Not itemized by the broker, \(unitemized.formatted())")
                }
            }
            .padding(.horizontal, DSSpace.md)
        }
    }

    private func header(_ account: AccountHoldings) -> some View {
        let line = lines[account.id]
        let name = line?.name ?? "Investment account"
        let asOf = "as of \(NetWorthView.day(account.fetchedAt))"
        let detail = [line?.detail, asOf].compactMap { $0 }.joined(separator: " · ")
        return HStack(alignment: .firstTextBaseline, spacing: DSSpace.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .dsFont(.headline)
                    .foregroundStyle(Color.ds.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .dsFont(.caption)
                    .foregroundStyle(Color.ds.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DSSpace.md)
            DSAmountText(account.total.decimal, currencyCode: account.total.currencyCode)
        }
        .padding(.vertical, DSSpace.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): positions worth \(account.total.formatted()), \(asOf)")
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ holding: Holding) -> some View {
        DSListRow(holding.name, detail: Self.detail(holding)) {
            VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                DSAmountText(holding.value.decimal, currencyCode: holding.value.currencyCode)
                if let gain = holding.gain, gain != .zero {
                    Text(gain.signedWhole)
                        .dsFont(.caption)
                        .foregroundStyle(Color.ds.inkSecondary)
                }
            }
        }
        .accessibilityLabel(Self.spoken(holding))
    }

    // MARK: Words

    /// "VTI · 12.5 sh · cost $1,000"; cash reads "Cash".
    static func detail(_ holding: Holding) -> String? {
        if holding.isCash { return "Cash" }
        let parts = [holding.ticker, holding.quantity.map { "\(shares($0)) sh" }, holding.costBasis.map { "cost \($0.formatted(fractionDigits: 0))" }]
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }

    /// "Vanguard Total Stock Market ETF, 12.5 shares, worth $3,100, up $400 from cost".
    static func spoken(_ holding: Holding) -> String {
        var parts = [holding.isCash ? "\(holding.name), cash" : holding.name]
        if !holding.isCash, let quantity = holding.quantity { parts.append("\(shares(quantity)) \(quantity == 1 ? "share" : "shares")") }
        parts.append("worth \(holding.value.formatted(fractionDigits: 0))")
        if let gain = holding.gain, gain != .zero {
            parts.append("\(gain.isNegative ? "down" : "up") \(gain.magnitude.formatted(fractionDigits: 0)) from cost")
        }
        return parts.joined(separator: ", ")
    }

    static func shares(_ quantity: Decimal) -> String { quantity.formatted(.number.precision(.fractionLength(0...4))) }
}
