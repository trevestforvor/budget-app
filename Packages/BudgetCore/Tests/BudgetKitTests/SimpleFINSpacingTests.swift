import Foundation
import Testing
@testable import BudgetKit

/// The `simplefinDailyPulls` setting spaces scheduled pulls over the day, and the link's history walk waits for a bank
/// that needs a sign-in.
@Suite("SimpleFIN: pull spacing and a paused history walk")
struct SimpleFINSpacingTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
    static func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
    static func scheduled(_ hoursAgo: Double) -> SimpleFINRequest {
        SimpleFINRequest(at: Self.hoursAgo(hoursAgo), purpose: .fresh, trigger: SimpleFINBudget.Trigger.scheduled.rawValue, status: 200)
    }

    @Test("Eight pulls a day are three hours apart, not held to four")
    func eightADayAreThreeHoursApart() {
        #expect(SimpleFINBudget.automaticGap(perDay: 4) == 6 * 3600 && SimpleFINBudget.automaticGap(perDay: 8) == 3 * 3600)
        // Five already today, the last three hours ago: at eight a day the sixth runs; at four, not until the second is a day old.
        let five = [23, 19, 15, 9, 3].map { Self.scheduled(Double($0)) }
        #expect(SimpleFINBudget.allowance(log: five, trigger: .scheduled, now: Self.now, automaticPerDay: 8) == .pull(backfill: 6))
        #expect(SimpleFINBudget.allowance(log: five, trigger: .scheduled, now: Self.now, automaticPerDay: 4) == .skipped(nextAt: Self.hoursAgo(-5)))
        // Two hours after the last: an hour to wait.
        #expect(SimpleFINBudget.allowance(log: [Self.scheduled(2)], trigger: .scheduled, now: Self.now, automaticPerDay: 8) == .skipped(nextAt: Self.hoursAgo(-1)))
        // Eight in the day: the next once the oldest is a day old.
        let eight = (0..<8).map { Self.scheduled(23 - Double($0) * 3) }
        #expect(SimpleFINBudget.allowance(log: eight, trigger: .scheduled, now: Self.now, automaticPerDay: 8) == .skipped(nextAt: Self.hoursAgo(-1)))
    }

    @Test("The link's history walk waits while any bank needs a sign-in; healthy banks' gaps still go")
    func historyWalkWaitsForASignIn() {
        let backfill = SimpleFINBackfill(reachedBack: Self.daysAgo(89))
        let gap = SimpleFINGap(from: Self.daysAgo(130), through: Self.daysAgo(100), purpose: .repair)
        let connections = ["a": SimpleFINConnectionState(name: "Harbor", lastGoodData: Self.daysAgo(0), accountIDs: ["A1"], gap: gap),
                           "b": SimpleFINConnectionState(name: "Keystone", status: .needsReauth, lastGoodData: Self.daysAgo(20), accountIDs: ["B1"])]
        let windows = SimpleFINPlanner.catchUp(connections: connections, backfill: backfill, now: Self.now, limit: 6)
        #expect(windows.count == 1 && windows[0].connectionID == "a" && windows[0].purpose == .repair)
        var healed = connections
        healed["b"]?.status = .connected
        #expect(SimpleFINPlanner.catchUp(connections: healed, backfill: backfill, now: Self.now, limit: 6).contains { $0.connectionID == nil && $0.end == Self.daysAgo(89) })
    }
}
