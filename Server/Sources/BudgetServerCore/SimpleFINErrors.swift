import BudgetKit
import Foundation

/// SimpleFIN's errors as a kind of failure (`LinkFailureClassifier`): 403 or `gen.auth` → revoked (a new setup token),
/// 402 or `gen.api` → the provider's side, the server's own daily cap → rate limited, anything else → transient. One
/// bank's `con.auth` never gets here: it doesn't fail the sync (`SimpleFINSync`).
enum SimpleFINErrors {
    /// Nil leaves it to the next classifier.
    static func classify(_ error: any Error) -> LinkFailure? {
        guard let error = error as? SimpleFINError else { return nil }
        return LinkFailure(kind: error.kind, code: error.code, message: error.errorDescription ?? "SimpleFIN sync failed.")
    }
}
