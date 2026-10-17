import BudgetKit
@testable import BudgetServerCore
import Foundation
import Logging
import Testing

/// Links and a server for the connection pushes, on 2026-09-29 in Los Angeles.
enum ConnectionAlertFixture {
    static let noon = PushFixture.at(12, 0)
    static let day: TimeInterval = 86_400

    static func link(_ id: String = "plaid-item-1", institution: String = "Chase", provider: SourceKind = .plaid, token: String = "sealed",
                     kind: LinkErrorKind? = nil, since: Date? = nil, consent: Date? = nil, pendingDisconnect: Date? = nil) -> StoredLink {
        var link = StoredLink(id: id, provider: provider, institution: institution, externalID: id, sealedToken: token, cursor: nil,
                              status: kind == .needsSignIn || kind == .revoked ? .needsReauth : .connected, lastSync: nil, lastError: nil,
                              createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        link.errorKind = kind
        link.firstFailedAt = since
        if consent != nil || pendingDisconnect != nil {
            var plaid = PlaidLinkState()
            plaid.consentExpiresAt = consent
            plaid.pendingDisconnectAt = pendingDisconnect
            link.plaid = plaid
        }
        return link
    }

    /// An empty ledger, the APNs key set (unless `withKey` is false) and `links` stored.
    static func service(apns: FakeAPNs, clock: TestClock, links: [StoredLink], store: MemoryStore? = nil, withKey: Bool = true,
                        logger: Logger = Logger(label: "test")) async throws -> (BudgetService, MemoryStore) {
        let store = store ?? MemoryStore()
        for link in links { try await store.upsertLink(link) }
        let (service, _) = try await BudgetServerApp.makeService(config: TestServer.config(), store: store, logger: logger, pushTransport: apns,
                                                                 clock: { clock.now })
        try await BudgetServerApp.prepare(service)
        if withKey {
            let oneLine = PushFixture.key.pemRepresentation.replacingOccurrences(of: "\n", with: "")
            try await service.settings.update(["apnsKey": oneLine, "apnsKeyID": "ABC123DEFG", "apnsTeamID": "TEAMID1234", "apnsTopic": "com.example.budget"])
        }
        return (service, store)
    }

    /// A phone in Los Angeles: the morning summary as given, no pace alerts, connection pushes as given (nil: an app that
    /// doesn't send the choice).
    static func register(_ service: BudgetService, token: String = PushFixture.token, enabled: Bool = true, pace: PaceAlertPreferences? = nil,
                         connections: Bool? = nil) async throws {
        _ = try await service.morning.register(DeviceRegistration(token: token, environment: .sandbox, timeZone: "America/Los_Angeles", enabled: enabled,
                                                                  paceAlerts: pace, connectionAlerts: connections))
    }

    static func sent(_ apns: FakeAPNs) -> [(title: String, info: [String: String])] { PaceFixture.alerts(apns) }
}

@Suite("Connection pushes: what the links call for")
struct ConnectionAlertCollectorTests {
    typealias F = ConnectionAlertFixture

    @Test("A sign-in needed or access withdrawn: one alert per failure run, keyed on its start; healthy and pre-0.6.0 parked links none")
    func signIn() {
        let since = F.noon.addingTimeInterval(-3_600)
        let alerts = ConnectionAlerts.linkAlerts([
            F.link("plaid-a", kind: .needsSignIn, since: since),
            F.link("plaid-b", institution: "Amex", token: "", kind: .revoked, since: since),
            F.link("plaid-c", institution: "Ally"),
            { var parked = F.link("plaid-d", institution: "Citi"); parked.status = .needsReauth; return parked }(),
        ], now: F.noon)
        #expect(alerts.map(\.kind) == [.needsSignIn, .revoked])
        let signIn = alerts[0]
        #expect(signIn.episodeKeys == ["signin|plaid-a|\(Int(since.timeIntervalSince1970))"])
        #expect(signIn.title == "Chase needs you to sign in again" && signIn.linkID == "plaid-a" && signIn.opensReconnect)
        // A withdrawn Item can't be repaired from the phone: the tap opens Accounts.
        #expect(alerts[1].title == "Amex stopped sharing with Budget" && !alerts[1].opensReconnect)
        // A new failure run is a new episode.
        let later = ConnectionAlerts.linkAlerts([F.link("plaid-a", kind: .needsSignIn, since: since.addingTimeInterval(86_400))], now: F.noon)
        #expect(later.first?.episodeKeys != signIn.episodeKeys)
    }

    @Test("Consent: 13 days out one alert (the 14-day key); 20 days none; the day after none; inside a week the 7-day key covers the 14")
    func expiry() throws {
        func alerts(_ consent: Date?, pending: Date? = nil) -> [ConnectionAlert] {
            ConnectionAlerts.linkAlerts([F.link(institution: "Amex", consent: consent, pendingDisconnect: pending)], now: F.noon)
        }
        let thirteen = F.noon.addingTimeInterval(13 * F.day)
        let first = try #require(alerts(thirteen).first)
        #expect(alerts(thirteen).count == 1 && first.kind == .consentExpiring && first.opensReconnect)
        #expect(first.episodeKeys == ["expiry|plaid-item-1|\(ConnectionAlerts.day(thirteen))|14"])
        #expect(alerts(F.noon.addingTimeInterval(20 * F.day)).isEmpty)
        #expect(alerts(F.noon.addingTimeInterval(-F.day)).isEmpty)
        let six = F.noon.addingTimeInterval(6 * F.day)
        #expect(alerts(six).first?.episodeKeys == ["expiry|plaid-item-1|\(ConnectionAlerts.day(six))|7", "expiry|plaid-item-1|\(ConnectionAlerts.day(six))|14"])

        // PENDING_DISCONNECT without a consent date: a week from the warning. With one far off, the sooner of the two.
        let warned = F.noon.addingTimeInterval(-2 * F.day)
        let fromWarning = ConnectionAlerts.day(warned.addingTimeInterval(7 * F.day))
        #expect(alerts(nil, pending: warned).first?.episodeKeys.first == "expiry|plaid-item-1|\(fromWarning)|7")
        #expect(alerts(F.noon.addingTimeInterval(200 * F.day), pending: warned).first?.episodeKeys.first == "expiry|plaid-item-1|\(fromWarning)|7")

        // A link that already needs a sign-in hears about that, not the date; a dropped Item about neither date nor renewal.
        let both = ConnectionAlerts.linkAlerts([F.link(kind: .needsSignIn, since: F.noon, consent: thirteen)], now: F.noon)
        #expect(both.map(\.kind) == [.needsSignIn])
        #expect(ConnectionAlerts.linkAlerts([F.link(token: "", consent: thirteen)], now: F.noon).isEmpty)
    }

    @Test("The date in the copy is the phone's: access ending 3:00 UTC on Oct 3 ends Oct 2 in Los Angeles")
    func dateInPhoneZone() throws {
        let ends = try Date("2026-10-03T03:00:00Z", strategy: .iso8601)
        let now = ends.addingTimeInterval(-5 * F.day)
        let la = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(ConnectionAlerts.linkAlerts([F.link(institution: "Amex", consent: ends)], now: now, timeZone: la).first?.title == "Amex access ends Oct 2")
        let utc = ConnectionAlerts.linkAlerts([F.link(institution: "Amex", consent: ends)], now: now)
        #expect(utc.first?.title == "Amex access ends Oct 3")
        // The key doesn't move with the zone.
        #expect(ConnectionAlerts.linkAlerts([F.link(consent: ends)], now: now, timeZone: la).first?.episodeKeys == utc.first?.episodeKeys)
    }

    @Test("The server's Plaid setup refused: one alert for the earliest run, however many links it stops; Teller none")
    func setup() {
        let early = F.noon.addingTimeInterval(-7_200)
        let alerts = ConnectionAlerts.linkAlerts([
            F.link("plaid-a", kind: .providerSetup, since: F.noon), F.link("plaid-b", kind: .providerSetup, since: early),
            F.link("teller-x", provider: .teller, kind: .needsSignIn, since: early),
        ], now: F.noon)
        #expect(alerts.count == 1 && alerts.first?.kind == .providerSetup)
        #expect(alerts.first?.episodeKeys == ["setup|plaid|\(Int(early.timeIntervalSince1970))"] && alerts.first?.linkID == nil)
    }

    @Test("Most pressing first: setup, then sign-ins, then dates")
    func order() {
        let alerts = ConnectionAlerts.all(links: [
            F.link("plaid-a", consent: F.noon.addingTimeInterval(3 * F.day)), F.link("plaid-b", kind: .needsSignIn, since: F.noon),
            F.link("plaid-c", kind: .providerSetup, since: F.noon),
        ], health: [], now: F.noon, timeZone: ConnectionAlerts.utc)
        #expect(alerts.map(\.kind) == [.providerSetup, .needsSignIn, .consentExpiring])
    }

    @Test("The payload: where a tap goes and ids only, grouped, replacing itself, gone after a day; never a URL or token")
    func payload() {
        let alert = ConnectionAlerts.linkAlerts([F.link(kind: .needsSignIn, since: F.noon)], now: F.noon)[0]
        let n = ConnectionAlerts.notification(alert, now: F.noon)
        #expect(n.userInfo == ["kind": "connection", "alert": "needsSignIn", "linkID": "plaid-item-1", "to": "reconnect"])
        #expect(n.threadID == "connections" && n.collapseID == "conn-needsSignIn-plaid-item-1")
        #expect(n.expiration == F.noon.addingTimeInterval(24 * 3600))
        var account = ConnectionAlert(kind: .accountStale, episodeKeys: ["stale|x|1"], title: "t", body: "b", accountID: String(repeating: "acct-", count: 20))
        #expect(ConnectionAlerts.notification(account, now: F.noon).collapseID.utf8.count <= 64)
        account.bankID = "conn-1"
        #expect(ConnectionAlerts.notification(account, now: F.noon).userInfo["to"] == "accounts")
        #expect(ConnectionAlerts.notification(account, now: F.noon).userInfo["bank"] == "conn-1")
        // Nothing but kinds, ids and where to go; no amounts or masks in the copy.
        let keys: Set<String> = ["kind", "alert", "linkID", "accountID", "bank", "to"]
        #expect(Set(n.userInfo.keys).isSubset(of: keys))
        #expect(!n.title.contains("$") && !n.body.contains("$") && !n.body.contains("http"))
    }

    @Test("Who listens: any phone that takes some push from the server, unless it turned these off")
    func listens() {
        var device = PushFixture.device(enabled: true)
        #expect(ConnectionAlerts.listens(device))
        device.connectionAlerts = false
        #expect(!ConnectionAlerts.listens(device))
        device = PushFixture.device(enabled: false)
        #expect(!ConnectionAlerts.listens(device))
        device.paceAlerts = PaceAlertPreferences(everyday: true)
        #expect(ConnectionAlerts.listens(device))
        device.connectionAlerts = true
        device.paceAlerts = PaceAlertPreferences(everyday: false)
        #expect(!ConnectionAlerts.listens(device))
    }
}

@Suite("Connection pushes: end to end")
struct ConnectionAlertTests {
    typealias F = ConnectionAlertFixture

    @Test("One push per episode, none again after a restart; a new failure run pushes again")
    func oncePerEpisode() async throws {
        let apns = FakeAPNs()
        let clock = TestClock(F.noon)
        let since = F.noon.addingTimeInterval(-600)
        let (service, store) = try await F.service(apns: apns, clock: clock, links: [F.link(kind: .needsSignIn, since: since)])
        try await F.register(service)
        await service.alerts.sendDue()
        await service.alerts.sendDue()
        let sent = F.sent(apns)
        #expect(sent.count == 1)
        #expect(sent.first?.title == "Chase needs you to sign in again")
        #expect(sent.first?.info == ["kind": "connection", "alert": "needsSignIn", "linkID": "plaid-item-1", "to": "reconnect"])
        #expect(apns.sent.first?.host == "api.sandbox.push.apple.com")
        let log = await service.alerts.sentLog()
        #expect(log[PushFixture.token]?.keys.sorted() == ["signin|plaid-item-1|\(Int(since.timeIntervalSince1970))"])

        // A restart: the same store, a new process.
        let (again, _) = try await F.service(apns: apns, clock: clock, links: [], store: store)
        await again.alerts.sendDue()
        #expect(apns.sent.count == 1)

        // Healed, then failing again later: a new episode.
        try await store.upsertLink(F.link(kind: .needsSignIn, since: F.noon.addingTimeInterval(3_600)))
        clock.set(F.noon.addingTimeInterval(4_000))
        await again.alerts.sendDue()
        #expect(apns.sent.count == 2)
    }

    @Test("Consent: 20 days out nothing; at 13 days one push; at 6 days one more; then none, and none the day after it ends")
    func consentWarnings() async throws {
        let apns = FakeAPNs()
        let ends = F.noon.addingTimeInterval(20 * F.day)
        let clock = TestClock(F.noon)
        let (service, _) = try await F.service(apns: apns, clock: clock, links: [F.link(institution: "Amex", consent: ends)])
        try await F.register(service)
        await service.alerts.sendDue()
        #expect(apns.sent.isEmpty)

        clock.set(ends.addingTimeInterval(-13 * F.day))
        await service.alerts.sendDue()
        await service.alerts.sendDue()
        #expect(F.sent(apns).map(\.title) == ["Amex access ends Oct 19"])
        #expect(F.sent(apns).first?.info["to"] == "reconnect")

        clock.set(ends.addingTimeInterval(-6 * F.day))
        await service.alerts.sendDue()
        clock.set(ends.addingTimeInterval(-2 * F.day))
        await service.alerts.sendDue()
        #expect(apns.sent.count == 2)

        clock.set(ends.addingTimeInterval(F.day))
        await service.alerts.sendDue()
        #expect(apns.sent.count == 2)
    }

    @Test("Inside a week at first sight: one push, not the 14-day one after it")
    func sevenCoversFourteen() async throws {
        let apns = FakeAPNs()
        let clock = TestClock(F.noon)
        let (service, _) = try await F.service(apns: apns, clock: clock, links: [F.link(consent: F.noon.addingTimeInterval(5 * F.day))])
        try await F.register(service)
        for _ in 0..<3 { await service.alerts.sendDue() }
        #expect(apns.sent.count == 1)
        let keys = await service.alerts.sentLog()[PushFixture.token]?.keys.sorted() ?? []
        #expect(keys.count == 2 && keys.allSatisfy { $0.hasPrefix("expiry|plaid-item-1|") })
    }

    @Test("Night is quiet: at 22:00 where the phone is nothing; from 9:00 the push")
    func nightIsQuiet() async throws {
        let apns = FakeAPNs()
        let clock = TestClock(PushFixture.at(22, 0, day: 28))
        let (service, _) = try await F.service(apns: apns, clock: clock, links: [F.link(kind: .needsSignIn, since: PushFixture.at(21, 0, day: 28))])
        try await F.register(service)
        await service.alerts.sendDue()
        clock.set(PushFixture.at(8, 59))
        await service.alerts.sendDue()
        #expect(apns.sent.isEmpty)
        clock.set(PushFixture.at(9, 0))
        await service.alerts.sendDue()
        #expect(apns.sent.count == 1)
    }

    @Test("A phone that turned connection pushes off gets nothing; one with only pace alerts on gets them")
    func turnedOff() async throws {
        let apns = FakeAPNs()
        let clock = TestClock(F.noon)
        let (service, _) = try await F.service(apns: apns, clock: clock, links: [F.link(kind: .needsSignIn, since: F.noon)])
        try await F.register(service, connections: false)
        await service.alerts.sendDue()
        #expect(apns.sent.isEmpty)
        // Re-registering without a choice keeps "off".
        try await F.register(service)
        await service.alerts.sendDue()
        #expect(apns.sent.isEmpty)

        let other = String(repeating: "cd", count: 32)
        try await F.register(service, token: other, enabled: false, pace: PaceAlertPreferences(everyday: true))
        await service.alerts.sendDue()
        #expect(apns.sent.count == 1 && apns.sent.first?.path.hasSuffix(other) == true)
    }

    @Test("At most three to a phone per check, the rest at the next")
    func perCheck() async throws {
        let apns = FakeAPNs()
        let clock = TestClock(F.noon)
        let links = (1...5).map { F.link("plaid-\($0)", institution: "Bank \($0)", kind: .needsSignIn, since: F.noon) }
        let (service, _) = try await F.service(apns: apns, clock: clock, links: links)
        try await F.register(service)
        await service.alerts.sendDue()
        #expect(apns.sent.count == 3)
        await service.alerts.sendDue()
        await service.alerts.sendDue()
        #expect(apns.sent.count == 5)
        #expect(Set(F.sent(apns).map(\.title)).count == 5)
    }

    @Test("A token APNs no longer takes stops pushes to that phone")
    func deadToken() async throws {
        let dead = FakeAPNs(["api.sandbox.push.apple.com": (410, #"{"reason":"Unregistered"}"#), "api.push.apple.com": (410, #"{"reason":"Unregistered"}"#)])
        let clock = TestClock(F.noon)
        let (service, _) = try await F.service(apns: dead, clock: clock, links: [F.link(kind: .needsSignIn, since: F.noon)])
        try await F.register(service)
        await service.alerts.sendDue()
        let device = try #require(try await service.morning.devices().first)
        #expect(!device.enabled && device.lastError?.contains("no longer accepts") == true)
        let tries = dead.sent.count
        await service.alerts.sendDue()
        #expect(dead.sent.count == tries)
        #expect(await service.alerts.sentLog().isEmpty)
    }

    @Test("What was sent is kept 120 days, and only for phones still registered")
    func pruning() async throws {
        let apns = FakeAPNs()
        let clock = TestClock(F.noon)
        let store = MemoryStore()
        let old: [String: [String: Date]] = [
            PushFixture.token: ["signin|gone|1": F.noon.addingTimeInterval(-121 * F.day), "signin|kept|1": F.noon.addingTimeInterval(-119 * F.day)],
            "unregistered": ["signin|x|1": F.noon],
        ]
        try await store.saveSetting(ConnectionAlerts.sentKey, HTTP.encoder.encode(old))
        let (service, _) = try await F.service(apns: apns, clock: clock, links: [F.link(kind: .needsSignIn, since: F.noon)], store: store)
        try await F.register(service)
        await service.alerts.sendDue()
        let log = await service.alerts.sentLog()
        #expect(log.keys.sorted() == [PushFixture.token])
        #expect(log[PushFixture.token]?.keys.sorted() == ["signin|kept|1", "signin|plaid-item-1|\(Int(F.noon.timeIntervalSince1970))"])
    }

    @Test("Without an APNs key: a 'would push' line per episode, once, with kind and key only")
    func wouldPush() async throws {
        let apns = FakeAPNs()
        let captured = CapturedLog()
        let clock = TestClock(F.noon)
        let since = F.noon.addingTimeInterval(-60)
        let (service, _) = try await F.service(apns: apns, clock: clock, links: [F.link(institution: "Chase", kind: .needsSignIn, since: since)],
                                               withKey: false, logger: captured.logger)
        await service.alerts.sendDue()
        await service.alerts.sendDue()
        let lines = captured.lines.filter { $0.contains("would push") }
        #expect(lines == ["notice would push needsSignIn signin|plaid-item-1|\(Int(since.timeIntervalSince1970))"])
        #expect(apns.sent.isEmpty)
        #expect(await service.alerts.sentLog().isEmpty)
    }
}
