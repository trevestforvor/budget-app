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

/// Pulls every linked provider into the ledger: Plaid incrementally by cursor, SimpleFIN by date
/// window (two years on first sync). Each run is one rollback-able batch.
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
    /// waits for that run and returns its results. So the person's "Sync now" that lands during a scheduled run gets that
    /// run's results, read with Plaid's cached balances, and no live balance read of its own: accepted, as it's rare and
    /// the next tap reads live.
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
    /// `afterUpdateMode`: the dashboard says Plaid Link just finished update mode on this link (see `noteUpdateMode`).
    public func sync(linkID: String, trigger: SyncTrigger = .personLink, afterUpdateMode: Bool = false) async throws -> LinkSyncResult {
        try await serialized {
            guard let link = try await self.store.links().first(where: { $0.id == linkID }) else { throw BudgetAPIError.notFound }
            guard LinkHealthBook.isDue(link, trigger: trigger, now: Date()) else {
                return LinkSyncResult(linkID: link.id, institution: link.institution, ok: false, error: link.lastError, errorKind: link.errorKind,
                                      skipped: "\(link.institution) is waiting for you to reconnect it, so the server didn't ask the bank.")
            }
            return await self.syncAndPublish(link, trigger: trigger, afterUpdateMode: afterUpdateMode)
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
    /// `change` may return what it found (the daily Item check says whether it healed the link).
    @discardableResult
    public func updateLink<T: Sendable>(_ id: String, _ change: @escaping @Sendable (inout StoredLink) async throws -> T) async throws -> T {
        try await serialized {
            guard var link = try await self.store.links().first(where: { $0.id == id }) else { throw BudgetAPIError.notFound }
            let result = try await change(&link)
            try await self.store.upsertLink(link)
            return result
        }
    }

    private func syncAndPublish(_ link: StoredLink, trigger: SyncTrigger, afterUpdateMode: Bool = false) async -> LinkSyncResult {
        let result = await sync(link, trigger: trigger, afterUpdateMode: afterUpdateMode)
        await publishInstitutions()
        return result
    }

    /// A sync that follows Plaid's update mode: the phone's reconnect (its `/item/get` already ran), or the dashboard
    /// saying Plaid Link just finished one (`afterUpdateMode`). Signing in again is what a PENDING_DISCONNECT asked for,
    /// so its warning is cleared (the access-ends date then goes back to the consent date, if any). After the dashboard's,
    /// the daily Item check is also made due, so the next look (within 15 minutes) reads the renewed consent date instead
    /// of a day later. Only a sync that went through gets here.
    static func noteUpdateMode(_ link: inout StoredLink, trigger: SyncTrigger, afterUpdateMode: Bool) {
        guard link.provider == .plaid, afterUpdateMode || trigger == .reconnect else { return }
        link.plaid?.pendingDisconnectAt = nil
        if afterUpdateMode { link.plaid?.lastItemCheckAt = nil }
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

    private func sync(_ original: StoredLink, trigger: SyncTrigger, afterUpdateMode: Bool = false) async -> LinkSyncResult {
        var link = original
        if trigger.retriesSignIn, link.status == .needsReauth { link.status = .connected }
        let batchID = "\(link.provider.rawValue)-\(link.id)-\(Int(Date().timeIntervalSince1970))"
        do {
            guard let sealer else {
                throw LinkFailure(kind: .providerSetup, code: "no-token-key", message: "BUDGET_TOKEN_KEY isn't set; can't open stored tokens.")
            }
            if link.provider == .plaid, !link.hasLiveItem {
                // Plaid deleted the Item (ITEM_NOT_FOUND, confirmed by /item/get) and the token was dropped: nothing to ask.
                throw LinkFailure(kind: .revoked, code: "ITEM_NOT_FOUND", message: Self.itemGoneMessage(link))
            }
            // Teller withdrew its API in July 2026 and its code is gone; a link stored before then only says so.
            if link.provider == .teller { throw BudgetAPIError.rejected(Self.tellerGone) }
            let token: String
            do { token = try sealer.open(link.sealedToken) } catch {
                throw LinkFailure(kind: .providerSetup, code: "token-unsealable",
                                  message: "The saved sign-in for \(link.institution) won't open with this server's BUDGET_TOKEN_KEY.")
            }
            let outcome: ProviderSyncOutcome
            switch link.provider {
            case .plaid: outcome = try await syncPlaid(&link, token: token, batchID: batchID, trigger: trigger)
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
            Self.noteUpdateMode(&link, trigger: trigger, afterUpdateMode: afterUpdateMode)
            try await store.upsertLink(link)
            let linkID = link.id
            if await LinkHealthBook.shouldRecordImport(report, failure: nil, lastRecordedWarnings: { await self.lastRecordedWarnings(linkID) }) {
                var record = ImportRecord(batchID: batchID, kind: .sync, linkID: link.id, label: "\(link.institution) sync",
                                          report: report, createdAt: Date(), rolledBack: false, outcome: report.warnings.isEmpty ? .ok : .warning)
                if report.rowsAdded + report.rowsUpdated == 0 {
                    // Warnings only: no row carries the batch id, so the record takes an id of its own, as a failure does,
                    // and never replaces the record of a batch in the same second that did write rows.
                    record.batchID = "\(batchID)-warning-\(UUID().uuidString.prefix(8).lowercased())"
                    record.report.batchID = record.batchID
                }
                try await store.upsertImport(record)
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
            if await LinkHealthBook.shouldRecordImport(nil, failure: failure) {
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

    /// Plaid: incrementally by cursor, with balances read as `balanceRead` says, then card bills (best effort).
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
        let now = Date()
        let read = Self.balanceRead(link, trigger: trigger, now: now)
        let pull: PlaidSource.Pull
        do {
            let page = try await source.sync(from: link.cursor)
            if read.isLive {
                // Counted once the transactions are in and the live read goes out, not when it's answered: a refused or
                // failed live read still spent the call. A transactions page that fails never reaches it, so spends none.
                var plaidState = link.plaid ?? PlaidLinkState()
                plaidState.recordBalanceRead(now: now)
                link.plaid = plaidState
            }
            pull = try await source.pull(page, balances: read, now: now)
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
        if pull.liveBalance {
            link.plaid?.balanceAsOf = now
        } else if let refused = pull.balanceFallback {
            logger.warning("live balance for \(link.institution) refused (code \(refused.errorCode ?? "status \(refused.status)"), request_id \(refused.requestID ?? "none")); used Plaid's cached balances")
        }
        let snapshot = pull.snapshot
        let report = try await api.ingest(snapshot, batchID: batchID)
        let removed = try await api.removeSourceRows(.plaid, externalIDs: pull.removed)
        link.cursor = pull.nextCursor
        // Best effort, after the rows are in: never fails the sync (CardBills.swift). A card-bill check that wasn't ready or
        // consented is asked again on a retry, as in 0.5.x: one link's sync, a reconnect or a new link, never a sync of
        // everything. That is `retriesSignIn`, not `requestedByPerson` (which also covers "sync everything" and leaves
        // out reconnects and new links); it's what gates a live balance call, not this.
        link.cardBills = await CardBillSync.refresh(enabled: await settings.cardBillsEnabled, source: source, snapshot: snapshot,
                                                    previous: link.cardBills, requestedByPerson: trigger.retriesSignIn, api: api, now: Date(),
                                                    institution: link.institution, logger: logger)
        // Holdings come from the daily Item check and HOLDINGS webhooks, never a routine sync. The one exception is the
        // person's retry, on the same syncs that retry card bills: after Plaid wasn't ready, wanted consent or failed,
        // one link's sync or a reconnect asks again (`HoldingsSync.isDue`), under the same `auto` rule as the daily check
        // (from the billed products it stored). Never before a first check has run.
        if trigger.retriesSignIn, let previous = link.holdings, [.notReady, .needsConsent, .failed].contains(previous.access) {
            let mode = await settings.holdingsMode
            let enabled = mode == .on || (mode == .auto && (link.plaid?.billedProducts ?? []).contains("investments"))
            link.holdings = await HoldingsSync.refresh(enabled: enabled, source: source, previous: previous, requestedByPerson: true,
                                                       webhookDue: false, api: api, now: Date(), institution: link.institution, logger: logger)
        }
        return ProviderSyncOutcome(report: report, removed: removed)
    }

    /// How this sync reads balances. Routinely Plaid's cached ones (`/accounts/get`). A live read (`/accounts/balance/get`)
    /// only when the person asked (`SyncTrigger.requestedByPerson`: never the schedule, the morning catch-up, a webhook,
    /// a reconnect or a new link's first sync), and only within the per-Item cap; above it, the cached read again. Either
    /// way, cached balances are dated by the newest time they're known to be from, never the time of the fetch.
    static func balanceRead(_ link: StoredLink, trigger: SyncTrigger, now: Date) -> PlaidSource.BalanceRead {
        let state = link.plaid ?? PlaidLinkState()
        let asOf = state.cachedBalanceAsOf(now: now)
        if trigger.requestedByPerson, state.mayReadLiveBalance(now: now) { return .live(fallbackAsOf: asOf) }
        return .cached(asOf: asOf)
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
        "Plaid no longer has this connection to \(link.institution). Link the bank again on the dashboard; its accounts come back as new ones."
    }

    // MARK: - [end lane P]

    /// A failure as the person can read it: the provider's own message when it gave one.
    static func describe(_ error: any Error) -> String {
        switch error {
        case let e as SourceHTTPError: HTTP.providerMessage(e)
        case let e as BudgetAPIError: e.localizedDescription
        // "Plaid: <error_message> (<CODE>)", the same words a sync's SourceHTTPError gives for the same answer.
        case let e as PlaidAPIError: e.localizedDescription
        default: String(describing: error)
        }
    }

    /// Whether the provider refused the saved sign-in (Plaid's ITEM_LOGIN_REQUIRED, a 401 or 403): only the person
    /// signing in again fixes that.
    static func needsSignIn(_ error: any Error) -> Bool {
        let codes = ["ITEM_LOGIN_REQUIRED"]
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
        let records = (try? await store.imports()) ?? []
        let history = Self.recentSyncs(records)
        // The same read prunes each link's old failed and warning-only records, so the history stays bounded.
        let prunable = LinkHealthBook.prunableSyncRecords(records)
        if !prunable.isEmpty { try? await store.deleteImports(prunable) }
        let phoneCapable = await ReconnectMethod.phoneCapable(settings: settings, providers: providers, sealer: sealer)
        let now = Date()
        let rows = links.flatMap { link in
            let base = InstitutionLink(id: link.id, institution: link.institution, primary: link.provider, fallback: nil, accountKinds: [],
                                       status: link.status, note: Self.note(link, style), lastSync: link.lastSync, lastError: link.lastError,
                                       errorKind: link.errorKind, failingSince: link.firstFailedAt, nextRetryAt: link.nextAttemptAt,
                                       consentExpiresAt: ConnectionAlerts.shownAccessEnds(link, now: now),
                                       reconnect: ReconnectMethod.for(link, phoneCapable: phoneCapable), recentSyncs: history[link.id])
            return link.provider == .simplefin ? SimpleFINLinkState.institutionRows(link, base: base, accounts: accounts) : [base]
        }
        await api.setInstitutions(rows)
    }

    /// The warnings on the link's newest recorded sync (none when it failed). Read only for a sync that changed no rows
    /// but warned, to tell a new warning from one every ingest repeats.
    private func lastRecordedWarnings(_ linkID: String) async -> Set<String> {
        LinkHealthBook.lastRecordedWarnings((try? await store.imports()) ?? [], linkID: linkID)
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

    // MARK: A stored Teller link

    /// Teller withdrew its API in July 2026, and 0.6.0 removed its code (SPEC §10). A Teller link stored before then still
    /// decodes (`SourceKind.teller` stays, decode-only): it lists, says this, and can be removed on the dashboard.
    static let tellerGone = "Teller has shut down — remove this link. Its transactions stay."

    /// How a Teller link's failure is filed: terminal rather than transient, with a fixed code, so no scheduled run
    /// retries it (`LinkHealthBook.isDue`) and health and push logic can leave it out (`LinkFailureClassifier`).
    static let tellerFailure = LinkFailure(kind: .providerSetup, code: "teller.shutdown", message: tellerGone)

    /// One plain line about a link, for clients that show a note: what's wrong, by its kind, and what happens next.
    static func note(_ link: StoredLink, _ style: Date.FormatStyle) -> String {
        if link.provider == .teller { return tellerGone }
        let retry = link.nextAttemptAt.map { " The server tries again \($0.formatted(style))." } ?? " The next sync tries again."
        switch link.errorKind {
        case .revoked?:
            if link.provider == .plaid, !link.hasLiveItem { return itemGoneMessage(link) }
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
