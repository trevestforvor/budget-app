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

    static let utc = TimeZone(identifier: "UTC")!

    static func epoch(_ date: Date) -> Int { Int(date.timeIntervalSince1970) }

    /// How long a sent key is kept. An episode still going after that may push once more, which beats a log that grows forever.
    static let keepSentFor: TimeInterval = 120 * 86_400

    /// Every push the server's links and accounts call for now, most pressing first. Dates in the copy are in `timeZone`
    /// (the phone's); the keys never depend on it. `reconnect` is how each link is repaired (see `linkAlerts`).
    static func all(links: [StoredLink], health: [AccountHealth], now: Date, timeZone: TimeZone,
                    reconnect: (StoredLink) -> ReconnectMethod = { ReconnectMethod.for($0, phoneCapable: false) }) -> [ConnectionAlert] {
        let alerts = linkAlerts(links, now: now, timeZone: timeZone, reconnect: reconnect) + healthAlerts(health, links: links, now: now)
        // A stable sort: the collectors' own order holds within a kind.
        return alerts.enumerated().sorted { ($0.element.kind.rank, $0.offset) < ($1.element.kind.rank, $1.offset) }.map(\.element)
    }

    /// The alerts in `alerts` whose own key hasn't gone out yet.
    static func due(_ alerts: [ConnectionAlert], sent: [String: Date]) -> [ConnectionAlert] {
        alerts.filter { alert in alert.episodeKeys.first.map { sent[$0] == nil } ?? false }
    }

    /// An episode already told carries the keys that joined it since (another link stopped by the same refused setup),
    /// so it doesn't push again when the link that started it heals first.
    static func absorb(_ alerts: [ConnectionAlert], into sent: inout [String: Date], now: Date) {
        for alert in alerts {
            guard let first = alert.episodeKeys.first, sent[first] != nil else { continue }
            for key in alert.episodeKeys.dropFirst() where sent[key] == nil { sent[key] = now }
        }
    }

    /// The notification. A tap opens signing in again (`to: "reconnect"`) or Accounts; it carries ids and the alert's
    /// kind, never a URL, a link token or a session: the phone asks the server for a fresh session when it's tapped.
    static func notification(_ alert: ConnectionAlert, now: Date) -> APNsClient.Alert {
        var info = ["kind": "connection", "alert": alert.kind.rawValue, "to": alert.opensReconnect ? "reconnect" : "accounts"]
        info["linkID"] = alert.linkID
        info["accountID"] = alert.accountID
        info["bank"] = alert.bankID
        // The most specific id first, so two banks behind one link (or two accounts) don't replace each other, and the
        // 64-byte cap cuts the least specific.
        let ids = [alert.accountID, alert.bankID, alert.linkID].compactMap { $0 }.joined(separator: "-")
        let collapse = PaceAlertSender.utf8Prefix("conn-\(alert.kind.rawValue)-\(ids)", maxBytes: 64)
        return APNsClient.Alert(title: alert.title, body: alert.body, collapseID: collapse, threadID: threadID, userInfo: info,
                                expiration: now.addingTimeInterval(24 * 3600))
    }

    /// Whether `device` hears about connections: it takes some notification from the server, and didn't turn these off.
    static func listens(_ device: StoredDevice) -> Bool {
        (device.enabled || device.paceAlerts?.any == true) && device.connectionAlerts != false
    }

    /// The day in UTC, so a key never changes with the server's time zone.
    static func day(_ date: Date) -> String {
        var style = Date.ISO8601FormatStyle().year().month().day()
        style.timeZone = utc
        return date.formatted(style)
    }
}

extension ConnectionAlertKind {
    /// Which goes first when a phone has more due than one check sends: what stops every sync, then a bank waiting for a
    /// sign-in, then a warning, then a quiet account.
    var rank: Int {
        switch self {
        case .providerSetup: 0
        case .needsSignIn, .revoked: 1
        case .bankNeedsSignIn: 2
        case .consentExpiring: 3
        case .accountStale: 4
        }
    }
}

/// Sends connection pushes: a bank that needs a sign-in, access withdrawn or running out, the server's Plaid setup
/// broken, an account gone quiet. Like pace alerts it checks every ten minutes, sends only in each phone's waking hours
/// (9:00 to 21:00 where it is), at most a few to a phone per check, and each episode once — saved, so a restart doesn't
/// send it again. Without an APNs key (a test server) it only logs what it would have sent.
public actor ConnectionAlertSender {
    let api: LedgerBudgetAPI
    let store: any ServerStore
    let sync: SyncService
    let morning: MorningSummary
    let push: PushSender
    let settings: ServerSettings
    let logger: Logger
    let clock: @Sendable () -> Date

    /// The episodes already logged as "would push" in this process, so a server without a key logs each once.
    private var loggedWouldPush: Set<String> = []

    public init(api: LedgerBudgetAPI, store: any ServerStore, sync: SyncService, morning: MorningSummary, push: PushSender, settings: ServerSettings,
                logger: Logger, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api; self.store = store; self.sync = sync; self.morning = morning; self.push = push; self.settings = settings
        self.logger = logger; self.clock = clock
    }

    /// Checks every ten minutes for the life of the process.
    public func runScheduler() async {
        while !Task.isCancelled {
            await sendDue()
            try? await Task.sleep(for: PaceAlertSender.checkInterval)
        }
    }

    /// Sends what's due to every phone that listens and is awake.
    func sendDue() async {
        let now = clock()
        guard let links = try? await store.links(), let devices = try? await morning.devices() else { return }
        guard await push.credentials() != nil else {
            logWouldPush(links: links, health: await health(), now: now)
            return
        }
        let listening = devices.filter { ConnectionAlerts.listens($0) && PaceAlertSender.awake($0, now: now) }
        guard !listening.isEmpty else { return }
        let health = await health()
        let capable = await ReconnectMethod.phoneCapable(settings: settings, providers: sync.providers, sealer: sync.sealer)
        let reconnect: (StoredLink) -> ReconnectMethod = { ReconnectMethod.for($0, phoneCapable: capable) }

        var sent = await sentLog()
        var saved = sent
        // Only phones still registered, and only the last 120 days.
        let tokens = Set(devices.map(\.token))
        for (token, keys) in sent {
            let kept = tokens.contains(token) ? keys.filter { now.timeIntervalSince($0.value) < ConnectionAlerts.keepSentFor } : [:]
            sent[token] = kept.isEmpty ? nil : kept
        }

        for device in listening {
            let zone = TimeZone(identifier: device.timeZone) ?? ConnectionAlerts.utc
            var marked = sent[device.token] ?? [:]
            let alerts = ConnectionAlerts.all(links: links, health: health, now: now, timeZone: zone, reconnect: reconnect)
            ConnectionAlerts.absorb(alerts, into: &marked, now: now)
            let due = ConnectionAlerts.due(alerts, sent: marked)
            for alert in due.prefix(PaceAlertSender.perCheck) {
                let (outcome, environment) = await push.send(ConnectionAlerts.notification(alert, now: now), to: device.token,
                                                             environment: device.environment, now: now)
                if case .sent = outcome {
                    for key in alert.episodeKeys { marked[key] = now }
                    logger.info("connection alert sent: \(alert.kind.rawValue)")
                    if let environment, environment != device.environment {
                        _ = try? await morning.update(device.token) { $0.environment = environment }
                    }
                    continue
                }
                if case let .badToken(reason) = outcome {
                    // Dead for good: everything for this phone stops until it registers a new token.
                    logger.warning("connection alerts: dropped a dead device token (\(reason))")
                    _ = try? await morning.update(device.token) { d in
                        d.enabled = false
                        d.paceAlerts = nil
                        d.lastError = "APNs no longer accepts this phone's token (\(reason)). Turn notifications off and on again in Settings."
                    }
                } else if case let .failed(message) = outcome {
                    // Tried again at the next check.
                    logger.error("connection alert failed: \(message)")
                }
                break
            }
            sent[device.token] = marked.isEmpty ? nil : marked
            // Saved phone by phone, so a process that stops partway through doesn't send these again.
            if sent != saved, await save(sent) { saved = sent }
        }
        if sent != saved { _ = await save(sent) }
    }

    /// How fresh each account is, from the overview; empty until sync health is built or when the ledger can't be read.
    private func health() async -> [AccountHealth] {
        do { return try await api.overview().accountHealth ?? [] } catch {
            logger.error("connection alerts: couldn't read the ledger: \(error)")
            return []
        }
    }

    /// A server with no APNs key: one log line per episode per process, kind and key only (the key names a link or
    /// account id, never a bank's words or an amount).
    private func logWouldPush(links: [StoredLink], health: [AccountHealth], now: Date) {
        for alert in ConnectionAlerts.all(links: links, health: health, now: now, timeZone: ConnectionAlerts.utc) {
            guard let key = alert.episodeKeys.first, loggedWouldPush.insert(key).inserted else { continue }
            logger.notice("would push \(alert.kind.rawValue) \(key)")
        }
    }

    /// Writes the sent log; false when the store refused it.
    private func save(_ log: [String: [String: Date]]) async -> Bool {
        do {
            try await store.saveSetting(ConnectionAlerts.sentKey, HTTP.encoder.encode(log))
            return true
        } catch {
            logger.error("connection alerts: couldn't save what was sent: \(error)")
            return false
        }
    }

    /// Phone token → episode key → when it went out.
    func sentLog() async -> [String: [String: Date]] {
        (try? await store.setting(ConnectionAlerts.sentKey)).flatMap { try? HTTP.decoder.decode([String: [String: Date]].self, from: $0) } ?? [:]
    }
}
