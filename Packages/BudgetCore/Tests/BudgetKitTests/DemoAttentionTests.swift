@testable import BudgetKit
import Foundation
import Testing

@Suite("Demo attention")
struct DemoAttentionTests {
    @Test("The demo has one connection waiting for a sign-in, and Home's attention list says so first")
    func expiredConnection() async throws {
        let api = Fixture.api()
        let overview = try await api.overview()
        let attention = try #require(overview.attention)
        #expect(attention.map(\.kind) == [.needsReauth])
        #expect(attention.first?.institution == "Tidewater")
        // The Keystone card's statement came in two weeks ago; the next one isn't due yet, so it isn't flagged.
        #expect(!attention.contains { $0.accountID == Ledger.keystoneCardID })
        let status = try await api.serverStatus()
        let link = try #require(status.institutions.first { $0.id == LedgerBudgetAPI.demoExpiredLinkID })
        #expect(link.status == .needsReauth && link.lastError != nil)
        // Balance-only: the expired link moves no spending figure, so the flex budget is untouched.
        #expect(overview.flex == Fixture.ledger().overview().flex)
    }
}
