import BudgetKit
import Foundation
import Hummingbird
import Logging

/// Pace alerts as notifications: when the everyday budget is on pace to finish the month over, or a category target or
/// merchant cap passes 80% or is on pace to go over (`Ledger.paceAlerts`), each phone that asked for that kind hears
/// about it once that month — during the day where the phone is (9:00 to 21:00), never at night.
///
/// What went out is saved (`budget_settings` "paceAlertsSent"), so a restart doesn't send it again. An alert covers
/// the ones below it: once "on pace to go over" has gone out, "80% used" for the same target doesn't follow it.
public actor PaceAlertSender {
    private let api: LedgerBudgetAPI
    private let store: any ServerStore
    private let morning: MorningSummary
    private let push: PushSender
    private let logger: Logger
    private let clock: @Sendable () -> Date

    /// The waking hours, in the phone's zone: from 9:00 up to 21:00.
    static let awakeHours = 9..<21
    /// How often the ledger is checked. Pace moves with each sync, not by the minute.
    static let checkInterval: Duration = .seconds(10 * 60)
    /// At most this many to one phone in one check; the rest wait for the next.
    static let perCheck = 3
    static let sentKey = "paceAlertsSent"

    public init(api: LedgerBudgetAPI, store: any ServerStore, morning: MorningSummary, push: PushSender, logger: Logger,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.store = store
        self.morning = morning
        self.push = push
        self.logger = logger
        self.clock = clock
    }

    /// Checks every ten minutes for the life of the process.
    public func runScheduler() async {
        while !Task.isCancelled {
            await sendDue()
            try? await Task.sleep(for: Self.checkInterval)
        }
    }

    // MARK: Who gets what

    /// Whether it's daytime where the phone is.
    static func awake(_ device: StoredDevice, now: Date) -> Bool {
        guard let zone = TimeZone(identifier: device.timeZone) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return awakeHours.contains(calendar.component(.hour, from: now))
    }

    /// The alerts `wants` asks for that haven't gone out this month, most pressing first.
    static func due(_ report: PaceAlerts, wants: PaceAlertPreferences, sent: Set<String>) -> [PaceAlert] {
        report.alerts.filter { wants.wants($0.kind) && !sent.contains(sentID($0.id, month: report.month)) }
    }

    /// "2026-10|category:dining:used80".
    static func sentID(_ alertID: String, month: String) -> String { "\(month)|\(alertID)" }

    /// What sending `alert` marks as sent: it, and every lower threshold for the same target.
    static func marks(_ alert: PaceAlert, month: String) -> [String] {
        PaceAlert.Threshold.allCases.filter { $0 != .unknown && $0.rank <= alert.threshold.rank }
            .map { sentID("\(alert.targetKey):\($0.rawValue)", month: month) }
    }

    /// The notification. A tap opens the screen in `link` (`to`, and `id` for a category or merchant), in `month`.
    static func notification(_ alert: PaceAlert, month: String, now: Date) -> APNsClient.Alert {
        var info = ["kind": "pace", "month": month]
        switch alert.link {
        case .budget: info["to"] = "budget"
        case let .category(id): (info["to"], info["id"]) = ("category", id)
        case let .merchant(name): (info["to"], info["id"]) = ("merchant", name)
        default: break
        }
        // APNs takes a collapse id of at most 64 bytes; a long merchant name is cut, which only means two such alerts
        // in one month could replace each other on screen.
        let collapse = String(decoding: Data("pace-\(month)-\(alert.targetKey)".utf8).prefix(64), as: UTF8.self)
        return APNsClient.Alert(title: alert.title, body: alert.body, collapseID: collapse, threadID: "pace-alerts", userInfo: info,
                                expiration: now.addingTimeInterval(12 * 3600))
    }

    // MARK: Sending

    /// Sends what's due to every phone that wants it and is awake.
    func sendDue() async {
        let now = clock()
        guard let devices = try? await morning.devices() else { return }
        let listening = devices.filter { ($0.paceAlerts?.any ?? false) && Self.awake($0, now: now) }
        guard !listening.isEmpty, await push.credentials() != nil else { return }
        let report: PaceAlerts
        do { report = try await api.paceAlerts(asOf: now) } catch {
            logger.error("pace alerts: couldn't read the ledger: \(error)")
            return
        }
        var sent = await sentLog()
        let before = sent
        // Only this month and the one before are worth keeping, and only for phones still registered.
        let tokens = Set(devices.map(\.token))
        for (token, ids) in sent {
            sent[token] = tokens.contains(token) ? ids.filter { Self.recent($0, month: report.month) } : nil
        }

        for device in listening {
            let wants = device.paceAlerts ?? PaceAlertPreferences(everyday: false)
            var marked = Set(sent[device.token] ?? [])
            for alert in Self.due(report, wants: wants, sent: marked).prefix(Self.perCheck) {
                let (outcome, environment) = await push.send(Self.notification(alert, month: report.month, now: now), to: device.token,
                                                             environment: device.environment, now: now)
                if case .sent = outcome {
                    marked.formUnion(Self.marks(alert, month: report.month))
                    logger.info("pace alert sent: \(alert.kind.rawValue) \(alert.threshold.rawValue)")
                    if let environment, environment != device.environment {
                        _ = try? await morning.update(device.token) { $0.environment = environment }
                    }
                    continue
                }
                if case let .badToken(reason) = outcome {
                    // Dead for good: everything for this phone stops until it registers a new token.
                    logger.warning("pace alerts: dropped a dead device token (\(reason))")
                    _ = try? await morning.update(device.token) { d in
                        d.enabled = false
                        d.paceAlerts = nil
                        d.lastError = "APNs no longer accepts this phone's token (\(reason)). Turn notifications off and on again in Settings."
                    }
                } else if case let .failed(message) = outcome {
                    // Tried again at the next check.
                    logger.error("pace alert failed: \(message)")
                }
                break
            }
            sent[device.token] = marked.isEmpty ? nil : marked.sorted()
        }
        if sent != before { try? await store.saveSetting(Self.sentKey, HTTP.encoder.encode(sent)) }
    }

    /// Phone token → what went out to it ("2026-10|everyday:everyday:projectedOver").
    func sentLog() async -> [String: [String]] {
        (try? await store.setting(Self.sentKey)).flatMap { try? HTTP.decoder.decode([String: [String]].self, from: $0) } ?? [:]
    }

    /// Whether a sent id is from `month` or the month before it.
    static func recent(_ id: String, month: String) -> Bool {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return true }
        let previous = parts[1] == 1 ? String(format: "%04d-12", parts[0] - 1) : String(format: "%04d-%02d", parts[0], parts[1] - 1)
        return id.hasPrefix("\(month)|") || id.hasPrefix("\(previous)|")
    }
}

// MARK: - Route

func addPaceAlertRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService) {
    /// This month's pace and what's past a threshold now, as the notifications would tell it.
    router.get("/v1/alerts/pace") { _, _ in try HTTP.json(try await service.api.paceAlerts()) }
}
