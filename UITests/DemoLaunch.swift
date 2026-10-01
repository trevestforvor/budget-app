import Foundation

/// How UI tests start the app on the demo ledger: at noon on a fixed mid-month day (`-demoDate`), so the demo's month
/// and every "this month", "last month" and "late" in the app are the same whatever day the tests run.
enum DemoLaunch {
    static let date = "2026-09-20"
    static let arguments = ["-demo", "-demoDate", date]
    /// The app's "now" under `arguments`.
    static var now: Date {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))!
    }
}
