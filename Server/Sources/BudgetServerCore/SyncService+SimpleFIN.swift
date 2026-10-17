import BudgetKit
import Foundation

extension SyncService {
    /// SimpleFIN: by date window (two years on the first sync, then from ten days before the last).
    func syncSimpleFIN(_ link: inout StoredLink, token: String, batchID: String, trigger: SyncTrigger) async throws -> ProviderSyncOutcome {
        guard let url = URL(string: token) else { throw BudgetAPIError.rejected("Stored SimpleFIN access URL is invalid.") }
        let snapshot = try await SimpleFINSource(accessURL: url).fetch(since: window(link))
        let report = try await api.ingest(snapshot, batchID: batchID)
        return ProviderSyncOutcome(report: report)
    }
}
