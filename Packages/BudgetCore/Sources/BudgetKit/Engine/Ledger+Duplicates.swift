import Foundation

// Safer dedupe (Lane L, P1.3): rows that might be duplicates wait for the person, and every row merged away, skipped or
// swept is logged with both ids and a copy, so it can be brought back.

extension Ledger {
    /// How long merge-log entries are kept (pruned as entries are added).
    static let mergeLogDays = 400

    /// The start of a possible-duplicate review reason; how a reason is recognized as one.
    static let possibleDuplicateLead = "This might be the same charge as one already here"

    /// Adds entries to the merge log under ids of their own ("<kind>-<batch>-<row id>", numbered on a clash), and drops
    /// entries older than `mergeLogDays`. A row skipped again is logged once: a window source (SimpleFIN) sends its
    /// recent days on every sync, so the same incoming row is skipped each time until it's brought back.
    mutating func appendMerges(_ records: [RowMergeRecord]) {
        let cutoff = now.addingTimeInterval(-Double(Self.mergeLogDays) * 86_400)
        mergeLog.removeAll { $0.at < cutoff }
        guard !records.isEmpty else { return }
        // Built once per call: a statement import can log thousands of skipped rows.
        var taken = Set(mergeLog.map(\.id))
        var skipped = Set(mergeLog.filter { $0.kind == .skippedIncoming && $0.undoneAt == nil }.map(\.droppedID))
        for var record in records {
            if record.kind == .skippedIncoming { guard skipped.insert(record.droppedID).inserted else { continue } }
            let base = "\(record.kind.rawValue)-\(record.batchID ?? "none")-\(record.droppedID)"
            var id = base, n = 1
            while taken.contains(id) { n += 1; id = "\(base)-\(n)" }
            taken.insert(id)
            record.id = id
            mergeLog.append(record)
        }
    }

    /// What a merge carries from the row that goes onto the row that stays: the person's own category (and, when the
    /// person said two rows are one, a settled category onto a row still waiting for one), hidden, the note, tags, a
    /// renamed merchant. Undo works out the same thing again to tell whether the kept row changed since.
    static func carryOnMerge(from dropped: LedgerTransaction, to kept: inout LedgerTransaction, kind: RowMergeRecord.Kind) {
        if dropped.categorization?.tier == .user && kept.categorization?.tier != .user {
            kept.categorization = dropped.categorization
        } else if kind == .duplicateResolved, kept.categorization?.needsReview == true, let settled = dropped.categorization, !settled.needsReview {
            kept.categorization = settled
        }
        carryUserFields(from: dropped, to: &kept)
        if kept.isHidden { kept.categorization?.needsReview = false }
    }

    /// Sends rows added as possible duplicates to review, even ones a rule filed, saying which row they might be. Ids
    /// with no entry in `possibleDuplicates` (answered meanwhile) are skipped. A row left waiting because the decision
    /// model couldn't be reached keeps that reason, so it's still asked again; it's flagged once it's filed.
    mutating func flagPossibleDuplicates(_ ids: some Sequence<String>) {
        let index = Dictionary(transactions.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in Set(ids) {
            guard let others = possibleDuplicates[id], let i = index[id], let first = others.lazy.compactMap({ index[$0] }).first,
                  let categorization = transactions[i].categorization else { continue }
            transactions[i].categorization?.needsReview = true
            if (suggestions[id] ?? []).isEmpty {
                suggestions[id] = [CategorySuggestion(categoryID: categorization.categoryID, confidence: categorization.confidence)]
            }
            guard reviewReasons[id] != Categorizer.modelUnreachableReason else { continue }
            let other = transactions[first]
            reviewReasons[id] = "\(Self.possibleDuplicateLead) (\(other.source.displayName) · \(other.postedAt.formatted(.dateTime.month(.abbreviated).day())) · \(other.rawDescription)). If it is, choose Same charge in Review on the dashboard; if not, file it as usual."
        }
    }

    /// Drops possible-duplicate entries for rows that have left the ledger, and candidates that have.
    mutating func prunePossibleDuplicates() {
        guard !possibleDuplicates.isEmpty else { return }
        let ids = Set(transactions.map(\.id))
        possibleDuplicates = possibleDuplicates.reduce(into: [:]) { out, entry in
            guard ids.contains(entry.key) else { return }
            let others = entry.value.filter(ids.contains)
            if !others.isEmpty { out[entry.key] = others }
        }
    }

    /// The rows waiting on a Same charge / Keep both answer, newest first.
    var possibleDuplicateList: [PossibleDuplicate] {
        let index = Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return possibleDuplicates.compactMap { id, others -> PossibleDuplicate? in
            guard let row = index[id] else { return nil }
            let candidates = others.compactMap { index[$0] }
            return candidates.isEmpty ? nil : PossibleDuplicate(id: id, row: row, candidates: candidates)
        }
        .sorted { ($0.row.postedAt, $0.id) > ($1.row.postedAt, $1.id) }
    }

    /// The person's answer on a possible duplicate. `sameAs: nil` (Keep both) clears the question; the row stays in review
    /// for its category. `sameAs` one of its candidates merges the two: the provider's row stays (it keeps updating), and
    /// between two providers' rows the one that was here first. The kept row takes the other's category if the person
    /// gave it (or a settled one, when the kept row is still waiting), hidden, the note, tags, a renamed merchant and a
    /// transfer pairing, and the merge is logged with both ids and a copy of each row for undo.
    mutating func resolveDuplicate(rowID: String, sameAs: String?) throws -> RowMergeRecord? {
        guard let rowIndex = transactions.firstIndex(where: { $0.id == rowID }) else { throw BudgetAPIError.notFound }
        guard let sameAs else {
            possibleDuplicates[rowID] = nil
            return nil
        }
        guard possibleDuplicates[rowID]?.contains(sameAs) == true else {
            throw BudgetAPIError.rejected("That isn't one of the transactions this one might be the same as.")
        }
        guard let otherIndex = transactions.firstIndex(where: { $0.id == sameAs }) else { throw BudgetAPIError.notFound }
        let flagged = transactions[rowIndex], other = transactions[otherIndex]
        let keepFlagged = flagged.source != .fileImport && other.source == .fileImport
        let (keptIndex, dropped) = keepFlagged ? (rowIndex, other) : (otherIndex, flagged)
        let keptBefore = transactions[keptIndex]
        Self.carryOnMerge(from: dropped, to: &transactions[keptIndex], kind: .duplicateResolved)
        let keptID = keptBefore.id
        if transactions[keptIndex].categorization?.needsReview != true {
            suggestions[keptID] = nil
            reviewReasons[keptID] = nil
        } else if reviewReasons[keptID]?.hasPrefix(Self.possibleDuplicateLead) == true {
            reviewReasons[keptID] = "You said this is the same charge as the one from \(dropped.source.displayName); it still needs a category."
        }
        // The dropped row's transfer pairing moves to the kept row, when it has none of its own.
        if transactions[keptIndex].transferPeerID == nil, let peer = dropped.transferPeerID,
           let peerIndex = transactions.firstIndex(where: { $0.id == peer }) {
            transactions[keptIndex].transferPeerID = peer
            transactions[peerIndex].transferPeerID = keptID
        }
        transactions.removeAll { $0.id == dropped.id }
        suggestions[dropped.id] = nil
        reviewReasons[dropped.id] = nil
        possibleDuplicates[rowID] = nil
        possibleDuplicates[dropped.id] = nil
        prunePossibleDuplicates()
        reanchor(keptBefore.accountID)
        if dropped.accountID != keptBefore.accountID { reanchor(dropped.accountID) }
        unpairOrphans()
        appendMerges([RowMergeRecord(id: "", kind: .duplicateResolved, at: now, batchID: flagged.batchID, keptID: keptID,
                                     droppedID: dropped.id, dropped: dropped, keptBefore: keptBefore)])
        return mergeLog.last
    }

    /// The fields a merge may carry onto the kept row.
    private struct CarriedFields: Equatable {
        var categorization: Categorization?, isHidden: Bool, note: String?, tags: [String]?, merchant: String, originalMerchant: String?
        var isYearly: Bool?, orderMatch: OrderMatch?

        init(_ t: LedgerTransaction) {
            categorization = t.categorization; isHidden = t.isHidden; note = t.note; tags = t.tags; merchant = t.merchant
            originalMerchant = t.originalMerchant; isYearly = t.isYearly; orderMatch = t.orderMatch
        }

        func restore(onto t: inout LedgerTransaction) {
            t.categorization = categorization; t.isHidden = isHidden; t.note = note; t.tags = tags; t.merchant = merchant
            t.originalMerchant = originalMerchant; t.isYearly = isYearly; t.orderMatch = orderMatch
        }
    }

    /// Brings a logged row back. The kept row gets back what it had before the merge only if nobody changed it since;
    /// otherwise the person's later edits stand. A skipped incoming row comes back with no category, so the next
    /// ingest files it (`awaitingModel`). Returns 1.
    mutating func undoMerge(id: String) throws -> Int {
        guard let r = mergeLog.firstIndex(where: { $0.id == id }) else { throw BudgetAPIError.notFound }
        var record = mergeLog[r]
        guard record.undoneAt == nil else { throw BudgetAPIError.rejected("That transaction was already brought back.") }
        guard !transactions.contains(where: { $0.id == record.droppedID }) else { throw BudgetAPIError.rejected("That transaction is already in the ledger.") }
        guard accounts.contains(where: { $0.id == record.dropped.accountID }) else {
            throw BudgetAPIError.rejected("Its account isn't in the ledger anymore, so it can't come back.")
        }
        var restored = record.dropped
        restored.id = record.droppedID
        if let keptID = record.keptID, let k = transactions.firstIndex(where: { $0.id == keptID }), let before = record.keptBefore {
            var expected = before
            Self.carryOnMerge(from: record.dropped, to: &expected, kind: record.kind)
            if CarriedFields(transactions[k]) == CarriedFields(expected) {
                CarriedFields(before).restore(onto: &transactions[k])
                if transactions[k].categorization?.needsReview != true { reviewReasons[keptID] = nil }
            }
            // A pairing that moved onto the kept row goes back with its row.
            if before.transferPeerID == nil, let peer = record.dropped.transferPeerID, transactions[k].transferPeerID == peer {
                transactions[k].transferPeerID = nil
            }
        }
        if let peer = restored.transferPeerID {
            if let p = transactions.firstIndex(where: { $0.id == peer }),
               transactions[p].transferPeerID == nil || transactions[p].transferPeerID == record.keptID {
                transactions[p].transferPeerID = restored.id
            } else {
                restored.transferPeerID = nil
            }
        }
        transactions.append(restored)
        transactions.sort { $0.postedAt > $1.postedAt }
        record.undoneAt = now
        mergeLog[r] = record
        reanchor(restored.accountID)
        unpairOrphans()
        return 1
    }

    /// "Import the skipped rows anyway": brings back every row a batch skipped as already here. Returns how many came back.
    mutating func undoSkipped(batchID: String) -> Int {
        let ids = mergeLog.filter { $0.batchID == batchID && $0.kind == .skippedIncoming && $0.undoneAt == nil }.map(\.id)
        return ids.reduce(0) { $0 + ((try? undoMerge(id: $1)) ?? 0) }
    }
}
