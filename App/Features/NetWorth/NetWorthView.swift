import BudgetKit
import DesignSystem
import SwiftUI

/// Net worth over time, from Home's balances: today's figure and its change over the range, the chart (investments
/// before their first recorded balance dashed, as estimated), and what you own and owe — accounts and the assets and
/// debts you keep by hand, which open to edit.
struct NetWorthView: View {
    @Environment(AppModel.self) private var app
    @State private var range: NetWorthRange = .threeMonths
    @State private var state: LoadState<NetWorth> = .loading
    /// A server before 0.5.0 has no net worth history.
    @State private var unavailable = false
    @State private var editing: ManualAssetSheet.Target?
    @State private var toast: DSToastMessage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DSSpace.xl) {
                if unavailable {
                    DSStateView(systemImage: "chart.line.uptrend.xyaxis", title: "Not on your server yet",
                                message: "Net worth history needs a newer Budget server. Update it on your Olares, then come back.")
                } else {
                    switch state {
                    case .loading:
                        LoadingPlaceholder(text: "Adding up what you own and owe…")
                    case let .failed(message):
                        DSStateView(systemImage: "wifi.slash", title: "Can't load net worth", message: message, actionTitle: "Try again") {
                            Task { await load() }
                        }
                    case let .loaded(worth):
                        content(worth)
                    }
                }
            }
            .padding(.horizontal, DSSpace.gutter)
            .padding(.bottom, DSSpace.xxl)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .dsScreenBackground(bloom: .data)
        .navigationTitle("Net worth")
        .navigationBarTitleDisplayMode(.inline)
        .reloadable { await load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = .new } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add an asset or debt")
                    .disabled(unavailable || state.value == nil)
            }
        }
        .task(id: "\(app.revision)-\(range.rawValue)") { await load() }
        .sheet(item: $editing) { target in ManualAssetSheet(target: target, toast: $toast) }
        .dsToast($toast)
    }

    @discardableResult
    private func load() async -> String? {
        guard let api = app.api as? any NetWorthAPI else {
            unavailable = true
            return nil
        }
        let first = state.isLoading
        state = await state.orSaved(.netWorth(range: range.rawValue), app)
        let updating = app.beginUpdating(showingSaved: first && state.value != nil)
        defer { app.endUpdating(updating) }
        let wanted = range
        do {
            let worth = try await api.netWorth(range: wanted)
            unavailable = false
            // An answer for a range no longer on screen is dropped.
            if wanted == range { state = .loaded(worth) }
            return nil
        } catch BudgetAPIError.notFound {
            unavailable = true
            return nil
        } catch {
            if Task.isCancelled { return nil }
            if state.value == nil { state = .failed(error.localizedDescription) }
            return error.localizedDescription
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ worth: NetWorth) -> some View {
        hero(worth)
        DSSegmented("Range", selection: $range, options: NetWorthRange.allCases) { $0.label }
        chart(worth)
        breakdown(title: "What you own", total: worth.assets, lines: worth.assetLines, since: worth.start)
        breakdown(title: "What you owe", total: worth.liabilities, lines: worth.liabilityLines, since: worth.start)
        Button { editing = .new } label: {
            Label("Add an asset or debt", systemImage: "plus")
        }
        .buttonStyle(.ds(.secondary, fullWidth: true))
        .accessibilityHint("A home, a car or a loan that no bank reports")
        Text("Cash and cards are traced back through their transactions. Investments hold the balance recorded at each sync. Assets and debts you add count from the day you add them.")
            .dsFont(.caption)
            .foregroundStyle(Color.ds.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func hero(_ worth: NetWorth) -> some View {
        let percent = worth.changePercent.map { " (\($0 >= 0 ? "+" : "−")\(abs($0).formatted(.number.precision(.fractionLength(1))))%)" } ?? ""
        return DSHeroAmount(label: "Net worth", value: worth.netWorth.decimal, currencyCode: worth.netWorth.currencyCode,
                            caption: "\(worth.change.signedWhole)\(percent) since \(Self.day(worth.start))",
                            captionTint: worth.change.isNegative ? Color.ds.inkSecondary : Color.ds.inflow)
            .padding(.top, DSSpace.sm)
    }

    private func chart(_ worth: NetWorth) -> some View {
        // Points that hold an investment at a stand-in value are drawn dashed, and meet the solid line where records begin.
        let estimated = worth.points.filter { $0.isEstimated == true }
        let measured = worth.points.filter { $0.isEstimated != true }
        let dashed = estimated.isEmpty ? [] : (estimated + measured.prefix(1)).map(\.chartPoint)
        return DSCard {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                DSLineChart(actual: measured.map(\.chartPoint), projected: dashed, style: .full, currencyCode: worth.netWorth.currencyCode,
                            accessibilitySummary: "Net worth since \(Self.day(worth.start)), from \(worth.points.first?.netWorth.formatted(fractionDigits: 0) ?? "") to \(worth.netWorth.formatted(fractionDigits: 0))")
                    .frame(height: 180)
                if worth.estimatedThrough != nil {
                    HStack(alignment: .firstTextBaseline, spacing: DSSpace.xs) {
                        DSTag("Estimated", tint: Color.ds.iris)
                        Text(worth.note ?? "Part of this range is estimated.")
                            .dsFont(.caption)
                            .foregroundStyle(Color.ds.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func breakdown(title: String, total: Money, lines: [NetWorthLine], since: Date) -> some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            HStack(alignment: .firstTextBaseline) {
                DSSectionHeader(title)
                Spacer()
                DSAmountText(total.decimal, currencyCode: total.currencyCode)
            }
            if lines.isEmpty {
                DSCard {
                    Text(title == "What you owe" ? "Nothing owed: no card balances or debts." : "Nothing yet.")
                        .dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                }
            } else {
                DSCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            row(line, since: since)
                            if index < lines.count - 1 { DSDivider() }
                        }
                    }
                    .padding(.horizontal, DSSpace.md)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ line: NetWorthLine, since: Date) -> some View {
        let change = line.change.flatMap { $0 == .zero ? nil : "\($0.signedWhole) since \(Self.day(since))" }
        let detail = [line.detail, line.isManual == true ? "Added by you" : nil, line.isEstimated == true ? "Partly estimated" : nil, change]
            .compactMap { $0 }.joined(separator: " · ")
        let label = DSListRow(line.name, detail: detail.isEmpty ? nil : detail, systemImage: Self.symbol(line), tone: Self.tone(line.group)) {
            HStack(spacing: DSSpace.xs) {
                DSAmountText(line.value.decimal, currencyCode: line.value.currencyCode)
                if line.isManual == true {
                    Image(systemName: "chevron.right")
                        .font(.system(size: DSIconSize.xs, weight: .semibold))
                        .foregroundStyle(Color.ds.inkTertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        if line.isManual == true, let item = state.value?.manualAssets.first(where: { $0.id == line.id }) {
            Button { editing = .edit(item) } label: { label }
                .buttonStyle(.plain)
                .accessibilityHint("Edit \(line.name)")
        } else {
            label
        }
    }

    // MARK: Style

    static func day(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }

    static func tone(_ group: NetWorthGroup) -> DSTone {
        switch group {
        case .cash: .azure
        case .investments: .teal
        case .realEstate: .amber
        case .vehicles: .coral
        case .otherAssets: .lime
        case .cards: .rose
        case .loans: .violet
        case .otherDebts: .irisDeep
        }
    }

    static func symbol(_ line: NetWorthLine) -> String {
        switch line.group {
        case .cash: "building.columns"
        case .investments: "chart.line.uptrend.xyaxis"
        case .realEstate: ManualAssetCategory.realEstate.symbol
        case .vehicles: ManualAssetCategory.vehicle.symbol
        case .otherAssets: ManualAssetCategory.other.symbol
        case .cards: "creditcard"
        case .loans: ManualAssetCategory.loan.symbol
        case .otherDebts: "doc.text"
        }
    }
}

extension NetWorthPoint {
    var chartPoint: DSChartPoint { DSChartPoint(date: date, value: netWorth.doubleValue) }
}
