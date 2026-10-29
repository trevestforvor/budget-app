import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import NIOCore
import Testing

/// Server 0.6.3. Requests the token check turns away: counted by kind and address, saved, shown on the dashboard, and a push about a
/// wrong token at most once a day. `/health` keeps the version to itself without the token.
@Suite("Access watch")
struct AccessWatchTests {
    static func headers(_ authorization: String?, from address: String? = nil) -> HTTPFields {
        var h: HTTPFields = [:]
        if let authorization { h[.authorization] = authorization }
        if let address { h[HTTPField.Name("X-Real-IP")!] = address }
        return h
    }

    @Test("No token and another scheme count as no token; a wrong bearer token counts as wrong; the right one isn't counted")
    func counts() async throws {
        let (app, service) = try await TestServer.app(seedDemo: true)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/overview", method: .get, headers: Self.headers(nil, from: "198.51.100.7")) { #expect($0.status == .unauthorized) }
            try await client.execute(uri: "/wp-login.php", method: .get, headers: Self.headers("Basic YWRtaW46YWRtaW4=", from: "198.51.100.7")) {
                #expect($0.status == .unauthorized)
            }
            try await client.execute(uri: "/v1/links?x=secret", method: .get, headers: Self.headers("Bearer \(String(repeating: "0", count: 64))", from: "203.0.113.9")) {
                #expect($0.status == .unauthorized)
            }
            // A token that's a prefix of the real one is still wrong (the comparison is on the whole value).
            try await client.execute(uri: "/v1/overview", method: .get, headers: Self.headers("Bearer \(TestServer.token.dropLast())")) {
                #expect($0.status == .unauthorized)
            }
            try await client.execute(uri: "/v1/overview", method: .get, headers: TestServer.auth) { #expect($0.status == .ok) }
            try await client.execute(uri: "/health", method: .get) { #expect($0.status == .ok) }
        }
        let log = await service.access.snapshot()
        let today = try #require(log.days.first)
        #expect(log.days.count == 1)
        #expect(today.noToken == 2)
        #expect(today.wrongToken == 2)
        #expect(log.unannounced == 2)
        let scanner = try #require(today.sources.first { $0.address == "198.51.100.7" })
        #expect(scanner.noToken == 2 && scanner.wrongToken == 0 && scanner.lastPath == "/wp-login.php")
        let wrong = try #require(today.sources.first { $0.address == "203.0.113.9" })
        #expect(wrong.wrongToken == 1 && wrong.lastPath == "/v1/links")  // the path alone, never the query
        #expect(today.sources.contains { $0.address == AccessWatch.unknownAddress && $0.wrongToken == 1 })
    }

    @Test("/health tells the version only with the token, or on the dashboard")
    func healthVersion() async throws {
        let (app, _) = try await TestServer.app(seedDemo: false)
        try await app.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                #expect(response.status == .ok)
                #expect(!String(buffer: response.body).contains("version"))
            }
            try await client.execute(uri: "/health", method: .get, headers: Self.headers("Bearer nope")) {
                #expect(!String(buffer: $0.body).contains("version"))
            }
            try await client.execute(uri: "/health", method: .get, headers: TestServer.auth) {
                #expect(String(buffer: $0.body).contains(BudgetServerVersion.current))
            }
        }
        let (dashboard, _) = try await TestServer.app(seedDemo: false, surface: .dashboard)
        try await dashboard.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { #expect(String(buffer: $0.body).contains(BudgetServerVersion.current)) }
        }
    }

    @Test("The dashboard surface counts nothing (it takes no token), and /dash/access returns the log")
    func dashboard() async throws {
        let (app, service) = try await TestServer.app(seedDemo: false, surface: .dashboard)
        await service.access.record(.wrongToken, address: "203.0.113.9", path: "/v1/overview")
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/overview", method: .get, headers: Self.headers("Bearer nope")) { #expect($0.status == .ok) }
            try await client.execute(uri: "/dash/access", method: .get) { response in
                #expect(response.status == .ok)
                let log = try HTTP.decoder.decode(AccessWatch.Log.self, from: Data(response.body.readableBytesView))
                #expect(log.days.first?.wrongToken == 1)
            }
        }
    }

    @Test("Counts survive a restart: saved at the check, read back by the next process")
    func saved() async throws {
        let store = MemoryStore(ledger: nil)
        let clock = TestClock(PushFixture.at(12, 0))
        let push = PushSender(settings: ServerSettings(config: TestServer.config(), store: store, sealer: nil, logger: Logger(label: "test")),
                              transport: FakeAPNs())
        func watch() async throws -> AccessWatch {
            let (service, _) = try await BudgetServerApp.makeService(config: TestServer.config(), store: store, logger: Logger(label: "test"),
                                                                     clock: { clock.now })
            return AccessWatch(store: store, morning: service.morning, push: push, logger: Logger(label: "test"), clock: { clock.now })
        }
        let first = try await watch()
        await first.record(.noToken, address: "198.51.100.7", path: "/")
        await first.check()
        let second = try await watch()
        await second.record(.noToken, address: "198.51.100.7", path: "/.env")
        let log = await second.snapshot()
        #expect(log.days.count == 1)
        #expect(log.days[0].noToken == 2)
        #expect(log.days[0].sources.count == 1)
    }

    @Test("Past 50 addresses in a day, the rest share one row")
    func capped() async throws {
        let (_, service) = try await TestServer.app(seedDemo: false)
        for i in 0..<80 { await service.access.record(.noToken, address: "198.51.100.\(i)", path: "/") }
        let day = try #require(await service.access.snapshot().days.first)
        #expect(day.noToken == 80)
        #expect(day.sources.count == AccessWatch.maxSources)
        #expect(day.sources.last?.address == AccessWatch.othersAddress)
        #expect(day.sources.reduce(0) { $0 + $1.noToken } == 80)
    }

    @Test("A wrong token sends one push in the phone's daytime, then none for a day; no token never sends one")
    func push() async throws {
        let apns = FakeAPNs()
        let clock = TestClock(PushFixture.at(12, 0))
        let (app, service, _) = try await PaceFixture.service(apns: apns, clock: clock)
        _ = try await PaceFixture.registerOver(app, #"{"everyday":true,"categories":false,"merchants":false}"#)
        let before = apns.sent.count

        await service.access.record(.noToken, address: "198.51.100.7", path: "/")
        await service.access.check()
        #expect(apns.sent.count == before)

        await service.access.record(.wrongToken, address: "203.0.113.9", path: "/v1/overview")
        await service.access.record(.wrongToken, address: "203.0.113.9", path: "/v1/links")
        await service.access.check()
        let alerts = PaceFixture.alerts(apns).dropFirst(before)
        #expect(alerts.map(\.title) == ["A wrong API token was tried"])
        #expect(await service.access.snapshot().unannounced == 0)

        // Another one an hour later waits for the next day's push.
        clock.set(PushFixture.at(13, 0))
        await service.access.record(.wrongToken, address: "203.0.113.9", path: "/v1/overview")
        await service.access.check()
        #expect(apns.sent.count == before + 1)
        #expect(await service.access.snapshot().unannounced == 1)

        // Night in Los Angeles: still waiting, even after a day.
        clock.set(PushFixture.at(23, 0, day: 30))
        await service.access.check()
        #expect(apns.sent.count == before + 1)
        clock.set(PushFixture.at(10, 0, day: 30))
        await service.access.check()
        #expect(apns.sent.count == before + 2)
    }

    @Test("The push names the address, and how many more")
    func notification() {
        let now = PushFixture.at(12, 0)
        #expect(AccessWatch.notification(count: 1, addresses: ["203.0.113.9"], now: now).body.hasPrefix("A request reached your server from 203.0.113.9 "))
        #expect(AccessWatch.notification(count: 3, addresses: ["203.0.113.9", "198.51.100.7"], now: now).body
            .hasPrefix("3 requests reached your server from 203.0.113.9 and 1 more "))
    }

    @Test("Server version is 0.6.3")
    func version() { #expect(BudgetServerVersion.current == "0.6.4") }
}
