import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import NIOCore
import Testing

/// `POST /v1/actions` with `Budget-Basis`: an Ask proposal whose rows changed since it was made is refused with a 409
/// and changes nothing; without the header (the dashboard, apps before 0.6.0) an action applies as it always did.
@Suite("Stale-proof proposals over HTTP")
struct ActionBasisRouteTests {
    static let basisHeader = HTTPField.Name("Budget-Basis")!

    static func decode<T: Decodable>(_ type: T.Type, _ buffer: ByteBuffer) throws -> T {
        try RemoteBudgetAPI.decoder.decode(T.self, from: Data(buffer.readableBytesView))
    }

    static func body(_ action: AppAction) throws -> ByteBuffer {
        ByteBuffer(data: try RemoteBudgetAPI.encoder.encode(action))
    }

    static func headers(basis: String?) -> HTTPFields {
        var headers = TestServer.auth
        if let basis { headers[basisHeader] = basis }
        return headers
    }

    /// A rule over a merchant with more than a handful of rows, and one of those rows.
    static func ruleAndRow(_ service: BudgetService) async throws -> (action: AppAction, row: LedgerTransaction) {
        let rows = try await service.api.transactions(TransactionFilter(limit: 2000)).filter { !$0.isPending }
        let counts = Dictionary(grouping: rows, by: \.merchant).mapValues(\.count)
        let merchant = try #require(counts.filter { $0.value > ProposedAction.reviewAbove }.keys.sorted().first)
        let action = AppAction.createBudgetRule(CreateBudgetRule(match: RuleMatch(merchantContains: merchant), categoryID: "shopping", applyToExisting: true))
        return (action, try #require(rows.first { $0.merchant == merchant }))
    }

    static func recategorize(_ id: String, _ categoryID: String) -> AppAction {
        .recategorize(Recategorize(transactionIDs: [id], categoryID: categoryID))
    }

    @Test("A preview returns the basis to apply with; remembering a fact has none")
    func previewReturnsBasis() async throws {
        let (app, service) = try await TestServer.app()
        let (action, _) = try await Self.ruleAndRow(service)
        try await app.test(.router) { client in
            let preview = try await client.execute(uri: "/v1/actions/preview", method: .post, headers: TestServer.auth, body: try Self.body(action))
            #expect(preview.status == .ok)
            let basis = try #require(try Self.decode(ActionPreview.self, preview.body).basis)
            #expect(basis.hasPrefix("v1:") && basis.count == 35)
            let remember = try await client.execute(uri: "/v1/actions/preview", method: .post, headers: TestServer.auth,
                                                    body: TestServer.body(#"{"type":"rememberFact","fact":"Saving for a trip"}"#))
            #expect(remember.status == .ok)
            #expect(try Self.decode(ActionPreview.self, remember.body).basis == nil)
        }
    }

    @Test("A row re-filed between proposal and apply: 409, and neither the rule nor the row changes")
    func applyWithStaleBasisIs409AndChangesNothing() async throws {
        let (app, service) = try await TestServer.app()
        let (action, row) = try await Self.ruleAndRow(service)
        try await app.test(.router) { client in
            let proposed = try await client.execute(uri: "/v1/actions/preview", method: .post, headers: TestServer.auth, body: try Self.body(action))
            let stale = try #require(try Self.decode(ActionPreview.self, proposed.body).basis)
            try await client.execute(uri: "/v1/actions", method: .post, headers: TestServer.auth, body: try Self.body(Self.recategorize(row.id, "travel"))) {
                #expect($0.status == .ok)
            }
            let rulesBefore = try await service.api.rules().count
            let rowsBefore = try await service.store.loadLedger()?.transactions.count

            try await client.execute(uri: "/v1/actions", method: .post, headers: Self.headers(basis: stale), body: try Self.body(action)) { response in
                #expect(response.status == .conflict)
                #expect(String(buffer: response.body).contains("changed since this was proposed"))
            }
            #expect(try await service.api.rules().count == rulesBefore)
            let stored = try #require(try await service.store.loadLedger())
            #expect(stored.transactions.count == rowsBefore)
            #expect(stored.rules.count == rulesBefore)
            #expect(stored.transactions.first { $0.id == row.id }?.categorization?.categoryID == "travel")
        }
    }

    @Test("A basis that still matches applies")
    func applyWithMatchingBasisSucceeds() async throws {
        let (app, service) = try await TestServer.app()
        let (action, _) = try await Self.ruleAndRow(service)
        let rulesBefore = try await service.api.rules().count
        try await app.test(.router) { client in
            let proposed = try await client.execute(uri: "/v1/actions/preview", method: .post, headers: TestServer.auth, body: try Self.body(action))
            let basis = try #require(try Self.decode(ActionPreview.self, proposed.body).basis)
            try await client.execute(uri: "/v1/actions", method: .post, headers: Self.headers(basis: basis), body: try Self.body(action)) {
                #expect($0.status == .ok)
            }
        }
        #expect(try await service.api.rules().count == rulesBefore + 1)
    }

    @Test("Without the header (the dashboard, older apps) an action applies even though its rows changed; an empty one is no header")
    func applyWithoutHeaderStillWorks() async throws {
        let (app, service) = try await TestServer.app()
        let (action, row) = try await Self.ruleAndRow(service)
        let rulesBefore = try await service.api.rules().count
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/actions", method: .post, headers: TestServer.auth, body: try Self.body(Self.recategorize(row.id, "travel"))) {
                #expect($0.status == .ok)
            }
            try await client.execute(uri: "/v1/actions", method: .post, headers: Self.headers(basis: ""), body: try Self.body(action)) {
                #expect($0.status == .ok)
            }
            // Remembering a fact has no basis, so any header is ignored.
            try await client.execute(uri: "/v1/actions", method: .post, headers: Self.headers(basis: "v1:whatever"),
                                     body: TestServer.body(#"{"type":"rememberFact","fact":"Saving for a trip"}"#)) { #expect($0.status == .ok) }
        }
        #expect(try await service.api.rules().count == rulesBefore + 1)
    }

    @Test("A proposal whose row is gone is 404, as without a basis")
    func missingRowIs404() async throws {
        let (app, _) = try await TestServer.app()
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/actions", method: .post, headers: Self.headers(basis: "v1:" + String(repeating: "0", count: 32)),
                                     body: try Self.body(Self.recategorize("no-such-row", "dining"))) { #expect($0.status == .notFound) }
        }
    }

    @Test("The app's client sends the basis and reads a 409 as a server error with the message")
    func clientSendsBasis() async throws {
        let (app, service) = try await TestServer.app()
        let (action, row) = try await Self.ruleAndRow(service)
        try await app.test(.live) { client in
            let port = try #require(client.port)
            let remote = RemoteBudgetAPI(baseURL: URL(string: "http://localhost:\(port)")!, token: TestServer.token)
            let stale = try #require(try await remote.preview(action).basis)
            _ = try await remote.perform(Self.recategorize(row.id, "travel"))
            await #expect(throws: BudgetAPIError.server(status: 409, message: nil)) {
                do { _ = try await remote.perform(action, basis: stale) } catch let BudgetAPIError.server(status, message) {
                    #expect(message?.contains("Refresh it") == true)
                    throw BudgetAPIError.server(status: status, message: nil)
                }
            }
            let current = try #require(try await remote.preview(action).basis)
            _ = try await remote.perform(action, basis: current)
        }
    }
}
