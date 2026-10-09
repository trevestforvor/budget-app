import BudgetKit
import DesignSystem
import SwiftUI

// Home's cards, top to bottom. Each is built from design-system parts; figures come from the Overview.

/// Once a week: what the checkup found, with a way in. Put away, it returns next week.
struct WeeklyRecapCard: View {
    let checkup: Checkup
    let days: [DaySpend]
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        DSCard(elevation: .raised) {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                HStack(alignment: .center) {
                    DSEyebrow(title, dot: Color.ds.iris)
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
                    .accessibilityLabel("Hide this week's recap")
                }
                Text(checkup.headline)
                    .dsFont(.headline)
                    .foregroundStyle(Color.ds.ink)
                    .fixedSize(horizontal: false, vertical: true)
                // What needs you most, in the checkup's own words.
                VStack(alignment: .leading, spacing: DSSpace.xs) {
                    ForEach(needsYou) { finding in
                        HStack(alignment: .firstTextBaseline, spacing: DSSpace.xs) {
                            CheckupStatusMark(status: finding.status)
                            Text(finding.title)
                                .dsFont(.callout)
                                .foregroundStyle(Color.ds.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(CheckupView.spoken(finding.status)): \(finding.title)")
                    }
                }
                Button("Open the checkup", action: onOpen)
                    .buttonStyle(.ds(.quiet))
                    .accessibilityIdentifier("openCheckup")
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Up to three findings to act on or watch, most urgent first.
    private var needsYou: [Checkup.Finding] {
        Array(checkup.sections.flatMap(\.findings).filter { $0.status != .good }.sorted { $0.status > $1.status }.prefix(3))
    }

    /// "Your week · Sep 20 – 26".
    private var title: String {
        guard let first = days.first?.date, let last = days.last?.date else { return "Your week" }
        let sameMonth = Calendar.current.isDate(first, equalTo: last, toGranularity: .month)
        let end = last.formatted(sameMonth ? .dateTime.day() : .dateTime.month(.abbreviated).day())
        return "Your week · \(first.formatted(.dateTime.month(.abbreviated).day())) – \(end)"
    }
}

/// This month's flex budget: safe to spend after savings come off the top (docs/BUDGETING.md).
struct MonthCard: View {
    let overview: Overview
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let flex = overview.flex
        let fraction = flex.flexNumber.minorUnits > 0 ? flex.flexSpent.doubleValue / flex.flexNumber.doubleValue : 0
        DSCard {
            VStack(alignment: .leading, spacing: DSSpace.md) {
                HStack(alignment: .center) {
                    DSEyebrow("\(MonthKey.name(overview.asOf)) · \(FlexBudget.daysLeftPhrase(flex.daysLeftIncludingToday))")
                    Spacer(minLength: DSSpace.xs)
                    DSAskButton(label: "this month") { app.ask("Am I on track with safe to spend this month?") }
                }
                .padding(.top, -DSSpace.sm)
                // Side by side, or stacked when a large text size won't fit two.
                let stats = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: DSSpace.md))
                                                                : AnyLayout(HStackLayout(alignment: .top, spacing: DSSpace.md))
                stats {
                    DSStatBlock(label: "Safe to spend", value: flex.safeToSpend.decimal,
                                footnote: "of \(flex.flexNumber.formatted(fractionDigits: 0)) everyday",
                                tint: flex.safeToSpend.isNegative ? Color.ds.caution : Color.ds.inflow)
                    DSStatBlock(label: "Saved first", value: flex.plannedSavings.decimal,
                                footnote: flex.plannedSavingsIsSet ? "your plan" : "from your transfers")
                }
                if flex.flexNumber.minorUnits > 0 {
                    DSProgressBar(fraction: fraction)
                }
                pace(flex, isOver: DSProgressBar.isOver(fraction))
                Button("How it's figured") { app.route(Navigate(screen: .spending, range: .thisMonth)) }
                    .buttonStyle(.ds(.quiet))
                    .accessibilityHint("Opens Spending")
            }
        }
    }

    @ViewBuilder
    private func pace(_ flex: FlexBudget, isOver: Bool) -> some View {
        if flex.safeToSpend.isNegative {
            HStack(alignment: .firstTextBaseline, spacing: DSSpace.xs) {
                DSTag.over()
                Text("Everyday spending is \(flex.safeToSpend.magnitude.formatted(fractionDigits: 0)) past this month's budget.")
                    .dsFont(.callout).foregroundStyle(Color.ds.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let line = Self.perDayLine(flex) {
            Text(line)
                .dsFont(.callout).foregroundStyle(Color.ds.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "About $544 a day for the 5 days left" — the days the eyebrow counts (today included), on Home and Spending.
    static func perDayLine(_ flex: FlexBudget) -> String? {
        guard let perDay = flex.perDayLeft, perDay.minorUnits > 0 else { return nil }
        let days = flex.daysLeftIncludingToday
        return days <= 1 ? "\(perDay.formatted(fractionDigits: 0)) left for today"
                         : "About \(perDay.formatted(fractionDigits: 0)) a day for the \(days) days left"
    }
}

/// Everyday spending day by day — the same rows as safe to spend. The figure nets refunds across the week, as safe
/// to spend does; each bar is its own day.
struct LastSevenDaysCard: View {
    let days: [DaySpend]
    /// The week as one window (`Overview.lastSevenDaysSpent`); older servers don't send it, so the days are summed.
    let spent: Money?
    let asOf: Date
    @Environment(AppModel.self) private var app

    var body: some View {
        let total = spent ?? days.map(\.flexibleSpent).sum()
        DSCard {
            VStack(alignment: .leading, spacing: DSSpace.md) {
                HStack(alignment: .center) {
                    Button { app.selectedTab = .activity } label: {
                        HStack(spacing: 6) {
                            DSEyebrow("Everyday · last 7 days")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.ds.inkSecondary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: DSSize.hitTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens Activity")
                    Spacer(minLength: DSSpace.xs)
                    DSAskButton(label: "the last 7 days") { app.ask("Where did my everyday spending go in the last 7 days?") }
                }
                .padding(.top, -DSSpace.sm)
                Text(total.magnitude.formatted(fractionDigits: 0))
                    .dsFont(.amount)
                    .foregroundStyle(Color.ds.ink)
                    .accessibilityLabel("Spent in the last 7 days")
                    .accessibilityValue(total.magnitude.formatted(fractionDigits: 0))
                DSWeekStrip(days: days.map { DSDaySpend(date: $0.date, amount: $0.flexibleSpent.decimal) },
                            currencyCode: total.currencyCode, today: asOf) { app.showActivity(on: $0) }
            }
        }
    }
}

/// What's waiting for review, counted as Activity counts it: decisions, each of which may file several rows.
struct ReviewCallout: View {
    let decisions: Int
    let transactions: Int
    @Environment(AppModel.self) private var app

    var body: some View {
        DSCard(elevation: .raised) {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                DSEyebrow("Needs you", dot: Color.ds.orchid)
                Text(ReviewWaiting.headline(decisions: decisions, transactions: transactions))
                    .dsFont(.headline)
                    .foregroundStyle(Color.ds.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your answers become merchant memory, so fewer come back next month.")
                    .dsFont(.callout)
                    .foregroundStyle(Color.ds.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The same way in as Settings → Review: the one-at-a-time review, on Activity.
                Button("Review") {
                    app.selectedTab = .activity
                    app.opensFirstReview = true
                }
                    .buttonStyle(.ds(.primary))
                    .padding(.top, DSSpace.xxs)
            }
        }
    }
}

/// One tap runs everything: pace, categories, merchants, recurring, unusual, saving, outlook, data.
struct CheckupEntryCard: View {
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            DSCard {
                HStack(spacing: DSSpace.md) {
                    DSGlyph(systemImage: "stethoscope", tone: .iris, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Run a checkup").dsFont(.headline).foregroundStyle(Color.ds.ink)
                        Text("Everything at once: pace, targets, recurring charges, saving, and what needs you.")
                            .dsFont(.callout).foregroundStyle(Color.ds.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(Color.ds.inkTertiary).accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("runCheckup")
    }
}

/// An insight, with a way to ask about it when the ledger wrote a question for it.
struct InsightTile: View {
    let insight: Insight
    @Environment(AppModel.self) private var app

    var body: some View {
        DSInsightCard(eyebrow: insight.eyebrow, title: insight.title, message: insight.body,
                      tone: CategoryStyle.tone(for: insight.kind), provenance: insight.computedBy)
            .overlay(alignment: .topTrailing) {
                if let prompt = insight.askPrompt {
                    DSAskButton(label: insight.title) { app.ask(prompt) }
                        .padding(DSSpace.xxs)
                }
            }
    }
}

/// Every balance by kind, as of the last sync or import. No history: investments are balance-only.
struct BalancesCard: View {
    let balances: Balances
    let onOpenAccounts: () -> Void

    var body: some View {
        DSCard {
            VStack(alignment: .leading, spacing: DSSpace.sm) {
                HStack(alignment: .center) {
                    DSEyebrow("Balances")
                    Spacer()
                    Button("Accounts", action: onOpenAccounts)
                        .buttonStyle(.ds(.quiet))
                }
                .padding(.top, -DSSpace.sm)
                VStack(spacing: 0) {
                    DSFigureRow(label: "Cash", detail: "Checking and savings", value: balances.cash.decimal, currencyCode: balances.cash.currencyCode)
                    DSFigureRow(label: "Cards owed", value: (-balances.cardsOwed).decimal, currencyCode: balances.cardsOwed.currencyCode)
                    DSFigureRow(label: "Cash after cards", value: balances.cashAfterCards.decimal, currencyCode: balances.cashAfterCards.currencyCode)
                    DSFigureRow(label: "Investments", detail: "Balance only", value: balances.investments.decimal, currencyCode: balances.investments.currencyCode)
                    DSDivider().padding(.vertical, DSSpace.xs)
                    DSFigureRow(label: "Net worth", value: balances.netWorth.decimal, currencyCode: balances.netWorth.currencyCode)
                }
                Text("As of each account's last sync or statement. Investments show today's balance, not their history.")
                    .dsFont(.caption)
                    .foregroundStyle(Color.ds.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
