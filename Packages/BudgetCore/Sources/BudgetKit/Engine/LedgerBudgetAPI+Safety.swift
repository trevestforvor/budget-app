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
