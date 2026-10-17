import Foundation

/// What an ingest did, for the sync log and the import UI.
/// Imported rows that duplicate synced ones, found after the fact — listed for a preview, removed on apply.
public struct DuplicateSweep: Hashable, Codable, Sendable {
    public struct Pair: Hashable, Codable, Sendable {
        public var accountID: String
        public var amount: Money
        public var fileDate: Date
        public var fileDescription: String
        public var syncedDate: Date
        public var syncedDescription: String
        public var syncedSource: SourceKind
    }
    public var applied: Bool
    public var pairs: [Pair]
    public var removed: Int
}

public struct IngestReport: Hashable, Codable, Sendable {
    public var batchID: String
    public var source: SourceKind
    public var accountsAdded = 0
    public var accountsUpdated = 0
    public var rowsAdded = 0
    public var rowsUpdated = 0
    public var duplicatesSkipped = 0
    /// Filed by the person's rules.
    public var byRule = 0
    /// Filed as one side of a move between the person's accounts, and by what a statement file said the row is.
    /// Optional so reports saved before they were counted apart from rules still decode.
    public var byTransferMatch: Int?
    public var byStatement: Int?
    public var byMemory = 0
    public var byModel = 0
    public var needsReview = 0
    public var modelCalls = 0
    public var warnings: [String] = []
    /// What happened beyond this batch's own rows (rows from an earlier sync asked about again), for the sync log. Not a
    /// problem, so not a warning. Optional so reports saved before it existed still decode.
    public var notes: [String]?
    /// Time spent waiting on decision models, for the dashboard ("12 model calls · 0.8 s"). Optional so
    /// reports saved before it existed still decode.
    public var modelMilliseconds: Int?
    /// Posting dates of the rows added (or that a preview would add).
    public var addedFrom: Date?
    public var addedThrough: Date?
    /// A few of the rows skipped as already in the ledger from another source, and what each matched,
    /// so a preview can be checked by eye.
    public var duplicateSamples: [DuplicateSample]?
    /// Internal hand-off to the categorizer; not part of the wire report.
    var newRowIDs: [String] = []

    public init(batchID: String, source: SourceKind, warnings: [String] = []) {
        self.batchID = batchID
        self.source = source
        self.warnings = warnings
    }

    enum CodingKeys: String, CodingKey {
        case batchID, source, accountsAdded, accountsUpdated, rowsAdded, rowsUpdated, duplicatesSkipped, byRule, byMemory, byModel, needsReview, modelCalls, warnings
        case modelMilliseconds, addedFrom, addedThrough, duplicateSamples, byTransferMatch, byStatement, notes
    }

    public struct DuplicateSample: Hashable, Codable, Sendable {
        public var date: Date
        public var amount: Money
        public var description: String
        /// The ledger row it matched.
        public var matchedDate: Date
        public var matchedDescription: String
        public var matchedSource: SourceKind
    }

    mutating func record(_ outcome: Categorizer.Outcome) {
        byRule = outcome.byRule
        byTransferMatch = outcome.byTransferMatch
        byStatement = outcome.byStatement
        byMemory = outcome.byMemory
        byModel = outcome.byModel
        needsReview = outcome.needsReview
        modelCalls = outcome.modelCalls
        modelMilliseconds = outcome.modelMilliseconds
        warnings += outcome.warnings
    }
}

/// What Undo would do with one batch (`GET /v1/imports/:batch/undo`), with the counts behind it.
public struct RollbackPlan: Hashable, Codable, Sendable {
    public enum Verdict: String, Codable, Sendable {
        /// Undo removes the rows; nothing sends them again.
        case undo
        /// Undo removes the rows, but `returning` of them come back at the next sync (and all of them if the connection
        /// is linked again): it needs the person's yes.
        case undoReturns
        /// Undo would lose rows for good (a cursor source never re-sends them): hide them instead.
        case refuse
    }

    public var batchID: String
    /// The batch's rows still in the ledger.
    public var rows: Int
    /// Those rows by `SourceKind` raw value.
    public var bySource: [String: Int]
    /// Window-source rows the next sync fetches again (posted on or after its start).
    public var returning: Int
    public var verdict: Verdict
    /// Why, and what to do instead, in the person's words.
    public var message: String

    public init(batchID: String, rows: Int, bySource: [String: Int], returning: Int, verdict: Verdict, message: String) {
        self.batchID = batchID; self.rows = rows; self.bySource = bySource; self.returning = returning; self.verdict = verdict; self.message = message
    }
}

extension Ledger {
    func accountKind(_ id: String) -> AccountKind? { accounts.first { $0.id == id }?.kind }

    /// Ledger account id for a provider account: stable across syncs.
    static func accountID(_ source: SourceKind, _ external: String) -> String { "\(source.rawValue):\(external)" }

    /// The one currency the ledger holds. Totals add across accounts and there's no exchange rate to convert with, so
    /// ingest sets anything else aside (with a warning) instead of mixing it in.
    public static let homeCurrency = "USD"

    /// Rows to categorize again on the next ingest: those sent to review because the decision model couldn't be reached,
    /// and any left with no categorization at all (an older build could save a row before it was filed).
    var awaitingModel: [String] {
        transactions.filter {
            $0.categorization == nil || ($0.categorization?.needsReview == true && reviewReasons[$0.id] == Categorizer.modelUnreachableReason)
        }.map(\.id)
    }

    /// The ids whose row is still as it was in `earlier` (same category and transfer pairing): nobody filed, edited or
    /// removed it while a model was being asked, so an answer worked out from `earlier` may be written over it.
    func unchanged(_ ids: some Sequence<String>, since earlier: Ledger) -> Set<String> {
        let then = Dictionary(earlier.transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Set(ids.filter { id in
            guard let a = then[id], let b = now[id] else { return false }
            return a.categorization == b.categorization && a.transferPeerID == b.transferPeerID && earlier.reviewReasons[id] == reviewReasons[id]
        })
    }

    /// Rows left waiting because a model couldn't be reached go back to being ordinary review rows, so they aren't sent to
    /// a model the person hasn't asked to re-check them with.
    mutating func releaseAwaitingModel() {
        for row in transactions where reviewReasons[row.id] == Categorizer.modelUnreachableReason {
            reviewReasons[row.id] = Categorizer.modelWasUnreachableReason
        }
    }

    /// Maps a snapshot into the ledger (accounts upserted, rows deduplicated and tagged). Categorization is separate.
    mutating func prepareIngest(_ snapshot: SourceSnapshot, batchID: String, into targetAccountID: String?) throws -> IngestReport {
        var report = IngestReport(batchID: batchID, source: snapshot.source, warnings: snapshot.warnings)
        var touched = Set<String>()
        let byID = Dictionary(uniqueKeysWithValues: transactions.enumerated().map { ($1.id, $0) })

        for sourceAccount in snapshot.accounts {
            let label = sourceAccount.name + (sourceAccount.mask.map { " ••" + $0 } ?? "")
            guard sourceAccount.balance.currencyCode == Self.homeCurrency else {
                report.warnings.append("Set aside \(label): it's in \(sourceAccount.balance.currencyCode), and Budget only tracks \(Self.homeCurrency) for now, so its transactions weren't added.")
                continue
            }
            let accountID: String
            if let targetAccountID {
                guard accounts.contains(where: { $0.id == targetAccountID }) else { throw BudgetAPIError.rejected("Unknown account \(targetAccountID).") }
                accountID = targetAccountID
            } else {
                accountID = Self.accountID(snapshot.source, sourceAccount.externalID)
                if let index = accounts.firstIndex(where: { $0.id == accountID }) {
                    accounts[index].balance = sourceAccount.balance
                    accounts[index].name = sourceAccount.name
                    if let mask = sourceAccount.mask { accounts[index].mask = mask }
                    accounts[index].balanceAsOf = sourceAccount.balanceDate
                    if snapshot.source != .fileImport && snapshot.accountProblems[sourceAccount.externalID] == nil { accounts[index].lastSyncedAt = now }
                    report.accountsUpdated += 1
                } else {
                    let synced = snapshot.source != .fileImport && snapshot.accountProblems[sourceAccount.externalID] == nil
                    accounts.append(Account(id: accountID, name: sourceAccount.name, institution: sourceAccount.institution,
                                            kind: sourceAccount.kind, balance: sourceAccount.balance, source: snapshot.source, mask: sourceAccount.mask,
                                            balanceAsOf: sourceAccount.balanceDate, lastSyncedAt: synced ? now : nil))
                    report.accountsAdded += 1
                }
            }
            touched.insert(accountID)

            // Rows already on the account from a *different* source are the only fuzzy-duplicate
            // candidates: a source's own rows are told apart by id (two identical coffees on one day
            // are two rows), and each ledger row can absorb at most one incoming row.
            var candidates = transactions.filter { $0.accountID == accountID && $0.source != snapshot.source }
            var added: [LedgerTransaction] = []
            var addedIDs = Set<String>()
            // Posted rows that took over their pending row's category, by the pending row's index.
            var replaced: [(pending: Int, posted: String)] = []
            var otherCurrency = 0
            for row in sourceAccount.transactions {
                guard row.amount.currencyCode == Self.homeCurrency else { otherCurrency += 1; continue }
                // A statement file's row ids are only unique within the file, so they're scoped to the account
                // the rows land in (two cards can each have a $6.50 coffee on the same day).
                let id = snapshot.source == .fileImport
                    ? "\(snapshot.source.rawValue):\(accountID):\(row.externalID)" : "\(snapshot.source.rawValue):\(row.externalID)"
                // Files imported before ids were scoped to an account used the bare id.
                let legacy = snapshot.source == .fileImport ? byID["\(snapshot.source.rawValue):\(row.externalID)"].flatMap { transactions[$0].accountID == accountID ? $0 : nil } : nil
                if let index = byID[id] ?? legacy {
                    // Same provider row seen again: pending → posted, or an amended amount.
                    if transactions[index].isPending != row.isPending || transactions[index].amount != row.amount || transactions[index].postedAt != row.posted {
                        transactions[index].isPending = row.isPending
                        transactions[index].amount = row.amount
                        transactions[index].postedAt = row.posted
                        report.rowsUpdated += 1
                    }
                    continue
                }
                guard addedIDs.insert(id).inserted else { continue }
                if let match = Deduplicator.bestMatch(account: accountID, date: row.posted, amount: row.amount,
                                                      descriptions: [row.payee, row.description].compactMap { $0 }, in: candidates) {
                    let matched = candidates.remove(at: match)
                    report.duplicatesSkipped += 1
                    if (report.duplicateSamples?.count ?? 0) < 12 {
                        report.duplicateSamples = (report.duplicateSamples ?? []) + [IngestReport.DuplicateSample(
                            date: row.posted, amount: row.amount, description: row.description,
                            matchedDate: matched.postedAt, matchedDescription: matched.rawDescription, matchedSource: matched.source)]
                    }
                    continue
                }
                let name = merchant(for: row)
                var transaction = LedgerTransaction(
                    id: id, accountID: accountID, postedAt: row.posted, merchant: name.merchant, rawDescription: row.description,
                    amount: row.amount, categorization: nil, isPending: row.isPending, source: snapshot.source,
                    batchID: batchID, providerCategory: row.providerCategory, originalMerchant: name.original)
                // A posted row that replaces its pending version (a new provider id) keeps what was done to it.
                if let pendingID = row.replacesExternalID, let index = byID["\(snapshot.source.rawValue):\(pendingID)"],
                   transactions[index].accountID == accountID, Self.carryOver(from: transactions[index], to: &transaction) {
                    replaced.append((index, id))
                }
                added.append(transaction)
            }
            if otherCurrency > 0 {
                report.warnings.append("Skipped \(otherCurrency) transaction\(otherCurrency == 1 ? "" : "s") on \(label) that weren't in \(Self.homeCurrency).")
            }
            if let first = added.map(\.postedAt).min() { report.addedFrom = min(report.addedFrom ?? first, first) }
            if let last = added.map(\.postedAt).max() { report.addedThrough = max(report.addedThrough ?? last, last) }
            transactions += added
            report.rowsAdded += added.count
            let settled = Set(replaced.map(\.posted))
            report.newRowIDs += added.map(\.id).filter { !settled.contains($0) }
            // A matched transfer's other side now pairs with the posted row.
            for (pending, posted) in replaced {
                guard let peer = transactions[pending].transferPeerID else { continue }
                transactions[pending].transferPeerID = nil
                if let index = transactions.firstIndex(where: { $0.id == peer }) { transactions[index].transferPeerID = posted }
            }
        }
        transactions.sort { $0.postedAt > $1.postedAt }
        for id in touched { reanchor(id) }
        return report
    }

    /// The merchant a new row shows: the name the person gave its descriptor, else the provider's (with the
    /// provider's kept as the original).
    func merchant(for row: SourceTransaction) -> (merchant: String, original: String?) {
        let name = Self.merchantName(row)
        guard !Descriptor.isGeneric(row.description), let alias = merchantAliases[Descriptor.normalize(row.description)], alias != name else {
            return (name, nil)
        }
        return (alias, name)
    }

    /// Carries what the person did to a pending row onto the posted row replacing it: hidden, the note, a
    /// renamed merchant — and the category, when the person settled it (their own answer, or hid the row) or it
    /// was one side of a matched transfer, which moves to the posted row. Returns whether the category came
    /// along; if not, the posted row is categorized afresh.
    static func carryOver(from pending: LedgerTransaction, to posted: inout LedgerTransaction) -> Bool {
        carryUserFields(from: pending, to: &posted)
        guard let categorization = pending.categorization,
              categorization.tier == .user || pending.isHidden || pending.transferPeerID != nil else { return false }
        posted.categorization = categorization
        if posted.isHidden { posted.categorization?.needsReview = false }
        posted.transferPeerID = pending.transferPeerID
        return true
    }

    /// "SQ *CASA TACO 0423" → "Casa Taco"; the provider's payee wins when present.
    static func merchantName(_ row: SourceTransaction) -> String {
        if let payee = row.payee?.trimmingCharacters(in: .whitespaces), !payee.isEmpty { return payee }
        let cleaned = Descriptor.normalize(row.description)
        // Person-to-person payments are named after the service ("Venmo"), not the person.
        let redacted = CategoryDecisions.redacted(cleaned)
        if CategoryDecisions.peerToPeer.contains(where: redacted.hasPrefix) { return redacted.capitalized }
        return cleaned.isEmpty ? row.description : cleaned.capitalized
    }

    /// Imported (file) rows that a synced row also has — left when a provider's history arrived after
    /// the file under a stricter rule. Each pair: the file row and the synced row it duplicates.
    func crossSourceDuplicates() -> [(file: LedgerTransaction, synced: LedgerTransaction)] {
        var pairs: [(file: LedgerTransaction, synced: LedgerTransaction)] = []
        for (_, rows) in Dictionary(grouping: transactions, by: \.accountID) {
            var synced = rows.filter { $0.source != .fileImport }
            for row in rows where row.source == .fileImport {
                guard let index = Deduplicator.bestMatch(account: row.accountID, date: row.postedAt, amount: row.amount,
                                                         descriptions: [row.merchant, row.rawDescription], in: synced, similarOnly: true) else { continue }
                pairs.append((row, synced.remove(at: index)))
            }
        }
        return pairs.sorted { $0.file.postedAt > $1.file.postedAt }
    }

    /// Drops the file copy of each pair; the synced row stays (the provider keeps updating it) and inherits
    /// what the person did to the copy: their category, hidden, the note, a renamed merchant, a transfer pairing.
    mutating func removeDuplicates(_ pairs: [(file: LedgerTransaction, synced: LedgerTransaction)]) -> Int {
        let fileIDs = Set(pairs.map(\.file.id))
        // When both sides of a paired move are file copies, each synced row pairs with the other side's synced row.
        let replacement = Dictionary(pairs.map { ($0.file.id, $0.synced.id) }, uniquingKeysWith: { first, _ in first })
        for pair in pairs {
            guard let index = transactions.firstIndex(where: { $0.id == pair.synced.id }) else { continue }
            if pair.file.categorization?.tier == .user && pair.synced.categorization?.tier != .user {
                transactions[index].categorization = pair.file.categorization
            }
            Self.carryUserFields(from: pair.file, to: &transactions[index])
            if transactions[index].isHidden { transactions[index].categorization?.needsReview = false }
            if let filePeer = pair.file.transferPeerID, transactions[index].transferPeerID == nil,
               case let peer = replacement[filePeer] ?? filePeer, let other = transactions.firstIndex(where: { $0.id == peer }) {
                transactions[index].transferPeerID = peer
                transactions[other].transferPeerID = pair.synced.id
            }
        }
        let affected = Set(pairs.map(\.file.accountID))
        transactions.removeAll { fileIDs.contains($0.id) }
        for id in fileIDs { suggestions[id] = nil; reviewReasons[id] = nil }
        for id in affected { reanchor(id) }
        unpairOrphans()
        return fileIDs.count
    }

    /// Hidden, the note, tags and a renamed merchant, from one copy of a row to another (never over what the
    /// other already has: tags are added to its own).
    static func carryUserFields(from old: LedgerTransaction, to new: inout LedgerTransaction) {
        if old.isHidden { new.isHidden = true }
        if new.note == nil { new.note = old.note }
        if new.isYearly == nil { new.isYearly = old.isYearly }
        if old.tags != nil { new.tags = TransactionTags.merged(new.tags, old.tags) }
        if new.orderMatch == nil { new.orderMatch = old.orderMatch }
        if old.originalMerchant != nil, new.originalMerchant == nil, old.merchant != new.merchant {
            new.originalMerchant = new.merchant
            new.merchant = old.merchant
        }
    }

    /// What undoing a batch would do, worked out before anything is removed. A cursor source (Plaid) never sends a row
    /// twice, so removing its rows loses them for good: refused, hide them instead. A window source re-sends its last
    /// days, so rows from `nextWindowStart` on come back at the next sync, and the rest once it's linked again: undo
    /// needs a yes either way. Anything else (files) undoes.
    func rollbackPlan(batchID: String, nextWindowStart: Date?) -> RollbackPlan {
        let rows = transactions.filter { $0.batchID == batchID }
        let bySource = Dictionary(grouping: rows, by: \.source.rawValue).mapValues(\.count)
        let returning = nextWindowStart.map { start in rows.filter { $0.source.syncStyle == .window && $0.postedAt >= start }.count } ?? 0
        let n = rows.count == 1 ? "this row" : "these \(rows.count) rows"
        if let kept = rows.first(where: { [.cursor, .device].contains($0.source.syncStyle) }) {
            return RollbackPlan(batchID: batchID, rows: rows.count, bySource: bySource, returning: 0, verdict: .refuse,
                                message: "\(kept.source.displayName) won't send \(n) again, so undoing would lose \(rows.count == 1 ? "it" : "them") for good. Hide \(rows.count == 1 ? "it" : "them") instead: hidden rows stay out of every total, and you can show them again from Activity.")
        }
        if let source = rows.first(where: { $0.source.syncStyle == .window })?.source {
            // Even with none inside the next window (or no link left to sync), linking the connection again re-fetches
            // them, so a window source's rows always need the yes.
            let back = returning == 0 ? "None of them come back at the next sync, but \(source.displayName) sends \(rows.count == 1 ? "it" : "them") again if you link it again."
                : "\(returning == rows.count ? (rows.count == 1 ? "It comes" : "All of them come") : "\(returning) of them come") back at the next sync, because \(source.displayName) sends its most recent days again."
            return RollbackPlan(batchID: batchID, rows: rows.count, bySource: bySource, returning: returning, verdict: .undoReturns,
                                message: "Undo removes \(n). \(back) Hide \(rows.count == 1 ? "it" : "them") instead to keep \(rows.count == 1 ? "it" : "them") out of your totals for good.")
        }
        return RollbackPlan(batchID: batchID, rows: rows.count, bySource: bySource, returning: 0, verdict: .undo,
                            message: rows.isEmpty ? "Nothing from this batch is left to remove." : "Undo removes \(n) and nothing sends \(rows.count == 1 ? "it" : "them") again.")
    }

    mutating func rollback(batchID: String) -> Int {
        let affected = Set(transactions.filter { $0.batchID == batchID }.map(\.accountID))
        let removedIDs = Set(transactions.filter { $0.batchID == batchID }.map(\.id))
        transactions.removeAll { $0.batchID == batchID }
        for id in removedIDs { suggestions[id] = nil; reviewReasons[id] = nil }
        for id in affected { reanchor(id) }
        unpairOrphans()
        return removedIDs.count
    }

    /// Removes rows by id (the provider deleted them, or a pending row posted under a new id) and re-anchors
    /// their accounts. Returns how many went.
    mutating func removeRows(_ ids: Set<String>) -> Int {
        let affected = Set(transactions.filter { ids.contains($0.id) }.map(\.accountID))
        let before = transactions.count
        transactions.removeAll { ids.contains($0.id) }
        for id in ids { suggestions[id] = nil; reviewReasons[id] = nil }
        for id in affected { reanchor(id) }
        unpairOrphans()
        return before - transactions.count
    }

    // MARK: Transfer pairs

    /// Clears pairings whose other side has left the ledger.
    mutating func unpairOrphans() {
        let ids = Set(transactions.map(\.id))
        for index in transactions.indices where transactions[index].transferPeerID.map({ !ids.contains($0) }) ?? false {
            transactions[index].transferPeerID = nil
        }
    }

    /// Rows matched as transfers before pairs were recorded say so only in `decidedBy` ("Matched transfer ·
    /// Checking"). This finds each one's other side the way the match was made — the opposite amount on another
    /// account within five days, filed as a transfer, one side a cash account — preferring the named account,
    /// a row that names this one back, then the nearest date. Runs on every load; a no-op once pairs exist.
    mutating func pairLegacyTransfers() {
        unpairOrphans()
        let prefix = Categorizer.matchedTransfer + " · "
        let legacy = transactions.indices.filter {
            transactions[$0].transferPeerID == nil && (transactions[$0].categorization?.decidedBy ?? "").hasPrefix(Categorizer.matchedTransfer)
        }
        guard !legacy.isEmpty else { return }
        let names = Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let kinds = Dictionary(accounts.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        func isCash(_ id: String) -> Bool? { kinds[id].map { $0 == .checking || $0 == .savings } }
        let open = Dictionary(grouping: transactions.indices.filter {
            transactions[$0].transferPeerID == nil && transactions[$0].categorization?.categoryID == "transfer"
        }) { transactions[$0].amount.minorUnits }
        let order = legacy.sorted { (transactions[$0].postedAt, transactions[$0].id) < (transactions[$1].postedAt, transactions[$1].id) }
        for i in order where transactions[i].transferPeerID == nil {
            let row = transactions[i]
            let named = row.categorization?.decidedBy.flatMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
            let namesBack = prefix + (names[row.accountID] ?? "")
            let candidates = (open[-row.amount.minorUnits] ?? []).filter { j in
                let other = transactions[j]
                guard j != i, other.transferPeerID == nil, other.accountID != row.accountID, other.amount.minorUnits != 0,
                      abs(other.postedAt.timeIntervalSince(row.postedAt)) <= 5 * 86_400 else { return false }
                // Card-to-card never paired; with either kind unknown, give it the benefit of the doubt.
                guard let a = isCash(row.accountID), let b = isCash(other.accountID) else { return true }
                return a || b
            }
            func rank(_ j: Int) -> (Int, Int, Double, String) {
                let other = transactions[j]
                return (named != nil && names[other.accountID] == named ? 0 : 1, other.categorization?.decidedBy == namesBack ? 0 : 1,
                        abs(other.postedAt.timeIntervalSince(row.postedAt)), other.id)
            }
            guard let j = candidates.min(by: { rank($0) < rank($1) }) else { continue }
            transactions[i].transferPeerID = transactions[j].id
            transactions[j].transferPeerID = row.id
        }
    }

    /// What merchant memory holds: for each descriptor with a settled answer, the category its newest settled row
    /// has, where that answer came from, and how many rows share the descriptor. The person's answers, their
    /// rules, what statements said and the decision model's filings all teach it; a generic descriptor
    /// ("Withdrawal"), a matched transfer (it says something about that row, not the descriptor), the person's answer
    /// on a charge matched to a store order (it says what that order bought, not what the store sells), a hidden row
    /// and a forgotten descriptor teach it nothing. Most recently seen first.
    func merchantMemoryEntries(excluding ids: Set<String> = []) -> [RememberedMerchant] {
        struct Entry { var winner: LedgerTransaction; var origins: [String: LedgerTransaction] = [:] }
        var entries: [String: Entry] = [:]
        var seen: [String: (count: Int, newest: LedgerTransaction)] = [:]
        for row in transactions.reversed() where !ids.contains(row.id) && !row.isHidden { // oldest first, so the newest answer wins
            let descriptor = Descriptor.normalize(row.rawDescription)
            seen[descriptor] = ((seen[descriptor]?.count ?? 0) + 1, row)
            guard let c = row.categorization, !c.needsReview, [.user, .rule, .statement, .merchantMemory, .decisionModel].contains(c.tier),
                  !Descriptor.isGeneric(row.rawDescription), !forgottenMerchants.contains(descriptor),
                  !(c.tier == .user && row.orderMatch != nil) else { continue }
            var entry = entries[descriptor] ?? Entry(winner: row)
            entry.winner = row
            // A row memory filed repeats an earlier answer; the answer itself came from the newest row that wasn't.
            if c.tier != .merchantMemory { entry.origins[c.categoryID] = row }
            entries[descriptor] = entry
        }
        return entries.compactMap { descriptor, entry -> RememberedMerchant? in
            guard let categoryID = entry.winner.categorization?.categoryID, let seen = seen[descriptor] else { return nil }
            let origin = entry.origins[categoryID]?.categorization
            return RememberedMerchant(descriptor: descriptor, merchant: seen.newest.merchant, categoryID: categoryID,
                                      source: origin?.tier ?? .merchantMemory,
                                      confidence: origin?.tier == .decisionModel ? origin?.confidence : nil,
                                      rowCount: seen.count, lastSeen: seen.newest.postedAt)
        }
        .sorted { ($0.lastSeen, $0.descriptor) > ($1.lastSeen, $1.descriptor) }
    }

    /// Normalized descriptor → category: `merchantMemoryEntries` as the categorizer looks it up.
    func merchantMemory(excluding ids: Set<String>) -> [String: String] {
        Dictionary(merchantMemoryEntries(excluding: ids).map { ($0.descriptor, $0.categoryID) }, uniquingKeysWith: { first, _ in first })
    }

    mutating func apply(_ outcome: Categorizer.Outcome) {
        let index = Dictionary(uniqueKeysWithValues: transactions.enumerated().map { ($1.id, $0) })
        for (id, categorization) in outcome.categorizations {
            guard let i = index[id] else { continue }
            transactions[i].categorization = categorization
            // A row filed now (one asked again, or the other side of a transfer) sheds what it said while it waited.
            if !categorization.needsReview { suggestions[id] = nil; reviewReasons[id] = nil }
        }
        for (id, ranked) in outcome.suggestions { suggestions[id] = ranked }
        for (id, reason) in outcome.reasons { reviewReasons[id] = reason }
        for (id, peer) in outcome.transferPeers {
            guard let i = index[id] else { continue }
            transactions[i].transferPeerID = peer
        }
    }
}

/// The categorization pipeline for new rows (intent: merchant memory → classifier → model → you).
public enum Categorizer {
    public struct Outcome: Sendable {
        var categorizations: [String: Categorization] = [:]
        var suggestions: [String: [CategorySuggestion]] = [:]
        var reasons: [String: String] = [:]
        /// Both sides of each matched transfer, each pointing at the other.
        var transferPeers: [String: String] = [:]
        var byRule = 0, byTransferMatch = 0, byStatement = 0, byMemory = 0, byModel = 0, needsReview = 0, modelCalls = 0
        /// Wall time spent waiting on decision models (all batches, escalation included).
        var modelMilliseconds = 0
        var warnings: [String] = []
        /// The decision model was asked and couldn't be reached.
        var modelUnreachable = false
        /// The rows this outcome was asked about, so counts can be redone when some entries are dropped.
        var asked: Set<String> = []

        /// Only what may still be written to `ledger`: entries for rows unchanged since `earlier`, the copy this outcome was
        /// worked out from. A transfer pair goes only when both sides do.
        func unchanged(since earlier: Ledger, in ledger: Ledger) -> Outcome {
            var keep = ledger.unchanged(Set(categorizations.keys).union(transferPeers.keys), since: earlier)
            for (id, peer) in transferPeers where !keep.contains(id) || !keep.contains(peer) {
                keep.remove(id)
                keep.remove(peer)
            }
            var out = self
            out.categorizations = categorizations.filter { keep.contains($0.key) }
            out.suggestions = suggestions.filter { keep.contains($0.key) }
            out.reasons = reasons.filter { keep.contains($0.key) }
            out.transferPeers = transferPeers.filter { keep.contains($0.key) }
            guard out.categorizations.count < categorizations.count else { return out }
            // Something was dropped: count what's left, for the rows this outcome was asked about.
            let kept = out.categorizations.filter { asked.contains($0.key) }.values
            out.byRule = kept.filter { $0.tier == .rule }.count
            // A pair inside this batch was counted once (its other side is skipped), so it's counted once here too.
            out.byTransferMatch = out.categorizations.filter { id, c in
                c.tier == .transferMatch && asked.contains(id) && (out.transferPeers[id].map { !asked.contains($0) || id < $0 } ?? true)
            }.count
            out.byStatement = kept.filter { $0.tier == .statement }.count
            out.byMemory = kept.filter { $0.tier == .merchantMemory && !$0.needsReview }.count
            out.byModel = kept.filter { $0.tier == .decisionModel && !$0.needsReview }.count
            out.needsReview = kept.filter(\.needsReview).count
            return out
        }
    }

    /// The model's pick agrees with the bank's own category: two different classifiers landing on the same
    /// answer. Accepted when the model gives it at least even odds, even under the auto-accept bar.
    static let agreementFloor = 0.5

    /// Row types a statement file states outright; no model needed.
    static let statementSettled: [String: String] = [
        "INCOME_INTEREST_EARNED": "income", "TRANSFER_IN": "transfer", "TRANSFER_OUT": "transfer", "Payment": "transfer",
    ]

    /// `decidedBy` prefix for rows filed as transfers because the other side is in another of your accounts.
    static let matchedTransfer = "Matched transfer"

    /// The review reason on rows the decision model couldn't be reached for; `Ledger.awaitingModel` finds them by it, so
    /// it's stored in ledgers — reword it and rows saved under the old wording stop being asked again.
    static let modelUnreachableReason = "The decision model couldn't be reached, so this waits for you. It's asked again on the next sync."
    /// The reason on rows whose request the model rejected on its own (a 400 about it, an answer that didn't parse).
    /// They aren't asked again: the same request would be refused the same way.
    static let modelRefusedReason = "The decision model couldn't answer this one, so it waits for you."
    /// The reason once such a row is no longer asked again (the person switched models without re-checking the queue).
    static let modelWasUnreachableReason = "The decision model couldn't be reached when this came in, so it waits for you."

    /// The other side of a move between your own accounts: the opposite amount on a different account
    /// within five days — a card payment (the card's side must read as a payment) or a transfer between
    /// cash accounts. Card-to-card never pairs: a refund on one card and a charge on another aren't a move.
    /// A row already paired with another is taken.
    static func counterpart(of row: LedgerTransaction, in ledger: Ledger, taken: Set<String>) -> LedgerTransaction? {
        let kinds = Dictionary(uniqueKeysWithValues: ledger.accounts.map { ($0.id, $0.kind) })
        func isCash(_ id: String) -> Bool { kinds[id] == .checking || kinds[id] == .savings }
        guard row.amount.minorUnits != 0, kinds[row.accountID] != nil else { return nil }
        return ledger.transactions
            .filter { other in
                other.accountID != row.accountID && other.amount.minorUnits == -row.amount.minorUnits && !taken.contains(other.id)
                    && other.transferPeerID == nil
                    && abs(other.postedAt.timeIntervalSince(row.postedAt)) <= 5 * 86_400
                    && (isCash(row.accountID) || isCash(other.accountID))
                    && (isCash(row.accountID) || looksLikePayment(row)) && (isCash(other.accountID) || looksLikePayment(other))
                    && (other.categorization?.tier != .user || other.categorization?.categoryID == "transfer")
            }
            .min { abs($0.postedAt.timeIntervalSince(row.postedAt)) < abs($1.postedAt.timeIntervalSince(row.postedAt)) }
    }

    static func timed<T>(_ outcome: inout Outcome, _ work: () async throws -> T) async rethrows -> T {
        let start = ContinuousClock.now
        let result = try await work()
        let elapsed = ContinuousClock.now - start
        outcome.modelMilliseconds += Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        return result
    }

    /// One decision per descriptor and direction; every row with both inherits it. Money in and money out under one
    /// descriptor ("Brokerage transfer") are different questions, and so is money coming in on a credit card (never
    /// pay) and anywhere else. Ingest, re-checking the queue and re-checking what the model filed all group this way
    /// (`Ledger.decisionKey`).
    static func decisionKey(_ row: LedgerTransaction, accountKind: AccountKind?) -> String {
        Descriptor.normalize(row.rawDescription) + (row.amount.isNegative ? " ·out" : accountKind == .credit ? " ·in on a card" : " ·in")
    }

    /// Applies the agreement rule to an answer that fell short of the policy.
    static func agreement(_ answer: DecisionAnswer?, bankCategory: String?, known: Set<String>) -> String? {
        guard let answer, case let pick = answer.value, let hint = bankCategory.flatMap(ProviderCategories.map), known.contains(hint),
              pick == hint, (answer.confidence ?? 0) >= agreementFloor else { return nil }
        return pick
    }

    /// Never throws: by the time it runs, ingest has already added the rows to the ledger, and a failure here would
    /// leave them in memory unsaved — a later sync then skips them as known and moves the cursor past them. A model
    /// that can't be reached sends its rows to review instead, to be asked again next time.
    static func categorize(newRowIDs: [String], in ledger: Ledger, model: (any DecisionModel)?, escalation: (any DecisionModel)?) async -> Outcome {
        var outcome = Outcome()
        let ids = Set(newRowIDs)
        outcome.asked = ids
        let rows = ledger.transactions.filter { ids.contains($0.id) }
        let memory = ledger.merchantMemory(excluding: ids)
        // Nothing new is filed under a category that was merged away.
        let categories = ledger.activeCategories
        let known = Set(categories.map(\.id))
        let policy = ledger.decisionPolicy
        let book = ledger.ruleBook()
        var pending: [LedgerTransaction] = []
        var paired = Set<String>()
        let names = Dictionary(uniqueKeysWithValues: ledger.accounts.map { ($0.id, $0.name) })
        // Money coming in on a card that memory or a statement would file as Income: to review, with honest suggestions.
        func cardIncomeToReview(_ row: LedgerTransaction, _ source: String) {
            let ranked = ledger.cardCreditSuggestions(for: row, known: known)
            outcome.categorizations[row.id] = Categorization(categoryID: ranked.first?.categoryID ?? BudgetCategory.transferID,
                                                             confidence: ranked.first?.confidence ?? 0, tier: .model, needsReview: true)
            outcome.suggestions[row.id] = ranked
            outcome.reasons[row.id] = cardIncomeReason(source)
            outcome.needsReview += 1
        }

        // A row paired as the other side of an earlier row in this batch is already filed.
        for row in rows where !paired.contains(row.id) {
            if let rule = book.winner(for: row, RuleText(row), known: known) {
                outcome.categorizations[row.id] = Categorization(categoryID: rule.categoryID, confidence: 1, tier: .rule, needsReview: false, decidedBy: rule.stamp)
                outcome.byRule += 1
            } else if known.contains("transfer"), let other = counterpart(of: row, in: ledger, taken: paired) {
                // Both sides become a transfer: money moving between your accounts is neither spending nor income.
                paired.formUnion([row.id, other.id])
                outcome.transferPeers[row.id] = other.id
                outcome.transferPeers[other.id] = row.id
                outcome.categorizations[row.id] = Categorization(categoryID: "transfer", confidence: 1, tier: .transferMatch, needsReview: false,
                                                                 decidedBy: "\(matchedTransfer) · \(names[other.accountID] ?? "another account")")
                if other.categorization?.categoryID != "transfer" || other.categorization?.needsReview == true {
                    outcome.categorizations[other.id] = Categorization(categoryID: "transfer", confidence: 1, tier: .transferMatch, needsReview: false,
                                                                       decidedBy: "\(matchedTransfer) · \(names[row.accountID] ?? "another account")")
                }
                outcome.byTransferMatch += 1
            } else if row.source == .fileImport, let type = row.providerCategory, let settled = Self.statementSettled[type], known.contains(settled) {
                if settled == BudgetCategory.incomeID, ledger.isCardCredit(row) {
                    cardIncomeToReview(row, "The statement calls this income")
                } else {
                    // The statement itself says what the row is (an OFX interest or transfer row, a Chase payment).
                    outcome.categorizations[row.id] = Categorization(categoryID: settled, confidence: 1, tier: .statement, needsReview: false,
                                                                     decidedBy: statementDecidedBy)
                    outcome.byStatement += 1
                }
            } else if let remembered = memory[Descriptor.normalize(row.rawDescription)], known.contains(remembered),
                      !(ledger.isMoneyIn(remembered) && row.amount.isNegative) {
                if remembered == BudgetCategory.incomeID, ledger.isCardCredit(row) {
                    cardIncomeToReview(row, "Merchant memory would file this as Income")
                } else if let reason = policy.reviewReason(for: row, newMerchant: false) {
                    // Memory knows the merchant, but the amount is past what the person wants filed without a look.
                    outcome.categorizations[row.id] = Categorization(categoryID: remembered, confidence: 0.99, tier: .merchantMemory, needsReview: true)
                    outcome.suggestions[row.id] = [CategorySuggestion(categoryID: remembered, confidence: 0.99)]
                    outcome.reasons[row.id] = reason
                    outcome.needsReview += 1
                } else {
                    outcome.categorizations[row.id] = Categorization(categoryID: remembered, confidence: 0.99, tier: .merchantMemory, needsReview: false)
                    outcome.byMemory += 1
                }
            } else {
                pending.append(row)
            }
        }

        let key = ledger.decisionKey
        let groups = Dictionary(grouping: pending, by: key)
        let representatives = groups.values.map { $0[0] }
        var answers: [String: (answer: DecisionAnswer?, label: String)] = [:]
        var unreachable = false
        /// Descriptors the model rejected on their own (the rest of the batch was answered).
        var refused = Set<String>()
        if let model, !representatives.isEmpty {
            let requests = representatives.map { CategoryDecisions.request(for: $0, categories: categories, accountKind: ledger.accountKind($0.accountID)) }
            do {
                let responses = try await timed(&outcome) { try await model.decide(requests) }
                outcome.modelCalls += requests.count
                for (row, response) in zip(representatives, responses) {
                    if response.failure != nil { refused.insert(key(row)); continue }
                    answers[key(row)] = (response.answers[CategoryDecisions.questionID], model.label)
                }
                if let failure = responses.lazy.compactMap(\.failure).first {
                    let rows = pending.filter { refused.contains(key($0)) }.count
                    outcome.warnings.append("\(model.label) couldn't answer \(refused.count) merchant\(refused.count == 1 ? "" : "s") (\(failure)), so \(rows) transaction\(rows == 1 ? "" : "s") went to review.")
                }
            } catch {
                unreachable = true
                outcome.modelUnreachable = true
                outcome.warnings.append("Couldn't reach \(model.label) (\(error.localizedDescription)), so \(pending.count) transaction\(pending.count == 1 ? "" : "s") went to review. They're asked again on the next sync.")
            }
            // Escalation re-asks what the local model was unsure of; with no local answers at all it isn't asked, so no
            // more leaves than the person chose to send.
            if let escalation, !unreachable {
                // Only what the local model answered and wasn't sure of; a request it refused isn't passed on.
                let unsure = representatives.filter { !refused.contains(key($0)) && (answers[key($0)]?.answer?.confidence ?? 0) < policy.threshold }
                if !unsure.isEmpty {
                    do {
                        let second = try await timed(&outcome) { try await escalation.decide(unsure.map { CategoryDecisions.request(for: $0, categories: categories, accountKind: ledger.accountKind($0.accountID)) }) }
                        outcome.modelCalls += unsure.count
                        for (row, response) in zip(unsure, second) {
                            if let a = response.answers[CategoryDecisions.questionID], (a.confidence ?? 0) >= policy.threshold {
                                answers[key(row)] = (a, "\(escalation.label) · escalated")
                            }
                        }
                    } catch {
                        // An escalation failure keeps the local answers rather than failing the sync.
                        outcome.warnings.append("Couldn't reach \(escalation.label) for \(unsure.count) unsure merchant\(unsure.count == 1 ? "" : "s"): \(error.localizedDescription)")
                    }
                }
            }
        }

        for (descriptor, members) in groups {
            var decided = answers[descriptor]
            // Money going out is never money in, and money coming in on a card is never Income, however sure the model
            // is: those go to review (a group is one direction, and card money in is asked on its own).
            let (checked, held) = guarded(decided?.answer, for: members[0], in: ledger)
            if held != nil, let label = decided?.label { decided = (checked, label) }
            // What the model would file on its own: its pick above the bar, or below it the pick the bank's own
            // label agrees with.
            var filed: (categoryID: String, confidence: Double, label: String)?
            var ranked: [CategorySuggestion] = []
            switch CategoryDecisions.outcome(decided?.answer, policy: policy, knownCategoryIDs: known) {
            case let .accept(categoryID, confidence):
                if let decided { filed = (categoryID, confidence, decided.label) }
            case let .review(suggestions):
                ranked = suggestions
                if let decided, let agreed = agreement(decided.answer, bankCategory: members[0].providerCategory, known: known) {
                    filed = (agreed, decided.answer?.confidence ?? Self.agreementFloor, "\(decided.label) · agrees with the bank")
                }
            }
            if let filed {
                ranked = CategoryDecisions.suggestions(leadingWith: CategorySuggestion(categoryID: filed.categoryID, confidence: filed.confidence),
                                                       decided?.answer, knownCategoryIDs: known)
            }
            if let hint = members[0].providerCategory.flatMap(ProviderCategories.map), known.contains(hint), !ranked.contains(where: { $0.categoryID == hint }) {
                ranked.append(CategorySuggestion(categoryID: hint, confidence: 0.5))
            }
            if let held { guardSuggestions(&ranked, held: held, for: members[0], in: ledger, known: known) }
            ranked = offerable(ranked, for: members[0], in: ledger)
            for row in members {
                let policyHeld = filed == nil ? nil : policy.reviewReason(for: row, newMerchant: true)
                if let filed, policyHeld == nil {
                    outcome.categorizations[row.id] = Categorization(categoryID: filed.categoryID, confidence: filed.confidence, tier: .decisionModel,
                                                                    needsReview: false, decidedBy: filed.label)
                    outcome.byModel += 1
                    continue
                }
                let best = ranked.first
                outcome.categorizations[row.id] = Categorization(categoryID: best?.categoryID ?? "shopping", confidence: best?.confidence ?? 0,
                                                                tier: decided == nil ? .model : .decisionModel, needsReview: true, decidedBy: decided?.label)
                outcome.suggestions[row.id] = ranked
                outcome.reasons[row.id] = policyHeld ?? (unreachable ? modelUnreachableReason
                    : refused.contains(descriptor) ? modelRefusedReason : reviewReason(for: row, modelIsOn: model != nil, held: held))
                outcome.needsReview += 1
            }
        }
        return outcome
    }

    /// `decidedBy` on rows a statement file settled.
    static let statementDecidedBy = "From the statement"

    /// Why a new row the model didn't file came to the person, in plain words.
    static func reviewReason(for row: LedgerTransaction, modelIsOn: Bool, held: Held? = nil) -> String {
        if let held { return held.reason }
        if Descriptor.isGeneric(row.rawDescription) {
            // Nothing to remember it by, and the transfer match (the usual answer for these) found no other side.
            let other = row.amount.isNegative ? "deposit" : "withdrawal"
            return "“\(row.rawDescription.trimmingCharacters(in: .whitespaces))” doesn't name a merchant, and no matching \(other) turned up in your other accounts within 5 days."
        }
        return modelIsOn ? "New merchant; the decision model wasn't sure enough to file it." : "New merchant, and the decision model is off."
    }
}

/// Provider categories → ledger category ids. Hints only: shown as review suggestions, never auto-applied.
public enum ProviderCategories {
    public static func map(_ raw: String) -> String? {
        let s = raw.uppercased()
        // Plaid personal_finance_category (detailed first, then primary).
        let plaid: [(String, String)] = [
            ("FOOD_AND_DRINK_GROCERIES", "groceries"), ("RENT_AND_UTILITIES_RENT", "housing"), ("TRANSPORTATION", "transport"),
            ("FOOD_AND_DRINK", "dining"), ("GENERAL_MERCHANDISE", "shopping"), ("TRAVEL", "travel"), ("RENT_AND_UTILITIES", "utilities"),
            ("INCOME", "income"), ("TRANSFER_IN", "transfer"), ("TRANSFER_OUT", "transfer"), ("LOAN_PAYMENTS", "transfer"),
            ("MEDICAL", "health"), ("PERSONAL_CARE", "health"), ("ENTERTAINMENT", "entertainment"), ("HOME_IMPROVEMENT", "shopping"),
            ("BANK_FEES", "fees"),
        ]
        if let hit = plaid.first(where: { s.hasPrefix($0.0) }) { return hit.1 }
        // Teller details.category.
        let teller: [String: String] = [
            "DINING": "dining", "BAR": "dining", "GROCERIES": "groceries", "FUEL": "transport", "TRANSPORT": "transport",
            "TRANSPORTATION": "transport", "UTILITIES": "utilities", "PHONE": "utilities", "HEALTH": "health", "INCOME": "income",
            "SHOPPING": "shopping", "CLOTHING": "shopping", "ELECTRONICS": "shopping", "SOFTWARE": "subscriptions",
            "ACCOMMODATION": "travel", "HOME": "housing", "ENTERTAINMENT": "entertainment", "SPORT": "health",
        ]
        if let hit = teller[s] { return hit }
        // Chase's statement-export categories.
        let chase: [String: String] = [
            "FOOD & DRINK": "dining", "GROCERIES": "groceries", "SHOPPING": "shopping", "HEALTH & WELLNESS": "health",
            "TRAVEL": "travel", "GAS": "transport", "AUTOMOTIVE": "transport", "BILLS & UTILITIES": "utilities",
            "FEES & ADJUSTMENTS": "fees", "PAYMENT": "transfer",
        ]
        if let hit = chase[s] { return hit }
        // Amex's "Group-Subgroup" categories; only the unambiguous ones.
        let amexExact: [String: String] = [
            "MERCHANDISE & SUPPLIES-GROCERIES": "groceries", "BUSINESS SERVICES-HEALTH CARE SERVICES": "health",
            "COMMUNICATIONS-CABLE & INTERNET COMM": "utilities", "TRANSPORTATION-FUEL": "transport",
        ]
        if let hit = amexExact[s] { return hit }
        let amexGroup: [(String, String)] = [
            ("RESTAURANT-", "dining"), ("FEES & ADJUSTMENTS-", "fees"), ("TRAVEL-", "travel"), ("TRANSPORTATION-", "transport"),
            ("ENTERTAINMENT-", "entertainment"), ("MERCHANDISE & SUPPLIES-", "shopping"),
        ]
        return amexGroup.first(where: { s.hasPrefix($0.0) })?.1
    }
}
