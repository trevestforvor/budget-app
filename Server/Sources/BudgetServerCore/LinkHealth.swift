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

enum LinkFailureClassifier {
    /// Each provider's classifier gets a say first; what neither claims falls back to the rule 0.5.x had: a refused
    /// sign-in (a 401 or 403, ITEM_LOGIN_REQUIRED, a disconnected Teller enrollment) needs one, anything else is
    /// transient.
    static func classify(_ error: any Error, provider: SourceKind) -> LinkFailure {
        if provider == .teller { return SyncService.tellerFailure }  // [lane S] Teller removed (SPEC §10)
        if let failure = PlaidErrors.classify(error) ?? SimpleFINErrors.classify(error) { return failure }
        return LinkFailure(kind: SyncService.needsSignIn(error) ? .needsSignIn : .transient, message: SyncService.describe(error))
    }
}

/// What a sync writes on its link. It reproduces 0.5.x exactly, so the provider moves change no behaviour
/// (`LinkBookkeepingCharacterizationTests`); backoff and retry discipline come later.
enum LinkHealthBook {
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

    /// A sync failed: why, and the failure run. Only a refused sign-in (or withdrawn access) waits for the person;
    /// anything else leaves the status as it was, for the next run.
    static func recordFailure(_ link: inout StoredLink, _ failure: LinkFailure, now: Date) {
        link.lastError = failure.message
        if failure.kind == .needsSignIn || failure.kind == .revoked { link.status = .needsReauth }
        link.lastAttemptAt = now
        link.errorKind = failure.kind
        link.errorCode = failure.code
        link.errorRequestID = failure.requestID
        if link.firstFailedAt == nil { link.firstFailedAt = now }
        link.failureCount = (link.failureCount ?? 0) + 1
    }

    /// Whether a run with `trigger` syncs this link: a link waiting for a sign-in only when the trigger is a retry, and
    /// a stored Teller link never (Teller shut down; only syncing that one link says so again).
    static func isDue(_ link: StoredLink, trigger: SyncTrigger, now: Date) -> Bool {
        guard link.provider != .teller else { return false }  // [lane S] Teller removed (SPEC §10)
        return link.status != .needsReauth || trigger.retriesSignIn
    }

    /// Whether the sync goes in the import history: when it changed rows.
    static func shouldRecordImport(_ report: IngestReport?, failure: LinkFailure?) -> Bool {
        guard failure == nil, let report else { return false }
        return report.rowsAdded + report.rowsUpdated > 0
    }
}
