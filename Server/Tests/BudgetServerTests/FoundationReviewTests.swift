import BudgetKit
@testable import BudgetServerCore
import Foundation
import Testing

/// What the foundation review pinned: card bills are re-asked on exactly the syncs 0.5.5 re-asked on, whatever the new
/// triggers say about balance calls.
@Suite("0.6.0 foundation review")
struct FoundationReviewTests {
    @Test("A card-bill check waiting for consent is asked again on a reconnect or a new link, never on sync everything")
    func cardBillRetriesAsBefore() async throws {
        let plaid = LiabilitiesScript.provider(liabilities: [LiabilitiesScript.error("ADDITIONAL_CONSENT_REQUIRED"),
                                                            LiabilitiesScript.error("ADDITIONAL_CONSENT_REQUIRED"), LiabilitiesScript.bills])
        let (_, service) = try await TestServer.app(seedDemo: false, plaid: plaid)
        try await LiabilitiesScript.turnOn(service)
        try await LiabilitiesScript.link(service)

        #expect(await service.sync.syncAll().map(\.ok) == [true])
        #expect(try await LiabilitiesScript.check(service)?.access == .needsConsent)
        #expect(plaid.count("/liabilities/get") == 1)

        // "Sync now" for everything, from the phone or the dashboard, didn't re-ask in 0.5.5 and still doesn't.
        _ = await service.sync.syncAll(trigger: .person)
        #expect(plaid.count("/liabilities/get") == 1)

        // A new link's first sync and a reconnect did, and still do.
        _ = try await service.sync.sync(linkID: "plaid-item-1", trigger: .afterLink)
        #expect(plaid.count("/liabilities/get") == 2)
        _ = try await service.sync.sync(linkID: "plaid-item-1", trigger: .reconnect)
        #expect(plaid.count("/liabilities/get") == 3)
        #expect(try await LiabilitiesScript.check(service)?.access == .ok)
    }

    @Test("A stale account's push episode is keyed by its last good sync, in epoch seconds")
    func staleEpisodeKey() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(ConnectionAlerts.staleKey(accountID: "plaid:chk", lastGoodSync: at) == "stale|plaid:chk|1790000000")
    }
}
