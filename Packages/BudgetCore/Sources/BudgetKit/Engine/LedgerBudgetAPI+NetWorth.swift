import Foundation

/// Net worth history: balances recorded at each sync, kept in their own store, read with the ledger.
extension LedgerBudgetAPI: NetWorthAPI {
    /// Where daily balances are kept: the server's Postgres table. The default keeps them in memory.
    public func useBalanceHistory(_ store: any BalanceHistoryStore) {
        balanceHistory = store
    }

    /// Every balance recorded so far, in no particular order.
    public func recordedBalances() async throws -> [BalanceSnapshot] { try await balanceHistory.balanceSnapshots() }

    /// The hand-kept assets and debts, in the order they were added (`GET /v1/assets`).
    public func manualAssets() -> [ManualAsset] { ledger.manualAssets }

    public func netWorth(range: NetWorthRange) async throws -> NetWorth {
        tick(); await pause(0.5)
        let snapshots = try await balanceHistory.balanceSnapshots()
        return ledger.netWorth(range: range, snapshots: snapshots)
    }

    /// Records today's balance of each account a provider's sync just reported. A statement file's balance is the
    /// statement's, not today's, so imported files record nothing; their history comes from their rows. Best effort: a
    /// history that can't be written never fails the sync.
    func recordBalances(from snapshot: SourceSnapshot, into targetAccountID: String?) async {
        guard snapshot.source != .fileImport, targetAccountID == nil, !snapshot.accounts.isEmpty else { return }
        let ids = snapshot.accounts.map { Ledger.accountID(snapshot.source, $0.externalID) }
        let today = ledger.balanceSnapshots(for: ids)
        guard !today.isEmpty else { return }
        try? await balanceHistory.saveBalanceSnapshots(today)
    }

    /// Clears the recorded balances (an admin reset), and with `seedDemo` records the demo's.
    public func resetBalanceHistory(seedDemo: Bool) async throws {
        tick()
        try await balanceHistory.clearBalanceSnapshots()
        if seedDemo { try await balanceHistory.saveBalanceSnapshots(ledger.demoBalanceSnapshots()) }
    }
}
