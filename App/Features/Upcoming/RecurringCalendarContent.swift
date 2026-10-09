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
    enum Problem {
        /// The server has no Upcoming (older than `ServerStatus.upcomingSince`).
        case outdated
        /// It couldn't be reached, and there's no saved copy.
        case failed
    }

    let upcoming: Upcoming?
    /// Why `upcoming` is nil after loading; nil while it loads.
    var problem: Problem?
    /// The recurring list, so a bill or subscription on a day opens its edit sheet.
    var subscriptions: [Subscription] = []

    var body: some View {
        if let upcoming {
            if upcoming.items.isEmpty {
                DSStateView(systemImage: "calendar", title: "Nothing expected", message: "No paycheck, bill or card bill is expected in the next two months.")
            } else {
                UpcomingCalendar(upcoming: upcoming, subscriptions: subscriptions)
            }
        } else {
            switch problem {
            case nil:
                LoadingPlaceholder()
            case .failed:
                DSStateView(systemImage: "wifi.slash", title: "Couldn't load the calendar", message: "Pull to try again.")
            case .outdated:
                DSStateView(systemImage: "calendar", title: "No calendar yet",
                            message: "Your Budget server needs an update to show paychecks, bills and card bills by day.")
            }
        }
    }
}
