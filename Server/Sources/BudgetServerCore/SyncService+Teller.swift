import BudgetKit
import Foundation

extension SyncService {
    /// Teller withdrew its API in July 2026 and its code is gone. A Teller link stored before then still decodes
    /// (`SourceKind.teller`), and syncing one says what to do about it.
    // The integrator removes this file with the `.teller` branch in `SyncService.sync` (SPEC §10, item I2).
    func syncTeller(_ link: inout StoredLink, token: String, batchID: String, trigger: SyncTrigger) async throws -> ProviderSyncOutcome {
        throw BudgetAPIError.rejected(Self.tellerGone)
    }

    /// What a stored Teller link says on the dashboard, on the phone and in its last error.
    static let tellerGone = "Teller has shut down — remove this link. Its transactions stay."

    /// How a Teller link's failure is filed: terminal rather than transient, with a fixed code, so no scheduled run
    /// retries it (`LinkHealthBook.isDue`) and health and push logic can leave it out (`LinkFailureClassifier`).
    static let tellerFailure = LinkFailure(kind: .providerSetup, code: "teller.shutdown", message: tellerGone)
}
