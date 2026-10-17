import Foundation

// Ledger ids (Lane L, P0.6): one rename helper for every place the ledger holds an account or row id, and the one-time
// upgrade that takes account numbers out of statement ids.

/// What a rename changed.
public struct RenameReport: Hashable, Codable, Sendable {
    public var accounts = 0
    public var rows = 0
    /// Rules whose account changed.
    public var rules = 0
    /// Accounts or rows that landed on an id already taken, merged into the one the person touched more.
    public var collisions = 0

    public init(accounts: Int = 0, rows: Int = 0, rules: Int = 0, collisions: Int = 0) {
        self.accounts = accounts; self.rows = rows; self.rules = rules; self.collisions = collisions
    }

    public var isEmpty: Bool { accounts == 0 && rows == 0 && rules == 0 && collisions == 0 }
}

/// The statement-id upgrade, as run: counts, and the maps the server uses once to scrub chats (never stored).
public struct StatementIDMigration: Hashable, Sendable {
    public var report: RenameReport
    /// Old account id → new.
    public var accountMap: [String: String]
    /// Old row id → new.
    public var rowMap: [String: String]
}

/// What the statement-id upgrade would rename now, counted without changing anything.
public struct StatementIDAudit: Hashable, Codable, Sendable {
    /// Account ids named after a number, wherever the ledger holds one (an account, a row, a rule, a keyed field).
    public var accounts: Int
    public var rows: Int
    public var rules: Int

    public init(accounts: Int, rows: Int, rules: Int) { self.accounts = accounts; self.rows = rows; self.rules = rules }

    public var isClean: Bool { accounts == 0 && rows == 0 && rules == 0 }
}

extension Ledger {
    /// The upgrade's marker in `upgrades`. It records that the upgrade ran once; whether it runs again is the audit's
    /// call (`statementIDAudit`), so a ledger an older server wrote legacy ids back into is upgraded again.
    public static let statementIDsUpgrade = "statement-ids-h1"

    /// A statement row whose id was made with a key (`StatementIDs.rowExternalID`).
    static func isHashedStatementRow(_ row: LedgerTransaction) -> Bool {
        row.source == .fileImport && row.id.contains(":ofx\(StatementIDs.scheme)-")
    }

    /// The part of a statement row's id after its account ("ofx-…", "csv-…"), for the scoped form
    /// "fileImport:<account id>:<external>" and the older unscoped "fileImport:<external>".
    static func statementExternalPart(_ row: LedgerTransaction) -> String? {
        guard row.source == .fileImport else { return nil }
        let prefix = SourceKind.fileImport.rawValue + ":"
        if row.id.hasPrefix(prefix + row.accountID + ":") { return String(row.id.dropFirst(prefix.count + row.accountID.count + 1)) }
        return row.id.hasPrefix(prefix) ? String(row.id.dropFirst(prefix.count)) : nil
    }

    /// The account number behind a statement account an untargeted OFX import made ("fileImport:<ACCTID>"); nil for
    /// every other account. Named statement accounts ("csv-…"), upgraded ones ("stmt-…") and the "file" sentinel are
    /// left alone. Only untargeted OFX ever made any other `fileImport:` account id.
    static func legacyStatementNumber(_ account: Account) -> String? {
        account.source == .fileImport ? legacyStatementNumber(accountID: account.id) : nil
    }

    /// The same, from an account id alone, wherever it turns up (a row, a rule, a key) even with no account behind it.
    static func legacyStatementNumber(accountID id: String) -> String? {
        let prefix = SourceKind.fileImport.rawValue + ":"
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        guard !rest.isEmpty, rest != "file", !rest.hasPrefix("csv-"), !rest.hasPrefix("stmt-") else { return nil }
        return rest
    }

    /// Every account id the ledger refers to: accounts, rows, rules, keyed fields and the copies kept for undo. An older
    /// server can write back a row or a rule without the account it names, and that id still holds the number.
    var referencedAccountIDs: Set<String> {
        var ids = Set(accounts.map(\.id))
        ids.formUnion(transactions.map(\.accountID))
        ids.formUnion(rules.compactMap(\.match.accountID))
        ids.formUnion(openingBalances.keys)
        ids.formUnion(cardBills.keys)
        ids.formUnion(cardBills.values.map(\.accountID))
        ids.formUnion(holdings.keys)
        ids.formUnion(holdings.values.map(\.id))
        for record in mergeLog { ids.insert(record.dropped.accountID); if let kept = record.keptBefore { ids.insert(kept.accountID) } }
        return ids
    }

    /// The renames the statement-id upgrade makes: accounts named after a number, and every statement row whose id
    /// holds a legacy OFX id or a renamed account. Empty once upgraded.
    func statementIDMaps(_ ids: StatementIDs) -> (accounts: [String: String], rows: [String: String]) {
        // The target depends on the number alone, so an id maps the same wherever it turns up.
        var accountMap: [String: String] = [:]
        for id in referencedAccountIDs {
            guard let number = Self.legacyStatementNumber(accountID: id) else { continue }
            accountMap[id] = Self.accountID(.fileImport, ids.accountExternalID(acctID: number))
        }
        func newID(_ row: LedgerTransaction) -> String? {
            guard let external = Self.statementExternalPart(row) else { return nil }
            let account = accountMap[row.accountID] ?? row.accountID
            let isLegacyOFX = external.hasPrefix("ofx-")
            // Unscoped legacy rows move into the scoped form, so a re-import (always scoped) finds them by id.
            let isScoped = row.id.hasPrefix("\(SourceKind.fileImport.rawValue):\(row.accountID):")
            // A CSV row's id holds no number; it changes only when the account in it does.
            guard isLegacyOFX || (isScoped && accountMap[row.accountID] != nil) else { return nil }
            let renamed = "\(SourceKind.fileImport.rawValue):\(account):" + (isLegacyOFX ? ids.rowExternalID(legacy: external) : external)
            return renamed == row.id ? nil : renamed
        }
        var rowMap: [String: String] = [:]
        for row in transactions { if let id = newID(row) { rowMap[row.id] = id } }
        // Copies kept for undo come back under the same id their row would have now.
        for record in mergeLog {
            for row in [record.dropped] + (record.keptBefore.map { [$0] } ?? []) where rowMap[row.id] == nil {
                if let id = newID(row) { rowMap[row.id] = id }
            }
        }
        return (accountMap, rowMap)
    }

    /// Counts what `hashStatementIDs` would rename, without a key and without changing anything.
    public func statementIDAudit() -> StatementIDAudit {
        // The targets don't matter for counting, so any digest does.
        let (accountMap, rowMap) = statementIDMaps(StatementIDs(digest: { $0 }))
        let live = Set(transactions.map(\.id))
        return StatementIDAudit(accounts: accountMap.count, rows: rowMap.keys.filter(live.contains).count,
                                rules: rules.filter { $0.match.accountID.map { accountMap[$0] != nil } ?? false }.count)
    }

    /// Account ids named after an OFX number (with or without the account itself), and every OFX row id, rewritten with `ids` (P0.6). Running it again changes
    /// nothing; the marker is added either way.
    mutating func hashStatementIDs(_ ids: StatementIDs) -> StatementIDMigration {
        let (accountMap, rowMap) = statementIDMaps(ids)
        let numbers = Dictionary(accounts.compactMap { a in Self.legacyStatementNumber(a).map { (a.id, $0) } }, uniquingKeysWith: { first, _ in first })
        let report = renameIDs(accounts: accountMap, rows: rowMap)
        // An account named after its number shows only the last digits, which `mask` keeps.
        for (old, new) in accountMap {
            if let index = accounts.firstIndex(where: { $0.id == new }), accounts[index].mask == nil, let number = numbers[old] {
                accounts[index].mask = StatementIDs.mask(number)
            }
        }
        upgrades.insert(Self.statementIDsUpgrade)
        return StatementIDMigration(report: report, accountMap: accountMap, rowMap: rowMap)
    }

    /// Renames account and row ids everywhere the ledger refers to them; ids not in the maps are left alone. An id that
    /// lands on one already taken merges into the one the person touched more (their category, then a note, tags or
    /// hidden), which takes the other's note, tags and hidden. Each renamed account is re-anchored, and transfer pairs
    /// left without their other side are cleared.
    ///
    /// Every `LedgerState` field holding an id is handled here; `IDMigrationTests` fails when a field is added without
    /// saying whether it holds ids.
    @discardableResult
    mutating func renameIDs(accounts accountMap: [String: String], rows rowMap: [String: String]) -> RenameReport {
        var report = RenameReport()
        guard !accountMap.isEmpty || !rowMap.isEmpty else { return report }
        func account(_ id: String) -> String { accountMap[id] ?? id }
        func row(_ id: String) -> String { rowMap[id] ?? id }

        // Accounts. One whose new id is taken (an older server wrote the legacy one back) folds into the one there.
        var touchedAccounts = Set<String>()
        for (old, new) in accountMap where old != new {
            guard let index = accounts.firstIndex(where: { $0.id == old }) else { continue }
            report.accounts += 1
            touchedAccounts.insert(new)
            if let kept = accounts.firstIndex(where: { $0.id == new }) {
                let legacy = accounts[index]
                if accounts[kept].nickname == nil { accounts[kept].nickname = legacy.nickname }
                if accounts[kept].mask == nil { accounts[kept].mask = legacy.mask }
                if accounts[kept].kindSetByPerson != true, legacy.kindSetByPerson == true { accounts[kept].kind = legacy.kind; accounts[kept].kindSetByPerson = true }
                accounts.remove(at: index)
                report.collisions += 1
            } else {
                accounts[index].id = new
            }
        }
        func rekey<V>(_ dictionary: [String: V], _ map: (String) -> String) -> [String: V] {
            // When an old and a new key both exist, the one already under the new key stays.
            var out: [String: V] = [:]
            for (key, value) in dictionary where map(key) == key { out[key] = value }
            for (key, value) in dictionary where map(key) != key && out[map(key)] == nil { out[map(key)] = value }
            return out
        }
        openingBalances = rekey(openingBalances, account)
        cardBills = rekey(cardBills, account).mapValues { var bill = $0; bill.accountID = account(bill.accountID); return bill }
        holdings = rekey(holdings, account).mapValues { var h = $0; h.id = account(h.id); return h }
        for index in rules.indices {
            guard let id = rules[index].match.accountID, accountMap[id] != nil else { continue }
            rules[index].match.accountID = accountMap[id]
            report.rules += 1
        }

        // Rows.
        func renamed(_ t: LedgerTransaction) -> LedgerTransaction {
            var t = t
            t.id = row(t.id)
            t.accountID = account(t.accountID)
            t.transferPeerID = t.transferPeerID.map(row)
            return t
        }
        report.rows = transactions.filter { rowMap[$0.id] != nil && rowMap[$0.id] != $0.id }.count
        var byNewID: [String: [LedgerTransaction]] = [:]
        var order: [String] = []
        for t in transactions.map(renamed) {
            if byNewID[t.id] == nil { order.append(t.id) }
            byNewID[t.id, default: []].append(t)
        }
        var merged = Set<String>()
        transactions = order.map { id in
            let copies = byNewID[id]!
            guard copies.count > 1 else { return copies[0] }
            // The person's work decides which copy stays; the others hand over what's theirs.
            func touched(_ t: LedgerTransaction) -> Int {
                (t.categorization?.tier == .user ? 2 : 0) + (t.note != nil || !(t.tags ?? []).isEmpty || t.isHidden ? 1 : 0)
            }
            let winnerIndex = copies.indices.max { (touched(copies[$0]), -$0) < (touched(copies[$1]), -$1) }!
            var winner = copies[winnerIndex]
            for (i, other) in copies.enumerated() where i != winnerIndex {
                Self.carryUserFields(from: other, to: &winner)
                // Its pair's other side already names the merged id, so taking the pairing keeps both sides agreeing.
                if winner.transferPeerID == nil { winner.transferPeerID = other.transferPeerID }
                report.collisions += 1
            }
            merged.insert(id)
            return winner
        }
        // A pair whose sides no longer name each other (a merged copy kept its own) is cleared on the side left over.
        if !merged.isEmpty {
            let peers = Dictionary(transactions.map { ($0.id, $0.transferPeerID) }, uniquingKeysWith: { first, _ in first })
            for index in transactions.indices {
                guard let peer = transactions[index].transferPeerID, merged.contains(peer) || merged.contains(transactions[index].id) else { continue }
                if peers[peer] ?? nil != transactions[index].id { transactions[index].transferPeerID = nil }
            }
        }
        suggestions = rekey(suggestions, row)
        reviewReasons = rekey(reviewReasons, row)
        pendingMisses = rekey(pendingMisses, row)
        possibleDuplicates = rekey(possibleDuplicates, row).reduce(into: [:]) { out, entry in
            var seen = Set<String>()
            let others = entry.value.map(row).filter { $0 != entry.key && seen.insert($0).inserted }
            if !others.isEmpty { out[entry.key] = others }
        }
        mergeLog = mergeLog.map { record in
            var record = record
            record.keptID = record.keptID.map(row)
            record.droppedID = row(record.droppedID)
            record.dropped = renamed(record.dropped)
            record.keptBefore = record.keptBefore.map(renamed)
            return record
        }

        transactions.sort { $0.postedAt > $1.postedAt }
        for id in touchedAccounts.union(merged.compactMap { byNewID[$0]?.first?.accountID }) { reanchor(id) }
        unpairOrphans()
        return report
    }
}
