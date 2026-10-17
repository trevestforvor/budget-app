import BudgetKit
@testable import BudgetServerCore
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import Testing

/// After Plaid's update mode (P8 review): the dashboard's sync says Link finished, which answers a PENDING_DISCONNECT
/// and makes the Item check due; a plain sync costs no extra /item/get. Also the access-ends date's one rule, and the
/// one-Item-per-bank check holding when two exchanges race.
@Suite("Plaid renewal")
struct PlaidRenewalTests {
    static func sync(_ app: some ApplicationProtocol, _ json: String?) async throws -> HTTPResponse.Status {
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/links/plaid-item-0/sync", method: .post, headers: PlaidDashboardTests.write,
                                     body: json.map(TestServer.body)) { $0.status }
        }
    }

    @Test("A renewal after a PENDING_DISCONNECT, finished on the dashboard, clears the warning and makes the Item check due")
    func renewalClearsPendingDisconnect() async throws {
        let plaid = PlaidDashboardTests.provider()
        let checked = Date().addingTimeInterval(-600)
        let warned = Date().addingTimeInterval(-86_400)
        let (app, service) = try await PlaidDashboardTests.server(plaid) { link in
            link.plaid?.lastItemCheckAt = checked
            link.plaid?.pendingDisconnectAt = warned
        }
        let before = try #require(try await service.store.links().first)
        #expect(before.summary.consentExpiresAt == warned.addingTimeInterval(ConnectionAlerts.pendingDisconnectNotice))
        #expect(!PlaidMaintenance.isDue(before, now: Date()))

        #expect(try await Self.sync(app, #"{"afterUpdateMode":true}"#) == .ok)
        let after = try #require(try await service.store.links().first)
        #expect(after.plaid?.pendingDisconnectAt == nil)
        #expect(after.summary.consentExpiresAt == nil)
        #expect(after.plaid?.lastItemCheckAt == nil && PlaidMaintenance.isDue(after, now: Date()))
    }

    @Test("A plain sync of the same link, even with consent ending soon, keeps the warning and costs no extra Item check")
    func plainSyncLeavesItAlone() async throws {
        let plaid = PlaidDashboardTests.provider()
        let checked = Date().addingTimeInterval(-7_200)
        let warned = Date().addingTimeInterval(-86_400)
        let (app, service) = try await PlaidDashboardTests.server(plaid) { link in
            link.plaid?.lastItemCheckAt = checked
            link.plaid?.pendingDisconnectAt = warned
            link.plaid?.consentExpiresAt = Date().addingTimeInterval(5 * 86_400)
        }
        #expect(try await Self.sync(app, nil) == .ok)
        let link = try #require(try await service.store.links().first)
        #expect(link.plaid?.pendingDisconnectAt == warned && link.plaid?.lastItemCheckAt == checked)
    }

    @Test("The phone's reconnect clears the warning too, and keeps the Item check its /item/get just made")
    func phoneReconnectClearsWarning() async throws {
        let plaid = PlaidDashboardTests.provider()
        let checked = Date().addingTimeInterval(-5)
        let (_, service) = try await PlaidDashboardTests.server(plaid) { link in
            link.plaid?.lastItemCheckAt = checked
            link.plaid?.pendingDisconnectAt = Date().addingTimeInterval(-86_400)
        }
        #expect(try await service.sync.sync(linkID: "plaid-item-0", trigger: .reconnect).ok)
        let link = try #require(try await service.store.links().first)
        #expect(link.plaid?.pendingDisconnectAt == nil && link.plaid?.lastItemCheckAt == checked)
    }

    @Test("A sync after update mode that the bank still refuses leaves the warning and the check as they were")
    func failedSyncKeepsWarning() async throws {
        let plaid = ScriptedProvider(["/transactions/sync": [PlaidScript.loginRequired]])
        let checked = Date().addingTimeInterval(-600)
        let warned = Date().addingTimeInterval(-86_400)
        let (app, service) = try await PlaidDashboardTests.server(plaid) { link in
            link.plaid?.lastItemCheckAt = checked
            link.plaid?.pendingDisconnectAt = warned
        }
        #expect(try await Self.sync(app, #"{"afterUpdateMode":true}"#) == .ok)
        let link = try #require(try await service.store.links().first)
        #expect(link.plaid?.pendingDisconnectAt == warned && link.plaid?.lastItemCheckAt == checked)
    }

    @Test("Update mode on the dashboard ends the failure run: a transient failure right after starts a new episode")
    func updateModeEndsFailureRun() async throws {
        let plaid = ScriptedProvider(["/transactions/sync": [PlaidErrorKindTests.plaidError("INSTITUTION_DOWN", type: "INSTITUTION_ERROR")]])
        let firstFailed = Date().addingTimeInterval(-3 * 86_400)
        let (app, service) = try await PlaidDashboardTests.server(plaid) { link in
            LinkHealthBook.recordFailure(&link, LinkFailure(kind: .needsSignIn, code: "ITEM_LOGIN_REQUIRED", message: "sign in"), now: firstFailed)
            LinkHealthBook.recordFailure(&link, LinkFailure(kind: .needsSignIn, code: "ITEM_LOGIN_REQUIRED", message: "sign in"), now: firstFailed.addingTimeInterval(3_600))
        }
        #expect(try await service.store.links().first?.failureCount == 2)
        #expect(try await Self.sync(app, #"{"afterUpdateMode":true}"#) == .ok)
        let link = try #require(try await service.store.links().first)
        #expect(link.errorKind == .transient)
        #expect(link.failureCount == 1)
        #expect((link.firstFailedAt ?? .distantPast) > firstFailed.addingTimeInterval(86_400))
    }

    @Test("The phone's token can't claim update mode: afterUpdateMode on the API leaves a PENDING_DISCONNECT warning")
    func phoneCantClaimUpdateMode() async throws {
        let plaid = PlaidDashboardTests.provider()
        let warned = Date().addingTimeInterval(-86_400)
        let (_, service) = try await PlaidDashboardTests.server(plaid) { link in link.plaid?.pendingDisconnectAt = warned }
        let api = Application(router: buildRouter(service, surface: .api))
        try await api.test(.router) { client in
            var headers = TestServer.auth
            headers[.contentType] = "application/json"
            try await client.execute(uri: "/v1/links/plaid-item-0/sync", method: .post, headers: headers,
                                     body: TestServer.body(#"{"afterUpdateMode":true}"#)) { #expect($0.status == .ok) }
        }
        #expect(try await service.store.links().first?.plaid?.pendingDisconnectAt == warned)
    }

    @Test("A link whose token was dropped shows no access-ends date, on the dashboard as on the phone")
    func droppedTokenHasNoAccessEnds() async throws {
        let plaid = PlaidDashboardTests.provider()
        let (_, service) = try await PlaidDashboardTests.server(plaid) { link in
            link.plaid?.consentExpiresAt = Date().addingTimeInterval(5 * 86_400)
            link.sealedToken = ""
            LinkHealthBook.recordFailure(&link, LinkFailure(kind: .revoked, code: "ITEM_NOT_FOUND", message: "gone"), now: Date())
        }
        let link = try #require(try await service.store.links().first)
        #expect(link.summary.consentExpiresAt == nil)
        #expect(ConnectionAlerts.shownAccessEnds(link, now: Date()) == nil)
    }

    @Test("The summary and the phone read the same access-ends date")
    func summaryMatchesPhone() async throws {
        let now = Date()
        for (consent, warned) in [(5.0, nil), (60.0, -1.0), (60.0, -30.0), (-1.0, nil), (nil, -1.0)] as [(Double?, Double?)] {
            let plaid = PlaidDashboardTests.provider()
            let (_, service) = try await PlaidDashboardTests.server(plaid) { link in
                link.plaid?.consentExpiresAt = consent.map { now.addingTimeInterval($0 * 86_400) }
                link.plaid?.pendingDisconnectAt = warned.map { now.addingTimeInterval($0 * 86_400) }
            }
            let link = try #require(try await service.store.links().first)
            var summary = link.summary
            link.plaid?.summaryFields(into: &summary, liveItem: link.hasLiveItem, now: now)
            #expect(summary.consentExpiresAt == ConnectionAlerts.shownAccessEnds(link, now: now))
        }
    }

    @Test("The refusal stays short enough for the dashboard to show it, however long the bank's name")
    func refusalFitsTheDashboard() {
        var link = StoredLink(id: "plaid-x", provider: .plaid, institution: String(repeating: "Northwind Federal Credit Union ", count: 4),
                              externalID: nil, sealedToken: "x", cursor: nil, status: .connected, lastSync: nil, lastError: nil, createdAt: Date())
        #expect(StoredLink.duplicateItemMessage(link).count <= 180)
        link.institution = "Harbor Bank"
        #expect(StoredLink.duplicateItemMessage(link).hasPrefix("Harbor Bank is already linked."))
    }

    @Test("Two exchanges for the same bank at once (two tabs): one links, the other is refused before exchanging")
    func racingExchanges() async throws {
        let plaid = ScriptedProvider([
            PlaidDashboardTests.exchangePath: [PlaidScript.exchange],
            "/transactions/sync": [PlaidScript.page("c1")],
            "/accounts/get": [PlaidScript.balances],
        ], delay: .milliseconds(150))
        let (app, service) = try await TestServer.app(seedDemo: false, plaid: plaid, surface: .dashboard)
        let json = #"{"publicToken":"public-1","institution":"Northwind","institutionID":"ins_9"}"#
        let statuses = try await app.test(.router) { client in
            async let first = client.execute(uri: "/v1/links/plaid/exchange", method: .post, headers: PlaidDashboardTests.write,
                                             body: TestServer.body(json)) { $0.status.code }
            async let second = client.execute(uri: "/v1/links/plaid/exchange", method: .post, headers: PlaidDashboardTests.write,
                                              body: TestServer.body(json)) { $0.status.code }
            return try await [first, second].sorted()
        }
        #expect(statuses == [201, 409])
        #expect(plaid.count(PlaidDashboardTests.exchangePath) == 1)
        #expect(try await service.store.links().count == 1)
    }
}
