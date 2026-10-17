import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import Testing

/// The test-only aids (SPEC §7.3, §7.4 b) exist only on an in-memory demo server, the webhook key file only in the sandbox.
@Suite("Test-only hooks")
struct TestHooksTests {
    static func jwkFile() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("test-hooks-\(UUID().uuidString).jwk").path
        let set = #"{"keys": [{"kty": "EC", "crv": "P-256", "kid": "test-1", "x": "AAAA", "y": "BBBB"}]}"#
        try Data(set.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    @Test("The JWK file is read only on an in-memory demo server in the sandbox")
    func keyFileGated() throws {
        let path = try Self.jwkFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let logger = Logger(label: "test")
        var config = TestServer.config()
        config.testWebhookJWKFile = path
        #expect(TestHooks.webhookKeys(config, logger: logger)?["test-1"]?.x == "AAAA")
        var real = config
        real.allowDemo = false
        #expect(TestHooks.webhookKeys(real, logger: logger) == nil)
        var postgres = config
        postgres.database = .init(host: "db", port: 5432, username: "u", password: nil, database: "d")
        #expect(TestHooks.webhookKeys(postgres, logger: logger) == nil)
        var production = config
        production.plaid?.environment = .production
        #expect(TestHooks.webhookKeys(production, logger: logger) == nil)
    }

    @Test("The debug Item check exists on a test server's dashboard only")
    func debugRouteGated() async throws {
        let (dash, _) = try await TestServer.app(seedDemo: false, surface: .dashboard)
        try await dash.test(.router) { client in
            try await client.execute(uri: "/dash/debug/plaid/check/plaid-x", method: .post, headers: TestServer.dash) {
                #expect($0.status == .ok)  // no such link: the check is skipped, but the route is there
            }
        }
        var config = TestServer.config()
        config.allowDemo = false
        let (service, _) = try await BudgetServerApp.makeService(config: config, store: MemoryStore(), logger: Logger(label: "test"))
        let real = Application(router: buildRouter(service, surface: .dashboard))
        try await real.test(.router) { client in
            try await client.execute(uri: "/dash/debug/plaid/check/plaid-x", method: .post, headers: TestServer.dash) {
                #expect($0.status == .notFound)
            }
        }
    }
}
