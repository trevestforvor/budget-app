import Foundation
import Testing
@testable import BudgetKit

@Suite("SimpleFIN: the daily request budget")
struct SimpleFINBudgetTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
    static func request(_ hoursAgo: Double, _ purpose: SimpleFINPurpose = .fresh, _ trigger: SimpleFINBudget.Trigger = .scheduled) -> SimpleFINRequest {
        SimpleFINRequest(at: Self.hoursAgo(hoursAgo), purpose: purpose, trigger: trigger.rawValue, status: 200)
    }

    @Test("Scheduled runs pull at most four times a day, six hours apart; between, they skip quietly")
    func fourScheduledPullsSixHoursApart() {
        #expect(SimpleFINBudget.allowance(log: [], trigger: .scheduled, now: Self.now) == .pull(backfill: 6))
        // Two hours after the last: skipped until six hours after it.
        #expect(SimpleFINBudget.allowance(log: [Self.request(2)], trigger: .scheduled, now: Self.now) == .skipped(nextAt: Self.hoursAgo(-4)))
        #expect(SimpleFINBudget.allowance(log: [Self.request(6)], trigger: .scheduled, now: Self.now) == .pull(backfill: 6))
        // Four in the last day: the next once the oldest is a day old.
        let four = [Self.request(23), Self.request(17), Self.request(11), Self.request(6.5)]
        #expect(SimpleFINBudget.allowance(log: four, trigger: .scheduled, now: Self.now) == .skipped(nextAt: Self.hoursAgo(-1)))
        // The person's own pulls and backfill windows don't use up automatic pulls; backfill uses its own allowance.
        let mixed = [Self.request(1, .fresh, .person), Self.request(7), Self.request(7, .backfill), Self.request(7, .repair)]
        #expect(SimpleFINBudget.allowance(log: mixed, trigger: .scheduled, now: Self.now) == .pull(backfill: 4))
        // A dashboard setting of 2 a day.
        #expect(SimpleFINBudget.allowance(log: [Self.request(20), Self.request(8)], trigger: .scheduled, now: Self.now, automaticPerDay: 2)
                == .skipped(nextAt: Self.hoursAgo(-4)))
    }

    @Test("Automatic pulls stop at 12 a day, so the schedule never fills the hard stop: backfill and the person keep room")
    func automaticPullsCappedBelowTheHardStop() {
        #expect(SimpleFINBudget.maxAutomaticPerDay == 12)
        #expect(SimpleFINBudget.automaticGap(perDay: 20) == SimpleFINBudget.day / 12)
        // Twelve scheduled pulls two hours apart, asked for 20 a day: the 13th waits.
        let twelve = (0..<12).map { Self.request(23 - 2 * Double($0)) }
        guard case .skipped = SimpleFINBudget.allowance(log: twelve, trigger: .scheduled, now: Self.now, automaticPerDay: 20) else {
            Issue.record("a 13th automatic pull ran"); return
        }
        // With 12 automatic pulls and 6 backfills spent, the person still gets a pull.
        let full = twelve + (0..<6).map { Self.request(22.5 - 2 * Double($0), .backfill) }
        #expect(SimpleFINBudget.allowance(log: full, trigger: .person, now: Self.now) == .pull(backfill: 0))
        // And a scheduled pull with backfill left still gets its windows.
        let eleven = (0..<11).map { Self.request(23 - 2 * Double($0)) }
        #expect(SimpleFINBudget.allowance(log: eleven, trigger: .scheduled, now: Self.now, automaticPerDay: 20) == .pull(backfill: 6))
    }

    @Test("The 21st request in 24 hours is refused here, with when the next can run")
    func twentyFirstRequestRefusedWithNextTime() {
        let twenty = (0..<20).map { Self.request(23 - Double($0), .fresh, .person) }
        #expect(SimpleFINBudget.allowance(log: twenty, trigger: .person, now: Self.now) == .refused(nextAt: Self.hoursAgo(-1)))
        #expect(SimpleFINBudget.allowance(log: twenty, trigger: .firstLink, now: Self.now) == .refused(nextAt: Self.hoursAgo(-1)))
        #expect(SimpleFINBudget.allowance(log: twenty, trigger: .scheduled, now: Self.now) == .skipped(nextAt: Self.hoursAgo(-1)))
        #expect(!SimpleFINBudget.hasRoom(twenty, now: Self.now))
        let message = SimpleFINError.budget(nextAt: Self.hoursAgo(-1), nextAtText: "3:40 PM").errorDescription
        #expect(message == "SimpleFIN allows about 24 requests a day; this server stops at 20. The next pull can run at 3:40 PM.")
        #expect(SimpleFINError.budget(nextAt: Self.now, nextAtText: "").kind == .rateLimited)
    }

    @Test("The person's pulls are allowed until the hard stop; a new link gets three history windows if they fit")
    func personPullsAllowedUntilHardStop() {
        let nineteen = (0..<19).map { Self.request(Double($0) * 0.5, .fresh, .person) }
        #expect(SimpleFINBudget.allowance(log: nineteen, trigger: .person, now: Self.now) == .pull(backfill: 0))
        #expect(SimpleFINBudget.allowance(log: nineteen, trigger: .firstLink, now: Self.now) == .pull(backfill: 0))
        #expect(SimpleFINBudget.allowance(log: [], trigger: .firstLink, now: Self.now) == .pull(backfill: 3))
        #expect(SimpleFINBudget.allowance(log: Array(nineteen.prefix(17)), trigger: .firstLink, now: Self.now) == .pull(backfill: 2))
        #expect(SimpleFINBudget.hasRoom(nineteen, now: Self.now))
    }

    @Test("The day is a rolling 24 hours, not the calendar day")
    func rolling24hWindow() {
        let old = (0..<20).map { Self.request(24 + Double($0)) }
        #expect(SimpleFINBudget.recent(old, now: Self.now).isEmpty)
        #expect(SimpleFINBudget.allowance(log: old, trigger: .person, now: Self.now) == .pull(backfill: 0))
        let edge = (0..<19).map { _ in Self.request(23.9) } + [Self.request(24.1)]
        #expect(SimpleFINBudget.recent(edge, now: Self.now).count == 19)
        #expect(SimpleFINBudget.allowance(log: edge, trigger: .person, now: Self.now) == .pull(backfill: 0))
    }
}
