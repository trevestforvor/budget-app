import Foundation

extension Ledger {
    /// How fresh each synced account is (`Overview.accountHealth`). Nil until sync health is built.
    func accountHealth(institutions: [InstitutionLink]) -> [AccountHealth]? { nil }

    /// Each checking, savings or card account whose newest transaction is older than its own rhythm allows — for an
    /// account that only comes from statements, once the next statement is overdue. After `linkAttention` in
    /// `dataHealth`.
    func staleAttention(_ institutions: [InstitutionLink]) -> [DataAttention] {
        let reauth = institutions.filter { $0.status == .needsReauth }
        var result: [DataAttention] = []
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
        var dayStyle = Date.FormatStyle.dateTime.month(.abbreviated).day()
        dayStyle.timeZone = calendar.timeZone
        for account in accounts where account.kind != .investment && !paused.contains(Self.institutionKey(account.institution)) {
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
                institution: account.institution, accountID: account.id))
        }
        return result
    }

    /// An account is stale once its newest row is at least this many days old (or three of its usual gaps, if longer).
    static let staleAfterDays: Double = 10
    /// A statement-only account can't be newer than its last statement: it's stale once a month's statement plus a
    /// week to import it has passed since its newest row. (The dashboard's coverage is a different, later signal: it
    /// flags a calendar month with no rows at all once the 7th of the next month has passed.)
    static let statementStaleAfterDays: Double = 38
    /// A link that synced without an error this recently counts as heard from.
    static let recentSyncDays: Double = 3
}
