import BudgetKit
import Foundation

/// SimpleFIN's errors as a kind of failure (`LinkFailureClassifier`).
enum SimpleFINErrors {
    /// Nil leaves it to the next classifier.
    static func classify(_ error: any Error) -> LinkFailure? { nil }
}
