import BudgetKit
import Foundation

/// Plaid's errors as a kind of failure (`LinkFailureClassifier`).
enum PlaidErrors {
    /// Nil leaves it to the next classifier.
    static func classify(_ error: any Error) -> LinkFailure? { nil }
}
