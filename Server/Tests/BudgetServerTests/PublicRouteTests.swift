import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import Testing

/// The one route the API takes without the bearer token is exactly `POST /v1/plaid/webhook` (its auth is Plaid's signed
/// JWT). Anything near it still needs the token, and the dashboard doesn't have it at all.
@Suite("Public routes")
struct PublicRouteTests {
    static let json: HTTPFields = [.contentType: "application/json"]

    @Test("Without a token, only the exact webhook route gets through")
    func onlyTheWebhook() async throws {
        let (app, _) = try await TestServer.app(seedDemo: false)
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/plaid/webhook", method: .post, headers: Self.json, body: TestServer.body("{}")) { response in
                #expect(response.status == .badRequest)  // reached the route, which refuses a request without Plaid's JWT
            }
            // A cross-site Origin doesn't stop it either: Plaid isn't a browser, and the JWT is the check.
            var withOrigin = Self.json
            withOrigin[.origin] = "https://evil.example"
            try await client.execute(uri: "/v1/plaid/webhook", method: .post, headers: withOrigin, body: TestServer.body("{}")) {
                #expect($0.status == .badRequest)
            }
            // The query isn't part of the path.
            try await client.execute(uri: "/v1/plaid/webhook?x=1", method: .post, headers: Self.json, body: TestServer.body("{}")) {
                #expect($0.status == .badRequest)
            }
            let near: [(String, HTTPRequest.Method)] = [
                ("/v1/plaid/webhook/", .post), ("/v1/plaid/webhookx", .post),
                ("/v1/plaid/webhook/../../admin/reset", .post), ("/v1/plaid/webhook", .get), ("/v1/plaid/webhook", .put),
                ("/v1/plaid/webhook2", .post),
            ]
            for (uri, method) in near {
                try await client.execute(uri: uri, method: method, headers: Self.json, body: TestServer.body("{}")) { response in
                    #expect(response.status == .unauthorized, "\(method) \(uri) answered \(response.status)")
                }
            }
            // The check denies by default: a path outside "/v1" (paths are case-sensitive) still needs the token.
            try await client.execute(uri: "/V1/plaid/webhook", method: .post, headers: Self.json, body: TestServer.body("{}")) {
                #expect($0.status == .unauthorized)
            }
            // With the token the near misses are just routes that don't exist (or the wrong method).
            try await client.execute(uri: "/v1/plaid/webhookx", method: .post, headers: TestServer.auth, body: TestServer.body("{}")) {
                #expect($0.status == .notFound)
            }
            try await client.execute(uri: "/v1/overview", method: .get) { #expect($0.status == .unauthorized) }
        }
    }

    @Test("A doubled slash never skips the token: the router would still send //v1/… to the /v1 route")
    func doubledSlashOnTheAPI() async throws {
        let (app, _) = try await TestServer.app(seedDemo: true)
        try await app.test(.router) { client in
            for uri in ["//v1/overview", "//v1/links", "//v1/transactions", "/v1//overview", "///v1/overview", "//health"] {
                try await client.execute(uri: uri, method: .get) { response in
                    #expect(response.status == .badRequest, "GET \(uri) answered \(response.status)")
                }
            }
            // Even with the token: the path is refused, not guessed at.
            try await client.execute(uri: "//v1/overview", method: .get, headers: TestServer.auth) { #expect($0.status == .badRequest) }
            try await client.execute(uri: "/v1/overview", method: .get) { #expect($0.status == .unauthorized) }
            try await client.execute(uri: "/v1/overview", method: .get, headers: TestServer.auth) { #expect($0.status == .ok) }
            // The listed public routes still answer without a token.
            try await client.execute(uri: "/health", method: .get) { #expect($0.status == .ok) }
            try await client.execute(uri: "/plaid/oauth-return", method: .get) { #expect($0.status == .ok) }
            try await client.execute(uri: "/.well-known/apple-app-site-association", method: .get) {
                #expect($0.status == .notFound)  // reached the route: no BUDGET_IOS_APP_ID in the test config
            }
            // Anything else outside "/v1" needs the token too.
            try await client.execute(uri: "/anything", method: .get) { #expect($0.status == .unauthorized) }
        }
    }

    @Test("A doubled slash never skips the dashboard's write guard, and every write path is guarded")
    func doubledSlashOnTheDashboard() async throws {
        let (dash, _) = try await TestServer.app(seedDemo: true, surface: .dashboard)
        try await dash.test(.router) { client in
            let reset = TestServer.body(#"{"confirm":"erase my ledger","keepLedger":true}"#)
            var crossSite: HTTPFields = [.contentType: "text/plain"]
            crossSite[.origin] = "https://evil.example"
            try await client.execute(uri: "//v1/admin/reset", method: .post, headers: crossSite, body: reset) {
                #expect($0.status == .badRequest)
            }
            try await client.execute(uri: "/v1/admin/reset", method: .post, headers: crossSite, body: reset) {
                #expect($0.status == .forbidden)
            }
            // A write outside "/v1" and "/dash" is guarded the same way.
            try await client.execute(uri: "/elsewhere", method: .post, headers: crossSite, body: reset) {
                #expect($0.status == .forbidden)
            }
            // An opaque Origin ("null") is never the dashboard's own, even with the header.
            var opaque: HTTPFields = [HTTPField.Name("X-Budget-Dashboard")!: "1", .contentType: "application/json"]
            opaque[.origin] = "null"
            try await client.execute(uri: "/v1/admin/reset", method: .post, headers: opaque, body: reset) {
                #expect($0.status == .forbidden)
            }
            // Reads need nothing.
            try await client.execute(uri: "/v1/overview", method: .get) { #expect($0.status == .ok) }
        }
    }

    @Test("The dashboard has no webhook route")
    func notOnTheDashboard() async throws {
        let (dash, _) = try await TestServer.app(seedDemo: false, surface: .dashboard)
        try await dash.test(.router) { client in
            let write: HTTPFields = [HTTPField.Name("X-Budget-Dashboard")!: "1", .contentType: "application/json"]
            try await client.execute(uri: "/v1/plaid/webhook", method: .post, headers: write, body: TestServer.body("{}")) {
                #expect($0.status == .notFound)
            }
        }
    }
}
