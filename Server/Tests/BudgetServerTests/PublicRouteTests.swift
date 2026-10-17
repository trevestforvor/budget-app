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
            // Outside "/v1" (paths are case-sensitive) the token check doesn't apply, as for any non-API path, but the
            // router has nothing there: it never reaches the webhook.
            try await client.execute(uri: "/V1/plaid/webhook", method: .post, headers: Self.json, body: TestServer.body("{}")) {
                #expect($0.status == .notFound)
            }
            // With the token the near misses are just routes that don't exist (or the wrong method).
            try await client.execute(uri: "/v1/plaid/webhookx", method: .post, headers: TestServer.auth, body: TestServer.body("{}")) {
                #expect($0.status == .notFound)
            }
            try await client.execute(uri: "/v1/overview", method: .get) { #expect($0.status == .unauthorized) }
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
