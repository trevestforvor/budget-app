import Foundation

// The recurring review queue: two questions Budget asks about recurring charges instead of deciding on its own.
// "Is this recurring?" — repeat charges that look like a series but don't have enough history for the recurring list.
// "Did this stop?" — a series on the list whose charge is about half a cycle overdue.

/// What Budget would like the person to look at on the recurring list.
public struct RecurringReview: Hashable, Codable, Sendable {
    public var asOf: Date
    /// "Is this recurring?" Charges that repeat on a schedule but aren't on the recurring list yet: two monthly charges of
    /// the same size, three weekly ones. Yes puts the merchant on the list at that cadence (`setRecurring`); no takes it
    /// off for good (`setRecurring` with `isRecurring` false). Most expensive per month first.
    public var candidates: [Subscription]
    /// "Did this stop?" Series on the recurring list with no charge for about a cycle and a half (`reviewRecurring`).
    /// Longest overdue first.
    public var maybeStopped: [Subscription]
    /// Merchants the person said stopped, whose series would otherwise still be on the list: a way to put one back.
    /// Nil from servers before it existed.
    public var ended: [String]?

    public init(asOf: Date, candidates: [Subscription], maybeStopped: [Subscription], ended: [String]? = nil) {
        self.asOf = asOf; self.candidates = candidates; self.maybeStopped = maybeStopped; self.ended = ended
    }

    /// How many questions are waiting.
    public var count: Int { candidates.count + maybeStopped.count }
}

/// The person's answer to "Did this stop?" for one merchant, kept in the ledger (`LedgerState.recurringReviews`), keyed
/// like `RecurringChoice`.
public struct RecurringReviewMark: Hashable, Codable, Sendable {
    /// The merchant as shown.
    public var merchant: String
    /// "Yes, I canceled it": the series ended at this instant. It leaves the recurring list and the usual month of bills
    /// and subscriptions at once; its past charges keep their bucket. A charge after this brings it back.
    public var endedAt: Date?
    /// "No, still active": not asked again before this instant (about one cycle on).
    public var snoozedUntil: Date?

    public init(merchant: String, endedAt: Date? = nil, snoozedUntil: Date? = nil) {
        self.merchant = merchant; self.endedAt = endedAt; self.snoozedUntil = snoozedUntil
    }
}

/// The person's answer to "Did this stop?", from the recurring review or a recurring charge's editor. Not a tool the
/// assistant can call.
public struct ReviewRecurring: Hashable, Sendable, Codable {
    public enum Answer: String, Hashable, Sendable, Codable {
        /// "Yes, I canceled it": ends the series now.
        case stopped
        /// "No, still active": asks again a cycle from now if no charge comes.
        case stillActive
    }

    /// The merchant as shown on the recurring list.
    public var merchant: String
    public var answer: Answer?
    /// An undo (or putting an ended series back): sets the merchant's mark exactly to `mark` — nil clears it — with no
    /// checks.
    public var restores: Bool?
    public var mark: RecurringReviewMark?

    public init(merchant: String, answer: Answer?, restores: Bool? = nil, mark: RecurringReviewMark? = nil) {
        self.merchant = merchant; self.answer = answer; self.restores = restores; self.mark = mark
    }
}

/// The recurring review on clients that can ask for it (a server from 0.5.0 on, or the demo).
public protocol RecurringReviewAPI: Sendable {
    /// "Is this recurring?" and "Did this stop?" questions waiting for the person.
    func recurringReview() async throws -> RecurringReview
}

extension ServerStatus {
    /// The first server with the recurring review (`GET /v1/recurring/review`) and the `reviewRecurring` action. An older
    /// one answers 404 to the read and 400 "Unknown action" to the write.
    public static let recurringReviewSince = "0.5.0"
}

extension LedgerBudgetAPI: RecurringReviewAPI {}
extension RemoteBudgetAPI: RecurringReviewAPI {}
extension CachingBudgetAPI: RecurringReviewAPI {}
