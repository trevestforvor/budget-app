import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Logging
import Testing

/// Plaid on the dashboard (P8). One Item per bank: the exchange route refuses a second Item at a bank that already has
/// a working one, before anything is exchanged. Update mode on a working link renews its consent.
@Suite("Plaid on the dashboard")
struct PlaidDashboardTests {
    static let write: HTTPFields = [HTTPField.Name("X-Budget-Dashboard")!: "1", .contentType: "application/json"]
    static let exchangePath = "/item/public_token/exchange"

    static func provider() -> ScriptedProvider {
        ScriptedProvider([
            exchangePath: [PlaidScript.exchange],
            "/transactions/sync": [PlaidScript.page("c1")],
            "/accounts/get": [PlaidScript.balances],
            "/item/get": [LiabilitiesScript.item],
            "/institutions/get_by_id": [LiabilitiesScript.institution(id: "ins_1")],
            "/link/token/create": [(200, #"{"link_token": "link-update-1"}"#)],
        ])
    }

    /// A dashboard-surface server holding one Plaid link, `plaid-item-0` ("Harbor Bank"), changed by `change`.
    static func server(_ plaid: ScriptedProvider, institutionID: String? = "ins_1",
                       change: (inout StoredLink) -> Void = { _ in }) async throws -> (some ApplicationProtocol, BudgetService) {
        let (app, service) = try await TestServer.app(seedDemo: false, plaid: plaid, surface: .dashboard)
        var link = StoredLink(id: "plaid-item-0", provider: .plaid, institution: "Harbor Bank", externalID: "item-0",
                              sealedToken: try #require(try service.sealer?.seal("access-sandbox-0")), cursor: "c0", status: .connected,
                              lastSync: nil, lastError: nil, createdAt: Date())
        if let institutionID {
            var state = PlaidLinkState()
            state.institutionID = institutionID
            link.plaid = state
        }
        change(&link)
        try await service.store.upsertLink(link)
        return (app, service)
    }

    static func exchange(_ app: some ApplicationProtocol, _ json: String) async throws -> (HTTPResponse.Status, String) {
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/links/plaid/exchange", method: .post, headers: write, body: TestServer.body(json)) { response in
                (response.status, String(buffer: response.body))
            }
        }
    }

    @Test("A second Item at a linked bank is refused with 409 before any exchange, naming the bank and Reconnect")
    func sameInstitutionRefused() async throws {
        let plaid = Self.provider()
        let (app, service) = try await Self.server(plaid)
        let (status, body) = try await Self.exchange(app, #"{"publicToken":"public-2","institution":"Harbor Bank","institutionID":"ins_1"}"#)
        #expect(status == .conflict)
        #expect(body.contains("Harbor Bank is already linked") && body.contains("Reconnect"))
        #expect(plaid.count(Self.exchangePath) == 0)
        #expect(plaid.requests.isEmpty)
        #expect(try await service.store.links().map(\.id) == ["plaid-item-0"])
    }

    @Test("Before the link's institution id is known, the same bank name is enough to refuse")
    func sameNameRefused() async throws {
        let plaid = Self.provider()
        let (app, _) = try await Self.server(plaid, institutionID: nil)
        let (status, _) = try await Self.exchange(app, #"{"publicToken":"public-2","institution":" harbor bank ","institutionID":"ins_1"}"#)
        #expect(status == .conflict)
        #expect(plaid.count(Self.exchangePath) == 0)
    }

    @Test("A dashboard that sends no institution id (before 0.6.0) is still refused by name")
    func oldDashboardRefusedByName() async throws {
        let plaid = Self.provider()
        let (app, _) = try await Self.server(plaid)
        let (status, _) = try await Self.exchange(app, #"{"publicToken":"public-2","institution":"Harbor Bank"}"#)
        #expect(status == .conflict)
        #expect(plaid.count(Self.exchangePath) == 0)
    }

    @Test("Another bank links, and its institution id is stored on the new link")
    func otherInstitutionLinks() async throws {
        let plaid = Self.provider()
        let (app, service) = try await Self.server(plaid)
        let (status, _) = try await Self.exchange(app, #"{"publicToken":"public-2","institution":"Northwind","institutionID":"ins_2"}"#)
        #expect(status == .created)
        #expect(plaid.count(Self.exchangePath) == 1)
        let added = try #require(try await service.store.links().first { $0.id == "plaid-item-1" })
        #expect(added.plaid?.institutionID == "ins_2")
        #expect(added.summary.institutionID == "ins_2")
    }

    @Test("Ids win over names: a different institution id with the same name links")
    func idBeatsName() async throws {
        let plaid = Self.provider()
        let (app, _) = try await Self.server(plaid)
        let (status, _) = try await Self.exchange(app, #"{"publicToken":"public-2","institution":"Harbor Bank","institutionID":"ins_9"}"#)
        #expect(status == .created)
        #expect(plaid.count(Self.exchangePath) == 1)
    }

    @Test("A link whose Item is gone, or whose access was withdrawn, doesn't block linking the bank again",
          arguments: ["gone", "withdrawn"])
    func deadLinkDoesNotBlock(_ how: String) async throws {
        let plaid = Self.provider()
        let (app, service) = try await Self.server(plaid) { link in
            if how == "gone" { link.sealedToken = "" }
            LinkHealthBook.recordFailure(&link, LinkFailure(kind: .revoked, code: how == "gone" ? "ITEM_NOT_FOUND" : "USER_PERMISSION_REVOKED",
                                                            message: "revoked"), now: Date())
        }
        let (status, _) = try await Self.exchange(app, #"{"publicToken":"public-2","institution":"Harbor Bank","institutionID":"ins_1"}"#)
        #expect(status == .created)
        #expect(plaid.count(Self.exchangePath) == 1)
        // The old link stays, with its history.
        #expect(Set(try await service.store.links().map(\.id)) == ["plaid-item-0", "plaid-item-1"])
    }

    @Test("A link waiting for a sign-in still holds its Item: linking the bank again is refused (Reconnect fixes it)")
    func needsSignInStillBlocks() async throws {
        let plaid = Self.provider()
        let (app, _) = try await Self.server(plaid) { link in
            LinkHealthBook.recordFailure(&link, LinkFailure(kind: .needsSignIn, code: "ITEM_LOGIN_REQUIRED", message: "sign in"), now: Date())
        }
        let (status, _) = try await Self.exchange(app, #"{"publicToken":"public-2","institution":"Harbor Bank","institutionID":"ins_1"}"#)
        #expect(status == .conflict)
        #expect(plaid.count(Self.exchangePath) == 0)
    }

    @Test("Other providers' links at the same bank don't count")
    func otherProviderDoesNotBlock() async throws {
        let plaid = Self.provider()
        let (app, _) = try await Self.server(plaid, institutionID: nil) { link in
            link.id = "simplefin-1"; link.provider = .simplefin
        }
        let (status, _) = try await Self.exchange(app, #"{"publicToken":"public-2","institution":"Harbor Bank","institutionID":"ins_1"}"#)
        #expect(status == .created)
    }

    @Test("Only an id shaped like Plaid's is stored")
    func malformedInstitutionIDIgnored() {
        #expect(StoredLink.institutionID("ins_109508") == "ins_109508")
        #expect(StoredLink.institutionID("../ins") == nil)
        #expect(StoredLink.institutionID("") == nil)
        #expect(StoredLink.institutionID(String(repeating: "a", count: 65)) == nil)
        #expect(StoredLink.institutionID(nil) == nil)
    }

    @Test("\"Plaid\" (no bank named by Link) never matches by name")
    func placeholderNameNeverMatches() async throws {
        let plaid = Self.provider()
        let (app, _) = try await Self.server(plaid, institutionID: nil) { $0.institution = "Plaid" }
        let (status, _) = try await Self.exchange(app, #"{"publicToken":"public-2","institution":"Plaid"}"#)
        #expect(status == .created)
    }

    // MARK: Update mode from the dashboard

    static func tokenBody(_ app: some ApplicationProtocol, _ plaid: ScriptedProvider, _ json: String) async throws -> String {
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/links/plaid/token", method: .post, headers: write, body: TestServer.body(json)) { #expect($0.status == .ok) }
        }
        return try #require(plaid.requests.last { $0.path == "/link/token/create" }).body
    }

    @Test("Renew access on a working link asks Plaid for reauthorization; a repair or the card-bill grant doesn't")
    func renewalAsksForReauthorization() async throws {
        let healthy = Self.provider()
        let (app, _) = try await Self.server(healthy)
        let renew = try await Self.tokenBody(app, healthy, #"{"linkID":"plaid-item-0"}"#)
        #expect(renew.contains(#""reauthorization_enabled":true"#) && renew.contains("access-sandbox-0"))
        let grant = try await Self.tokenBody(app, healthy, #"{"linkID":"plaid-item-0","grantCardBills":true}"#)
        #expect(!grant.contains("reauthorization_enabled"))

        let broken = Self.provider()
        let (repairApp, _) = try await Self.server(broken) { link in
            LinkHealthBook.recordFailure(&link, LinkFailure(kind: .needsSignIn, code: "ITEM_LOGIN_REQUIRED", message: "sign in"), now: Date())
        }
        let repair = try await Self.tokenBody(repairApp, broken, #"{"linkID":"plaid-item-0"}"#)
        #expect(!repair.contains("reauthorization_enabled"))
        let fresh = try await Self.tokenBody(repairApp, broken, "{}")
        #expect(!fresh.contains("reauthorization_enabled") && !fresh.contains("access_token"))
    }
    // MARK: After a renewal (the sync that follows update mode: PlaidRenewalTests)

    @Test("The summary's access-ends date is the phone's: a PENDING_DISCONNECT week that ends first wins")
    func summaryAccessEnds() {
        let now = Date()
        var state = PlaidLinkState()
        state.consentExpiresAt = now.addingTimeInterval(60 * 86_400)
        var summary = LinkSummary(id: "plaid-x", provider: .plaid, institution: "Harbor", status: .connected, lastSync: nil, lastError: nil,
                                  createdAt: now, externalID: nil)
        state.summaryFields(into: &summary, liveItem: true, now: now)
        #expect(summary.consentExpiresAt == state.consentExpiresAt)
        state.pendingDisconnectAt = now.addingTimeInterval(-86_400)
        state.summaryFields(into: &summary, liveItem: true, now: now)
        #expect(summary.consentExpiresAt == now.addingTimeInterval(6 * 86_400))
        // A warning week that passed while the Item stayed healthy doesn't hide the consent date.
        state.pendingDisconnectAt = now.addingTimeInterval(-30 * 86_400)
        state.summaryFields(into: &summary, liveItem: true, now: now)
        #expect(summary.consentExpiresAt == state.consentExpiresAt)
        // A consent date that has passed still shows, for "has ended".
        state = PlaidLinkState()
        state.consentExpiresAt = now.addingTimeInterval(-86_400)
        state.summaryFields(into: &summary, liveItem: true, now: now)
        #expect(summary.consentExpiresAt == state.consentExpiresAt)
    }
}
