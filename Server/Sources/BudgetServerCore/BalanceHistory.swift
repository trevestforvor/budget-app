import BudgetKit
import Foundation
import Logging
import PostgresNIO

/// Daily balances in Postgres (`budget_balances`, migration 3): one row per account per day, written at each sync and
/// read whole for net worth history. They grow every day, so they're rows of their own rather than a ledger document
/// rewritten on every save.
struct PostgresBalanceHistory: BalanceHistoryStore {
    let client: PostgresClient
    let logger: Logger

    func balanceSnapshots() async throws -> [BalanceSnapshot] {
        var out: [BalanceSnapshot] = []
        let rows = try await client.query("SELECT account_id, day, minor, currency FROM budget_balances", logger: logger)
        for try await (account, day, minor, currency) in rows.decode((String, String, Int64, String).self) {
            out.append(BalanceSnapshot(accountID: account, day: day, balance: Money(minorUnits: minor, currencyCode: currency)))
        }
        return out
    }

    func saveBalanceSnapshots(_ snapshots: [BalanceSnapshot]) async throws {
        guard !snapshots.isEmpty else { return }
        try await client.withConnection { connection in
            try await connection.query("BEGIN", logger: logger)
            do {
                for s in snapshots {
                    try await connection.query("""
                        INSERT INTO budget_balances (account_id, day, minor, currency, updated_at)
                        VALUES (\(s.accountID), \(s.day), \(s.balance.minorUnits), \(s.balance.currencyCode), now())
                        ON CONFLICT (account_id, day) DO UPDATE SET minor = EXCLUDED.minor, currency = EXCLUDED.currency, updated_at = now()
                        """, logger: logger)
                }
                try await connection.query("COMMIT", logger: logger)
            } catch {
                _ = try? await connection.query("ROLLBACK", logger: logger)
                throw error
            }
        }
    }

    func clearBalanceSnapshots() async throws {
        try await client.query("DELETE FROM budget_balances", logger: logger)
    }
}

extension BudgetServerApp {
    /// Where the ledger's daily balances go: beside the ledger in Postgres, or in memory with no database.
    static func balanceHistory(for store: any ServerStore, logger: Logger) -> any BalanceHistoryStore {
        if let postgres = store as? PostgresStore { return PostgresBalanceHistory(client: postgres.client, logger: logger) }
        return MemoryBalanceHistory()
    }
}
