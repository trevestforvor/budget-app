import BudgetKit
import DesignSystem
import SwiftUI

/// Maps ledger concepts onto design-system vocabulary. Kept in the app so
/// DesignSystem stays free of money models and BudgetKit stays free of SwiftUI.
enum CategoryStyle {
    /// The tone a category wears: the colour the person picked, else the standard one for its id. Both come from
    /// BudgetKit's `CategoryColor` (whose names are `DSTone` cases), so the app, the dashboard and the ledger
    /// agree on one map. A category the app hasn't loaded yet is amber, like any category without a colour.
    static func tone(for category: BudgetCategory?) -> DSTone {
        guard let category else { return .amber }
        return DSTone(token: category.effectiveColor.rawValue) ?? .amber
    }

    static func tone(for kind: InsightKind) -> DSTone {
        switch kind {
        case .trend, .anomaly: .orchid
        case .subscription: .iris
        case .budget: .azure
        case .plan, .savings: .cyan
        }
    }
}

/// How the app says what's waiting for review — counted in decisions, as the Activity badge counts them, since one
/// answer files every row in a group.
enum ReviewWaiting {
    /// "3 transactions need a quick look." or "8 quick answers file 11 transactions." (`ReviewGroup.headline`, which the
    /// checkup and the dashboard use too).
    static func headline(decisions: Int, transactions: Int) -> String {
        ReviewGroup.headline(decisions: decisions, transactions: transactions)
    }
}

extension BalancePoint {
    var chartPoint: DSChartPoint { DSChartPoint(date: date, value: balance.doubleValue) }
}

extension Money {
    /// "+$1,204" / "−$310" for change captions. The sign never ends a line on its own (`keepingSign`).
    var signedWhole: String {
        Self.keepingSign((isNegative ? "" : "+") + formatted(fractionDigits: 0))
    }

    /// "+$100.00" / "−$25.50".
    var signedString: String {
        Self.keepingSign((isNegative ? "" : "+") + formatted())
    }

    /// A word joiner (U+2060) after a leading sign: text may wrap before "−$1,350" but never between "−" and "$1,350".
    static func keepingSign(_ text: String) -> String {
        guard let first = text.first, "+-−–".contains(first) else { return text }
        return String(first) + "\u{2060}" + text.dropFirst()
    }
}

extension Date {
    /// "Today", "Yesterday", "Thu, Sep 24"; a past year is named ("Thu, Sep 25, 2025").
    var ledgerDay: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "Today" }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        if !calendar.isDate(self, equalTo: AppClock.now, toGranularity: .year) {
            return formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
        }
        return formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

extension AccountKind {
    /// "Checking", "Credit card" — how the app names an account's kind.
    var title: String {
        switch self {
        case .checking: "Checking"
        case .savings: "Savings"
        case .credit: "Credit card"
        case .investment: "Investments"
        }
    }
}

/// A transaction rendered with the design system: muted when it doesn't count toward spending (hidden,
/// or a transfer between the person's own accounts), an eye-slash when hidden, an orchid dot while it
/// waits for review.
struct LedgerRow: View {
    /// What follows the category in the subtitle.
    enum Detail {
        /// "Dining · Today" — for lists that aren't grouped by day (Home's recent rows).
        case day
        /// "Dining · Gold Card ••1008" — for lists already grouped by day (Activity).
        case account
        /// The caller's own words after the category.
        case text(String)
    }

    let transaction: LedgerTransaction
    var detail: Detail = .day
    @Environment(AppModel.self) private var app

    var body: some View {
        let category = app.category(transaction.categorization?.categoryID)
        DSTransactionRow(
            title: transaction.merchant,
            subtitle: [category?.name ?? "Uncategorized", detailText].compactMap { $0 }.joined(separator: " · "),
            amount: transaction.amount.decimal,
            currencyCode: transaction.amount.currencyCode,
            systemImage: category?.symbol ?? "questionmark",
            tone: CategoryStyle.tone(for: category),
            isPending: transaction.isPending,
            emphasis: transaction.isCounted(category: category) ? .normal : .muted,
            isHidden: transaction.isHidden,
            needsReview: transaction.categorization?.needsReview == true,
            tags: transaction.tags ?? []
        )
    }

    private var detailText: String? {
        switch detail {
        case .day: transaction.postedAt.ledgerDay
        case .account: app.account(transaction.accountID)?.shortLabel
        case let .text(text): text
        }
    }
}

struct LoadingPlaceholder: View {
    var text = "Reading the ledger…"
    var body: some View {
        DSThinkingLine(text).frame(maxWidth: .infinity, minHeight: 280)
    }
}

/// Serif page title used at the top of each tab, in place of the system large title.
struct PageTitle: View {
    let eyebrow: String?
    let title: String
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: String, eyebrow: String? = nil) {
        self.title = title
        self.eyebrow = eyebrow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.xs) {
            // The badge sits beside the eyebrow, or under it at accessibility sizes so neither breaks mid-word.
            let row = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: DSSpace.xs))
                                                          : AnyLayout(HStackLayout())
            row {
                if let eyebrow { DSEyebrow(eyebrow) }
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                DSPrivacyBadge(app.privacyState)
            }
            Text(title)
                .dsFont(.display)
                .foregroundStyle(Color.ds.ink)
                .accessibilityAddTraits(.isHeader)
        }
    }
}
