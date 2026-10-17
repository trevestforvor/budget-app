import BudgetKit
import Foundation
import Hummingbird

/// Undo plans, hiding a batch, account edits, duplicates and merges, and the statement-id dry run.
func addLedgerSafetyRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService, surface: Surface) {
    if surface == .dashboard {
        /// What the statement-id upgrade would rename now (`LedgerMigrations.StatementIDCounts`), counts only. Useful
        /// in `BUDGET_STATEMENT_ID_MIGRATION=audit` on a restored copy; a normal start upgrades before it serves, so 0s.
        router.get("/dash/maintenance/statement-ids") { _, _ in try HTTP.json(await LedgerMigrations.statementIDCounts(service)) }
    }
}
