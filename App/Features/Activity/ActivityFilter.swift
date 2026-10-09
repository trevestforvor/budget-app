import BudgetKit
import Foundation

/// The date choices in Filters, by the names the ledger gives periods. "Next 3 months" is left out on
/// purpose: there are no future rows to show.
enum ActivityPeriod: String, CaseIterable, Identifiable {
    case all
    case thisMonth = "this_month"
    case lastMonth = "last_month"
    case last30Days = "last_30_days"
    case last90Days = "last_90_days"
    case last6Months = "last_6_months"
    case yearToDate = "year_to_date"
    case lastYear = "last_year"
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All time"
        case .thisMonth: "This month"
        case .lastMonth: "Last month"
        case .last30Days: "Last 30 days"
        case .last90Days: "Last 90 days"
        case .last6Months: "Last 6 months"
        case .yearToDate: "This year"
        case .lastYear: "Last year"
        case .custom: "Custom dates"
        }
    }
}

extension TransactionFilter.Sort {
    var title: String {
        switch self {
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .largest: "Largest"
        }
    }
}

extension TransactionFilter.Visibility {
    var title: String {
        switch self {
        case .all: "Everything"
        case .counted: "Counted only"
        case .notCounted: "Not counted only"
        }
    }
}

extension TransactionFilter {
    static let pageSize = 100

    /// Activity's starting point: every row, newest first, one page.
    static var activity: TransactionFilter { TransactionFilter(limit: pageSize) }

    var activePeriod: ActivityPeriod {
        if since != nil || until != nil { return .custom }
        return period.flatMap(ActivityPeriod.init(rawValue:)) ?? .all
    }

    mutating func setPeriod(_ choice: ActivityPeriod, calendar: Calendar = .current) {
        switch choice {
        case .all:
            period = nil; since = nil; until = nil
        case .custom:
            period = nil
            let today = calendar.startOfDay(for: AppClock.now)
            if since == nil { since = calendar.date(byAdding: .day, value: -30, to: today) }
            if until == nil { until = calendar.date(byAdding: .day, value: 1, to: today) }
        default:
            period = choice.rawValue; since = nil; until = nil
        }
    }

    /// How many choices the Filters sheet (and the quick chips, which set the same things) holds —
    /// search, sort and paging aside. "Filters · 2".
    var choiceCount: Int {
        var n = 0
        if activePeriod != .all { n += 1 }
        if !(categoryIDs ?? []).isEmpty { n += 1 }
        if !(accountIDs ?? []).isEmpty { n += 1 }
        if !(tags ?? []).isEmpty { n += 1 }
        if direction != nil || minAmount != nil || maxAmount != nil { n += 1 }
        if visibility != .all { n += 1 }
        if needsReviewOnly { n += 1 }
        if pendingOnly { n += 1 }
        if modelFiledOnly { n += 1 }
        return n
    }

    /// Whether the list shows fewer than every row: a search or any choice. The summary card shows then.
    var narrows: Bool { choiceCount > 0 || !(search ?? "").trimmingCharacters(in: .whitespaces).isEmpty }

    /// The same search and order with every choice cleared.
    var clearingChoices: TransactionFilter {
        TransactionFilter(search: search, sort: sort, limit: limit)
    }
}
