import BudgetKit
import Foundation

/// One-time ledger migrations that need the server (keys, the balance history), run by `prepare` after the ledger loads
/// and before anything syncs. Never throws: a failure must not stop the server from starting; each migration handles and
/// logs its own. Skipped when `ledgerInSync` is false (saving the loaded ledger failed, so memory and Postgres differ).
enum LedgerMigrations {
    static func run(_ service: BudgetService, ledgerInSync: Bool) async {}
}
