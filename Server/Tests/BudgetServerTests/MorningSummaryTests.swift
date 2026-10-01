import BudgetKit
@testable import BudgetServerCore
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import NIOCore
import Testing

/// APNs as a script: each host answers with its (status, body) reply, 200 when there's none. Every request is kept.
final class FakeAPNs: HTTPTransport, @unchecked Sendable {
    struct Sent { var host: String; var path: String; var headers: [String: String]; var body: [String: Any] }
    private let lock = NSLock()
    private let replies: [String: (Int, String)]
    private var log: [Sent] = []

    init(_ replies: [String: (Int, String)] = [:]) { self.replies = replies }

    var sent: [Sent] { lock.withLock { log } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let host = request.url!.host!
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
        let headers = Dictionary((request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        lock.withLock { log.append(Sent(host: host, path: request.url!.path, headers: headers, body: body)) }
        let (status, text) = replies[host] ?? (200, "")
        return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

/// A settable clock for the scheduler.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var now: Date { lock.withLock { value } }
    func set(_ date: Date) { lock.withLock { value = date } }
}

enum PushFixture {
    static let key = P256.Signing.PrivateKey()
    static let token = String(repeating: "ab", count: 32)

    /// `hour`:`minute` on 2026-09-29 in `zone`.
    static func at(_ hour: Int, _ minute: Int, in zone: String = "America/Los_Angeles", day: Int = 29) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    static func device(_ zone: String = "America/Los_Angeles", lastSent: String? = nil, lastAttempt: Date? = nil, enabled: Bool = true) -> StoredDevice {
        StoredDevice(token: token, environment: .sandbox, timeZone: zone, enabled: enabled, hour: 9, minute: 30, lastSentDay: lastSent,
                     lastAttempt: lastAttempt, updatedAt: .distantPast)
    }

    /// With `spending`, the demo ledger up to the clock (the bank has sent yesterday); without, an empty one.
    static func service(apns: FakeAPNs, clock: TestClock, withKey: Bool = true, spending: Bool = true) async throws -> (some ApplicationProtocol, BudgetService) {
        let store = MemoryStore(ledger: spending ? LedgerBudgetAPI.demoState(now: clock.now, calendar: TestServer.config().calendar) : nil)
        let (service, _) = try await BudgetServerApp.makeService(config: TestServer.config(), store: store, logger: Logger(label: "test"),
                                                                 pushTransport: apns, clock: { clock.now })
        try await BudgetServerApp.prepare(service)
        if withKey {
            // Pasted into a one-line field: no newlines at all.
            let oneLine = key.pemRepresentation.replacingOccurrences(of: "\n", with: "")
            try await service.settings.update(["apnsKey": oneLine, "apnsKeyID": "ABC123DEFG", "apnsTeamID": "TEAMID1234", "apnsTopic": "com.example.budget"])
        }
        return (Application(router: buildRouter(service)), service)
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

@Suite("Morning summary: APNs")
struct APNsTests {
    @Test("No built-in team or bundle ID: with only the key, nothing is set up to send")
    func needsTeamAndTopic() async throws {
        let (_, service) = try await PushFixture.service(apns: FakeAPNs(), clock: TestClock(Date()), withKey: false)
        let oneLine = PushFixture.key.pemRepresentation.replacingOccurrences(of: "\n", with: "")
        try await service.settings.update(["apnsKey": oneLine, "apnsKeyID": "ABC123DEFG"])
        #expect(await service.morning.credentials() == nil)
        try await service.settings.update(["apnsTeamID": "TEAMID1234", "apnsTopic": "com.example.budget"])
        #expect(await service.morning.credentials()?.topic == "com.example.budget")
    }

    @Test("The provider token is an ES256 JWT for the key id and team, and verifies with the key")
    func providerToken() throws {
        let client = try APNsClient(credentials: .init(key: PushFixture.key.pemRepresentation, keyID: "ABC123DEFG", teamID: "TEAMID1234", topic: "com.example.budget"),
                                    transport: FakeAPNs())
        let jwt = try client.token(issuedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let parts = jwt.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        let header = try JSONSerialization.jsonObject(with: try #require(PushFixture.base64URLDecode(parts[0]))) as? [String: String]
        let claims = try JSONSerialization.jsonObject(with: try #require(PushFixture.base64URLDecode(parts[1]))) as? [String: Any]
        #expect(header == ["alg": "ES256", "kid": "ABC123DEFG"])
        #expect(claims?["iss"] as? String == "TEAMID1234" && claims?["iat"] as? Int == 1_790_000_000)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(PushFixture.base64URLDecode(parts[2])))
        #expect(PushFixture.key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test("A .p8 reads with or without its line breaks; anything else is refused in words")
    func keyText() throws {
        let pem = PushFixture.key.pemRepresentation
        #expect(try APNsClient.privateKey(pem).rawRepresentation == PushFixture.key.rawRepresentation)
        #expect(try APNsClient.privateKey(pem.replacingOccurrences(of: "\n", with: " ")).rawRepresentation == PushFixture.key.rawRepresentation)
        #expect(throws: BudgetAPIError.self) { try APNsClient.privateKey("not a key") }
    }

    @Test("What APNs answers: sent, a dead token, or a failure worth retrying")
    func outcomes() async throws {
        let alert = APNsClient.Alert(title: "Yesterday · $12", body: "Blue Bottle $12.", collapseID: "summary-2026-09-28", threadID: "morning-summary",
                                     userInfo: ["day": "2026-09-28"], expiration: Date(timeIntervalSince1970: 1_790_000_000))
        let credentials = APNsClient.Credentials(key: PushFixture.key.pemRepresentation, keyID: "K", teamID: "T", topic: "com.example.budget")
        let ok = FakeAPNs()
        let client = try APNsClient(credentials: credentials, transport: ok)
        #expect(await client.send(alert, to: PushFixture.token, environment: .production, providerToken: "jwt") == .sent)
        let sent = try #require(ok.sent.first)
        #expect(sent.host == "api.push.apple.com" && sent.path == "/3/device/\(PushFixture.token)")
        #expect(sent.headers["authorization"] == "bearer jwt" && sent.headers["apns-topic"] == "com.example.budget")
        #expect(sent.headers["apns-push-type"] == "alert" && sent.headers["apns-collapse-id"] == "summary-2026-09-28")
        let aps = try #require(sent.body["aps"] as? [String: Any])
        #expect((aps["alert"] as? [String: String]) == ["title": "Yesterday · $12", "body": "Blue Bottle $12."])
        #expect(sent.body["day"] as? String == "2026-09-28")

        let gone = try APNsClient(credentials: credentials, transport: FakeAPNs(["api.push.apple.com": (410, #"{"reason":"Unregistered"}"#)]))
        #expect(await gone.send(alert, to: PushFixture.token, environment: .production, providerToken: "jwt") == .badToken("Unregistered"))
        let down = try APNsClient(credentials: credentials, transport: FakeAPNs(["api.push.apple.com": (503, #"{"reason":"ServiceUnavailable"}"#)]))
        #expect(await down.send(alert, to: PushFixture.token, environment: .production, providerToken: "jwt") == .failed("APNs refused it: ServiceUnavailable"))
    }
}

@Suite("Morning summary: when it goes out")
struct MorningScheduleTests {
    @Test("Due from 9:30 in the phone's zone for three hours, summing up the day before")
    func window() {
        let d = PushFixture.device()
        #expect(MorningSummary.due(d, now: PushFixture.at(9, 29)) == nil)
        #expect(MorningSummary.due(d, now: PushFixture.at(9, 30))! == ("2026-09-29", "2026-09-28"))
        #expect(MorningSummary.due(d, now: PushFixture.at(12, 29)) != nil)
        #expect(MorningSummary.due(d, now: PushFixture.at(12, 30)) == nil)
        #expect(MorningSummary.due(PushFixture.device(enabled: false), now: PushFixture.at(9, 30)) == nil)
    }

    @Test("It follows the phone: 9:30 in Tokyo is not 9:30 in Los Angeles")
    func followsTheZone() {
        let tokyo = PushFixture.device("Asia/Tokyo")
        #expect(MorningSummary.due(tokyo, now: PushFixture.at(9, 30)) == nil)
        #expect(MorningSummary.due(tokyo, now: PushFixture.at(9, 35, in: "Asia/Tokyo"))! == ("2026-09-29", "2026-09-28"))
    }

    @Test("Once a day: not again today, not a day already sent after crossing the date line, and not before a retry wait")
    func once() {
        #expect(MorningSummary.due(PushFixture.device(lastSent: "2026-09-29"), now: PushFixture.at(10, 0)) == nil)
        // Sent in Tokyo on the 29th, then flew to Los Angeles, where it's still the 28th at 9:30.
        #expect(MorningSummary.due(PushFixture.device(lastSent: "2026-09-29"), now: PushFixture.at(9, 45, day: 28)) == nil)
        let tried = PushFixture.at(9, 30)
        #expect(MorningSummary.due(PushFixture.device(lastAttempt: tried), now: PushFixture.at(9, 40)) == nil)
        #expect(MorningSummary.due(PushFixture.device(lastAttempt: tried), now: PushFixture.at(9, 45)) != nil)
    }
}

@Suite("Morning summary: end to end")
struct MorningSummaryRouteTests {
    static func status(_ response: TestResponse) throws -> DeviceStatus {
        try RemoteBudgetAPI.decoder.decode(DeviceStatus.self, from: Data(response.body.readableBytesView))
    }

    static func register(_ zone: String = "America/Los_Angeles", enabled: Bool = true) -> ByteBuffer {
        TestServer.body(#"{"token":"\#(PushFixture.token)","environment":"sandbox","timeZone":"\#(zone)","enabled":\#(enabled),"hour":9,"minute":30}"#)
    }

    @Test("Registered at night; at 9:30 local it's sent once, to the sandbox, as yesterday's summary")
    func sendsOnce() async throws {
        let apns = FakeAPNs()
        let clock = TestClock(PushFixture.at(22, 0, day: 28))
        let (app, service) = try await PushFixture.service(apns: apns, clock: clock)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/devices", method: .post, headers: TestServer.auth, body: Self.register()) { #expect($0.status == .ok) }
        }
        await service.morning.sendDue()
        #expect(apns.sent.isEmpty)
        clock.set(PushFixture.at(9, 31))
        await service.morning.sendDue()
        await service.morning.sendDue()
        #expect(apns.sent.count == 1)
        let push = try #require(apns.sent.first)
        #expect(push.host == "api.sandbox.push.apple.com")
        let title = (push.body["aps"] as? [String: Any]).flatMap { $0["alert"] as? [String: String] }?["title"]
        #expect(title?.hasPrefix("Yesterday · $") == true, "\(title ?? "no title")")
        #expect(push.body["day"] as? String == "2026-09-28")
        let device = try #require(try await service.morning.devices().first)
        #expect(device.lastSentDay == "2026-09-29" && device.lastError == nil)
    }

    @Test("A day the bank hasn't sent waits, every 15 minutes, and goes out on the last try saying so")
    func waitsForTheBank() async throws {
        let apns = FakeAPNs()
        let clock = TestClock(PushFixture.at(22, 0, day: 28))
        let (app, service) = try await PushFixture.service(apns: apns, clock: clock, spending: false)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/devices", method: .post, headers: TestServer.auth, body: Self.register()) { response in
                #expect(response.status == .ok)
                let s = try Self.status(response)
                #expect(s.enabled && s.pushConfigured && s.timeZone == "America/Los_Angeles" && s.lastSentDay == nil)
            }
        }
        for (hour, minute) in [(9, 31), (9, 47), (11, 0)] {
            clock.set(PushFixture.at(hour, minute))
            await service.morning.sendDue()
        }
        #expect(apns.sent.isEmpty)
        #expect(try await service.morning.devices().first?.lastSentDay == nil)

        clock.set(PushFixture.at(12, 20))
        await service.morning.sendDue()
        #expect(apns.sent.count == 1)
        let alert = (apns.sent.first?.body["aps"] as? [String: Any]).flatMap { $0["alert"] as? [String: String] }
        #expect(alert?["title"] == "Yesterday · not in from the bank yet")
        #expect(try await service.morning.devices().first?.lastSentDay == "2026-09-29")
    }

    @Test("The phone picks the time: 7:15 in its zone")
    func pickedTime() async throws {
        let apns = FakeAPNs()
        let clock = TestClock(PushFixture.at(7, 14))
        let (app, service) = try await PushFixture.service(apns: apns, clock: clock)
        let body = TestServer.body(#"{"token":"\#(PushFixture.token)","environment":"sandbox","timeZone":"America/Los_Angeles","enabled":true,"hour":7,"minute":15}"#)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/devices", method: .post, headers: TestServer.auth, body: body) { response in
                let s = try Self.status(response)
                #expect(s.hour == 7 && s.minute == 15)
            }
        }
        await service.morning.sendDue()
        #expect(apns.sent.isEmpty)
        clock.set(PushFixture.at(7, 15))
        await service.morning.sendDue()
        #expect(apns.sent.count == 1)
    }

    @Test("Without an APNs key nothing is sent, and the phone is told why")
    func noKey() async throws {
        let apns = FakeAPNs()
        let (app, _) = try await PushFixture.service(apns: apns, clock: TestClock(PushFixture.at(9, 31)), withKey: false)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/devices", method: .post, headers: TestServer.auth, body: Self.register()) { response in
                let status = try Self.status(response)
                #expect(status.pushConfigured == false)
            }
            try await client.execute(uri: "/v1/devices/test", method: .post, headers: TestServer.auth,
                                     body: TestServer.body(#"{"token":"\#(PushFixture.token)"}"#)) { response in
                #expect(response.status == .unprocessableContent)
                #expect(String(buffer: response.body).contains("no APNs key"))
            }
        }
        #expect(apns.sent.isEmpty)
    }

    @Test("A token APNs no longer takes turns the summary off for that phone; one from the other environment is retried there")
    func tokens() async throws {
        let dead = FakeAPNs(["api.sandbox.push.apple.com": (410, #"{"reason":"Unregistered"}"#), "api.push.apple.com": (410, #"{"reason":"Unregistered"}"#)])
        let (app, service) = try await PushFixture.service(apns: dead, clock: TestClock(PushFixture.at(9, 31)))
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/devices", method: .post, headers: TestServer.auth, body: Self.register()) { #expect($0.status == .ok) }
        }
        await service.morning.sendDue()
        let off = try #require(try await service.morning.devices().first)
        #expect(!off.enabled && off.lastError?.contains("no longer accepts") == true)

        let production = FakeAPNs(["api.sandbox.push.apple.com": (400, #"{"reason":"BadDeviceToken"}"#)])
        let (app2, service2) = try await PushFixture.service(apns: production, clock: TestClock(PushFixture.at(9, 31)))
        try await app2.test(.router) { client in
            try await client.execute(uri: "/v1/devices", method: .post, headers: TestServer.auth, body: Self.register()) { #expect($0.status == .ok) }
        }
        await service2.morning.sendDue()
        let moved = try #require(try await service2.morning.devices().first)
        #expect(moved.enabled && moved.environment == .production && moved.lastSentDay == "2026-09-29")
        #expect(production.sent.map(\.host) == ["api.sandbox.push.apple.com", "api.push.apple.com"])
    }

    @Test("The digest route sums up a day, and says what a bad day is")
    func digestRoute() async throws {
        let (app, _) = try await PushFixture.service(apns: FakeAPNs(), clock: TestClock(PushFixture.at(9, 31)), spending: false)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/digest?day=2026-09-28", method: .get, headers: TestServer.auth) { response in
                #expect(response.status == .ok)
                let digest = try RemoteBudgetAPI.decoder.decode(DayDigest.self, from: Data(response.body.readableBytesView))
                #expect(digest.day == "2026-09-28" && digest.count == 0)
            }
            try await client.execute(uri: "/v1/digest?day=soon", method: .get, headers: TestServer.auth) { #expect($0.status == .badRequest) }
        }
    }
}
