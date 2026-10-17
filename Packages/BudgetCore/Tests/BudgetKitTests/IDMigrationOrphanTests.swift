import Foundation
import Testing
@testable import BudgetKit

/// P0.6, the half-reverted case: an older server writes back a legacy row or rule after the upgrade, without the account
/// it names. The legacy account id still holds the number, so the audit has to find it there.
@Suite("Statement id migration: orphaned legacy ids")
struct IDMigrationOrphanTests {
    typealias T = IDMigrationTests

    @Test("A legacy row and rule written back without their account are found, merged into the upgraded copy, and leave no number")
    func orphanRowAndRule() throws {
        var ledger = T.ledger()
        let done = ledger.hashStatementIDs(.test)
        let migratedCount = ledger.transactions.count
        let newAccount = try #require(done.accountMap[T.legacyAccount])

        // A 0.5.5 pod upserts one changed row under its legacy id and saves its `rules` document, but not `accounts`.
        var reverted = ledger.state
        var stale = T.row(T.legacyRow("F1"), T.legacyAccount, day: T.days[0], T.amounts[0], "MEADOW ROW 1")
        stale.merchant = "Meadow Renamed"
        reverted.transactions.append(stale)
        let rule = try #require(reverted.rules.firstIndex { $0.id == "rule-ofx" })
        reverted.rules[rule].match.accountID = T.legacyAccount
        #expect(!reverted.accounts.contains { $0.id == T.legacyAccount })

        var orphaned = T.ledger(reverted)
        #expect(orphaned.statementIDAudit() == StatementIDAudit(accounts: 1, rows: 1, rules: 1))
        let again = orphaned.hashStatementIDs(.test)
        #expect(again.accountMap[T.legacyAccount] == newAccount)
        #expect(again.rowMap[T.legacyRow("F1")] == done.rowMap[T.legacyRow("F1")])
        #expect(again.report.collisions == 1)
        #expect(orphaned.transactions.count == migratedCount)
        #expect(Set(orphaned.transactions.map(\.id)).count == orphaned.transactions.count)
        #expect(orphaned.rules.first { $0.id == "rule-ofx" }?.match.accountID == newAccount)
        #expect(orphaned.statementIDAudit().isClean)
        #expect(!(try T.encoded(orphaned.state).contains("9876543210")))
        #expect(orphaned.balances() == ledger.balances())
    }

    @Test("Legacy keys written back without their account (opening balance, card bill, holdings) are found and renamed")
    func orphanKeys() throws {
        var ledger = T.ledger()
        let done = ledger.hashStatementIDs(.test)
        let newAccount = try #require(done.accountMap[T.legacyAccount])

        var reverted = ledger.state
        reverted.openingBalances[T.legacyAccount] = reverted.openingBalances.removeValue(forKey: newAccount)
        reverted.cardBills[T.legacyAccount] = CardBill(accountID: T.legacyAccount, statementBalance: Money(100), updatedAt: Fixture.now)
        reverted.cardBills[newAccount] = nil
        reverted.holdings[T.legacyAccount] = AccountHoldings(id: T.legacyAccount, holdings: [], total: .zero, fetchedAt: Fixture.now)
        reverted.holdings[newAccount] = nil

        var orphaned = T.ledger(reverted)
        #expect(orphaned.statementIDAudit() == StatementIDAudit(accounts: 1, rows: 0, rules: 0))
        _ = orphaned.hashStatementIDs(.test)
        #expect(orphaned.statementIDAudit().isClean)
        #expect(orphaned.openingBalances[newAccount] != nil && orphaned.cardBills[newAccount]?.accountID == newAccount)
        #expect(orphaned.holdings[newAccount]?.id == newAccount)
        #expect(!(try T.encoded(orphaned.state).contains("9876543210")))
    }
}
