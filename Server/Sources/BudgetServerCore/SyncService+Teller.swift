import BudgetKit
import Foundation

extension SyncService {
    /// Teller: by date window, like SimpleFIN.
    func syncTeller(_ link: inout StoredLink, token: String, batchID: String, trigger: SyncTrigger) async throws -> ProviderSyncOutcome {
        guard let teller = await providers.teller() else { throw BudgetAPIError.rejected("Teller isn't set up on the server.") }
        let snapshot = try await TellerSource(accessToken: token, transport: teller.transport).fetch(since: window(link))
        let report = try await api.ingest(snapshot, batchID: batchID)
        return ProviderSyncOutcome(report: report)
    }
}
