import BudgetKit
import DesignSystem
import SwiftUI

/// The first week of a month: how last month went, with the full recap a tap away. Put away, it's gone until next month.
struct MonthlyRecapCard: View {
    let recap: MonthlyRecap
    let onOpen: () -> Void
    let onDismiss: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        DSCard(elevation: .raised, tone: .cyan) {
            VStack(alignment: .leading, spacing: DSSpace.md) {
                HStack(alignment: .center) {
                    DSEyebrow("\(MonthlyRecapSheet.monthName(recap)) recap", dot: Color.ds.accent)
                    Spacer(minLength: DSSpace.xs)
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: DSIconSize.xs, weight: .semibold))
                            .foregroundStyle(Color.ds.inkSecondary)
                            .frame(width: DSSize.hitTarget, height: DSSize.hitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, -DSSpace.sm)
                    .padding(.trailing, -DSSpace.sm)
                    .accessibilityLabel("Hide last month's recap")
                }
                Text(recap.summary)
                    .dsFont(.headline)
                    .foregroundStyle(Color.ds.ink)
                    .fixedSize(horizontal: false, vertical: true)
                let stats = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: DSSpace.md))
                                                                : AnyLayout(HStackLayout(alignment: .top, spacing: DSSpace.md))
                stats {
                    DSStatBlock(label: "Came in", value: recap.income.decimal, currencyCode: recap.income.currencyCode, tint: Color.ds.inflow)
                    DSStatBlock(label: "Went out", value: recap.spending.decimal, currencyCode: recap.spending.currencyCode)
                    DSStatBlock(label: recap.saved.isNegative ? "Short" : "Left over", value: recap.saved.magnitude.decimal,
                                currencyCode: recap.saved.currencyCode, tint: recap.saved.isNegative ? Color.ds.caution : Color.ds.ink)
                }
                Button("See the recap", action: onOpen)
                    .buttonStyle(.ds(.quiet))
                    .accessibilityIdentifier("openMonthlyRecap")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("monthlyRecap")
    }
}

/// Last month in full: what came in and went out, each bucket against its budget, the categories that moved most,
/// and what happened to cash (or net worth, once there's a history of it).
struct MonthlyRecapSheet: View {
    let recap: MonthlyRecap
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpace.xl) {
                    DSHeroAmount(label: recap.saved.isNegative ? "Spent past income in \(Self.monthName(recap))" : "Left over in \(Self.monthName(recap))",
                                 value: recap.saved.magnitude.decimal, currencyCode: recap.saved.currencyCode,
                                 caption: "\(recap.income.formatted(fractionDigits: 0)) came in · \(recap.spending.formatted(fractionDigits: 0)) went out")
                    Text(recap.summary)
                        .dsFont(.body)
                        .foregroundStyle(Color.ds.inkSoft)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    buckets
                    if !recap.categoryChanges.isEmpty { changes }
                    money
                    AskLink("How did \(Self.monthName(recap)) go?", question: "Give me a recap of \(Self.monthName(recap))")
                }
                .padding(.horizontal, DSSpace.gutter)
                .padding(.vertical, DSSpace.lg)
            }
            .dsScreenBackground(bloom: .data)
            .navigationTitle("\(Self.monthName(recap)) recap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationBackground(Color.ds.canvas)
    }

    /// Bills, subscriptions and everyday, each against what the budget planned for it that month.
    private var buckets: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            DSSectionHeader(recap.hasBudget ? "Against the budget" : "Where it went")
            DSCard {
                VStack(alignment: .leading, spacing: DSSpace.md) {
                    ForEach(recap.buckets, id: \.group) { bucket in
                        VStack(alignment: .leading, spacing: DSSpace.xs) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(bucket.group.label).dsFont(.bodyEmphasis).foregroundStyle(Color.ds.ink)
                                Spacer(minLength: DSSpace.xs)
                                DSAmountText(bucket.spent.decimal, currencyCode: bucket.spent.currencyCode, sign: .magnitude)
                            }
                            if let planned = bucket.planned, planned.minorUnits > 0 {
                                let fraction = bucket.spent.doubleValue / planned.doubleValue
                                DSProgressBar(fraction: fraction)
                                HStack(alignment: .firstTextBaseline, spacing: DSSpace.xs) {
                                    if let over = bucket.overBy, over.minorUnits > 0 { DSTag.over() }
                                    Text(Self.planLine(bucket, planned: planned))
                                        .dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if !recap.hasBudget {
                Text("There weren't three full months before it to budget from, so this shows what was spent.")
                    .dsFont(.caption).foregroundStyle(Color.ds.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "$180 under the $2,140 budget" / "$60 over the $410 budget".
    static func planLine(_ bucket: RecapBucket, planned: Money) -> String {
        let over = bucket.spent - planned
        if over.minorUnits == 0 { return "Right on the \(planned.formatted(fractionDigits: 0)) budget" }
        return "\(over.magnitude.formatted(fractionDigits: 0)) \(over.isNegative ? "under" : "over") the \(planned.formatted(fractionDigits: 0)) budget"
    }

    private var changes: some View {
        VStack(alignment: .leading, spacing: DSSpace.sm) {
            DSSectionHeader("Biggest changes")
            DSCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(recap.categoryChanges.enumerated()), id: \.element.id) { index, change in
                        let category = app.category(change.categoryID)
                        HStack(spacing: DSSpace.sm) {
                            DSGlyph(systemImage: category?.symbol ?? "circle", tone: CategoryStyle.tone(for: category))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(change.name).dsFont(.body).foregroundStyle(Color.ds.ink)
                                Text("\(change.previous.formatted(fractionDigits: 0)) the month before")
                                    .dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                            }
                            Spacer(minLength: DSSpace.xs)
                            VStack(alignment: .trailing, spacing: 3) {
                                DSAmountText(change.spent.decimal, currencyCode: change.spent.currencyCode, sign: .magnitude)
                                Label(change.change.magnitude.formatted(fractionDigits: 0),
                                      systemImage: change.change.isNegative ? "arrow.down" : "arrow.up")
                                    .dsFont(.caption).foregroundStyle(Color.ds.inkSecondary)
                            }
                        }
                        .padding(.horizontal, DSSpace.md)
                        .frame(minHeight: DSSize.listRow)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(change.name): \(change.spent.formatted()), \(change.change.isNegative ? "down" : "up") \(change.change.magnitude.formatted()) on the month before")
                        if index < recap.categoryChanges.count - 1 { DSDivider() }
                    }
                }
                .padding(.vertical, DSSpace.xxs)
            }
        }
    }

    /// Cash (or net worth) over the month, and what went to savings.
    private var money: some View {
        let (label, change) = recap.netWorthChange.map { ("Net worth", $0) } ?? ("Cash", recap.cashChange)
        return DSCard {
            HStack(alignment: .top, spacing: DSSpace.md) {
                DSStatBlock(label: "\(label) \(change.isNegative ? "fell" : "grew")", value: change.magnitude.decimal, currencyCode: change.currencyCode,
                            tint: change.isNegative ? Color.ds.ink : Color.ds.inflow)
                DSStatBlock(label: "Moved to savings", value: recap.movedToSavings.decimal, currencyCode: recap.movedToSavings.currencyCode)
            }
        }
    }

    /// "September", or "September 2025" when it isn't this year.
    static func monthName(_ recap: MonthlyRecap) -> String {
        MonthKey.date(recap.month).map { MonthKey.name($0) } ?? recap.month
    }
}
