import BudgetKit
import Foundation
import Logging

/// One phone that asked for the morning summary, as the server keeps it (JSON in `budget_settings` under "devices").
struct StoredDevice: Codable, Hashable, Sendable {
    var token: String
    var environment: DeviceRegistration.Environment
    /// Where the phone last said it was; the summary goes out at `hour`:`minute` there.
    var timeZone: String
    var enabled: Bool
    var hour: Int
    var minute: Int
    /// The phone's local date the last summary went out on.
    var lastSentDay: String?
    var lastAttempt: Date?
    var lastError: String?
    var updatedAt: Date
    /// The pace alerts this phone asked for; nil for none (an app before them never asks).
    var paceAlerts: PaceAlertPreferences?
    /// Pushes about bank connections; nil (any phone that registered) means on, only false turns them off.
    var connectionAlerts: Bool? = nil
}

/// Yesterday's spending, sent to each phone at 9:30 in whatever time zone it last reported — so it follows a trip. The
/// phone reports its zone whenever the app runs (`POST /v1/devices`); the server checks every minute who is due.
///
/// A deploy restarts the server, so what was sent is saved (`lastSentDay`), and a phone is still due for three hours
/// after its time: a restart at 9:31 doesn't skip the day, and one that was down all morning doesn't notify at 4pm.
public actor MorningSummary {
    private let api: LedgerBudgetAPI
    private let store: any ServerStore
    private let sync: SyncService
    private let settings: ServerSettings
    private let push: PushSender
    private let logger: Logger
    private let clock: @Sendable () -> Date

    /// How long after its time a phone is still due, and how long a failed attempt waits before the next.
    static let graceMinutes = 180
    static let retryInterval: TimeInterval = 15 * 60
    /// A sync older than this runs again first, so the summary counts the latest charges.
    static let freshSync: TimeInterval = 2 * 3600
    static let keptDigests = 14

    /// Device writes take turns (`oneAtATime`).
    private var writingDevices = false
    private var waitingDeviceWriters: [CheckedContinuation<Void, Never>] = []

    public init(api: LedgerBudgetAPI, store: any ServerStore, sync: SyncService, settings: ServerSettings, push: PushSender,
                logger: Logger, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.store = store
        self.sync = sync
        self.settings = settings
        self.push = push
        self.logger = logger
        self.clock = clock
    }

    // MARK: Devices

    func devices() async throws -> [StoredDevice] {
        try await store.setting("devices").map { try HTTP.decoder.decode([StoredDevice].self, from: $0) } ?? []
    }

    private func save(_ devices: [StoredDevice]) async throws {
        try await store.saveSetting("devices", HTTP.encoder.encode(devices))
    }

    func update(_ token: String, _ change: (inout StoredDevice) -> Void) async throws -> StoredDevice {
        try await oneAtATime {
            var all = try await devices()
            guard let index = all.firstIndex(where: { $0.token == token }) else { throw BudgetAPIError.notFound }
            change(&all[index])
            try await save(all)
            return all[index]
        }
    }

    /// Writes to the device list take turns. Each reads the whole list, changes one phone and saves it all back, and
    /// two that overlap across those awaits (the morning summary marking a day sent while the pace-alert sender drops a
    /// dead token, or a phone registering) would lose one's change; losing `lastSentDay` would send the summary twice.
    private func oneAtATime<T>(_ body: () async throws -> T) async throws -> T {
        if writingDevices { await withCheckedContinuation { waitingDeviceWriters.append($0) } } else { writingDevices = true }
        defer { if waitingDeviceWriters.isEmpty { writingDevices = false } else { waitingDeviceWriters.removeFirst().resume() } }
        return try await body()
    }

    public func register(_ r: DeviceRegistration) async throws -> DeviceStatus {
        let token = r.token.filter(\.isHexDigit).lowercased()
        guard token.count >= 32 else { throw BudgetAPIError.rejected("That isn't an APNs device token.") }
        guard TimeZone(identifier: r.timeZone) != nil else { throw BudgetAPIError.rejected("“\(r.timeZone)” isn't a time zone.") }
        guard (0...23).contains(r.hour), (0...59).contains(r.minute) else { throw BudgetAPIError.rejected("The time must be a valid hour and minute.") }
        let device = try await oneAtATime { try await registered(token, r) }
        return await status(device)
    }

    private func registered(_ token: String, _ r: DeviceRegistration) async throws -> StoredDevice {
        var all = try await devices()
        var device = all.first { $0.token == token }
            ?? StoredDevice(token: token, environment: r.environment, timeZone: r.timeZone, enabled: r.enabled, hour: r.hour, minute: r.minute, updatedAt: clock())
        device.environment = r.environment
        device.timeZone = r.timeZone
        device.enabled = r.enabled
        (device.hour, device.minute) = (r.hour, r.minute)
        // An app that doesn't send a choice (one from before pace alerts) leaves the last one standing.
        if let pace = r.paceAlerts { device.paceAlerts = pace }
        if let connections = r.connectionAlerts { device.connectionAlerts = connections }
        device.updatedAt = clock()
        all.removeAll { $0.token == token }
        all.append(device)
        try await save(all)
        return device
    }

    func status(_ d: StoredDevice) async -> DeviceStatus {
        DeviceStatus(enabled: d.enabled, timeZone: d.timeZone, hour: d.hour, minute: d.minute, lastSentDay: d.lastSentDay, lastError: d.lastError,
                     pushConfigured: await credentials() != nil, paceAlerts: d.paceAlerts,
                     connectionAlerts: d.connectionAlerts)
    }

    // MARK: Schedule

    /// Checks every minute for the life of the process.
    public func runScheduler() async {
        while !Task.isCancelled {
            await sendDue()
            try? await Task.sleep(for: .seconds(60))
        }
    }

    /// Sends to every phone that's due now.
    func sendDue() async {
        let now = clock()
        guard let all = try? await devices() else { return }
        for device in all {
            guard let due = Self.due(device, now: now) else { continue }
            await deliver(to: device.token, day: due.yesterday, marking: due.today, waitForBank: !Self.lastChance(device, now: now))
        }
    }

    /// Whether `device` should get a summary now: past its time today (in its own zone) but within the grace window,
    /// not sent yet today, and not tried in the last few minutes. `yesterday` is the day to sum up. A later date than
    /// the last one sent is needed, so crossing the date line westward doesn't repeat a day.
    static func due(_ device: StoredDevice, now: Date) -> (today: String, yesterday: String)? {
        guard device.enabled, let zone = TimeZone(identifier: device.timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minutes = parts.hour! * 60 + parts.minute!
        let time = device.hour * 60 + device.minute
        guard minutes >= time, minutes < time + graceMinutes else { return nil }
        let today = day(now, calendar)
        if let last = device.lastSentDay, today <= last { return nil }
        if let tried = device.lastAttempt, now.timeIntervalSince(tried) < retryInterval { return nil }
        return (today, day(calendar.date(byAdding: .day, value: -1, to: now)!, calendar))
    }

    /// Whether this is the last try in the window: after it the day is skipped, so it goes out even if the bank hasn't
    /// sent the day yet (saying so).
    static func lastChance(_ device: StoredDevice, now: Date) -> Bool {
        guard let zone = TimeZone(identifier: device.timeZone) else { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let minutes = parts.hour! * 60 + parts.minute!
        return minutes + Int(retryInterval / 60) >= device.hour * 60 + device.minute + graceMinutes
    }

    static func day(_ date: Date, _ calendar: Calendar) -> String {
        let p = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", p.year!, p.month!, p.day!)
    }

    // MARK: Sending

    /// Yesterday in `token`'s time zone, sent now — the app's "Send one now". The day isn't marked as sent.
    public func sendTest(token: String) async throws -> DeviceStatus {
        let token = token.filter(\.isHexDigit).lowercased()
        guard let device = try await devices().first(where: { $0.token == token }) else { throw BudgetAPIError.notFound }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: device.timeZone) ?? .current
        let yesterday = Self.day(calendar.date(byAdding: .day, value: -1, to: clock())!, calendar)
        let after = await deliver(to: token, day: yesterday, marking: nil)
        if let error = after.lastError { throw BudgetAPIError.rejected(error) }
        return await status(after)
    }

    /// Writes (or reuses) the summary of `day` and sends it; records the outcome on the device. `marking` is the local
    /// date to record as sent, nil for a test. With `waitForBank`, a day the bank hasn't sent yet isn't sent either: the
    /// attempt is recorded and the next one, 15 minutes on, looks again.
    @discardableResult
    func deliver(to token: String, day: String, marking today: String?, waitForBank: Bool = false) async -> StoredDevice {
        let now = clock()
        var outcome: APNsClient.Outcome
        var sentWith: DeviceRegistration.Environment?
        do {
            guard await credentials() != nil else { throw BudgetAPIError.rejected(PushSender.noKey) }
            await syncIfStale(now: now)
            let digest = try await digest(day: day)
            if waitForBank, !digest.received {
                logger.info("morning summary for \(day) waits: the bank hasn't sent the day yet")
                return (try? await update(token) { $0.lastAttempt = now }) ?? StoredDevice(token: token, environment: .production, timeZone: "UTC",
                                                                                           enabled: false, hour: 9, minute: 30, updatedAt: now)
            }
            let alert = APNsClient.Alert(title: digest.title("Yesterday"), body: digest.summary, collapseID: "summary-\(day)",
                                         threadID: "morning-summary", userInfo: ["day": day], expiration: now.addingTimeInterval(6 * 3600))
            guard let device = try await devices().first(where: { $0.token == token }) else { throw BudgetAPIError.notFound }
            // A token from the other environment is tried once on the other host (`PushSender.send`).
            (outcome, sentWith) = await push.send(alert, to: token, environment: device.environment, now: now)
        } catch {
            outcome = .failed((error as? BudgetAPIError)?.localizedDescription ?? String(describing: error))
        }

        let result = outcome
        let environment = sentWith
        let updated = try? await update(token) { device in
            device.lastAttempt = now
            switch result {
            case .sent:
                device.lastError = nil
                if let today { device.lastSentDay = today }
                if let environment { device.environment = environment }
            case let .badToken(reason):
                // Dead for good: stop until the phone registers a new token.
                device.enabled = false
                device.paceAlerts = nil
                device.lastError = "APNs no longer accepts this phone's token (\(reason)). Turn the summary off and on again in Settings."
            case let .failed(message):
                device.lastError = message
            }
        }
        switch result {
        case .sent: logger.info("morning summary for \(day) sent")
        case let .badToken(reason): logger.warning("morning summary: dropped a dead device token (\(reason))")
        case let .failed(message): logger.error("morning summary for \(day) failed: \(message)")
        }
        return updated ?? StoredDevice(token: token, environment: .production, timeZone: "UTC", enabled: false, hour: 9, minute: 30,
                                       lastError: "This phone isn't registered.", updatedAt: now)
    }

    /// The APNs key, key id, team and topic, when all are set (`PushSender`).
    func credentials() async -> APNsClient.Credentials? { await push.credentials() }

    private func syncIfStale(now: Date) async {
        let links = ((try? await store.links()) ?? []).filter { $0.status != .needsReauth }
        guard !links.isEmpty else { return }
        let last = links.compactMap(\.lastSync).max() ?? .distantPast
        if now.timeIntervalSince(last) > Self.freshSync { _ = await sync.syncAll(trigger: .morningCatchUp) }
    }

    // MARK: Digests

    /// The summary of `day`, reusing the saved one while its facts hold (so the model writes each day once), and
    /// saving what's new. The last two weeks are kept.
    public func digest(day: String) async throws -> DayDigest {
        var saved = (try? await store.setting("digests")).flatMap { try? HTTP.decoder.decode([String: DayDigest].self, from: $0) } ?? [:]
        let digest = try await api.dayDigest(day: day, reuse: saved[day])
        if let problem = digest.writerProblem { logger.warning("morning summary for \(day) uses the template: \(problem)") }
        if saved[day] != digest {
            saved[day] = digest
            for old in saved.keys.sorted().dropLast(Self.keptDigests) { saved[old] = nil }
            try? await store.saveSetting("digests", HTTP.encoder.encode(saved))
        }
        return digest
    }
}
