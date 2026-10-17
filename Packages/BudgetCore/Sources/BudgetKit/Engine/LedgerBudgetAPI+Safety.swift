import Foundation

// Ledger safety (Lane L): what Undo may do with a batch, and hiding a batch instead.

extension LedgerBudgetAPI {
    /// What undoing `batchID` would do now. `nextWindowStart` is where the next sync of the batch's link starts
    /// (nil when nothing will sync it again), so window-source rows from then on count as coming back.
    public func rollbackPlan(batchID: String, nextWindowStart: Date?) -> RollbackPlan {
        ledger.rollbackPlan(batchID: batchID, nextWindowStart: nextWindowStart)
    }

    /// Hides a batch's rows from every total (balances keep them): what synced rows get instead of Undo, since a
    /// hidden row stays hidden when its provider sends it again. It's an ordinary edit, so the result carries its undo.
    public func hideBatch(batchID: String) async throws -> ActionResult {
        tick()
        return try await write {
            let ids = ledger.transactions.filter { $0.batchID == batchID && !$0.isHidden }.map(\.id)
            guard !ids.isEmpty else { return ActionResult(message: "Nothing from this batch is left to hide.") }
            return try ledger.perform(.editTransactions(EditTransactions(transactionIDs: ids, isHidden: true)))
        }
    }

    /// The batches that still have rows, all of them hidden. History works "hidden" out from this on every read, so a
    /// batch shown again (its undo, or from Activity) reads as not hidden and can be hidden again.
    public func hiddenBatchIDs() -> Set<String> {
        var allHidden: [String: Bool] = [:]
        for row in ledger.transactions { if let batch = row.batchID { allHidden[batch] = (allHidden[batch] ?? true) && row.isHidden } }
        return Set(allHidden.filter(\.value).keys)
    }
}

// MARK: Statement ids (P0.6)

extension LedgerBudgetAPI {
    /// What the statement-id upgrade would rename now, counted (no key needed, nothing changed).
    public func statementIDAudit() -> StatementIDAudit { ledger.statementIDAudit() }

    /// Takes account numbers out of statement ids, in one write: the old rows are deleted and the new ones written in
    /// one transaction, and a failed save leaves the ledger (in memory too) as it was. Running it again changes nothing.
    public func hashStatementIDs(_ ids: StatementIDs) async throws -> StatementIDMigration {
        tick()
        return try await write { ledger.hashStatementIDs(ids) }
    }

    /// Runs every kept conversation's stored JSON through `scrub` and saves those it changed (none with `dryRun`).
    /// Returns how many it changed. The server runs it once at start, before anyone can ask anything.
    public func rewriteChats(dryRun: Bool = false, _ scrub: @Sendable (String) -> String) async throws -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var changed = 0
        for summary in try await chatStore.chatSummaries() {
            guard let record = try await chatStore.chatRecord(id: summary.id) else { continue }
            let text = String(decoding: try encoder.encode(record), as: UTF8.self)
            let scrubbed = scrub(text)
            guard scrubbed != text else { continue }
            changed += 1
            if !dryRun { try await chatStore.saveChatRecord(try JSONDecoder().decode(ChatSessionRecord.self, from: Data(scrubbed.utf8))) }
        }
        return changed
    }
}

// MARK: Possible duplicates and the merge log (P1.3)

extension LedgerBudgetAPI {
    /// Rows added that might be the same charge as one already here, each with the rows it could be.
    public func possibleDuplicates() -> [PossibleDuplicate] { ledger.possibleDuplicateList }

    /// Same charge (`sameAs` one of the row's candidates) or Keep both (nil). Returns the merge, nil for Keep both.
    public func resolveDuplicate(rowID: String, sameAs: String?) async throws -> RowMergeRecord? {
        tick()
        return try await write { try ledger.resolveDuplicate(rowID: rowID, sameAs: sameAs) }
    }

    /// The merge log, newest first; with `batchID`, only that batch's entries.
    public func merges(batchID: String? = nil) -> [RowMergeRecord] {
        ledger.mergeLog.filter { batchID == nil || $0.batchID == batchID }.sorted { ($0.at, $0.id) > ($1.at, $1.id) }
    }

    /// Brings one logged row back. Returns how many rows came back (1).
    public func undoMerge(id: String) async throws -> Int {
        tick()
        return try await write { try ledger.undoMerge(id: id) }
    }

    /// Brings back every row a batch skipped as already here. Returns how many came back.
    public func undoSkipped(batchID: String) async throws -> Int {
        tick()
        return try await write { ledger.undoSkipped(batchID: batchID) }
    }
}
