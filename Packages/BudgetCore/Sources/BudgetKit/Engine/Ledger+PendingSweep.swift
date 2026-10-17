import Foundation

// Stale-pending sweep (Lane L, B4). A window source (SimpleFIN) has no "removed" list the way Plaid does: a pending row
// that posts under a new id, or that the bank drops, simply stops coming. Left alone it stays in the ledger for good,
// counted twice next to its posted row. After each account's rows, ingest settles such a row into the posted row that
// replaced it when one clearly does, and otherwise drops it once it's been missed twice, half a day apart. Both are
// logged in the merge log with a full copy, so either can be brought back.

/// The sweep's bands and waits. Guesses to tune against real pulls, as the proposal says.
enum PendingSweep {
    /// Rows this close to the start of what the pull covered aren't swept: a bank can shift a date across the edge.
    static let windowMargin: TimeInterval = 2 * 86_400
    /// A posted row may be dated this long before its pending row…
    static let settleBefore: TimeInterval = 86_400
    /// …or this long after.
    static let settleAfter: TimeInterval = 10 * 86_400
    /// A posted row up to 30% plus $2 more than the hold settles it (a tip, a small adjustment)…
    static let tipPercent: Int64 = 130
    static let tipSlack = Money(minorUnits: 200)
    /// …and down to 75% of it.
    static let shrinkPercent: Int64 = 75
    /// A hold that came down to a smaller charge (near-identical wording) settles only into one at least this share of
    /// it: a $200 hold at a store and an unrelated $4.99 charge there a few days later aren't one charge.
    static let shrinkFloorPercent: Int64 = 25
    /// A hold this small is a placeholder authorization (a fuel pump, a hotel): the real charge is any amount.
    static let placeholderMax = Money(minorUnits: 150)
    /// Wording at least this close is the same merchant for sure: a placeholder settles, and so does a hold that came
    /// down to a smaller charge.
    static let sameMerchant = 0.8
    /// Wording at least this close is needed at all.
    static let similar = Deduplicator.similarityThreshold
    /// A missed row goes only when it's missed again at least this long after the first miss.
    static let minMissAge: TimeInterval = 12 * 3_600

    /// Whether `posted` is a plausible final charge for the hold `pending`, given how alike they read.
    static func amountsFit(pending: Money, posted: Money, similarity: Double) -> Bool {
        guard pending.isNegative == posted.isNegative else { return false }
        let p = pending.magnitude.minorUnits, q = posted.magnitude.minorUnits
        if 100 * q >= shrinkPercent * p && 100 * q <= tipPercent * p + 100 * tipSlack.minorUnits { return true }
        if p <= placeholderMax.minorUnits && similarity >= sameMerchant { return true }
        return similarity >= sameMerchant && q < p && 100 * q >= shrinkFloorPercent * p
    }

    /// How alike two rows read: the best of their merchants' and descriptions' similarity, either way round.
    static func similarity(_ a: LedgerTransaction, _ b: LedgerTransaction) -> Double {
        [Deduplicator.similarity(a.merchant, b.merchant), Deduplicator.similarity(a.merchant, b.rawDescription),
         Deduplicator.similarity(a.rawDescription, b.merchant), Deduplicator.similarity(a.rawDescription, b.rawDescription)].max() ?? 0
    }

    /// Pairs missing pending rows with posted rows, one to one, both given by an index of the caller's. A posted row may be
    /// dated `before` seconds ahead of its pending row, up to `settleAfter` after, with wording that agrees and an amount
    /// that fits. A pending row two posted rows fit, or a posted row two pending rows fit, isn't paired. Returns the pairs
    /// (pending → posted) and every pending row anything fit.
    static func pairs(pending: [(Int, LedgerTransaction)], posted: [(Int, LedgerTransaction)], before: TimeInterval)
        -> (pairs: [Int: Int], fitted: Set<Int>) {
        var fits: [Int: [Int]] = [:]
        var claimants: [Int: Int] = [:]
        for (i, hold) in pending {
            for (j, row) in posted {
                let gap = row.postedAt.timeIntervalSince(hold.postedAt)
                guard gap >= -before, gap <= settleAfter else { continue }
                let score = similarity(hold, row)
                guard score >= similar, amountsFit(pending: hold.amount, posted: row.amount, similarity: score) else { continue }
                fits[i, default: []].append(j)
                claimants[j, default: 0] += 1
            }
        }
        var pairs: [Int: Int] = [:]
        for (i, candidates) in fits where candidates.count == 1 && claimants[candidates[0]] == 1 { pairs[i] = candidates[0] }
        return (pairs, Set(fits.keys))
    }
}

extension Ledger {
    /// What sweeping one account's stale pending rows did. The caller appends `replaced` to its own list (so the
    /// transfer pairing moves to the posted row and a carried category skips categorizing), removes `remove` once every
    /// account is done, and logs `log`.
    struct PendingSweepOutcome {
        var replaced: [(pending: Int, posted: String)] = []
        var remove: Set<String> = []
        var log: [RowMergeRecord] = []
        var settled = 0
        var dropped = 0
    }

    /// Sweeps the pending rows `source` stopped sending on one account. `seen` is every incoming row id for the account
    /// this pull; `added` the rows about to be added (settled posted rows take what the person did to their pending
    /// row); `claimed` posted ids that already replaced a pending row; `coveredFrom` the oldest day the pull asked for.
    /// Only rows on or after `coveredFrom` plus a margin count as missing: older ones weren't asked for.
    ///
    /// Settling is strong evidence, so it's immediate: a missing pending row and a new posted row of the same sign, dated
    /// a day before to ten days after it, with wording that agrees and an amount that fits (`PendingSweep.amountsFit`),
    /// pair one to one. A pending row two posted rows fit, or a posted row two pending rows fit, isn't settled: it falls
    /// to the miss rule. A pending row nothing in `added` fits may instead settle into a posted row already in the
    /// ledger (same account and source, dated on or up to ten days after it, not already a settled row's): a bank can
    /// send the posted row for a pull or two while still listing the pending one. Dropping is weak evidence: a missing
    /// row is remembered in `pendingMisses` and dropped only when it's missing again 12 hours or more later. A row the
    /// person brought back from the log isn't dropped again, or settled again into a row already here.
    mutating func sweepPending(account accountID: String, source: SourceKind, coveredFrom: Date, seen: Set<String>,
                               added: inout [LedgerTransaction], claimed: Set<String>, claimedPending: Set<Int>,
                               batchID: String) -> PendingSweepOutcome {
        var outcome = PendingSweepOutcome()
        for id in seen { pendingMisses[id] = nil }
        let edge = coveredFrom.addingTimeInterval(PendingSweep.windowMargin)
        let missing = transactions.indices.filter { i in
            let row = transactions[i]
            return row.accountID == accountID && row.source == source && row.isPending && row.postedAt >= edge
                && !seen.contains(row.id) && !claimedPending.contains(i)
        }
        guard !missing.isEmpty else { return outcome }

        let broughtBack = Set(mergeLog.lazy.filter { ($0.kind == .pendingDropped || $0.kind == .pendingSettled) && $0.undoneAt != nil }.map(\.droppedID))
        // First the posted rows this pull adds…
        let fresh = added.enumerated().filter { !$0.element.isPending && !claimed.contains($0.element.id) }.map { ($0.offset, $0.element) }
        let (intoAdded, fitted) = PendingSweep.pairs(pending: missing.map { ($0, transactions[$0]) }, posted: fresh, before: PendingSweep.settleBefore)
        // …then, for a pending row none of them fit, the posted rows already here that no pending row settled into yet.
        let settledInto = Set(mergeLog.lazy.filter { $0.kind == .pendingSettled }.compactMap(\.keptID))
        let unfitted = missing.filter { !fitted.contains($0) && !broughtBack.contains(transactions[$0].id) }
        let here = unfitted.isEmpty ? [] : transactions.indices.filter { k in
            let row = transactions[k]
            return row.accountID == accountID && row.source == source && !row.isPending && !claimed.contains(row.id) && !settledInto.contains(row.id)
        }.map { ($0, transactions[$0]) }
        let intoLedger = here.isEmpty ? [:] : PendingSweep.pairs(pending: unfitted.map { ($0, transactions[$0]) }, posted: here, before: 0).pairs

        for i in missing {
            let pending = transactions[i]
            if let j = intoAdded[i] {
                let keptBefore = added[j]
                if Self.carryOver(from: pending, to: &added[j]) { outcome.replaced.append((i, added[j].id)) }
                outcome.remove.insert(pending.id)
                outcome.log.append(RowMergeRecord(id: "", kind: .pendingSettled, at: now, batchID: batchID, keptID: keptBefore.id,
                                                  droppedID: pending.id, dropped: pending, keptBefore: keptBefore))
                outcome.settled += 1
                continue
            }
            if let k = intoLedger[i] {
                let keptBefore = transactions[k]
                if Self.carryOver(from: pending, to: &transactions[k]) {
                    outcome.replaced.append((i, keptBefore.id))
                    if transactions[k].categorization?.needsReview != true { reviewReasons[keptBefore.id] = nil }
                }
                outcome.remove.insert(pending.id)
                outcome.log.append(RowMergeRecord(id: "", kind: .pendingSettled, at: now, batchID: batchID, keptID: keptBefore.id,
                                                  droppedID: pending.id, dropped: pending, keptBefore: keptBefore))
                outcome.settled += 1
                continue
            }
            guard !broughtBack.contains(pending.id) else { continue }
            guard let firstMiss = pendingMisses[pending.id] else {
                pendingMisses[pending.id] = now
                continue
            }
            guard now.timeIntervalSince(firstMiss) >= PendingSweep.minMissAge else { continue }
            outcome.remove.insert(pending.id)
            outcome.log.append(RowMergeRecord(id: "", kind: .pendingDropped, at: now, batchID: batchID, droppedID: pending.id, dropped: pending))
            outcome.dropped += 1
        }
        return outcome
    }

    /// Takes the swept rows out (their review state with them) and forgets misses for rows that are gone or have posted.
    /// The caller re-anchors the accounts.
    mutating func removeSweptPending(_ ids: Set<String>) {
        if !ids.isEmpty {
            transactions.removeAll { ids.contains($0.id) }
            for id in ids { suggestions[id] = nil; reviewReasons[id] = nil }
            unpairOrphans()
            prunePossibleDuplicates()
        }
        guard !pendingMisses.isEmpty else { return }
        let stillPending = Set(transactions.lazy.filter(\.isPending).map(\.id))
        pendingMisses = pendingMisses.filter { stillPending.contains($0.key) }
    }

    /// The sync log's line for what the sweep did ("2 pending charges settled under new ids; 1 the bank dropped was
    /// removed."), nil when it did nothing.
    static func pendingSweepNote(settled: Int, dropped: Int) -> String? {
        let settledPart = settled == 0 ? nil
            : settled == 1 ? "1 pending charge settled under a new id" : "\(settled) pending charges settled under new ids"
        let droppedPart = dropped == 0 ? nil
            : settledPart == nil ? "\(dropped) pending charge\(dropped == 1 ? "" : "s") the bank dropped \(dropped == 1 ? "was" : "were") removed"
            : "\(dropped) the bank dropped \(dropped == 1 ? "was" : "were") removed"
        let parts = [settledPart, droppedPart].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "; ") + "."
    }
}
