import BudgetKit
import Foundation
import Logging

/// One push about a bank connection: a sign-in needed, consent running out, an account gone quiet.
public struct ConnectionAlert: Sendable, Equatable {
    public var kind: ConnectionAlertKind
    /// The first is this alert's own key; any others are marked sent with it (a 7-day warning covers the 14-day one).
    public var episodeKeys: [String]
    public var title: String
    public var body: String
    public var linkID: String?
    public var accountID: String?
    public var bankID: String?
    /// The tap opens signing in again from the phone, not just Accounts.
    public var opensReconnect: Bool

    public init(kind: ConnectionAlertKind, episodeKeys: [String], title: String, body: String, linkID: String? = nil, accountID: String? = nil,
                bankID: String? = nil, opensReconnect: Bool = false) {
        self.kind = kind; self.episodeKeys = episodeKeys; self.title = title; self.body = body; self.linkID = linkID
        self.accountID = accountID; self.bankID = bankID; self.opensReconnect = opensReconnect
    }
}

/// "Once per episode": each key holds the episode's start, so a new episode gets a new key by itself. Sent keys are kept
/// per phone in `budget_settings` under `sentKey`.
enum ConnectionAlerts {
    static let sentKey = "connectionAlertsSent"
    static let threadID = "connections"

    /// A sign-in needed or access withdrawn: `signin|<linkID>|<firstFailedAt epoch s>`.
    static func signInKey(linkID: String, firstFailedAt: Date) -> String { "signin|\(linkID)|\(epoch(firstFailedAt))" }
    /// Consent running out, `daysBefore` (14 or 7) ahead: `expiry|<linkID>|<yyyy-MM-dd>|<days>`.
    static func expiryKey(linkID: String, expiresAt: Date, daysBefore: Int) -> String { "expiry|\(linkID)|\(day(expiresAt))|\(daysBefore)" }
    /// One bank behind an aggregator link: `bank|<linkID>|<connID>|<firstFailedAt epoch s>`.
    static func bankKey(linkID: String, connectionID: String, firstFailedAt: Date) -> String { "bank|\(linkID)|\(connectionID)|\(epoch(firstFailedAt))" }
    /// An account gone quiet: `stale|<accountID>|<lastGoodSync epoch s>`, so the next good sync starts a new episode.
    static func staleKey(accountID: String, lastGoodSync: Date) -> String { "stale|\(accountID)|\(epoch(lastGoodSync))" }
    /// The server's own setup with a provider: `setup|<provider>|<firstFailedAt epoch s>`.
    static func setupKey(provider: SourceKind, firstFailedAt: Date) -> String { "setup|\(provider.rawValue)|\(epoch(firstFailedAt))" }

    static func epoch(_ date: Date) -> Int { Int(date.timeIntervalSince1970) }

    /// The day in UTC, so a key never changes with the server's time zone.
    static func day(_ date: Date) -> String {
        var style = Date.ISO8601FormatStyle().year().month().day()
        style.timeZone = TimeZone(identifier: "UTC")!
        return date.formatted(style)
    }
}

/// Sends connection pushes: checks every so often, in each phone's waking hours, a few at most per check, each episode
/// once. Not built yet: the scheduler does nothing.
public actor ConnectionAlertSender {
    let api: LedgerBudgetAPI
    let store: any ServerStore
    let sync: SyncService
    let morning: MorningSummary
    let push: PushSender
    let settings: ServerSettings
    let logger: Logger
    let clock: @Sendable () -> Date

    public init(api: LedgerBudgetAPI, store: any ServerStore, sync: SyncService, morning: MorningSummary, push: PushSender, settings: ServerSettings,
                logger: Logger, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api; self.store = store; self.sync = sync; self.morning = morning; self.push = push; self.settings = settings
        self.logger = logger; self.clock = clock
    }

    public func runScheduler() async {}
}
