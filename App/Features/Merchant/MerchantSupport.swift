import BudgetKit
import DesignSystem
import SwiftUI

enum MerchantSupport {
    static let unavailable = "Merchant pages need a newer Budget server. Update your server, then try again."
}

extension AppModel {
    /// Merchant pages and lists, on clients that have them (the demo, and servers through the caching client).
    var merchants: (any MerchantAPI)? { api as? any MerchantAPI }

    /// Whether the server is older than `minimum` — so a 404 means "not yet" rather than "not there". The demo never is.
    func serverPredates(_ minimum: String) async -> Bool {
        guard let version = await knownServerVersion() else { return false }
        return !ServerStatus.version(version, isAtLeast: minimum)
    }
}

// MARK: - Most frequent

/// Spending's "Most frequent": the period's merchants with the most charges, each opening its page. Hidden when the
/// server doesn't have merchant lists yet, or the period has none.
struct TopMerchantsSection: View {
    /// A period the ledger names: "2026-09", "last_90_days", "year_to_date".
    let period: String
    @Environment(AppModel.self) private var app
    @State private var top: TopMerchants?

    var body: some View {
        Group {
            if let top, !top.merchants.isEmpty {
                VStack(alignment: .leading, spacing: DSSpace.sm) {
                    DSSectionHeader("Most frequent")
                    DSCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(top.merchants.enumerated()), id: \.element.id) { index, merchant in
                                if index > 0 { DSDivider() }
                                NavigationLink { MerchantDetailView(merchant: merchant.merchant) } label: { row(merchant) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, DSSpace.md)
                        .padding(.vertical, DSSpace.xxs)
                    }
                }
                .accessibilityIdentifier("mostFrequent")
            }
        }
        .task(id: "\(period)|\(app.revision)") {
            guard let merchants = app.merchants else { return }
            let next = try? await merchants.topMerchants(period: period, limit: 5, sort: .visits)
            if next != nil || top?.period != period { top = next }
        }
    }

    private func row(_ merchant: MerchantTotal) -> some View {
        let category = app.category(merchant.categoryID)
        let visits = "\(merchant.visits) visit\(merchant.visits == 1 ? "" : "s")"
        return DSListRow(merchant.merchant, detail: [visits, category?.name].compactMap { $0 }.joined(separator: " · "),
                         systemImage: category?.symbol ?? "storefront", tone: CategoryStyle.tone(for: category)) {
            HStack(spacing: DSSpace.xs) {
                DSAmountText(merchant.spent.decimal, currencyCode: merchant.spent.currencyCode, sign: .magnitude)
                Image(systemName: "chevron.right").font(.system(size: DSIconSize.xs, weight: .semibold))
                    .foregroundStyle(Color.ds.inkTertiary).accessibilityHidden(true)
            }
        }
        .accessibilityHint("Opens \(merchant.merchant)")
    }
}

// MARK: - From a search

/// Over Activity's results for a search that names a merchant: a way into that merchant's page.
struct MerchantSearchLink: View {
    let query: String
    let rows: [LedgerTransaction]
    @Environment(AppModel.self) private var app

    /// The merchant the search names: of the shown rows' merchants containing the text, the one with the most rows.
    private var merchant: String? {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2, app.merchants != nil else { return nil }
        let names = rows.map(\.merchant).filter { $0.localizedCaseInsensitiveContains(text) }
        return Dictionary(grouping: names, by: { $0 }).max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key
    }

    var body: some View {
        if let merchant {
            NavigationLink { MerchantDetailView(merchant: merchant) } label: {
                DSCard(padding: 0) {
                    DSListRow(merchant, detail: "How often, how much, and every month", systemImage: "storefront", tone: .cyan) {
                        DSListValue("Merchant", showsChevron: true)
                    }
                    .padding(.horizontal, DSSpace.md)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens \(merchant)'s page")
            .accessibilityIdentifier("merchantSearchLink")
        }
    }
}

// MARK: - What an order bought

/// On a charge matched to a store order: what it bought.
struct OrderItemsCard: View {
    let order: OrderMatch

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            DSEyebrow("\(order.store) order")
            DSCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(order.items.enumerated()), id: \.offset) { index, item in
                        if index > 0 { DSDivider() }
                        DSListRow(item)
                    }
                    DSDivider()
                    Text("Order \(order.orderID)\(order.orderedAt.map { ", placed \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? ""). From the order history you imported.")
                        .dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, DSSpace.sm)
                }
                .padding(.horizontal, DSSpace.md)
            }
        }
        .accessibilityIdentifier("orderItems")
    }
}
