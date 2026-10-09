import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import NIOCore
import Testing

/// The demo ledger on September 29 (day 29 of 30) with a savings plan that leaves an everyday budget of $1,000, so the
/// everyday budget is over as well as Dining, Transport and Subscriptions past their targets.
enum PaceFixture {
    static let seeded = PushFixture.at(10, 0)

    static func state() async throws -> LedgerState {
        let calendar = TestServer.config().calendar
        var state = LedgerBudgetAPI.demoState(now: seeded, calendar: calendar)
        let ledger = LedgerBudgetAPI(state: state, calendar: calendar, clock: { seeded }, chatModel: nil, decisions: DecisionRouting(), persistence: nil,
                                     deployment: DeploymentInfo(endpoint: "test", version: "test", sources: [], institutions: []))
        let flex = try await ledger.overview().flex
        state.monthlySavings = flex.plannedSavings + flex.flexNumber - Money(1_000)
        return state
    }

    static func service(apns: FakeAPNs, clock: TestClock, store: MemoryStore? = nil) async throws -> (some ApplicationProtocol, BudgetService, MemoryStore) {
        let store = if let store { store } else { MemoryStore(ledger: try await state()) }
        let (service, _) = try await BudgetServerApp.makeService(config: TestServer.config(), store: store, logger: Logger(label: "test"),
                                                                 pushTransport: apns, clock: { clock.now })
        try await BudgetServerApp.prepare(service)
        let oneLine = PushFixture.key.pemRepresentation.replacingOccurrences(of: "\n", with: "")
        try await service.settings.update(["apnsKey": oneLine, "apnsKeyID": "ABC123DEFG", "apnsTeamID": "TEAMID1234", "apnsTopic": "com.example.budget"])
        return (Application(router: buildRouter(service)), service, store)
    }

    /// A phone with the morning summary off and pace alerts as given (`nil`: an app from before them).
    static func register(_ pace: String?, zone: String = "America/Los_Angeles") -> ByteBuffer {
        let field = pace.map { #","paceAlerts":\#($0)"# } ?? ""
        return TestServer.body(#"{"token":"\#(PushFixture.token)","environment":"sandbox","timeZone":"\#(zone)","enabled":false,"hour":9,"minute":30\#(field)}"#)
    }

    static func registerOver(_ app: some ApplicationProtocol, _ pace: String?, zone: String = "America/Los_Angeles") async throws -> DeviceStatus {
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/devices", method: .post, headers: TestServer.auth, body: register(pace, zone: zone)) { response in
                #expect(response.status == .ok)
                return try RemoteBudgetAPI.decoder.decode(DeviceStatus.self, from: Data(response.body.readableBytesView))
            }
        }
    }

    static func alerts(_ apns: FakeAPNs) -> [(title: String, info: [String: String])] {
        apns.sent.map { sent in
            let alert = (sent.body["aps"] as? [String: Any]).flatMap { $0["alert"] as? [String: String] }
            var info: [String: String] = [:]
            for (key, value) in sent.body where key != "aps" { info[key] = value as? String }
            return (alert?["title"] ?? "", info)
        }
    }
}

@Suite("Pace alerts: when they go out")
struct PaceAlertScheduleTests {
    @Test("Only in the phone's daytime: from 9:00 up to 21:00 where it is")
    func awake() {
        let la = PushFixture.device()
        #expect(!PaceAlertSender.awake(la, now: PushFixture.at(8, 59)))
        #expect(PaceAlertSender.awake(la, now: PushFixture.at(9, 0)))
        #expect(PaceAlertSender.awake(la, now: PushFixture.at(20, 59)))
        #expect(!PaceAlertSender.awake(la, now: PushFixture.at(21, 0)))
        // 22:00 in Los Angeles is mid-afternoon in Tokyo.
        #expect(PaceAlertSender.awake(PushFixture.device("Asia/Tokyo"), now: PushFixture.at(22, 0)))
        #expect(!PaceAlertSender.awake(PushFixture.device("Not/AZone"), now: PushFixture.at(12, 0)))
    }

    @Test("Once per target per threshold per month; a higher one covers the lower, a new month starts over")
    func once() {
        let status = PaceStatus(spent: Money(400), limit: Money(450), projected: Money(500), perDayLeft: nil, usedPercent: 89)
        let used = PaceAlert(kind: .category, threshold: .used80, targetID: "dining", name: "Dining", status: status, title: "", body: "", link: .category("dining"))
        var over = used
        over.threshold = .projectedOver
        let all = PaceAlertPreferences(everyday: true, categories: true, merchants: true)
        let october = PaceAlerts(month: "2026-10", day: 12, daysInMonth: 31, projecting: true, everyday: nil, alerts: [over])
        #expect(PaceAlertSender.due(october, wants: all, sent: []).map(\.id) == ["category:dining:projectedOver"])
        let marks = Set(PaceAlertSender.marks(over, month: "2026-10"))
        #expect(marks == ["2026-10|category:dining:used80", "2026-10|category:dining:projectedOver"])
        #expect(PaceAlertSender.due(october, wants: all, sent: marks).isEmpty)
        // After "on pace to go over", "80% used" for the same target doesn't follow.
        let later = PaceAlerts(month: "2026-10", day: 20, daysInMonth: 31, projecting: true, everyday: nil, alerts: [used])
        #expect(PaceAlertSender.due(later, wants: all, sent: marks).isEmpty)
        // "80% used" first doesn't cover "on pace to go over".
        #expect(PaceAlertSender.due(october, wants: all, sent: Set(PaceAlertSender.marks(used, month: "2026-10"))).count == 1)
        // November: the same target can alert again.
        let november = PaceAlerts(month: "2026-11", day: 12, daysInMonth: 30, projecting: true, everyday: nil, alerts: [over])
        #expect(PaceAlertSender.due(november, wants: all, sent: marks).count == 1)
        // Off for categories: nothing.
        #expect(PaceAlertSender.due(october, wants: .defaults, sent: []).isEmpty)
        // What's kept: this month and last.
        #expect(PaceAlertSender.recent("2026-10|x", month: "2026-11") && PaceAlertSender.recent("2025-12|x", month: "2026-01"))
        #expect(!PaceAlertSender.recent("2026-09|x", month: "2026-11"))
    }

    @Test("The notification says what a tap opens, groups with the others and replaces itself rather than stacking")
    func payload() {
        let status = PaceStatus(spent: Money(400), limit: Money(450), projected: Money(500), perDayLeft: nil, usedPercent: 89)
        let alert = PaceAlert(kind: .category, threshold: .used80, targetID: "dining", name: "Dining", status: status, title: "Dining: 89% of its target",
                              body: "Dining has used $400.", link: .category("dining"))
        let n = PaceAlertSender.notification(alert, month: "2026-10", now: PushFixture.at(10, 0))
        #expect(n.userInfo == ["kind": "pace", "month": "2026-10", "to": "category", "id": "dining"])
        #expect(n.threadID == "pace-alerts" && n.collapseID == "pace-2026-10-category:dining")
        var long = alert
        (long.kind, long.targetID, long.link) = (.merchant, String(repeating: "Very Long Merchant ", count: 6), .merchant("x"))
        #expect(PaceAlertSender.notification(long, month: "2026-10", now: .now).collapseID.utf8.count <= 64)
        var everyday = alert
        (everyday.kind, everyday.targetID, everyday.link) = (.everyday, "everyday", .budget)
        #expect(PaceAlertSender.notification(everyday, month: "2026-10", now: .now).userInfo == ["kind": "pace", "month": "2026-10", "to": "budget"])
    }
}

@Suite("Pace alerts: end to end")
struct PaceAlertRouteTests {
    @Test("Everyday on by default: at night nothing; from 9:00 the everyday alert, once, to the sandbox, with where a tap goes")
    func everydayByDefault() async throws {
        let apns = FakeAPNs()
        let clock = TestClock(PushFixture.at(21, 30, day: 28))
        let (app, service, _) = try await PaceFixture.service(apns: apns, clock: clock)
        let status = try await PaceFixture.registerOver(app, "{}")
        #expect(status.paceAlerts == .defaults && !status.enabled)
        await service.pace.sendDue()
        clock.set(PushFixture.at(8, 59))
        await service.pace.sendDue()
        #expect(apns.sent.isEmpty)

        clock.set(PushFixture.at(9, 0))
        await service.pace.sendDue()
        await service.pace.sendDue()
        let sent = PaceFixture.alerts(apns)
        #expect(sent.count == 1)
        #expect(sent.first?.title == "Everyday is over budget")
        #expect(sent.first?.info == ["kind": "pace", "month": "2026-09", "to": "budget"])
        #expect(apns.sent.first?.host == "api.sandbox.push.apple.com")
        // The morning summary is off, and stays unsent.
        #expect(try await service.morning.devices().first?.lastSentDay == nil)
    }

    @Test("Categories and caps when turned on: the most pressing first, a few per check, and none sent twice — not even after a restart")
    func categoriesAndRestart() async throws {
        let apns = FakeAPNs()
        let clock = TestClock(PushFixture.at(12, 0))
        let (app, service, store) = try await PaceFixture.service(apns: apns, clock: clock)
        _ = try await PaceFixture.registerOver(app, #"{"everyday":false,"categories":true,"merchants":true}"#)
        let expected = try await service.api.paceAlerts(asOf: clock.now).alerts.filter { $0.kind == .category }
        #expect(expected.count >= 2)
        await service.pace.sendDue()
        #expect(apns.sent.count == min(expected.count, PaceAlertSender.perCheck))
        for _ in 0..<3 { await service.pace.sendDue() }
        let sent = PaceFixture.alerts(apns)
        #expect(sent.map(\.title) == expected.map(\.title))
        #expect(sent.allSatisfy { $0.info["to"] == "category" && $0.info["id"] != nil })

        // A restart: the same store, a new process.
        let (_, again, _) = try await PaceFixture.service(apns: apns, clock: clock, store: store)
        await again.pace.sendDue()
        #expect(apns.sent.count == sent.count)
    }

    @Test("An app from before pace alerts gets none, and a later registration without a choice keeps the last one")
    func olderApp() async throws {
        let apns = FakeAPNs()
        let clock = TestClock(PushFixture.at(12, 0))
        let (app, service, _) = try await PaceFixture.service(apns: apns, clock: clock)
        let old = try await PaceFixture.registerOver(app, nil)
        #expect(old.paceAlerts == nil)
        await service.pace.sendDue()
        #expect(apns.sent.isEmpty)

        _ = try await PaceFixture.registerOver(app, #"{"everyday":true}"#)
        let kept = try await PaceFixture.registerOver(app, nil, zone: "Asia/Tokyo")
        #expect(kept.paceAlerts == .defaults && kept.timeZone == "Asia/Tokyo")
        // Noon in Los Angeles is 4am in Tokyo: it waits for the phone's morning.
        await service.pace.sendDue()
        #expect(apns.sent.isEmpty)
        clock.set(PushFixture.at(17, 0))
        await service.pace.sendDue()
        #expect(apns.sent.count == 1)
    }

    @Test("A token APNs no longer takes stops pace alerts for that phone")
    func deadToken() async throws {
        let dead = FakeAPNs(["api.sandbox.push.apple.com": (410, #"{"reason":"Unregistered"}"#), "api.push.apple.com": (410, #"{"reason":"Unregistered"}"#)])
        let clock = TestClock(PushFixture.at(12, 0))
        let (app, service, _) = try await PaceFixture.service(apns: dead, clock: clock)
        _ = try await PaceFixture.registerOver(app, "{}")
        await service.pace.sendDue()
        let device = try #require(try await service.morning.devices().first)
        #expect(device.paceAlerts == nil && device.lastError?.contains("no longer accepts") == true)
        let tries = dead.sent.count
        await service.pace.sendDue()
        #expect(dead.sent.count == tries)
    }

    @Test("GET /v1/alerts/pace: the app's client reads the ledger's report")
    func route() async throws {
        let (app, service, _) = try await PaceFixture.service(apns: FakeAPNs(), clock: TestClock(PushFixture.at(12, 0)))
        try await app.test(.live) { client in
            let port = try #require(client.port)
            let remote = RemoteBudgetAPI(baseURL: URL(string: "http://localhost:\(port)")!, token: TestServer.token)
            // The route works the report out at the server's own clock, as the ledger itself does.
            let report = try await remote.paceAlerts()
            let ledger = try await service.api.paceAlerts()
            #expect(report.month == ledger.month && report.alerts.map(\.id) == ledger.alerts.map(\.id))
            #expect(report.alerts.allSatisfy { !$0.title.isEmpty && !$0.body.isEmpty })
        }
    }
}
