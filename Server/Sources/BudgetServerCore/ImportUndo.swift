import BudgetKit
import Foundation

/// What Undo may do with an import batch. The cheap annotation on every history read; `GET /v1/imports/:batch/undo`
/// works out the counts (`RollbackPlan`), and `DELETE` is decided by that plan inside the ledger's write.
enum ImportUndo {
    /// A file undoes as always. A Plaid sync is refused: its cursor has moved on, so Plaid never sends the rows again,
    /// and hiding them is the real answer. A SimpleFIN sync warns: rows inside its next window come back.
    static func policy(for record: ImportRecord) -> UndoPolicy {
        if record.rolledBack { return UndoPolicy(mode: .refused, message: "This import was already undone.") }
        if record.outcome == .failed { return UndoPolicy(mode: .refused, message: "This sync failed, so there's nothing to undo.") }
        guard record.kind == .sync else { return UndoPolicy(mode: .allowed) }
        let source = record.report.source
        switch source.syncStyle {
        case .file: return UndoPolicy(mode: .allowed)
        case .window:
            return UndoPolicy(mode: .warn, message: "\(source.displayName) sends its last \(SyncService.overlapDays) days again at every sync, so rows from those days come back after Undo. Hide them instead to keep them out of your totals.")
        case .cursor, .device:
            return UndoPolicy(mode: .refused, message: "\(source.displayName) won't send these rows again. Hide them instead.")
        }
    }

    /// Where the next sync of the record's link starts, so a plan can count the rows it brings back. Nil for a file, or
    /// once the link is gone (nothing will sync it again).
    static func nextWindowStart(for record: ImportRecord, _ service: BudgetService) async throws -> Date? {
        guard record.kind == .sync, let linkID = record.linkID,
              let link = try await service.store.links().first(where: { $0.id == linkID }) else { return nil }
        return await service.sync.window(link)
    }

    /// The plan for a record: the ledger's counts, refused outright whenever the record's own policy refuses (an undone
    /// or failed batch, or a Plaid batch whose rows were since tagged otherwise).
    static func plan(for record: ImportRecord, _ service: BudgetService) async throws -> RollbackPlan {
        var plan = await service.api.rollbackPlan(batchID: record.batchID, nextWindowStart: try await nextWindowStart(for: record, service))
        let policy = policy(for: record)
        if policy.mode == .refused {
            plan.verdict = .refuse
            plan.message = policy.message ?? plan.message
        }
        return plan
    }
}
