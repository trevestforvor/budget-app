import BudgetKit
import Foundation
import Logging

/// Pulls every linked provider into the ledger: Plaid incrementally by cursor, Teller and
/// SimpleFIN by date window (two years on first sync). Each run is one rollback-able batch.
///
/// Runs happen one at a time — the schedule, "sync everything", one bank's "Sync now" and a reconnect — so two never
/// pull the same link (and write its cursor) at once.
public actor SyncService {
    private let api: LedgerBudgetAPI
    private let store: any ServerStore
    private let config: ServerConfig
    private let sealer: TokenSealer?
    private let providers: Providers
    private let settings: ServerSettings
    private let logger: Logger
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
    public func syncAll() async -> [LinkSyncResult] {
        if let allRun { return await allRun.value }
        let run = Task { (try? await serialized { await self.runAll() }) ?? [] }
        allRun = run
        defer { allRun = nil }
        return await run.value
    }

    private func runAll() async -> [LinkSyncResult] {
        var results: [LinkSyncResult] = []
        for link in (try? await store.links()) ?? [] where link.status != .needsReauth {
            results.append(await sync(link, retrying: false))
        }
        await publishInstitutions()
        return results
    }

    /// Syncs one link now, whatever its state. Asking for it is a retry: a link waiting for a sign-in is tried again
    /// (the person may just have signed in — Plaid's update mode ends with this call, not a token exchange), and it's
    /// marked as needing one only if the bank still refuses. Any other failure leaves it for the next scheduled sync.
    public func sync(linkID: String) async throws -> LinkSyncResult {
        try await serialized {
            guard let link = try await self.store.links().first(where: { $0.id == linkID }) else { throw BudgetAPIError.notFound }
            return await self.syncAndPublish(link)
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
            return await self.syncAndPublish(link)
        }
    }

    private func syncAndPublish(_ link: StoredLink) async -> LinkSyncResult {
        let result = await sync(link, retrying: true)
        await publishInstitutions()
        return result
    }

    /// Runs `work` after every run already started.
    private func serialized<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { () async throws -> T in
            await previous?.value
            return try await work()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }

    private func sync(_ original: StoredLink, retrying: Bool) async -> LinkSyncResult {
        var link = original
        if retrying, link.status == .needsReauth { link.status = .connected }
        let batchID = "\(link.provider.rawValue)-\(link.id)-\(Int(Date().timeIntervalSince1970))"
        do {
            guard let sealer else { throw BudgetAPIError.rejected("BUDGET_TOKEN_KEY isn't set; can't open stored tokens.") }
            let token = try sealer.open(link.sealedToken)
            var removed = 0
            let report: IngestReport
            switch link.provider {
            case .plaid:
                guard let plaid = try await providers.plaid() else { throw BudgetAPIError.rejected("Plaid isn't set up on the server.") }
                let source = PlaidSource(environment: plaid.environment, credentials: .init(clientID: plaid.clientID, secret: plaid.secret),
                                         accessToken: token, institution: link.institution, transport: providers.transport)
                let (snapshot, next, deleted) = try await source.snapshot(cursor: link.cursor)
                report = try await api.ingest(snapshot, batchID: batchID)
                removed = try await api.removeSourceRows(.plaid, externalIDs: deleted)
                link.cursor = next
            case .teller:
                guard let teller = await providers.teller() else { throw BudgetAPIError.rejected("Teller isn't set up on the server.") }
                let snapshot = try await TellerSource(accessToken: token, transport: teller.transport).fetch(since: window(link))
                report = try await api.ingest(snapshot, batchID: batchID)
            case .simplefin:
                guard let url = URL(string: token) else { throw BudgetAPIError.rejected("Stored SimpleFIN access URL is invalid.") }
                let snapshot = try await SimpleFINSource(accessURL: url).fetch(since: window(link))
                report = try await api.ingest(snapshot, batchID: batchID)
            default:
                throw BudgetAPIError.rejected("\(link.provider.displayName) links don't sync.")
            }
            link.status = .connected
            link.lastSync = Date()
            link.lastError = nil
            try await store.upsertLink(link)
            if report.rowsAdded + report.rowsUpdated > 0 {
                try await store.upsertImport(ImportRecord(batchID: batchID, kind: .sync, linkID: link.id, label: "\(link.institution) sync",
                                                          report: report, createdAt: Date(), rolledBack: false))
            }
            logger.info("synced \(link.institution): +\(report.rowsAdded) rows, \(report.needsReview) to review, \(report.modelCalls) model calls in \(report.modelMilliseconds ?? 0) ms\(report.warnings.isEmpty ? "" : " — " + report.warnings.joined(separator: " "))\((report.notes ?? []).isEmpty ? "" : " — " + (report.notes ?? []).joined(separator: " "))")
            return LinkSyncResult(linkID: link.id, institution: link.institution, ok: true, report: report, removed: removed, error: nil)
        } catch {
            let message = Self.describe(error)
            link.lastError = message
            // Provider auth failures need the person to reconnect; everything else retries next run.
            if Self.needsSignIn(error) { link.status = .needsReauth }
            try? await store.upsertLink(link)
            logger.error("sync failed for \(link.institution): \(String(describing: error))")
            return LinkSyncResult(linkID: link.id, institution: link.institution, ok: false, report: nil, removed: 0, error: message)
        }
    }

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

    /// First sync reaches back two years; later syncs overlap ten days to catch late-posting rows.
    private func window(_ link: StoredLink) -> Date {
        if let last = link.lastSync { return last.addingTimeInterval(-10 * 86_400) }
        return Date().addingTimeInterval(-Double(Self.historyDays) * 86_400)
    }

    /// Keeps Settings → Accounts in step with the real links. The ledger adds each link's accounts and how far they
    /// reach (`serverStatus`), and lists statement-only institutions after them.
    public func publishInstitutions() async {
        let links = (try? await store.links()) ?? []
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = await settings.timeZone
        let rows = links.map { link in
            InstitutionLink(id: link.id, institution: link.institution, primary: link.provider, fallback: nil, accountKinds: [],
                            status: link.status, note: Self.note(link, style), lastSync: link.lastSync, lastError: link.lastError)
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
            _ = await syncAll()
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
