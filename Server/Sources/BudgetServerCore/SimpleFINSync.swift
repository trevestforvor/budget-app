import BudgetKit
import Foundation
import Logging

/// One SimpleFIN link's sync: plan the windows, check the day's request budget, pull each window, ingest it, and move
/// each bank on. Kept out of `SyncService` so that stays small.
///
/// - The fresh pull reaches back from the oldest healthy bank's last good pull (`SimpleFINPlanner.fresh`).
/// - A bank SimpleFIN reports `con.auth` for is marked on its own; the link stays connected and the other banks keep
///   syncing. Only a refusal of the whole link (403, `gen.auth`) fails the sync, and the link waits for a new setup token.
/// - Older windows (a bank's repair, the history walk) ride along within the budget. One that fails is logged by code
///   and tried on a later run; it never fails the sync.
/// - Every window goes into the same batch, so the sync is one entry in the import history.
enum SimpleFINSync {
    /// What started the run, as the budget counts it: nobody waiting, the person, or a new link.
    static func budgetTrigger(_ trigger: SyncTrigger) -> SimpleFINBudget.Trigger {
        switch trigger {
        case .schedule, .morningCatchUp, .webhook: .scheduled
        case .person, .personLink, .reconnect: .person
        case .afterLink: .firstLink
        }
    }

    static func run(link: inout StoredLink, url: URL, trigger: SyncTrigger, batchID: String, api: LedgerBudgetAPI, transport: any HTTPTransport,
                    automaticPerDay: Int, timeZone: TimeZone, now: Date = Date(), logger: Logger) async throws -> ProviderSyncOutcome {
        var state = link.simplefin ?? SimpleFINLinkState()
        state.requests = SimpleFINBudget.recent(state.requests, now: now)
        // Written back whatever happens below, so every request made counts against the day, even one that failed.
        defer { link.simplefin = state }
        let kind = budgetTrigger(trigger)
        let backfillAllowed: Int
        switch SimpleFINBudget.allowance(log: state.requests, trigger: kind, now: now, automaticPerDay: automaticPerDay) {
        case let .pull(backfill):
            backfillAllowed = backfill
        case let .skipped(nextAt):
            let text = time(nextAt, timeZone)
            logger.info("simplefin \(link.id): skipped (\(state.requests.count) of \(SimpleFINBudget.hardStopPerDay) today); next automatic pull after \(text)")
            return ProviderSyncOutcome(report: nil, skipped: "SimpleFIN refreshes about once a day, so the server asks a few times a day at most. The next pull runs after \(text).")
        case let .refused(nextAt):
            logger.info("simplefin \(link.id): refused, \(state.requests.count) of \(SimpleFINBudget.hardStopPerDay) today")
            throw SimpleFINError.budget(nextAt: nextAt, nextAtText: time(nextAt, timeZone))
        }

        let source = SimpleFINSource(accessURL: url, transport: transport)
        let fresh = SimpleFINPlanner.fresh(connections: state.connections, now: now)
        let pull = try await request(fresh, source: source, state: &state, linkID: link.id, trigger: kind, now: now, logger: logger)
        if let problem = pull.linkProblem {
            throw problem.kind == .revoked ? SimpleFINError.revoked : SimpleFINError.provider(code: problem.code)
        }
        var report = try await api.ingest(pull.snapshot, batchID: batchID)
        let firstSince060 = state.backfill == nil
        update(&state, after: pull, freshStart: fresh.start, startsHistory: !firstSince060, now: now, logger: logger, linkID: link.id)
        if firstSince060 { state.backfill = SimpleFINBackfill(reachedBack: fresh.start) }
        logExtraKeys(pull, state: &state, linkID: link.id, now: now, logger: logger)

        for window in SimpleFINPlanner.catchUp(connections: state.connections, backfill: state.backfill, now: now, limit: backfillAllowed) {
            guard SimpleFINBudget.hasRoom(state.requests, now: now) else { break }
            do {
                let older = try await request(window, source: source, state: &state, linkID: link.id, trigger: kind, now: now, logger: logger)
                if older.linkProblem != nil { break }
                // The bank this window is for went back to needing a sign-in: its gap waits for it.
                if let id = window.connectionID, older.problems.contains(where: { $0.code.hasPrefix("con.auth") && $0.connectionID == id }) { continue }
                merge(try await api.ingest(older.snapshot, batchID: batchID), into: &report)
                advance(&state, after: window, transactions: older.transactionCount, now: now)
            } catch {
                logger.warning("simplefin \(link.id): \(window.purpose.rawValue) window not fetched (\(code(error))); a later run tries again")
                break
            }
        }
        return ProviderSyncOutcome(report: report)
    }

    /// Trades a setup token for the access URL. A token the bridge won't take is the person's to fix (422), not a fault.
    static func claim(_ setupToken: String, transport: any HTTPTransport) async throws -> URL {
        do {
            return try await SimpleFINSource.claim(setupToken: setupToken, transport: transport)
        } catch let error as SimpleFINSource.SetupError {
            throw BudgetAPIError.rejected(error.errorDescription ?? "SimpleFIN didn't take that setup token.")
        }
    }

    /// One request, logged by count (never the URL) and recorded on the link whatever the answer.
    static func request(_ window: SimpleFINWindow, source: SimpleFINSource, state: inout SimpleFINLinkState, linkID: String,
                        trigger: SimpleFINBudget.Trigger, now: Date, logger: Logger) async throws -> SimpleFINPull {
        var status = 0
        defer {
            state.requests.append(SimpleFINRequest(at: now, purpose: window.purpose, trigger: trigger.rawValue, status: status))
            logger.info("simplefin \(linkID): request \(SimpleFINBudget.recent(state.requests, now: now).count) of \(SimpleFINBudget.hardStopPerDay) today (\(window.purpose.rawValue))")
        }
        do {
            let pull = try await source.fetch(window, now: now)
            status = 200
            return pull
        } catch let error as SimpleFINError {
            if case let .http(code) = error { status = code } else if error == .revoked { status = 403 } else if error == .paymentRequired { status = 402 }
            throw error
        }
    }

    /// Moves each bank on after the fresh pull: names and accounts from the bridge; a `con.auth` bank marked as needing a
    /// sign-in (its window stays put); a bank whose accounts all came through stamped, with a repair gap queued when it
    /// was away longer than the fresh pull reaches; a bank first seen on a link that already has history, its history.
    static func update(_ state: inout SimpleFINLinkState, after pull: SimpleFINPull, freshStart: Date, startsHistory: Bool, now: Date,
                       logger: Logger, linkID: String) {
        let accountsByBank = Dictionary(grouping: pull.snapshot.accounts) { $0.connectionID ?? "" }
        let named = Set(pull.snapshot.connections.map(\.id))
        for connection in pull.snapshot.connections {
            let accounts = accountsByBank[connection.id] ?? []
            var bank = state.connections[connection.id]
                ?? SimpleFINConnectionState(name: connection.name, gap: startsHistory ? SimpleFINPlanner.newBankGap(freshStart: freshStart, now: now) : nil)
            bank.name = connection.name
            bank.orgURL = connection.orgURL
            if !accounts.isEmpty { bank.accountIDs = accounts.map(\.externalID) }
            let signIn = pull.problems.first { $0.code.hasPrefix("con.auth") && $0.connectionID == connection.id }
            let failed = pull.problems.contains { $0.code.hasPrefix("act.") && $0.accountID.map(bank.accountIDs.contains) == true }
            if let signIn {
                if bank.status != .needsReauth { logger.info("simplefin \(linkID): \(signIn.code) on one bank; the others keep syncing") }
                bank.status = .needsReauth
                bank.firstFailedAt = bank.firstFailedAt ?? now
                bank.lastMessage = signIn.message
                bank.errorCode = signIn.code
            } else if failed {
                // One account didn't come through: nothing to fix, but its window doesn't move.
                bank.lastMessage = pull.problems.first { $0.code.hasPrefix("act.") && $0.accountID.map(bank.accountIDs.contains) == true }?.message
            } else {
                if bank.status == .needsReauth, bank.gap == nil {
                    // Back from a sign-in: the days it missed, or, if it never brought anything, its history.
                    bank.gap = bank.lastGoodData == nil
                        ? (startsHistory ? SimpleFINPlanner.newBankGap(freshStart: freshStart, now: now) : nil)
                        : SimpleFINPlanner.repairGap(lastGoodData: bank.lastGoodData, freshStart: freshStart)
                }
                bank.status = .connected
                bank.firstFailedAt = nil
                bank.lastMessage = nil
                bank.errorCode = nil
                bank.lastGoodData = pull.requestedAt
            }
            state.connections[connection.id] = bank
        }
        // A bank removed at the bridge stops being listed. A v1 bridge names no connections; nothing is dropped then.
        if !named.isEmpty { state.connections = state.connections.filter { named.contains($0.key) } }
    }

    /// Moves a gap or the history walk on after an older window landed.
    static func advance(_ state: inout SimpleFINLinkState, after window: SimpleFINWindow, transactions: Int, now: Date) {
        if let id = window.connectionID, var bank = state.connections[id], var gap = bank.gap {
            gap.through = window.start
            let empty = gap.purpose == .backfill && transactions == 0
            bank.gap = gap.through <= gap.from || empty ? nil : gap
            state.connections[id] = bank
        } else if window.purpose == .backfill, var backfill = state.backfill {
            backfill.reachedBack = window.start
            backfill.done = SimpleFINPlanner.backfillDone(after: window, transactions: transactions, now: now)
            state.backfill = backfill
        }
    }

    /// The bridge's `extra` key names, once a day per link: what it sends that isn't read yet. Never a value.
    static func logExtraKeys(_ pull: SimpleFINPull, state: inout SimpleFINLinkState, linkID: String, now: Date, logger: Logger) {
        guard !pull.extraKeys.isEmpty, state.extraKeysLoggedAt.map({ now.timeIntervalSince($0) >= SimpleFINBudget.day }) ?? true else { return }
        logger.info("simplefin \(linkID) extra keys: \(pull.extraKeys.sorted().joined(separator: ", ")) (\(pull.transactionCount) rows)")
        state.extraKeysLoggedAt = now
    }

    /// One batch's report from several ingests.
    static func merge(_ other: IngestReport, into report: inout IngestReport) {
        report.accountsAdded += other.accountsAdded
        report.accountsUpdated = max(report.accountsUpdated, other.accountsUpdated)
        report.rowsAdded += other.rowsAdded
        report.rowsUpdated += other.rowsUpdated
        report.duplicatesSkipped += other.duplicatesSkipped
        report.byRule += other.byRule
        report.byTransferMatch = sum(report.byTransferMatch, other.byTransferMatch)
        report.byStatement = sum(report.byStatement, other.byStatement)
        report.byMemory += other.byMemory
        report.byModel += other.byModel
        report.needsReview += other.needsReview
        report.modelCalls += other.modelCalls
        report.warnings += other.warnings.filter { !report.warnings.contains($0) }
        if let notes = other.notes { report.notes = (report.notes ?? []) + notes }
        report.modelMilliseconds = sum(report.modelMilliseconds, other.modelMilliseconds)
        report.addedFrom = [report.addedFrom, other.addedFrom].compactMap { $0 }.min()
        report.addedThrough = [report.addedThrough, other.addedThrough].compactMap { $0 }.max()
        if let samples = other.duplicateSamples { report.duplicateSamples = Array(((report.duplicateSamples ?? []) + samples).prefix(10)) }
    }

    private static func sum(_ a: Int?, _ b: Int?) -> Int? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }

    /// A failure's code for a log line: never a URL or a message from the bridge.
    static func code(_ error: any Error) -> String {
        (error as? SimpleFINError)?.code ?? (error is DecodingError ? "unreadable answer" : "network")
    }

    static func time(_ date: Date, _ timeZone: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = timeZone
        return date.formatted(style)
    }
}

/// `PUT /v1/links/:id/token`'s answer: the sync's result with one more key, `note`.
struct ReplacedToken: Encodable {
    let result: LinkSyncResult
    let note: String?
    enum CodingKeys: String, CodingKey { case note }
    func encode(to encoder: any Encoder) throws {
        try result.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(note, forKey: .note)
    }
}
