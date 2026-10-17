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
    /// first; what none claims falls back to the rule 0.5.x had: a refused sign-in (a 401 or 403, ITEM_LOGIN_REQUIRED)
    /// needs one, anything else is transient. A stored Teller link's is always the shut-down note.
    static func classify(_ error: any Error, provider: SourceKind) -> LinkFailure {
        if provider == .teller { return SyncService.tellerFailure }
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
///   schedule can't fix it (0.5.5 did the same, and Plaid says not to). A webhook (Plaid has new data) still tries,
///   until the third refused sign-in in a row.
/// - Withdrawn access is never retried on its own.
/// - A webhook skips only a transient failure's backoff (Plaid has the data ready); a rate limit or a setup problem
///   keeps its wait, since asking sooner can't help.
/// - The person asking always goes ahead, whatever the backoff says. Their "sync everything" still leaves out links
///   that need a sign-in or lost their access, as 0.5.5 did; their sync of that one link, a reconnect or a new link
///   tries it.
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
        link.plaid?.signInFailures = nil
    }

    /// Plaid's `/item/get` says the Item is healthy again (the person signed in elsewhere, or LOGIN_REPAIRED): connected,
    /// the error and the failure run cleared, which ends the push episode. Not stamped as synced: nothing was pulled.
    static func recordRepaired(_ link: inout StoredLink) {
        link.status = .connected
        link.lastError = nil
        link.errorKind = nil
        link.errorCode = nil
        link.errorRequestID = nil
        link.firstFailedAt = nil
        link.failureCount = nil
        link.nextAttemptAt = nil
        link.plaid?.signInFailures = nil
    }

    /// Whether the link waits for the person: a refused sign-in or withdrawn access (or a link parked before 0.6.0).
    static func waitsForPerson(_ link: StoredLink) -> Bool {
        link.status == .needsReauth || link.errorKind == .needsSignIn || link.errorKind == .revoked
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
        if failure.kind == .needsSignIn, link.provider == .plaid {
            var plaid = link.plaid ?? PlaidLinkState()
            plaid.signInFailures = (plaid.signInFailures ?? 0) + 1
            link.plaid = plaid
        } else {
            link.plaid?.signInFailures = nil
        }
        switch failure.kind {
        case .needsSignIn, .revoked: link.nextAttemptAt = nil
        case .transient, .rateLimited, .providerSetup: link.nextAttemptAt = now.addingTimeInterval(backoff(failures: count) * jitter)
        }
    }

    /// The wait after the `failures`-th failure in a row, before jitter.
    static func backoff(failures: Int) -> TimeInterval {
        min(maxBackoff, firstBackoff * pow(2, Double(min(max(failures - 1, 0), 20))))
    }

    /// Refused sign-ins in a row. Plaid (the only provider with webhooks) counts them apart from other failures, so a
    /// bank that was down before it asked for a sign-in doesn't use up a webhook's retries; elsewhere it's every failure
    /// in a row.
    static func signInFailures(_ link: StoredLink) -> Int {
        link.provider == .plaid ? link.plaid?.signInFailures ?? 0 : link.failureCount ?? 0
    }

    /// Whether a run with `trigger` asks the provider for this link. A stored Teller link goes only when it's synced
    /// alone (Teller shut down; that says so again), never in a run.
    static func isDue(_ link: StoredLink, trigger: SyncTrigger, now: Date) -> Bool {
        // One link's "Sync now", a reconnect and a new link always go: they're how a link gets repaired.
        if trigger.retriesSignIn { return true }
        guard link.provider != .teller else { return false }
        let webhook = if case .webhook = trigger { true } else { false }
        // A link parked before 0.6.0 has no kind: it waits for a sign-in.
        let kind = link.errorKind ?? (link.status == .needsReauth ? .needsSignIn : nil)
        switch kind {
        case .revoked?:
            return false
        case .needsSignIn?:
            return webhook && signInFailures(link) < signInRetries
        case .rateLimited?, .providerSetup?:
            if link.status == .needsReauth { return false }
            // Only the person skips this wait: asking again sooner, webhook or not, can't lift a rate limit or fix keys.
            if trigger.requestedByPerson { return true }
            return (link.nextAttemptAt ?? .distantPast) <= now
        case .transient?, nil:
            if link.status == .needsReauth { return false }
            // The person's "sync everything" and Plaid saying it has data ready skip the backoff.
            if trigger.requestedByPerson || webhook { return true }
            return (link.nextAttemptAt ?? .distantPast) <= now
        }
    }

    /// Whether the sync goes in the import history: it failed, it changed rows, or it warned about something the link's
    /// last recorded sync didn't. A clean sync with nothing new writes nothing, so the history doesn't grow by a row per
    /// link per run. Some warnings come with every ingest while a setting is off (a decision model not set up, a non-USD
    /// account set aside, a SimpleFIN errlist entry): those are recorded once, not each run. `lastRecordedWarnings` is
    /// asked only for a sync that changed no rows but warned.
    static func shouldRecordImport(_ report: IngestReport?, failure: LinkFailure?,
                                   lastRecordedWarnings: @Sendable () async -> Set<String> = { [] }) async -> Bool {
        if failure != nil { return true }
        guard let report else { return false }
        if report.rowsAdded + report.rowsUpdated > 0 || loggedMerges(report) > 0 { return true }
        guard !report.warnings.isEmpty else { return false }
        return Set(report.warnings) != (await lastRecordedWarnings())
    }

    /// Merge-log entries this sync logged under its own batch: pending rows it settled or dropped, and rows it skipped as
    /// already here (less those an earlier import logged first). The dashboard offers Bring back for them only on the
    /// batch's history row, so a sync that logged any is recorded, under its own batch id, even when it wrote no rows.
    static func loggedMerges(_ report: IngestReport) -> Int {
        (report.pendingSettled ?? 0) + (report.pendingDropped ?? 0) + max(0, report.duplicatesSkipped - (report.duplicatesSkippedBefore ?? 0))
    }

    /// How many sync records that wrote no rows (failed, or warnings only) each link keeps; older ones are pruned.
    static let rowFreeRecordsKept = 50

    /// Sync records that wrote no rows (a failure, or warnings only: each has an id of its own, `-failed-` /
    /// `-warning-`) beyond each link's newest `keep`. A record whose batch wrote rows is the unit of Undo and is never
    /// pruned here, nor is a file import. A failing link backs off to every 6 hours, so without this its failures alone
    /// would add about 1,500 records a year.
    static func prunableSyncRecords(_ records: [ImportRecord], keep: Int = rowFreeRecordsKept) -> [String] {
        let rowFree = records.filter { r in
            r.kind == .sync && r.linkID != nil && r.report.rowsAdded + r.report.rowsUpdated == 0
                && (r.outcome == .failed || r.batchID.contains("-failed-") || r.batchID.contains("-warning-"))
        }
        return Dictionary(grouping: rowFree) { $0.linkID ?? "" }.values.flatMap { list in
            list.sorted { $0.createdAt > $1.createdAt }.dropFirst(keep).map(\.batchID)
        }
    }

    /// The warnings on the link's newest recorded sync: none when that one failed (a warning back after a failure is
    /// recorded again).
    static func lastRecordedWarnings(_ records: [ImportRecord], linkID: String) -> Set<String> {
        let last = records.filter { $0.kind == .sync && $0.linkID == linkID }.max { $0.createdAt < $1.createdAt }
        guard let last, last.outcome != .failed else { return [] }
        return Set(last.report.warnings)
    }
}
