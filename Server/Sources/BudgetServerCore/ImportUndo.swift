import BudgetKit
import Foundation

/// What Undo may do with an import batch.
enum ImportUndo {
    /// Every batch that isn't rolled back or failed may be undone, as before.
    static func policy(for record: ImportRecord) -> UndoPolicy {
        if record.rolledBack { return UndoPolicy(mode: .refused, message: "This import was already undone.") }
        if record.outcome == .failed { return UndoPolicy(mode: .refused, message: "This sync failed, so there's nothing to undo.") }
        return UndoPolicy(mode: .allowed)
    }
}
