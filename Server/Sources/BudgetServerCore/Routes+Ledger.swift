import BudgetKit
import Foundation
import Hummingbird

/// Undo plans, hiding a batch, account edits, duplicates and merges, and the statement-id dry run.
func addLedgerSafetyRoutes(_ router: Router<BasicRequestContext>, _ service: BudgetService, surface: Surface) {
    /// An account's kind, nickname or last digits (`AccountChange`) → `AccountChangeResult`, with what to check and how
    /// many rows went back to review. On both surfaces: the phone's sheet and the dashboard's drawer. Undo is a second
    /// PATCH with the previous values. 404 for an unknown account, 422 for a nickname or digits it won't keep.
    router.patch("/v1/accounts/:id") { request, context in
        let change = try await HTTP.body(AccountChange.self, request, limit: 64 * 1024)
        return try HTTP.json(try await service.api.updateAccount(id: try HTTP.rowID(context), change))
    }

    if surface == .dashboard {
        /// What the statement-id upgrade would rename now (`LedgerMigrations.StatementIDCounts`), counts only. Useful
        /// in `BUDGET_STATEMENT_ID_MIGRATION=audit` on a restored copy; a normal start upgrades before it serves, so 0s.
        router.get("/dash/maintenance/statement-ids") { _, _ in try HTTP.json(await LedgerMigrations.statementIDCounts(service)) }
    }
}
