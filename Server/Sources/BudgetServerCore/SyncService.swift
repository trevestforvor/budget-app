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

    /// Syncs one link now, whatever its state. Asking for it is a retry: a link waiting for a sign-in is tried again
    /// (the person may just have signed in — Plaid's update mode ends with this call, not a token exchange), and it's
    /// marked as needing one only if the bank still refuses. Any other failure leaves it for the next scheduled sync.
    public func sync(linkID: String, trigger: SyncTrigger = .personLink) async throws -> LinkSyncResult {
        try await serialized {
            guard let link = try await self.store.links().first(where: { $0.id == linkID }) else { throw BudgetAPIError.notFound }
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
            guard let sealer else { throw BudgetAPIError.rejected("BUDGET_TOKEN_KEY isn't set; can't open stored tokens.") }
            let token = try sealer.open(link.sealedToken)
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
                                                          report: report, createdAt: Date(), rolledBack: false))
            }
            logger.info("synced \(link.institution): +\(report.rowsAdded) rows, \(report.needsReview) to review, \(report.modelCalls) model calls in \(report.modelMilliseconds ?? 0) ms\(report.warnings.isEmpty ? "" : " — " + report.warnings.joined(separator: " "))\((report.notes ?? []).isEmpty ? "" : " — " + (report.notes ?? []).joined(separator: " "))")
            return LinkSyncResult(linkID: link.id, institution: link.institution, ok: true, report: report, removed: removed, error: nil)
        } catch {
            // Provider auth failures need the person to reconnect; everything else retries next run.
            let failure = LinkFailureClassifier.classify(error, provider: link.provider)
            LinkHealthBook.recordFailure(&link, failure, now: Date())
            try? await store.upsertLink(link)
            logger.error("sync failed for \(link.institution): \(String(describing: error))")
            return LinkSyncResult(linkID: link.id, institution: link.institution, ok: false, report: nil, removed: 0, error: failure.message,
                                  errorKind: failure.kind)
        }
    }

    // MARK: - [lane P] Plaid

    /// Plaid: incrementally by cursor, then card bills (best effort).
    private func syncPlaid(_ link: inout StoredLink, token: String, batchID: String, trigger: SyncTrigger) async throws -> ProviderSyncOutcome {
        guard let plaid = try await providers.plaid() else { throw BudgetAPIError.rejected("Plaid isn't set up on the server.") }
        let source = PlaidSource(environment: plaid.environment, credentials: .init(clientID: plaid.clientID, secret: plaid.secret),
                                 accessToken: token, institution: link.institution, transport: providers.transport)
        let (snapshot, next, deleted) = try await source.snapshot(cursor: link.cursor)
        let report = try await api.ingest(snapshot, batchID: batchID)
        let removed = try await api.removeSourceRows(.plaid, externalIDs: deleted)
        link.cursor = next
        // Best effort, after the rows are in: never fails the sync (CardBills.swift).
        link.cardBills = await CardBillSync.refresh(enabled: await settings.cardBillsEnabled, source: source, snapshot: snapshot,
                                                    previous: link.cardBills, requestedByPerson: trigger.requestedByPerson, api: api, now: Date(),
                                                    institution: link.institution, logger: logger)
        return ProviderSyncOutcome(report: report, removed: removed)
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
        let rows = links.flatMap { link in
            let base = InstitutionLink(id: link.id, institution: link.institution, primary: link.provider, fallback: nil, accountKinds: [],
                                       status: link.status, note: Self.note(link, style), lastSync: link.lastSync, lastError: link.lastError,
                                       errorKind: link.errorKind, failingSince: link.firstFailedAt, nextRetryAt: link.nextAttemptAt,
                                       consentExpiresAt: link.plaid?.consentExpiresAt)
            return link.provider == .simplefin ? SimpleFINLinkState.institutionRows(link, base: base, accounts: accounts) : [base]
        }
        await api.setInstitutions(rows)
    }

    /// One plain line about a link, for clients that show a note.
    static func note(_ link: StoredLink, _ style: Date.FormatStyle) -> String {
        if link.status == .needsReauth { return "\(link.institution) needs you to sign in again. Reconnect it on the Budget dashboard." }
        if link.lastError != nil { return "The last sync didn't go through. The next one tries again." }
        return link.lastSync.map { "Last synced \($0.formatted(style))." } ?? "Not synced yet."
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
