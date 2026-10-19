import BudgetKit
import Foundation
import HTTPTypes
import Logging

/// API requests turned away for their token, counted per day (UTC) and by where they came from: kept 14 days in
/// `budget_settings`, shown on the dashboard, and a push at most once a day when one carried a token that's wrong.
///
/// No token is what scanners send, and they try every address on the internet, so those are only counted. A wrong token
/// means something token-shaped is out there (an old phone, a leaked one), which is worth a push. There's no lockout:
/// the token is 256 random bits, so guessing can't win, and a lockout would let anyone lock the phone out.
///
/// Counts live in memory and are saved at each check (every ten minutes), so a burst of requests never becomes a burst
/// of writes; a restart can lose up to ten minutes of them.
public actor AccessWatch {
    public enum Kind: String, Codable, Sendable { case noToken, wrongToken }

    /// One address on one day.
    public struct Source: Codable, Equatable, Sendable {
        /// As the proxy in front of the server reported it (`X-Real-IP`, else the first `X-Forwarded-For`); a client
        /// can fake it, so it's a lead, not proof.
        public var address: String
        public var noToken: Int
        public var wrongToken: Int
        public var lastSeen: Date
        public var lastPath: String
    }

    public struct Day: Codable, Equatable, Sendable {
        public var day: String
        public var noToken: Int
        public var wrongToken: Int
        /// Most recent first, at most `maxSources`; the rest of the day's requests go to one `othersAddress` row.
        public var sources: [Source]
    }

    /// What's saved, and what `GET /dash/access` returns.
    public struct Log: Codable, Equatable, Sendable {
        public var days: [Day] = []
        /// Wrong-token requests since the last push (or ever, without one).
        public var unannounced: Int = 0
        public var lastAlertAt: Date?
    }

    static let settingKey = "accessWatch"
    static let keepDays = 14
    static let maxSources = 50
    static let othersAddress = "others"
    static let unknownAddress = "unknown"
    static let threadID = "access"
    /// One push a day at most, whatever the phone's time zone.
    static let alertEvery: TimeInterval = 20 * 3600

    let store: any ServerStore
    let morning: MorningSummary
    let push: PushSender
    let logger: Logger
    let clock: @Sendable () -> Date

    private var log = Log()
    private var loaded = false
    private var dirty = false
    /// Addresses already logged today, so a wrong token logs once per address per day, not once per request.
    private var loggedToday: (day: String, addresses: Set<String>) = ("", [])

    public init(store: any ServerStore, morning: MorningSummary, push: PushSender, logger: Logger, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.morning = morning; self.push = push; self.logger = logger; self.clock = clock
    }

    /// Checks every ten minutes for the life of the process.
    public func runScheduler() async {
        while !Task.isCancelled {
            await check()
            try? await Task.sleep(for: PaceAlertSender.checkInterval)
        }
    }

    // MARK: Counting

    /// One turned-away request. `address` is from `clientAddress(_:)`; `path` is the path alone, never the query.
    func record(_ kind: Kind, address: String, path: String) async {
        await loadOnce()
        let now = clock()
        let today = ConnectionAlerts.day(now)
        if log.days.first?.day != today { log.days.insert(Day(day: today, noToken: 0, wrongToken: 0, sources: []), at: 0) }
        var day = log.days[0]
        let wrong = kind == .wrongToken
        if wrong { day.wrongToken += 1 } else { day.noToken += 1 }
        let shown = String(path.prefix(100))
        var index = day.sources.firstIndex { $0.address == address }
        if index == nil {
            if day.sources.count >= Self.maxSources - 1 { index = day.sources.firstIndex { $0.address == Self.othersAddress } }
            if index == nil {
                let name = day.sources.count >= Self.maxSources - 1 ? Self.othersAddress : address
                day.sources.append(Source(address: name, noToken: 0, wrongToken: 0, lastSeen: now, lastPath: shown))
                index = day.sources.count - 1
            }
        }
        if let i = index {
            if wrong { day.sources[i].wrongToken += 1 } else { day.sources[i].noToken += 1 }
            day.sources[i].lastSeen = now
            day.sources[i].lastPath = shown
        }
        log.days[0] = day
        log.days = Array(log.days.prefix(Self.keepDays))
        if wrong {
            log.unannounced += 1
            if loggedToday.day != today { loggedToday = (today, []) }
            if loggedToday.addresses.insert(address).inserted { logger.warning("API request with a wrong token from \(address) (\(shown))") }
        }
        dirty = true
    }

    /// Where a request came from, as the proxy in front reported it.
    static func clientAddress(_ headers: HTTPFields) -> String {
        if let real = headers[HTTPField.Name("X-Real-IP")!]?.trimmingCharacters(in: .whitespaces), !real.isEmpty { return String(real.prefix(64)) }
        if let forwarded = headers[HTTPField.Name("X-Forwarded-For")!]?.split(separator: ",").first?.trimmingCharacters(in: .whitespaces),
           !forwarded.isEmpty { return String(forwarded.prefix(64)) }
        return unknownAddress
    }

    /// A bearer token with something in it is a wrong token; no header, or another scheme (Basic, from a scanner's
    /// password list), is no token.
    static func kind(_ headers: HTTPFields) -> Kind {
        guard let sent = headers[.authorization], sent.hasPrefix("Bearer "),
              !sent.dropFirst(7).trimmingCharacters(in: .whitespaces).isEmpty else { return .noToken }
        return .wrongToken
    }

    // MARK: Reading

    /// The saved days, most recent first.
    public func snapshot() async -> Log {
        await loadOnce()
        return log
    }

    // MARK: Saving and the push

    /// Saves what changed, then pushes when a wrong token came in since the last push and a day has passed.
    func check() async {
        await loadOnce()
        let now = clock()
        if log.unannounced > 0, log.lastAlertAt.map({ now.timeIntervalSince($0) >= Self.alertEvery }) ?? true {
            await announce(now: now)
        }
        if dirty {
            do {
                try await store.saveSetting(Self.settingKey, HTTP.encoder.encode(log))
                dirty = false
            } catch {
                logger.error("access watch: couldn't save the counts: \(error)")
            }
        }
    }

    private func announce(now: Date) async {
        guard await push.credentials() != nil else { return }
        guard let devices = try? await morning.devices() else { return }
        // Any phone that takes a notification from the server, in its daytime; the rest wait for the next check.
        let awake = devices.filter { ($0.enabled || $0.paceAlerts?.any == true) && PaceAlertSender.awake($0, now: now) }
        guard !awake.isEmpty else { return }
        let alert = Self.notification(count: log.unannounced, addresses: Self.recentWrongAddresses(log), now: now)
        var sent = false
        for device in awake {
            let (outcome, _) = await push.send(alert, to: device.token, environment: device.environment, now: now)
            if case .sent = outcome { sent = true } else if case let .failed(message) = outcome { logger.error("access alert failed: \(message)") }
        }
        guard sent else { return }
        logger.info("access alert sent: \(log.unannounced) wrong-token requests")
        log.unannounced = 0
        log.lastAlertAt = now
        dirty = true
    }

    /// The addresses that sent a wrong token, most recent first, over the days kept.
    static func recentWrongAddresses(_ log: Log) -> [String] {
        var seen: [String] = []
        for source in log.days.flatMap(\.sources).filter({ $0.wrongToken > 0 }).sorted(by: { $0.lastSeen > $1.lastSeen })
        where !seen.contains(source.address) { seen.append(source.address) }
        return seen
    }

    static func notification(count: Int, addresses: [String], now: Date) -> APNsClient.Alert {
        let requests = count == 1 ? "A request" : "\(count) requests"
        let from = switch addresses.count {
        case 0: ""
        case 1: " from \(addresses[0])"
        default: " from \(addresses[0]) and \(addresses.count - 1) more"
        }
        return APNsClient.Alert(title: "A wrong API token was tried",
                                body: "\(requests) reached your server\(from) with a token that isn't its own. If that wasn't one of your devices, change the API token. The dashboard's Settings has the details.",
                                collapseID: threadID, threadID: threadID, userInfo: [:], expiration: now.addingTimeInterval(24 * 3600))
    }

    private func loadOnce() async {
        guard !loaded else { return }
        loaded = true
        if let data = try? await store.setting(Self.settingKey), let saved = try? HTTP.decoder.decode(Log.self, from: data) {
            // Merged, in case requests were counted before the saved log came back.
            var merged = saved
            for day in log.days.reversed() {
                if let i = merged.days.firstIndex(where: { $0.day == day.day }) {
                    merged.days[i].noToken += day.noToken
                    merged.days[i].wrongToken += day.wrongToken
                    merged.days[i].sources = day.sources + merged.days[i].sources.filter { s in !day.sources.contains { $0.address == s.address } }
                } else { merged.days.insert(day, at: 0) }
            }
            merged.unannounced += log.unannounced
            log = merged
        }
    }
}
