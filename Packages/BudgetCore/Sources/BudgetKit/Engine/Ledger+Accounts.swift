import Foundation

extension Ledger {
    // MARK: Balances

    /// Every account's balance summed by kind. Cards are negative in the ledger; `cardsOwed` turns that around.
    func balances() -> Balances {
        func total(_ kind: AccountKind) -> Money {
            accounts.filter { $0.kind == kind }.map { balance(of: $0.id, through: now) }.sum()
        }
        let cash = cash(through: now)
        let cardsOwed = -total(.credit)
        let investments = total(.investment)
        return Balances(cash: cash, cardsOwed: cardsOwed, investments: investments, netWorth: cash - cardsOwed + investments,
                        cashAfterCards: cash - cardsOwed)
    }

    // MARK: Data health

    /// What keeps the numbers from being current, worst first: each connection the bank ended (sign in again), then
    /// each checking, savings or card account whose newest transaction is older than its own rhythm allows — for an
    /// account that only comes from statements, once the next statement is overdue — or an empty ledger. Home's
    /// attention list and the checkup's data section both come from here.
    /// - Parameter institutions: the deployment's links; only their status is read.
    func dataHealth(institutions: [InstitutionLink]) -> [DataAttention] {
        let reauth = institutions.filter { $0.status == .needsReauth }
        var result = reauth.map { link in
            DataAttention(id: "reauth-\(link.id)", kind: .needsReauth, title: "\(link.institution) needs you to sign in again.",
                          detail: "The bank ended the connection, so nothing new is coming in. Reconnect it on the Budget dashboard — your accounts and history stay as they are.",
                          institution: link.institution)
        }
        guard !transactions.isEmpty else {
            result.append(DataAttention(id: "no-data", kind: .emptyLedger, title: "The ledger is empty.",
                                        detail: "Link an account or import a statement on the Budget dashboard."))
            return result
        }
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

    static func institutionKey(_ name: String) -> String { name.trimmingCharacters(in: .whitespaces).lowercased() }

    /// "Harbor Total Checking", or just "Keystone Mastercard" when the name already says where it is.
    static func fullName(_ account: Account) -> String {
        account.name.localizedCaseInsensitiveContains(account.institution) ? account.name : "\(account.institution) \(account.name)"
    }

    // MARK: Institutions

    /// The institutions as the phone lists them: each published link with the ledger accounts it holds and how far their
    /// rows reach, then one entry per institution whose accounts all come from imported statements (nothing to sign in
    /// to). A link holds the accounts at its institution that its provider brought in; a SimpleFIN link, one bridge
    /// for many banks, holds every SimpleFIN account.
    func institutionLinks(_ published: [InstitutionLink]) -> [InstitutionLink] {
        var newest: [String: Date] = [:]
        for row in transactions where row.postedAt > newest[row.accountID] ?? .distantPast { newest[row.accountID] = row.postedAt }
        func summarize(_ link: inout InstitutionLink, _ held: [Account]) {
            link.accountIDs = held.map(\.id)
            link.coversThrough = held.compactMap { newest[$0.id] }.max()
            if link.accountKinds.isEmpty { link.accountKinds = AccountKind.allCases.filter { kind in held.contains { $0.kind == kind } } }
        }
        var claimed: Set<String> = []
        var result = published.map { original in
            var link = original
            let held = accounts.filter { account in
                guard let provider = link.primary, provider != .fileImport, account.source == provider else { return false }
                return provider == .simplefin || Self.institutionKey(account.institution) == Self.institutionKey(link.institution)
            }
            claimed.formUnion(held.map(\.id))
            summarize(&link, held)
            return link
        }
        let statementOnly = Dictionary(grouping: accounts.filter { !claimed.contains($0.id) && $0.source == .fileImport }) { Self.institutionKey($0.institution) }
        for key in statementOnly.keys.sorted() {
            let held = statementOnly[key]!
            var link = InstitutionLink(id: "statements-\(key.filter { $0.isLetter || $0.isNumber })", institution: held[0].institution,
                                       primary: .fileImport, fallback: nil, accountKinds: [], status: .connected,
                                       note: "From statements you import on the Budget dashboard.")
            summarize(&link, held)
            result.append(link)
        }
        // Apps before server 0.2.0 can't read a link without a priority, so every link carries one (nothing reads it now)
        // until those apps are gone.
        for index in result.indices where result[index].priority == nil { result[index].priority = .core }
        return result
    }
}
