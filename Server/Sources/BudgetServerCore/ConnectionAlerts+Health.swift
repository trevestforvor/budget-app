import BudgetKit
import Foundation

extension ConnectionAlerts {
    /// The pushes account health calls for now: one bank behind a SimpleFIN link needing a sign-in (keyed by when it
    /// began), and accounts gone stale (keyed by their last good sync, so the next good sync ends the episode). An
    /// account waiting for a sign-in is never pushed as stale: its link's sign-in push covers it. Nor is one from a
    /// provider whose setup is broken on the server (a link with `errorKind` providerSetup): that link's own push says
    /// why everything stopped. Pure, so it's tested directly; the sender calls it with the overview's health and accounts.
    /// - Parameters:
    ///   - accounts: the ledger's accounts, to name them; without them the push says "An account".
    ///   - timeZone: the phone's zone, for the date in the copy.
    static func healthAlerts(_ health: [AccountHealth], links: [StoredLink], now: Date, accounts: [Account] = [],
                             timeZone: TimeZone = .current) -> [ConnectionAlert] {
        let broken = Set(links.filter { $0.errorKind == .providerSetup }.map(\.provider))
        let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pushable = health.filter { item in byID[item.id].map { !broken.contains($0.source) } ?? true }
        return bankAlerts(links) + staleAlerts(pushable, accounts: accounts, timeZone: timeZone)
    }

    static func bankAlerts(_ links: [StoredLink]) -> [ConnectionAlert] {
        links.filter { $0.provider == .simplefin && $0.status != .needsReauth }.flatMap { link -> [ConnectionAlert] in
            (link.simplefin?.sortedConnections ?? []).compactMap { id, bank in
                guard bank.status == .needsReauth, let since = bank.firstFailedAt else { return nil }
                let bankID = SimpleFINLinkState.bankID(id)
                return ConnectionAlert(kind: .bankNeedsSignIn, episodeKeys: [bankKey(linkID: link.id, connectionID: bankID, firstFailedAt: since)],
                                       title: "\(bank.name) needs you to sign in",
                                       body: "Sign in again on SimpleFIN Bridge. Nothing new comes in from \(bank.name) until then; your other banks keep syncing.",
                                       linkID: link.id, bankID: SimpleFINLinkState.rowID(linkID: link.id, connectionID: id))
            }
        }
    }

    /// One push per institution whose accounts went stale, so a bank that stops answering is one push, not one per
    /// account. Its first key is the account longest unheard from; every stale account's key rides along. The sender
    /// skips an alert whose first key went out and marks keys only when it sends, so accounts that go stale together
    /// push once, and one still stale when the first recovers doesn't push again. One that goes stale later, while the
    /// first is still stale, isn't announced then (its institution's push already went); it pushes once the first
    /// recovers, if it's still behind.
    static func staleAlerts(_ health: [AccountHealth], accounts: [Account], timeZone: TimeZone) -> [ConnectionAlert] {
        let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let stale = health.compactMap { item in item.state == .stale ? item.lastGoodSync.map { (item, $0) } : nil }
            .sorted { ($0.1, $0.0.id) < ($1.1, $1.0.id) }
        var order: [String] = []
        var groups: [String: [(AccountHealth, Date)]] = [:]
        for entry in stale {
            let key = byID[entry.0.id].map { $0.institution.trimmingCharacters(in: .whitespaces).lowercased() } ?? "account:\(entry.0.id)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(entry)
        }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.timeZone = timeZone
        style.locale = Locale(identifier: "en_US") // "Sep 21" whatever the server's LANG (C.UTF-8 gives "21 Sep")
        return order.map { key in
            let group = groups[key]!
            let (first, since) = group[0]
            let account = byID[first.id]
            let name = group.count == 1 ? account.map(fullName) ?? "An account" : account?.institution ?? "An account"
            return ConnectionAlert(kind: .accountStale, episodeKeys: group.map { staleKey(accountID: $0.0.id, lastGoodSync: $0.1) },
                                   title: "\(name) hasn't updated since \(since.formatted(style))",
                                   body: group.count == 1 ? "Open Accounts to check its connection."
                                                          : "\(group.count) of its accounts are behind. Open Accounts to check the connection.",
                                   accountID: first.id)
        }
    }

    /// "Harbor Total Checking", or just "Keystone Mastercard" when the name already says where it is. No digits.
    static func fullName(_ account: Account) -> String {
        account.displayName.localizedCaseInsensitiveContains(account.institution) ? account.displayName : "\(account.institution) \(account.displayName)"
    }
}
