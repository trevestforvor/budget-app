import Foundation

/// What a request to SimpleFIN is for.
public enum SimpleFINPurpose: String, Codable, Hashable, Sendable {
    /// The latest rows for every bank.
    case fresh
    /// Rows a bank missed while it waited for a sign-in, for that bank's accounts only.
    case repair
    /// Older history, walked back a window at a time.
    case backfill
}

/// One request's date range: `[start, end)`, or from `start` to now when `end` is nil.
public struct SimpleFINWindow: Hashable, Sendable {
    public var start: Date
    /// Exclusive, like the bridge's `end-date`.
    public var end: Date?
    /// Only these accounts (the bridge's ids); empty means all.
    public var accountIDs: [String]
    public var purpose: SimpleFINPurpose
    /// Which bank's gap this fills (`repair`, or a bank added later), so its progress moves on.
    public var connectionID: String?

    public init(start: Date, end: Date? = nil, accountIDs: [String] = [], purpose: SimpleFINPurpose, connectionID: String? = nil) {
        self.start = start; self.end = end; self.accountIDs = accountIDs; self.purpose = purpose; self.connectionID = connectionID
    }
}

/// One bank behind a SimpleFIN link (a bridge "connection"), as the server keeps it.
public struct SimpleFINConnectionState: Codable, Hashable, Sendable {
    public var name: String
    public var orgURL: String?
    /// `.connected`, or `.needsReauth` while the bridge reports `con.auth` for it.
    public var status: ConnectionStatus
    /// The last pull that brought every one of its accounts without a problem; its next window starts ten days before.
    public var lastGoodData: Date?
    /// When the current sign-in problem began.
    public var firstFailedAt: Date?
    /// The bridge's ids of its accounts.
    public var accountIDs: [String]
    /// The bridge's message about it, sanitized.
    public var lastMessage: String?
    public var errorCode: String?
    /// Days it still lacks, filled a window at a time (newest first).
    public var gap: SimpleFINGap?

    public init(name: String, orgURL: String? = nil, status: ConnectionStatus = .connected, lastGoodData: Date? = nil, firstFailedAt: Date? = nil,
                accountIDs: [String] = [], lastMessage: String? = nil, errorCode: String? = nil, gap: SimpleFINGap? = nil) {
        self.name = name; self.orgURL = orgURL; self.status = status; self.lastGoodData = lastGoodData; self.firstFailedAt = firstFailedAt
        self.accountIDs = accountIDs; self.lastMessage = lastMessage; self.errorCode = errorCode; self.gap = gap
    }
}

/// A span of days one bank still lacks: `[from, through)`. `through` moves back as each window lands.
public struct SimpleFINGap: Codable, Hashable, Sendable {
    public var from: Date
    public var through: Date
    /// `.repair` after a long sign-in problem; `.backfill` for a bank added after the link (stops at an empty window).
    public var purpose: SimpleFINPurpose

    public init(from: Date, through: Date, purpose: SimpleFINPurpose) { self.from = from; self.through = through; self.purpose = purpose }
}

/// How far back the link's history walk has reached.
public struct SimpleFINBackfill: Codable, Hashable, Sendable {
    public var reachedBack: Date
    public var done: Bool

    public init(reachedBack: Date, done: Bool = false) { self.reachedBack = reachedBack; self.done = done }
}

/// Which windows to ask SimpleFIN for. Pure: the server keeps the state, and a phone-only edition could reuse it.
///
/// The bridge silently cuts a request to about 90 days, so no window spans more than 89. Each bank's own last good pull
/// sets how far back the fresh pull reaches, so one bank broken for a while never leaves a hole in the others, and a
/// bank that comes back after more than about 80 days gets walk-back windows for its accounts only.
public enum SimpleFINPlanner {
    public static let maxSpan: TimeInterval = 89 * 86_400
    /// Late-posting rows: the same ten days a window source always overlapped.
    public static let overlap: TimeInterval = 10 * 86_400
    public static let historyLimit: TimeInterval = 730 * 86_400

    /// The one fresh request: from ten days before the oldest healthy bank's last good pull, at most 89 days back, no
    /// end, every account. A bank waiting for a sign-in doesn't pull it back further; it's repaired when it returns.
    public static func fresh(connections: [String: SimpleFINConnectionState], now: Date) -> SimpleFINWindow {
        let floor = now.addingTimeInterval(-maxSpan)
        let healthy = connections.values.filter { $0.status != .needsReauth }
        // A bank never pulled yet (or none known) reaches as far as a window can.
        let reach = healthy.contains { $0.lastGoodData == nil } || healthy.isEmpty
            ? floor : healthy.compactMap(\.lastGoodData).min()!.addingTimeInterval(-overlap)
        return SimpleFINWindow(start: max(floor, reach), purpose: .fresh)
    }

    /// The gap a bank coming back from a sign-in problem needs, or nil when the fresh pull already reaches it.
    public static func repairGap(lastGoodData: Date?, freshStart: Date) -> SimpleFINGap? {
        guard let lastGoodData else { return nil }
        let from = lastGoodData.addingTimeInterval(-overlap)
        return from < freshStart ? SimpleFINGap(from: from, through: freshStart, purpose: .repair) : nil
    }

    /// The history a bank added after the link needs: back two years from the fresh pull, until a window comes back empty.
    public static func newBankGap(freshStart: Date, now: Date) -> SimpleFINGap {
        SimpleFINGap(from: now.addingTimeInterval(-historyLimit), through: freshStart, purpose: .backfill)
    }

    /// Up to `limit` older windows, in order: each bank's gap (repairs first), then the link's history walk.
    public static func catchUp(connections: [String: SimpleFINConnectionState], backfill: SimpleFINBackfill?, now: Date, limit: Int) -> [SimpleFINWindow] {
        guard limit > 0 else { return [] }
        var windows: [SimpleFINWindow] = []
        let gaps = connections.filter { $0.value.gap != nil && $0.value.status != .needsReauth }
            .sorted { ($0.value.gap!.purpose == .repair ? 0 : 1, $0.key) < ($1.value.gap!.purpose == .repair ? 0 : 1, $1.key) }
        for (id, connection) in gaps {
            let gap = connection.gap!
            var end = gap.through
            while end > gap.from, windows.count < limit {
                let start = max(gap.from, end.addingTimeInterval(-maxSpan))
                windows.append(SimpleFINWindow(start: start, end: end, accountIDs: connection.accountIDs, purpose: gap.purpose, connectionID: id))
                end = start
            }
        }
        if let backfill, !backfill.done {
            let oldest = now.addingTimeInterval(-historyLimit)
            var end = backfill.reachedBack
            while end > oldest, windows.count < limit {
                let start = max(oldest, end.addingTimeInterval(-maxSpan))
                windows.append(SimpleFINWindow(start: start, end: end, purpose: .backfill))
                end = start
            }
        }
        return windows
    }

    /// Whether the history walk is finished after a backfill window: it came back empty, or it reached two years.
    public static func backfillDone(after window: SimpleFINWindow, transactions: Int, now: Date) -> Bool {
        transactions == 0 || window.start <= now.addingTimeInterval(-historyLimit)
    }
}
