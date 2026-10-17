import BudgetKit
import Foundation

/// Plaid's errors as a kind of failure (`LinkFailureClassifier`). It branches on `error_type` and `error_code`, never on
/// the HTTP status or the message, which Plaid may reword (INSTITUTION_DOWN comes back as a 400 and is transient).
enum PlaidErrors {
    /// The person has to sign in to the bank again (update mode); retrying on a schedule can't help.
    static let needsSignIn = PlaidAPIError.needsSignInCodes
    /// The Item is gone or its access was withdrawn.
    static let revoked = PlaidAPIError.revokedCodes
    /// The server's own Plaid setup is wrong: its keys, or a token from another environment.
    static let providerSetup = PlaidAPIError.providerSetupCodes
    /// Plaid or the bank asked us to slow down. Any error of type RATE_LIMIT_EXCEEDED is one too, whatever its code.
    static let rateLimited: Set<String> = ["RATE_LIMIT_EXCEEDED", "INSTITUTION_RATE_LIMIT"]

    /// Plaid's error in `error`, read from the typed error or from a raw HTTP failure's body; nil when it isn't Plaid's.
    static func plaidError(_ error: any Error) -> PlaidAPIError? {
        if let plaid = error as? PlaidAPIError { return plaid }
        return (error as? SourceHTTPError).flatMap(PlaidAPIError.init)
    }

    /// Nil leaves it to the next classifier: an error without Plaid's `error_type`/`error_code` (a network failure, a
    /// proxy's HTML page) isn't Plaid's to judge.
    static func classify(_ error: any Error) -> LinkFailure? {
        guard let plaid = plaidError(error) else { return nil }
        return LinkFailure(kind: kind(type: plaid.errorType, code: plaid.errorCode), code: plaid.errorCode ?? plaid.errorType,
                           requestID: plaid.requestID, message: SyncService.describe(error))
    }

    /// A code this list doesn't know is transient: Plaid adds codes without notice, so nothing here matches
    /// exhaustively, and an unknown failure backs off rather than parking the link.
    static func kind(type: String?, code: String?) -> LinkErrorKind {
        if let code {
            if needsSignIn.contains(code) { return .needsSignIn }
            if revoked.contains(code) { return .revoked }
            if providerSetup.contains(code) { return .providerSetup }
            if rateLimited.contains(code) { return .rateLimited }
        }
        if type == "RATE_LIMIT_EXCEEDED" { return .rateLimited }
        // INSTITUTION_DOWN, INSTITUTION_NOT_RESPONDING, PRODUCT_NOT_READY, API_ERROR, a pagination that kept changing,
        // and everything unknown.
        return .transient
    }
}
