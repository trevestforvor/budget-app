import BudgetKit
import Foundation

/// The person's pay settings, kept on this phone only (never sent to the server).
extension EarningsProfile {
    static let storageKey = "opportunity.earnings"

    static var saved: EarningsProfile {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let profile = try? JSONDecoder().decode(EarningsProfile.self, from: data) else { return EarningsProfile() }
        return profile
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

/// Take-home pay as the ledger sees it: a typical month of the Income category over the last six full months — the
/// median of the months that had any, so a bonus, a tax refund or a month with a third paycheck doesn't pass for pay.
/// Paychecks land after tax, so this already is take-home.
struct Paychecks: Equatable {
    var monthly: Money
    /// The months looked at that had income, oldest first.
    var months: [Date]

    static let monthsLooked = 6

    /// "June to August" or "August".
    var span: String {
        guard let first = months.first, let last = months.last else { return "" }
        let style = Date.FormatStyle.dateTime.month(.wide)
        return first == last ? first.formatted(style) : "\(first.formatted(style)) to \(last.formatted(style))"
    }

    /// Nil when no recent month had any income filed.
    static func load(from api: any BudgetAPI, asOf now: Date) async throws -> Paychecks? {
        let thisMonth = MonthKey.start(of: now)
        let months = (1...monthsLooked).reversed().compactMap { Calendar.current.date(byAdding: .month, value: -$0, to: thisMonth) }
        let totals = try await withThrowingTaskGroup(of: (Date, Money).self) { group in
            for month in months {
                group.addTask {
                    let filter = TransactionFilter(categoryIDs: [BudgetCategory.incomeID], period: MonthKey.string(month))
                    return (month, try await api.transactionSummary(filter).income)
                }
            }
            var found: [Date: Money] = [:]
            for try await (month, income) in group { found[month] = income }
            return found
        }
        guard let typical = TakeHome.typicalMonth(months.compactMap { totals[$0] }) else { return nil }
        return Paychecks(monthly: typical, months: months.filter { (totals[$0]?.minorUnits ?? 0) > 0 })
    }
}
