import BudgetKit
@testable import BudgetServerCore
import Foundation
import Testing

/// A PENDING_DISCONNECT reaches the phone the same way its push does: the institution row carries the week's notice as
/// the date access ends, so Linked accounts shows "Renew access" and Home an `expiring-` item a tapped push can open.
@Suite("PENDING_DISCONNECT on the phone: the published date matches the push")
struct PendingDisconnectPublishTests {
    typealias R = ReconnectRouteTests

    /// The real clock: `publishInstitutions` and the ledger read it, not the fixture's.
    static func fixture(pendingDisconnect: Date?, consent: Date? = nil) async throws -> R.Fixture {
        try await R.fixture(needsSignIn: false, link: { link in
            var plaid = PlaidLinkState()
            plaid.pendingDisconnectAt = pendingDisconnect
            plaid.consentExpiresAt = consent
            link.plaid = plaid
        })
    }

    @Test("Only a PENDING_DISCONNECT, no consent date: a date about 7 days out, one expiring item for the link")
    func pendingDisconnectOnly() async throws {
        let warned = Date()
        let f = try await Self.fixture(pendingDisconnect: warned)
        await f.service.sync.publishInstitutions()
        let row = try #require(try await f.service.api.serverStatus().institutions.first { $0.id == R.id })
        let ends = try #require(row.consentExpiresAt)
        #expect(abs(ends.timeIntervalSince(warned) - ConnectionAlerts.pendingDisconnectNotice) < 1)
        #expect(ends == ConnectionAlerts.accessEnds(try await f.link(), now: Date()))
        let expiring = (try await f.service.api.overview().attention ?? []).filter { $0.id == "expiring-\(R.id)" }
        #expect(expiring.count == 1)
        #expect(expiring.first?.reason == DataAttention.Reason.consentExpiring)
        #expect(expiring.first?.dueBy == ends)
    }

    @Test("A consent date sooner than the week's notice wins, as in the push")
    func soonerConsentWins() async throws {
        let consent = Date().addingTimeInterval(3 * 86_400)
        let f = try await Self.fixture(pendingDisconnect: Date(), consent: consent)
        await f.service.sync.publishInstitutions()
        #expect(try await f.service.api.serverStatus().institutions.first { $0.id == R.id }?.consentExpiresAt == consent)
    }

    @Test("A consent date already past still publishes, for \"has ended\"")
    func passedConsentStillShown() async throws {
        let consent = Date().addingTimeInterval(-86_400)
        let f = try await Self.fixture(pendingDisconnect: nil, consent: consent)
        await f.service.sync.publishInstitutions()
        #expect(try await f.service.api.serverStatus().institutions.first { $0.id == R.id }?.consentExpiresAt == consent)
    }

    @Test("Neither date: nothing published and no expiring item")
    func neither() async throws {
        let f = try await Self.fixture(pendingDisconnect: nil)
        await f.service.sync.publishInstitutions()
        #expect(try await f.service.api.serverStatus().institutions.first { $0.id == R.id }?.consentExpiresAt == nil)
        #expect((try await f.service.api.overview().attention ?? []).allSatisfy { !$0.id.hasPrefix("expiring-") })
    }
}
