import Foundation

/// Budget months travel as "2026-09" (the ledger's `month` keys); screens work with the month's first day.
enum MonthKey {
    static func string(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 1)
    }

    /// The first instant of the month `key` names, or nil when it isn't written like 2026-09.
    static func date(_ key: String?, calendar: Calendar = .current) -> Date? {
        guard let key else { return nil }
        let parts = key.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: 1))
    }

    static func start(of date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? date
    }

    /// "September", or "September 2025" when it isn't this year.
    static func name(_ date: Date, calendar: Calendar = .current, now: Date = AppClock.now) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return date.formatted(sameYear ? .dateTime.month(.wide) : .dateTime.month(.wide).year())
    }
}
