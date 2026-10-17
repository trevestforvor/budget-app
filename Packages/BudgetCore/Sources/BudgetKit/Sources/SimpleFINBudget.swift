import Foundation

/// One request this server made to SimpleFIN, kept on the link for a rolling 24 hours.
public struct SimpleFINRequest: Codable, Hashable, Sendable {
    public var at: Date
    public var purpose: SimpleFINPurpose
    /// `SimpleFINBudget.Trigger`'s raw value.
    public var trigger: String
    /// The HTTP status; 0 when no answer came.
    public var status: Int

    public init(at: Date, purpose: SimpleFINPurpose, trigger: String, status: Int) {
        self.at = at; self.purpose = purpose; self.trigger = trigger; self.status = status
    }
}

/// How many requests SimpleFIN gets from this server. SimpleFIN asks for no more than about 24 a day and refreshes its
/// data about once a day, so a short sync interval must never mean 96 pulls. Pure, so it's tested without a clock.
public enum SimpleFINBudget {
    /// Scheduled fresh pulls in 24 hours (the `simplefinDailyPulls` setting's default), spread evenly over the day.
    public static let automaticPerDay = 4
    /// How long after one scheduled pull the next may run: the day split evenly, so 4 a day are 6 h apart and 8 are 3 h.
    public static func automaticGap(perDay: Int) -> TimeInterval { day / Double(max(1, min(perDay, hardStopPerDay))) }
    /// Repair and history windows on scheduled runs in 24 hours.
    public static let backfillPerDay = 6
    /// History windows the first sync of a new link adds to its fresh pull (about a year).
    public static let firstLinkBackfill = 3
    /// Every request of any kind in a rolling 24 hours.
    public static let hardStopPerDay = 20
    public static let day: TimeInterval = 86_400

    public enum Trigger: String, Sendable {
        /// The schedule, the morning catch-up, a webhook: nobody is waiting.
        case scheduled
        /// Sync now, Try again, a new setup token.
        case person
        /// A new link's first sync.
        case firstLink
    }

    public enum Allowance: Equatable, Sendable {
        /// A fresh pull, then up to `backfill` older windows.
        case pull(backfill: Int)
        /// A scheduled run that doesn't ask this time, quietly: not an error. `nextAt` is the next automatic pull.
        case skipped(nextAt: Date)
        /// The person asked past the hard stop: an error that says when.
        case refused(nextAt: Date)
    }

    /// The requests still inside the rolling 24 hours, oldest first.
    public static func recent(_ log: [SimpleFINRequest], now: Date) -> [SimpleFINRequest] {
        log.filter { $0.at > now.addingTimeInterval(-day) && $0.at <= now }.sorted { $0.at < $1.at }
    }

    /// What a run with `trigger` may ask for now.
    public static func allowance(log: [SimpleFINRequest], trigger: Trigger, now: Date, automaticPerDay: Int = automaticPerDay) -> Allowance {
        let recent = recent(log, now: now)
        let left = hardStopPerDay - recent.count
        if left <= 0 {
            let nextAt = recent[recent.count - hardStopPerDay].at.addingTimeInterval(day)
            return trigger == .scheduled ? .skipped(nextAt: nextAt) : .refused(nextAt: nextAt)
        }
        switch trigger {
        case .person:
            return .pull(backfill: 0)
        case .firstLink:
            return .pull(backfill: min(firstLinkBackfill, left - 1))
        case .scheduled:
            let automatic = recent.filter { $0.trigger == Trigger.scheduled.rawValue && $0.purpose == .fresh }
            let perDay = max(1, min(automaticPerDay, hardStopPerDay))
            var nextAt: Date?
            if automatic.count >= perDay { nextAt = automatic[automatic.count - perDay].at.addingTimeInterval(day) }
            let gap = automaticGap(perDay: perDay)
            if let last = automatic.last, now.timeIntervalSince(last.at) < gap {
                nextAt = max(nextAt ?? .distantPast, last.at.addingTimeInterval(gap))
            }
            if let nextAt { return .skipped(nextAt: nextAt) }
            let backfillUsed = recent.filter { $0.trigger == Trigger.scheduled.rawValue && $0.purpose != .fresh }.count
            return .pull(backfill: max(0, min(backfillPerDay - backfillUsed, left - 1)))
        }
    }

    /// Whether one more request of any kind fits under the hard stop now.
    public static func hasRoom(_ log: [SimpleFINRequest], now: Date) -> Bool { recent(log, now: now).count < hardStopPerDay }
}
