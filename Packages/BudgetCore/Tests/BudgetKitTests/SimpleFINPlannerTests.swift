import Foundation
import Testing
@testable import BudgetKit

@Suite("SimpleFIN: which windows to ask for")
struct SimpleFINPlannerTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
    static func bank(_ lastGood: Double?, status: ConnectionStatus = .connected, accounts: [String] = ["A"], gap: SimpleFINGap? = nil) -> SimpleFINConnectionState {
        SimpleFINConnectionState(name: "Bank", status: status, lastGoodData: lastGood.map(daysAgo), accountIDs: accounts, gap: gap)
    }

    @Test("The fresh pull starts ten days before the oldest healthy bank's last good pull; a broken bank doesn't pull it back")
    func freshWindowFromOldestHealthyConnection() {
        let fresh = SimpleFINPlanner.fresh(connections: ["a": Self.bank(1), "b": Self.bank(5), "c": Self.bank(60, status: .needsReauth)], now: Self.now)
        #expect(fresh.start == Self.daysAgo(15) && fresh.end == nil && fresh.accountIDs.isEmpty && fresh.purpose == .fresh)
        // Nothing known, or a bank never pulled: as far as one window reaches.
        #expect(SimpleFINPlanner.fresh(connections: [:], now: Self.now).start == Self.daysAgo(89))
        #expect(SimpleFINPlanner.fresh(connections: ["a": Self.bank(1), "new": Self.bank(nil)], now: Self.now).start == Self.daysAgo(89))
        // A bank healthy but quiet for half a year still can't make one window span more than 89 days.
        #expect(SimpleFINPlanner.fresh(connections: ["a": Self.bank(180)], now: Self.now).start == Self.daysAgo(89))
    }

    @Test("A bank broken 120 days comes back to two repair windows, for its accounts only")
    func brokenBankExcludedThenRepairedWithAccountFilter() throws {
        let fresh = SimpleFINPlanner.fresh(connections: ["a": Self.bank(1), "b": Self.bank(120, status: .needsReauth, accounts: ["B1", "B2"])], now: Self.now)
        #expect(fresh.start == Self.daysAgo(11))
        // It recovered in this pull: the fresh window reached 11 days back; it last had data 120 days ago.
        let gap = try #require(SimpleFINPlanner.repairGap(lastGoodData: Self.daysAgo(120), freshStart: fresh.start))
        #expect(gap.from == Self.daysAgo(130) && gap.through == Self.daysAgo(11) && gap.purpose == .repair)
        let windows = SimpleFINPlanner.catchUp(connections: ["a": Self.bank(0), "b": Self.bank(0, accounts: ["B1", "B2"], gap: gap)],
                                               backfill: SimpleFINBackfill(reachedBack: Self.daysAgo(89), done: true), now: Self.now, limit: 6)
        #expect(windows.count == 2)
        #expect(windows.allSatisfy { $0.accountIDs == ["B1", "B2"] && $0.purpose == .repair && $0.connectionID == "b" })
        #expect(windows[0].end == Self.daysAgo(11) && windows[0].start == Self.daysAgo(100))
        #expect(windows[1].end == Self.daysAgo(100) && windows[1].start == Self.daysAgo(130))
        // Back within the fresh window's reach: nothing to repair. A shorter break than the spec's ~80 days still gets the
        // few days the fresh pull (set by the healthy banks) didn't reach.
        #expect(SimpleFINPlanner.repairGap(lastGoodData: Self.daysAgo(1), freshStart: Self.daysAgo(11)) == nil)
        #expect(SimpleFINPlanner.repairGap(lastGoodData: Self.daysAgo(5), freshStart: Self.daysAgo(11))?.from == Self.daysAgo(15))
        // Still broken: its gap waits.
        #expect(SimpleFINPlanner.catchUp(connections: ["b": Self.bank(0, status: .needsReauth, gap: gap)], backfill: nil, now: Self.now, limit: 6).isEmpty)
    }

    @Test("The history walk goes back a window at a time and stops at the first empty window")
    func backfillWalksBackAndStopsAtEmptyWindow() {
        let backfill = SimpleFINBackfill(reachedBack: Self.daysAgo(89))
        let windows = SimpleFINPlanner.catchUp(connections: [:], backfill: backfill, now: Self.now, limit: 3)
        #expect(windows.map(\.end) == [Self.daysAgo(89), Self.daysAgo(178), Self.daysAgo(267)])
        #expect(windows.map(\.start) == [Self.daysAgo(178), Self.daysAgo(267), Self.daysAgo(356)])
        #expect(windows.allSatisfy { $0.purpose == .backfill && $0.accountIDs.isEmpty })
        #expect(!SimpleFINPlanner.backfillDone(after: windows[0], transactions: 12, now: Self.now))
        #expect(SimpleFINPlanner.backfillDone(after: windows[1], transactions: 0, now: Self.now))
        #expect(SimpleFINPlanner.catchUp(connections: [:], backfill: SimpleFINBackfill(reachedBack: Self.daysAgo(89), done: true), now: Self.now, limit: 3).isEmpty)
        #expect(SimpleFINPlanner.catchUp(connections: [:], backfill: backfill, now: Self.now, limit: 0).isEmpty)
    }

    @Test("The history walk stops at two years")
    func backfillStopsAt730Days() {
        let windows = SimpleFINPlanner.catchUp(connections: [:], backfill: SimpleFINBackfill(reachedBack: Self.daysAgo(89)), now: Self.now, limit: 20)
        #expect(windows.count == 8)
        #expect(windows.last?.start == Self.daysAgo(730))
        #expect(SimpleFINPlanner.backfillDone(after: windows.last!, transactions: 40, now: Self.now))
    }

    @Test("No window ever spans more than 89 days")
    func windowsNeverExceed89Days() {
        let gap = SimpleFINGap(from: Self.daysAgo(700), through: Self.daysAgo(3), purpose: .backfill)
        let windows = SimpleFINPlanner.catchUp(connections: ["x": Self.bank(0, gap: gap), "y": Self.bank(0, gap: SimpleFINPlanner.repairGap(lastGoodData: Self.daysAgo(400), freshStart: Self.daysAgo(89)))],
                                               backfill: SimpleFINBackfill(reachedBack: Self.daysAgo(89)), now: Self.now, limit: 40)
        #expect(windows.count > 10)
        #expect(windows.allSatisfy { $0.end!.timeIntervalSince($0.start) <= 89 * 86_400 && $0.start < $0.end! })
        // Repairs come before a bank's history, and both before the link's walk.
        #expect(windows.first?.purpose == .repair && windows.first?.connectionID == "y")
        #expect(windows.last?.connectionID == nil)
        for connections in [[:], ["a": Self.bank(200)], ["a": Self.bank(nil)]] as [[String: SimpleFINConnectionState]] {
            let fresh = SimpleFINPlanner.fresh(connections: connections, now: Self.now)
            #expect(Self.now.timeIntervalSince(fresh.start) <= 89 * 86_400)
        }
    }
}
