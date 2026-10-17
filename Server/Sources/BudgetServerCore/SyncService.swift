import BudgetKit
import Foundation
import Logging

/// What started a sync. It decides whether a link waiting for a sign-in is tried, and whether the person asked (which
/// may spend a live balance call).
public enum SyncTrigger: Sendable, Equatable {
    /// The interval schedule.
    case schedule
    /// The morning summary catching up before it counts yesterday.
    case morningCatchUp
    /// The person's "Sync now" for everything (`POST /v1/sync` with `requestedByPerson`).
    case person
    /// The person's sync of one link (`POST /v1/links/:id/sync`).
    case personLink
    /// The end of signing in again (update mode).
    case reconnect
    /// The first sync of a new link.
    case afterLink
    /// A provider webhook, by its code.
    case webhook(String)

    /// Only the person's own asks: never a schedule, an app open, a webhook or a first sync.
    public var requestedByPerson: Bool {
        switch self {
        case .person, .personLink: true
        default: false
        }
    }

    /// A link waiting for a sign-in is tried again (the person may just have signed in).
    public var retriesSignIn: Bool {
        switch self {
        case .personLink, .reconnect, .afterLink: true
        default: false
        }
    }
}

/// What one provider's pull did, for the shared bookkeeping.
struct ProviderSyncOutcome: Sendable {
    /// What the ingest did; nil when the provider wasn't asked this time (`skipped` says why).
    var report: IngestReport?
    /// Rows the provider deleted and the ledger dropped.
    var removed: Int = 0
    var skipped: String? = nil
}

/// Pulls every linked provider into the ledger: Plaid incrementally by cursor, Teller and
/// SimpleFIN by date window (two years on first sync). Each run is one rollback-able batch.
///
/// Runs happen one at a time — the schedule, "sync everything", one bank's "Sync now" and a reconnect — so two never
/// pull the same link (and write its cursor) at once.
public actor SyncService {
    // Internal, not private: the provider extensions in other files (SyncService+SimpleFIN.swift, …) use them.
    let api: LedgerBudgetAPI
    let store: any ServerStore
    let config: ServerConfig
    let sealer: TokenSealer?
    let providers: Providers
    let settings: ServerSettings
    let logger: Logger
    /// The "sync everything" in progress, which a second request joins instead of starting another.
    private var allRun: Task<[LinkSyncResult], Never>?
    /// The last run started; each waits for the one before it.
    private var tail: Task<Void, Never>?

    public init(api: LedgerBudgetAPI, store: any ServerStore, config: ServerConfig, sealer: TokenSealer?, providers: Providers,
                settings: ServerSettings, logger: Logger) {
        self.settings = settings
        self.api = api
        self.store = store
        self.config = config
        self.sealer = sealer
        self.providers = providers
        self.logger = logger
    }

    public static let historyDays = 730

    /// Syncs every link, one at a time. A link waiting for the person to sign in again is left out — it would only be
    /// refused again — until a reconnect or a sync of that link marks it connected. A call while a run is under way
    /// waits for that run and returns its results.
    public func syncAll(trigger: SyncTrigger = .schedule) async -> [LinkSyncResult] {
        if let allRun { return await allRun.value }
        let run = Task { (try? await serialized { await self.runAll(trigger: trigger) }) ?? [] }
        allRun = run
        defer { allRun = nil }
        return await run.value
    }

    private func runAll(trigger: SyncTrigger) async -> [LinkSyncResult] {
        var results: [LinkSyncResult] = []
        let now = Date()
        for link in (try? await store.links()) ?? [] where LinkHealthBook.isDue(link, trigger: trigger, now: now) {
            results.append(await sync(link, trigger: trigger))
        }
        await publishInstitutions()
        return results
    }

    /// Syncs one link now. Asked by the person, a reconnect or a new link, that's whatever its state, and a retry: a link
    /// waiting for a sign-in is tried again (the person may just have signed in — Plaid's update mode ends with this
    /// call, not a token exchange), and it's marked as needing one only if the bank still refuses. Any other failure
    /// leaves it for the next scheduled sync. A webhook's sync keeps the stop rules (`LinkHealthBook.isDue`): a link
    /// whose access was withdrawn, or that has needed a sign-in three times running, is left alone.
    public func sync(linkID: String, trigger: SyncTrigger = .personLink) async throws -> LinkSyncResult {
        try await serialized {
            guard let link = try await self.store.links().first(where: { $0.id == linkID }) else { throw BudgetAPIError.notFound }
            guard LinkHealthBook.isDue(link, trigger: trigger, now: Date()) else {
                return LinkSyncResult(linkID: link.id, institution: link.institution, ok: false, error: link.lastError, errorKind: link.errorKind,
                                      skipped: "\(link.institution) is waiting for you to reconnect it, so the server didn't ask the bank.")
            }
            return await self.syncAndPublish(link, trigger: trigger)
        }
    }

    /// Asks for a sync of one link without waiting for it (a webhook's trigger). Several asks may share one run later;
    /// for now each is its own.
    public func requestSync(linkID: String, trigger: SyncTrigger) async {
        Task { _ = try? await self.sync(linkID: linkID, trigger: trigger) }
    }

    /// Changes a stored link in its turn, between syncs, so a sync that read the link earlier can't write over the
    /// change. Every link write outside a sync goes through here. Never call it from inside a sync or another
    /// `serialized` block: the queue isn't re-entrant, and that waits forever.
    public func updateLink(_ id: String, _ change: @escaping @Sendable (inout StoredLink) async throws -> Void) async throws {
        try await serialized {
            guard var link = try await self.store.links().first(where: { $0.id == id }) else { throw BudgetAPIError.notFound }
            try await change(&link)
            try await self.store.upsertLink(link)
        }
    }

    /// Stores the access token Teller Connect hands back when the person reconnects an enrollment, marks the link
    /// connected, and syncs it. The link keeps its id, so its accounts and history carry on.
    public func replaceToken(linkID: String, accessToken: String, enrollmentID: String?) async throws -> LinkSyncResult {
        try await serialized {
            guard var link = try await self.store.links().first(where: { $0.id == linkID }) else { throw BudgetAPIError.notFound }
            guard link.provider == .teller else {
                throw BudgetAPIError.rejected("Only Teller connections take a new access token; \(link.institution) connects through \(link.provider.displayName).")
            }
            let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw BudgetAPIError.rejected("The access token is empty.") }
            guard let sealer = self.sealer else { throw BudgetAPIError.rejected("Set BUDGET_TOKEN_KEY on the server before linking accounts.") }
            link.sealedToken = try sealer.seal(token)
            if let enrollmentID, !enrollmentID.isEmpty { link.externalID = enrollmentID }
            link.status = .connected
            link.lastError = nil
            try await self.store.upsertLink(link)
            return await self.syncAndPublish(link, trigger: .reconnect)
        }
    }

    private func syncAndPublish(_ link: StoredLink, trigger: SyncTrigger) async -> LinkSyncResult {
        let result = await sync(link, trigger: trigger)
        await publishInstitutions()
        return result
    }

    /// Runs `work` after every run already started. Not re-entrant: `work` must never call `serialized` again
    /// (`updateLink`, `sync(linkID:)`, `syncAll`), directly or through anything it calls, or both wait forever. Inside a
    /// sync, change the `inout` link instead.
    func serialized<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { () async throws -> T in
            await previous?.value
            return try await work()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    private func sync(_ original: StoredLink, trigger: SyncTrigger) async -> LinkSyncResult {
        var link = original
        if trigger.retriesSignIn, link.status == .needsReauth { link.status = .connected }
        let batchID = "\(link.provider.rawValue)-\(link.id)-\(Int(Date().timeIntervalSince1970))"
        do {
            guard let sealer else {
                throw LinkFailure(kind: .providerSetup, code: "no-token-key", message: "BUDGET_TOKEN_KEY isn't set; can't open stored tokens.")
            }
            if link.provider == .plaid, link.sealedToken.isEmpty {
                // Plaid deleted the Item (ITEM_NOT_FOUND, confirmed by /item/get) and the token was dropped: nothing to ask.
                throw LinkFailure(kind: .revoked, code: "ITEM_NOT_FOUND", message: Self.itemGoneMessage(link))
            }
            let token: String
            do { token = try sealer.open(link.sealedToken) } catch {
                throw LinkFailure(kind: .providerSetup, code: "token-unsealable",
                                  message: "The saved sign-in for \(link.institution) won't open with this server's BUDGET_TOKEN_KEY.")
            }
            let outcome: ProviderSyncOutcome
            switch link.provider {
            case .plaid: outcome = try await syncPlaid(&link, token: token, batchID: batchID, trigger: trigger)
            case .teller: outcome = try await syncTeller(&link, token: token, batchID: batchID, trigger: trigger)
            case .simplefin: outcome = try await syncSimpleFIN(&link, token: token, batchID: batchID, trigger: trigger)
            default:
                throw BudgetAPIError.rejected("\(link.provider.displayName) links don't sync.")
            }
            guard let report = outcome.report else {
                // The provider wasn't asked this time: nothing synced, so nothing is stamped.
                try await store.upsertLink(link)
                return LinkSyncResult(linkID: link.id, institution: link.institution, ok: true, report: nil, removed: 0, error: nil, skipped: outcome.skipped)
            }
            let removed = outcome.removed
            LinkHealthBook.recordSuccess(&link, now: Date())
            try await store.upsertLink(link)
            if LinkHealthBook.shouldRecordImport(report, failure: nil) {
                try await store.upsertImport(ImportRecord(batchID: batchID, kind: .sync, linkID: link.id, label: "\(link.institution) sync",
                                                          report: report, createdAt: Date(), rolledBack: false,
                                                          outcome: report.warnings.isEmpty ? .ok : .warning))
            }
            logger.info("synced \(link.institution): +\(report.rowsAdded) rows, \(report.needsReview) to review, \(report.modelCalls) model calls in \(report.modelMilliseconds ?? 0) ms\(report.warnings.isEmpty ? "" : " — " + report.warnings.joined(separator: " "))\((report.notes ?? []).isEmpty ? "" : " — " + (report.notes ?? []).joined(separator: " "))")
            return LinkSyncResult(linkID: link.id, institution: link.institution, ok: true, report: report, removed: removed, error: nil)
        } catch {
            // A refused sign-in or withdrawn access waits for the person; everything else backs off and retries.
            let failure = LinkFailureClassifier.classify(error, provider: link.provider)
            let now = Date()
            LinkHealthBook.recordFailure(&link, failure, now: now)
            try? await store.upsertLink(link)
            // The failure goes in the history, so the person can see the bank has been failing, not only that it is.
            // It wrote no rows, so it gets an id of its own: the batch id is per second, and a failure must never replace
            // the record of a batch that did write rows.
            if LinkHealthBook.shouldRecordImport(nil, failure: failure) {
                let failedID = "\(batchID)-failed-\(UUID().uuidString.prefix(8).lowercased())"
                try? await store.upsertImport(ImportRecord(batchID: failedID, kind: .sync, linkID: link.id, label: "\(link.institution) sync",
                                                           report: IngestReport(batchID: failedID, source: link.provider), createdAt: now,
                                                           rolledBack: false, outcome: .failed, error: failure.message, errorKind: failure.kind))
            }
            // The kind, the provider's code and Plaid's request_id (what Plaid support asks for); never a token or a body.
            logger.error("sync failed for \(link.institution): \(failure.kind.rawValue), code \(failure.code ?? "none"), request_id \(failure.requestID ?? "none"): \(failure.message)")
            return LinkSyncResult(linkID: link.id, institution: link.institution, ok: false, report: nil, removed: 0, error: failure.message,
                                  errorKind: failure.kind)
        }
    }

    // MARK: - [lane P] Plaid

    /// Plaid: incrementally by cursor, then card bills (best effort).
    ///
    /// The rows and the cursor are separate writes (the ledger, then the link), so they're replay-safe rather than
    /// atomic: the cursor is stored only after the rows are in and the removed ones dropped, and a crash in between
    /// replays from the old cursor, which ingest absorbs (rows are keyed by Plaid's id).
    private func syncPlaid(_ link: inout StoredLink, token: String, batchID: String, trigger: SyncTrigger) async throws -> ProviderSyncOutcome {
        guard let plaid = try await providers.plaid() else {
            throw LinkFailure(kind: .providerSetup, code: "plaid-not-configured", message: "Plaid isn't set up on the server.")
        }
        let source = PlaidSource(environment: plaid.environment, credentials: .init(clientID: plaid.clientID, secret: plaid.secret),
                                 accessToken: token, institution: link.institution, transport: providers.transport)
        let snapshot: SourceSnapshot, next: String, deleted: [String]
        do {
            (snapshot, next, deleted) = try await source.snapshot(cursor: link.cursor)
        } catch where PlaidErrors.plaidError(error)?.errorCode == "ITEM_NOT_FOUND" {
            // Unrecoverable: the Item was removed at Plaid. Once /item/get agrees, drop the token (it opens nothing now)
            // and keep the link, its accounts and its rows. Never /item/remove it: there's nothing left to remove.
            if await Self.itemIsGone(source) {
                link.sealedToken = ""
                logger.warning("Plaid no longer has the Item for \(link.institution); its token is dropped, its rows kept")
                throw LinkFailure(kind: .revoked, code: "ITEM_NOT_FOUND", requestID: PlaidErrors.plaidError(error)?.requestID,
                                  message: Self.itemGoneMessage(link))
            }
            throw error
        }
        let report = try await api.ingest(snapshot, batchID: batchID)
        let removed = try await api.removeSourceRows(.plaid, externalIDs: deleted)
        link.cursor = next
        // Best effort, after the rows are in: never fails the sync (CardBills.swift). A card-bill check that wasn't ready or
        // consented is asked again on a retry, as in 0.5.x: one link's sync, a reconnect or a new link, never a sync of
        // everything. That is `retriesSignIn`, not `requestedByPerson` (which also covers "sync everything" and leaves
        // out reconnects and new links); it's what gates a live balance call, not this.
        link.cardBills = await CardBillSync.refresh(enabled: await settings.cardBillsEnabled, source: source, snapshot: snapshot,
                                                    previous: link.cardBills, requestedByPerson: trigger.retriesSignIn, api: api, now: Date(),
                                                    institution: link.institution, logger: logger)
        return ProviderSyncOutcome(report: report, removed: removed)
    }

    /// Whether `/item/get` also says the Item is gone. Any other answer (healthy, another error, no answer) keeps the token.
    static func itemIsGone(_ source: PlaidSource) async -> Bool {
        do {
            _ = try await source.item()
            return false
        } catch {
            return PlaidErrors.plaidError(error)?.errorCode == "ITEM_NOT_FOUND"
        }
    }

    static func itemGoneMessage(_ link: StoredLink) -> String {
        "Plaid no longer has this connection to \(link.institution). Link the bank again; its history stays."
    }

    // MARK: - [end lane P]

    /// A failure as the person can read it: the provider's own message when it gave one.
    static func describe(_ error: any Error) -> String {
        switch error {
        case let e as SourceHTTPError: HTTP.providerMessage(e)
        case let e as BudgetAPIError: e.localizedDescription
        default: String(describing: error)
        }
    }

    /// Whether the provider refused the saved sign-in (Plaid's ITEM_LOGIN_REQUIRED, a disconnected Teller enrollment,
    /// a 401 or 403): only the person signing in again fixes that.
    static func needsSignIn(_ error: any Error) -> Bool {
        let codes = ["ITEM_LOGIN_REQUIRED", "enrollment.disconnected"]
        if let e = error as? SourceHTTPError { return [401, 403].contains(e.status) || codes.contains { e.body.contains($0) } }
        let text = String(describing: error)
        return codes.contains { text.contains($0) }
    }

    /// How far a window source's later syncs reach back before the last one, to catch late-posting rows.
    static let overlapDays = 10

    /// First sync reaches back two years; later syncs overlap ten days to catch late-posting rows.
    func window(_ link: StoredLink) -> Date {
        if let last = link.lastSync { return last.addingTimeInterval(-Double(Self.overlapDays) * 86_400) }
        return Date().addingTimeInterval(-Double(Self.historyDays) * 86_400)
    }

    /// Keeps Settings → Accounts in step with the real links. The ledger adds each link's accounts and how far they
    /// reach (`serverStatus`), and lists statement-only institutions after them.
    public func publishInstitutions() async {
        let links = (try? await store.links()) ?? []
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = await settings.timeZone
        let accounts = await api.accountList()
        let history = Self.recentSyncs((try? await store.imports()) ?? [])
        let rows = links.flatMap { link in
            let base = InstitutionLink(id: link.id, institution: link.institution, primary: link.provider, fallback: nil, accountKinds: [],
                                       status: link.status, note: Self.note(link, style), lastSync: link.lastSync, lastError: link.lastError,
                                       errorKind: link.errorKind, failingSince: link.firstFailedAt, nextRetryAt: link.nextAttemptAt,
                                       consentExpiresAt: link.plaid?.consentExpiresAt, recentSyncs: history[link.id])
            return link.provider == .simplefin ? SimpleFINLinkState.institutionRows(link, base: base, accounts: accounts) : [base]
        }
        await api.setInstitutions(rows)
    }

    /// Each link's last five recorded syncs, newest first: the ones that changed rows, warned or failed (a clean sync with
    /// nothing new isn't recorded).
    static func recentSyncs(_ records: [ImportRecord], limit: Int = 5) -> [String: [SyncOutcome]] {
        var byLink: [String: [ImportRecord]] = [:]
        for record in records where record.kind == .sync { if let id = record.linkID { byLink[id, default: []].append(record) } }
        return byLink.mapValues { list in
            list.sorted { $0.createdAt > $1.createdAt }.prefix(limit).map { r in
                SyncOutcome(at: r.createdAt, ok: r.outcome != .failed, rowsAdded: r.report.rowsAdded, kind: r.errorKind,
                            message: r.error ?? (r.report.warnings.isEmpty ? nil : r.report.warnings.joined(separator: " ")))
            }
        }
    }

    /// One plain line about a link, for clients that show a note: what's wrong, by its kind, and what happens next.
    static func note(_ link: StoredLink, _ style: Date.FormatStyle) -> String {
        let retry = link.nextAttemptAt.map { " The server tries again \($0.formatted(style))." } ?? " The next sync tries again."
        switch link.errorKind {
        case .revoked?:
            if link.provider == .plaid, link.sealedToken.isEmpty { return itemGoneMessage(link) }
            return "Access to \(link.institution) was withdrawn. Reconnect it on the Budget dashboard."
        case .needsSignIn?:
            return "\(link.institution) needs you to sign in again. Reconnect it on the Budget dashboard."
        case .rateLimited?:
            return "\(link.institution) asked the server to slow down." + retry
        case .providerSetup?:
            return "The server's \(link.provider.displayName) setup needs attention on the Budget dashboard: \(link.lastError ?? "it was refused")."
        case .transient?:
            return "The last sync didn't go through." + retry
        case nil:
            if link.status == .needsReauth { return "\(link.institution) needs you to sign in again. Reconnect it on the Budget dashboard." }
            if link.lastError != nil { return "The last sync didn't go through. The next one tries again." }
            return link.lastSync.map { "Last synced \($0.formatted(style))." } ?? "Not synced yet."
        }
    }

    /// Runs `syncAll` on an interval for the life of the process. The first wait counts from the last sync, not from
    /// the start: every deploy restarts the server, and a schedule that started over each time never came round.
    public func runScheduler() async {
        let links = ((try? await store.links()) ?? []).filter { $0.status != .needsReauth }
        var wait = Self.firstWait(interval: await settings.syncIntervalHours * 3600, lastSync: links.compactMap(\.lastSync).max(),
                                  linked: !links.isEmpty, now: Date())
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(wait))
            _ = await syncAll(trigger: .schedule)
            // Read each cycle, so a new interval from the dashboard applies after the current wait.
            wait = await settings.syncIntervalHours * 3600
        }
    }

    /// How long a server that just started waits before its first sync: what's left of the interval since the last
    /// one — a minute at least, so it settles first — or the whole interval when nothing is linked.
    static func firstWait(interval: TimeInterval, lastSync: Date?, linked: Bool, now: Date) -> TimeInterval {
        guard linked else { return interval }
        let left = lastSync.map { $0.addingTimeInterval(interval).timeIntervalSince(now) } ?? 0
        return min(max(left, 60), interval)
    }
}
