import Foundation

extension Ledger {
    /// How fresh each account is (`Overview.accountHealth`), in the ledger's order. A synced account is current until
    /// two days pass without a clean pull of it (`Account.lastSyncedAt`; before its first stamp, its link's last clean
    /// sync), then stale; a SimpleFIN account whose bank date (`balanceAsOf`) is older than that goes by it instead, since
    /// the Bridge can keep serving old data without an error. One under a row waiting for a sign-in is `waitingForSignIn`
    /// instead (that row has its own push and repair button). A statement account is overdue once its newest row is
    /// older than a month's statement plus time to import it; it has no balance date (the import stamps the day it ran,
    /// not the statement's). An account no link brings any more, or under a link that hasn't synced cleanly yet, is
    /// `notSynced`.
    ///
    /// The two days don't scale with the sync interval: with `syncIntervalHours` past about 47, every account would go
    /// stale between scheduled syncs (SimpleFIN pulls at least once a day, so it can't).
    /// - Parameter institutions: the deployment's links; which accounts each holds is worked out as the phone sees it.
    func accountHealth(institutions: [InstitutionLink]) -> [AccountHealth]? {
        // A row waiting for a sign-in wins over another that also names the account.
        var holder: [String: InstitutionLink] = [:]
        for row in institutionLinks(institutions) where row.primary != .fileImport {
            for id in row.accountIDs ?? [] where holder[id] == nil || row.status == .needsReauth { holder[id] = row }
        }
        var newest: [String: Date] = [:]
        for row in transactions where row.postedAt > newest[row.accountID] ?? .distantPast { newest[row.accountID] = row.postedAt }
        return accounts.map { account in
            if account.source == .fileImport {
                // By day, as the quiet rule counts it, so both call the same statement overdue.
                guard let latest = newest[account.id].map(calendar.startOfDay) else { return AccountHealth(id: account.id, state: .notSynced) }
                let due = latest.addingTimeInterval(Self.statementStaleAfterDays * 86_400)
                return AccountHealth(id: account.id, state: now > due ? .statementsOverdue : .current, lastGoodSync: latest,
                                     staleSince: now > due ? due : nil)
            }
            var health = AccountHealth(id: account.id, state: .notSynced, lastGoodSync: account.lastSyncedAt, balanceAsOf: account.balanceAsOf)
            guard let row = holder[account.id] else { return health }
            // An account not stamped since 0.6.0 (its link failing ever since, or not bringing it) counts from the link's
            // last clean sync, so it can still go stale.
            let pulled = account.lastSyncedAt ?? row.lastSync
            let banked = account.source == .simplefin ? account.balanceAsOf : nil
            health.lastGoodSync = [pulled, banked].compactMap { $0 }.min()
            if row.status == .needsReauth {
                health.state = .waitingForSignIn
            } else if pulled != nil, let synced = health.lastGoodSync {
                let due = synced.addingTimeInterval(Self.syncStaleAfterDays * 86_400)
                health.state = now > due ? .stale : .current
                health.staleSince = now > due ? due : nil
            }
            return health
        }
    }

    /// Each synced account not pulled cleanly for two days (`sync-stale-<id>`, reason `.syncStale`: we haven't heard
    /// from the bank), then each checking, savings or card account whose newest transaction is older than its own rhythm
    /// allows (`stale-<id>`, reason `.quiet`: the bank is quiet) — for an account that only comes from statements, once
    /// the next statement is overdue. An account already stale, or waiting for a sign-in, isn't called quiet too. After
    /// `linkAttention` in `dataHealth`.
    func staleAttention(_ institutions: [InstitutionLink]) -> [DataAttention] {
        let reauth = institutions.filter { $0.status == .needsReauth }
        var result: [DataAttention] = []
        var dayStyle = Date.FormatStyle.dateTime.month(.abbreviated).day()
        dayStyle.timeZone = calendar.timeZone
        let health = Dictionary((accountHealth(institutions: institutions) ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = institutionLinks(institutions)
        for account in accounts {
            guard let item = health[account.id], item.state == .stale, let since = item.lastGoodSync else { continue }
            let row = rows.first { $0.primary != .fileImport && $0.accountIDs?.contains(account.id) == true }
            result.append(DataAttention(
                id: "sync-stale-\(account.id)", kind: .stale,
                title: "\(Self.fullName(account)) hasn't updated since \(since.formatted(dayStyle)).",
                detail: "Its bank hasn't come through in over \(Int(Self.syncStaleAfterDays)) days, so its balance and transactions may be behind. Sync it, or check the connection on the Budget dashboard.",
                institution: account.institution, accountID: account.id, reason: .syncStale, linkID: row.map { $0.syncLinkID ?? $0.id }))
        }
        let unheard = Set(health.values.filter { $0.state == .stale || $0.state == .waitingForSignIn }.map(\.id))
        // An institution waiting for a sign-in already says why its accounts went quiet.
        let paused = Set(reauth.map { Self.institutionKey($0.institution) })
        // One that synced cleanly in the last few days is being heard from, so a quiet account there with nothing on
        // it is a card nobody uses, not missing data.
        let syncing = Set(institutions.filter { link in
            (link.status == .connected || link.status == .demo) && link.lastError == nil
                && link.lastSync.map { now.timeIntervalSince($0) <= Self.recentSyncDays * 86_400 } == true
        }.map { Self.institutionKey($0.institution) })
        var days: [String: Set<Date>] = [:]
        for row in transactions { days[row.accountID, default: []].insert(calendar.startOfDay(for: row.postedAt)) }
        for account in accounts where account.kind != .investment && !paused.contains(Self.institutionKey(account.institution)) && !unheard.contains(account.id) {
            guard let active = days[account.id]?.sorted(), let latest = active.last else { continue }
            let gaps = zip(active.dropFirst(), active).map { $0.timeIntervalSince($1) / 86_400 }.sorted()
            let fromFiles = account.source == .fileImport
            let allowed = max(fromFiles ? Self.statementStaleAfterDays : Self.staleAfterDays, 3 * (gaps.isEmpty ? 0 : gaps[gaps.count / 2]))
            guard now.timeIntervalSince(latest) / 86_400 > allowed else { continue }
            if !fromFiles, syncing.contains(Self.institutionKey(account.institution)), balance(of: account.id, through: now) == .zero { continue }
            result.append(DataAttention(
                id: "stale-\(account.id)", kind: .stale,
                title: "Nothing new from \(Self.fullName(account)) since \(latest.formatted(dayStyle)).",
                detail: fromFiles ? "Its transactions come from statements. Import a newer one on the Budget dashboard."
                                  : "It's still connected, but no transactions have arrived. Sync it, or check the connection on the Budget dashboard.",
                institution: account.institution, accountID: account.id, reason: .quiet))
        }
        return result
    }

    /// An account is stale once its newest row is at least this many days old (or three of its usual gaps, if longer).
    static let staleAfterDays: Double = 10
    /// A statement-only account can't be newer than its last statement: it's stale once a month's statement plus about
    /// ten days to import it has passed since its newest row, here and in sync health (`statementsOverdue`). (The
    /// dashboard's coverage is a different, later signal: it flags a calendar month with no rows at all once the 7th of
    /// the next month has passed.)
    static let statementStaleAfterDays: Double = 40
    /// A synced account is stale once this many days pass without a clean pull of it (`AccountHealth.State.stale`).
    static let syncStaleAfterDays: Double = 2
    /// A link that synced without an error this recently counts as heard from.
    static let recentSyncDays: Double = 3
}
