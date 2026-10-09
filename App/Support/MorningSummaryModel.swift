import BackgroundTasks
import BudgetKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// The morning summary on this phone: yesterday's spending at the time you pick (9:30 to start), wherever the phone is. The server sends it (APNs);
/// the phone's part is the permission, the device token, and telling the server its time zone — on turning it on,
/// whenever the app comes forward, when the clock's zone changes, and on background refresh — so a trip moves it.
@MainActor @Observable
final class MorningSummaryModel {
    static let shared = MorningSummaryModel()
    static let enabledKey = "morningSummary.enabled"
    static let timeKey = "morningSummary.minuteOfDay"
    static let refreshTaskID = (Bundle.main.bundleIdentifier ?? "budget") + ".morning-summary"
    /// 9:30, as minutes after midnight.
    static let defaultTime = 9 * 60 + 30
    static let paceKey = "paceAlerts.choice"
    static let paceActiveKey = "paceAlerts.active"

    /// Set at launch; the summary needs its server, and a tap opens its Activity.
    weak var app: AppModel?
    private(set) var enabled = UserDefaults.standard.bool(forKey: MorningSummaryModel.enabledKey)
    /// When it arrives, as minutes after midnight in whatever zone the phone is in.
    private(set) var minuteOfDay = UserDefaults.standard.object(forKey: MorningSummaryModel.timeKey) as? Int ?? MorningSummaryModel.defaultTime
    private(set) var status: DeviceStatus?
    private(set) var problem: String?
    private(set) var working = false
    /// iOS notifications turned off for Budget after the summary was turned on.
    private(set) var blockedInSettings = false
    private var token: String?
    private var waiting: [CheckedContinuation<String, any Error>] = []
    /// A tapped summary's day, until there's an app to open it in.
    private var pendingDay: String?
    /// Which pace alerts this phone wants. Until the person chooses, the everyday budget on and the rest off — sent
    /// with the first registration, so turning the morning summary on brings the everyday alert with it.
    private(set) var pace = MorningSummaryModel.savedPace()
    /// Whether the server holds a pace-alert choice with anything on for this phone (what it said last).
    private(set) var paceActive = UserDefaults.standard.bool(forKey: MorningSummaryModel.paceActiveKey)
    /// The server took a choice but kept none: it's older than 0.5.0.
    private(set) var paceUnsupported = false
    /// A tapped pace alert's payload, until there's an app to open it in.
    private var pendingPace: [String: String]?

    private init() {}

    /// Only with a server of your own: the demo has nothing to send from.
    var available: Bool { app.map { !$0.isDemo && $0.api is any MorningSummaryAPI } ?? false }
    private var api: (any MorningSummaryAPI)? { app?.api as? any MorningSummaryAPI }

    // MARK: Turning it on and off

    func setEnabled(_ on: Bool) async {
        problem = nil
        working = true
        defer { working = false }
        if on {
            guard await requestPermission() else { return }
        }
        do {
            status = try await register(enabled: on)
            save(on)
            if on { scheduleRefresh() }
        } catch {
            // Off stays off here even if the server didn't hear it; it's told again the next time the app runs.
            if !on { save(false) }
            problem = Self.describe(error)
        }
    }

    /// Tells the server where the phone is now. Quiet: a failure waits for the next time.
    func report() async {
        guard enabled || paceActive, available else { return }
        await refreshPermission()
        if let status = try? await register(enabled: enabled) { self.status = status }
    }

    /// Asks iOS to let Budget notify, saying what to do when it won't.
    private func requestPermission() async -> Bool {
        // No sound: a summary or a heads-up, not an alarm.
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge])) ?? false
        if !granted { problem = "Notifications are off for Budget. Turn them on in iOS Settings → Notifications → Budget." }
        return granted
    }

    /// A new time for the summary; the server hears it straight away.
    func setTime(hour: Int, minute: Int) async {
        let chosen = hour * 60 + minute
        guard chosen != minuteOfDay else { return }
        minuteOfDay = chosen
        UserDefaults.standard.set(chosen, forKey: Self.timeKey)
        guard enabled else { return }
        problem = nil
        do { status = try await register(enabled: true) } catch { problem = Self.describe(error) }
    }

    func sendTest() async {
        guard let api else { return }
        problem = nil
        working = true
        defer { working = false }
        do {
            status = try await api.sendTestSummary(token: try await deviceToken())
        } catch {
            problem = Self.describe(error)
        }
    }

    func refreshPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        blockedInSettings = (enabled || paceActive) && settings.authorizationStatus == .denied
    }

    /// Registers the phone: the summary on or off, where it is, and `choice` of pace alerts (the saved one by default).
    private func register(enabled: Bool, pace choice: PaceAlertPreferences? = nil) async throws -> DeviceStatus {
        guard let api else { throw BudgetAPIError.rejected("The morning summary needs your own server.") }
        let choice = choice ?? pace
        let registration = DeviceRegistration(token: try await deviceToken(), environment: Self.environment,
                                              timeZone: TimeZone.current.identifier, enabled: enabled,
                                              hour: minuteOfDay / 60, minute: minuteOfDay % 60, paceAlerts: choice)
        let status = try await api.registerDevice(registration)
        paceActive = status.paceAlerts?.any ?? false
        paceUnsupported = status.paceAlerts == nil && choice.any
        UserDefaults.standard.set(paceActive, forKey: Self.paceActiveKey)
        return status
    }

    private func save(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
    }

    static func describe(_ error: any Error) -> String {
        if case .notFound = error as? BudgetAPIError { return "Your server doesn't send notifications yet. Update it to 0.4.0 or later." }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: The device token

    /// This launch's APNs token, asking iOS for it the first time. iOS says nothing at all while it can't reach Apple
    /// (no connection, a network that blocks it), so after a while the wait ends in words.
    private func deviceToken() async throws -> String {
        if let token { return token }
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
            guard waiting.count == 1 else { return }
            UIApplication.shared.registerForRemoteNotifications()
            Task {
                try? await Task.sleep(for: .seconds(20))
                self.giveUpWaiting()
            }
        }
    }

    private func giveUpWaiting() {
        let resumed = waiting
        waiting = []
        resumed.forEach { $0.resume(throwing: BudgetAPIError.rejected("iOS hasn't given Budget a notification token yet — it needs to reach Apple's push service. Try again on a connection that isn't blocking it.")) }
    }

    /// Simulator only: a token to use instead of APNs's (`-pushToken`), so UI tests can register without Apple.
    func useToken(_ hex: String) { token = hex }

    func didRegister(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        token = hex
        let resumed = waiting
        waiting = []
        resumed.forEach { $0.resume(returning: hex) }
    }

    func didFailToRegister(_ error: any Error) {
        let resumed = waiting
        waiting = []
        resumed.forEach { $0.resume(throwing: BudgetAPIError.rejected("iOS didn't give Budget a notification token: \(error.localizedDescription)")) }
    }

    /// Development builds (run from Xcode) get sandbox tokens; TestFlight and App Store builds, production ones. The
    /// provisioning profile says which; an App Store build has none. The server also retries the other one.
    static let environment: DeviceRegistration.Environment = {
        #if targetEnvironment(simulator)
        return .sandbox
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return .production }
        let text = String(decoding: data, as: UTF8.self)
        guard let key = text.range(of: "<key>aps-environment</key>") else { return .production }
        return text[key.upperBound...].prefix(80).contains("development") ? .sandbox : .production
        #endif
    }()

    // MARK: Opening a summary

    /// A tapped summary opens Activity on the day it sums up.
    func open(day: String) {
        guard let app else {
            pendingDay = day
            return
        }
        pendingDay = nil
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return }
        app.showsSettings = false
        app.showsOpportunity = false
        app.showActivity(on: date)
    }

    func attach(_ app: AppModel) {
        self.app = app
        if let pendingDay { open(day: pendingDay) }
        if let pendingPace { openPace(pendingPace) }
    }

    // MARK: Pace alerts

    /// Whether this phone gets pace alerts of `kind`: chosen, and the server holding the choice.
    func wantsPace(_ kind: PaceAlert.Kind) -> Bool { paceActive && pace.wants(kind) }

    /// Turns one kind of pace alert on or off. On a phone that gets none yet, it starts from all off, so what the
    /// switches showed is what it gets.
    func setPace(_ kind: PaceAlert.Kind, _ on: Bool) async {
        problem = nil
        working = true
        defer { working = false }
        var next = paceActive ? pace : PaceAlertPreferences(everyday: false)
        switch kind {
        case .everyday: next.everyday = on
        case .category: next.categories = on
        case .merchant: next.merchants = on
        case .unknown: return
        }
        if on { guard await requestPermission() else { return } }
        do {
            status = try await register(enabled: enabled, pace: next)
            pace = next
            if let data = try? JSONEncoder().encode(next) { UserDefaults.standard.set(data, forKey: Self.paceKey) }
            if paceActive { scheduleRefresh() }
        } catch {
            problem = Self.describe(error)
        }
    }

    static func savedPace() -> PaceAlertPreferences {
        UserDefaults.standard.data(forKey: paceKey).flatMap { try? JSONDecoder().decode(PaceAlertPreferences.self, from: $0) } ?? .defaults
    }

    /// A tapped pace alert opens what it's about: the month's budget, a category in that month, or a merchant's charges.
    func openPace(_ payload: [String: String]) {
        guard let app else {
            pendingPace = payload
            return
        }
        pendingPace = nil
        app.showsSettings = false
        app.showsOpportunity = false
        let month = payload["month"]
        switch (payload["to"], payload["id"]) {
        case let ("category", id?): app.route(Navigate(screen: .spending, categoryID: id, month: month))
        case let ("merchant", name?): app.route(Navigate(screen: .activity, search: name))
        default: app.route(Navigate(screen: .spending, month: month))
        }
    }

    /// The same, from a pace alert listed in the app.
    func open(_ alert: PaceAlert, month: String) {
        switch alert.link {
        case let .category(id): openPace(["to": "category", "id": id, "month": month])
        case let .merchant(name): openPace(["to": "merchant", "id": name, "month": month])
        default: openPace(["to": "budget", "month": month])
        }
    }

    // MARK: Background refresh

    /// A background refresh: report where the phone is, ask for the next one, and finish — all on the main thread
    /// (`AppDelegate` registers it on the main queue). Running out of time cancels the report; it still finishes.
    func handleRefresh(_ task: BGTask) {
        let work = Task { @MainActor in
            await self.report()
            self.scheduleRefresh()
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// Asks iOS for a background run in a few hours, to report the time zone if the phone has moved.
    func scheduleRefresh() {
        guard enabled || paceActive else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date().addingTimeInterval(4 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
