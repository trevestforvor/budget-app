import BudgetKit
import Foundation

/// Why a sync failed, provider-agnostic.
public struct LinkFailure: Sendable, Equatable {
    public var kind: LinkErrorKind
    /// The provider's code ("ITEM_LOCKED", "con.auth"), when it gave one.
    public var code: String?
    /// Plaid's request_id; safe to log and show.
    public var requestID: String?
    /// The failure as the person can read it.
    public var message: String

    public init(kind: LinkErrorKind, code: String? = nil, requestID: String? = nil, message: String) {
        self.kind = kind; self.code = code; self.requestID = requestID; self.message = message
    }
}

/// A failure the server knows the kind of before asking any provider (no token key, a token that won't open, Plaid not
/// set up, an Item Plaid has already deleted). Thrown as is, and the classifier takes it as it is.
extension LinkFailure: LocalizedError {
    public var errorDescription: String? { message }
}

enum LinkFailureClassifier {
    /// A `LinkFailure` thrown by the sync is already classified. Otherwise the link's provider's classifier gets a say
    /// first; what none claims falls back to the rule 0.5.x had: a refused sign-in (a 401 or 403, ITEM_LOGIN_REQUIRED,
    /// a disconnected Teller enrollment) needs one, anything else is transient.
    static func classify(_ error: any Error, provider: SourceKind) -> LinkFailure {
        if let failure = error as? LinkFailure { return failure }
        if provider == .plaid, let failure = PlaidErrors.classify(error) { return failure }
        if let failure = SimpleFINErrors.classify(error) { return failure }
        return LinkFailure(kind: SyncService.needsSignIn(error) ? .needsSignIn : .transient, message: SyncService.describe(error))
    }
}

/// What a sync writes on its link, and whether the next run asks the provider at all.
///
/// - A transient failure, a rate limit or a setup problem backs off: the next scheduled try waits
///   `min(6 h, 5 min · 2^(n−1))`, give or take 20 %, after the n-th failure in a row.
/// - A refused sign-in waits for the person (or a reconnect, or Plaid saying the login is repaired): retrying on a
///   schedule can't fix it. A webhook (Plaid has new data) still tries, until the third failure in a row.
/// - Withdrawn access is never retried on its own.
/// - The person asking always goes ahead, whatever the backoff says.
enum LinkHealthBook {
    /// The first wait after a failure, and the most the wait grows to.
    static let firstBackoff: TimeInterval = 5 * 60
    static let maxBackoff: TimeInterval = 6 * 3600
    /// Failures in a row after which a webhook stops trying a link that needs a sign-in.
    static let signInRetries = 3

    /// A sync went through: connected, stamped, the error and the failure run cleared.
    static func recordSuccess(_ link: inout StoredLink, now: Date) {
        link.status = .connected
        link.lastSync = now
        link.lastError = nil
        link.lastAttemptAt = now
        link.errorKind = nil
        link.errorCode = nil
        link.errorRequestID = nil
        link.firstFailedAt = nil
        link.failureCount = nil
        link.nextAttemptAt = nil
    }

    /// A sync failed: why, the failure run, and when to try again. Only a refused sign-in (or withdrawn access) waits for
    /// the person; anything else leaves the status as it was and backs off. `jitter` (0.8–1.2) spreads the retries.
    static func recordFailure(_ link: inout StoredLink, _ failure: LinkFailure, now: Date, jitter: Double = .random(in: 0.8...1.2)) {
        link.lastError = failure.message
        if failure.kind == .needsSignIn || failure.kind == .revoked { link.status = .needsReauth }
        link.lastAttemptAt = now
        link.errorKind = failure.kind
        link.errorCode = failure.code
        link.errorRequestID = failure.requestID
        if link.firstFailedAt == nil { link.firstFailedAt = now }
        let count = (link.failureCount ?? 0) + 1
        link.failureCount = count
        switch failure.kind {
        case .needsSignIn, .revoked: link.nextAttemptAt = nil
        case .transient, .rateLimited, .providerSetup: link.nextAttemptAt = now.addingTimeInterval(backoff(failures: count) * jitter)
        }
    }

    /// The wait after the `failures`-th failure in a row, before jitter.
    static func backoff(failures: Int) -> TimeInterval {
        min(maxBackoff, firstBackoff * pow(2, Double(min(max(failures - 1, 0), 20))))
    }

    /// Whether a run with `trigger` asks the provider for this link.
    static func isDue(_ link: StoredLink, trigger: SyncTrigger, now: Date) -> Bool {
        // One link's "Sync now", a reconnect and a new link always go: they're how a link gets repaired.
        if trigger.retriesSignIn { return true }
        let webhook = if case .webhook = trigger { true } else { false }
        // A link parked before 0.6.0 has no kind: it waits for a sign-in.
        let kind = link.errorKind ?? (link.status == .needsReauth ? .needsSignIn : nil)
        switch kind {
        case .revoked?:
            return false
        case .needsSignIn?:
            return webhook && (link.failureCount ?? 0) < signInRetries
        default:
            if link.status == .needsReauth { return false }
            // The person's "sync everything" and Plaid saying it has data ready skip the backoff.
            if trigger.requestedByPerson || webhook { return true }
            return (link.nextAttemptAt ?? .distantPast) <= now
        }
    }

    /// Whether the sync goes in the import history: it changed rows, it finished with warnings, or it failed. A clean
    /// sync with nothing new writes nothing, so the history doesn't grow by a row per link per run.
    static func shouldRecordImport(_ report: IngestReport?, failure: LinkFailure?) -> Bool {
        if failure != nil { return true }
        guard let report else { return false }
        return report.rowsAdded + report.rowsUpdated > 0 || !report.warnings.isEmpty
    }
}
