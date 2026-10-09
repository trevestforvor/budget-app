import BudgetKit
import DesignSystem
import SwiftUI

/// Recurring shows its charges as a list or on a calendar.
enum RecurringLayout: String, CaseIterable, Identifiable {
    case list, calendar
    var id: String { rawValue }
    var title: String { self == .list ? "List" : "Calendar" }

    /// `-recurringCalendar` opens Recurring on the calendar (screenshots and UI tests).
    static var launched: RecurringLayout {
        ProcessInfo.processInfo.arguments.contains("-recurringCalendar") ? .calendar : .list
    }
}

/// Recurring's calendar mode: the calendar, or why there isn't one.
struct RecurringCalendarContent: View {
    let upcoming: Upcoming?

    var body: some View {
        if let upcoming {
            if upcoming.items.isEmpty {
                DSStateView(systemImage: "calendar", title: "Nothing expected", message: "No paycheck, bill or card bill is expected in the next two months.")
            } else {
                UpcomingCalendar(upcoming: upcoming)
            }
        } else {
            DSStateView(systemImage: "calendar", title: "No calendar yet",
                        message: "Your Budget server needs an update to show paychecks, bills and card bills by day.")
        }
    }
}
