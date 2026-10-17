import Foundation
import Testing
@testable import BudgetKit

/// P0.6: the one-time upgrade that takes account numbers out of statement ids, over a ledger shaped the way 0.5.x left it.
@Suite("Statement id migration")
struct IDMigrationTests {
    static let number = "9876543210123"
    static let legacyAccount = "fileImport:\(number)"
    static func legacyRow(_ fitid: String) -> String { "fileImport:\(legacyAccount):ofx-\(number)-\(fitid)" }
    static func unscopedRow(_ fitid: String) -> String { "fileImport:ofx-\(number)-\(fitid)" }
    static let days = [1, 3, 5, 8, 12, 15]
    static let amounts: [Decimal] = [-12.50, -48.10, 2100, -9.99, -250, -31.40]

    static func row(_ id: String, _ account: String, day: Int, _ amount: Decimal, _ raw: String) -> LedgerTransaction {
        LedgerTransaction(id: id, accountID: account, postedAt: FileImport.day(2026, 9, day)!, merchant: raw.capitalized, rawDescription: raw,
                          amount: Money(amount), categorization: Categorization(categoryID: "dining", confidence: 0.9, tier: .decisionModel, needsReview: false),
                          isPending: false, source: .fileImport, batchID: "file-legacy", providerCategory: nil)
    }

    /// The demo ledger plus what an untargeted 0.5.x OFX import left: an account named after the number, its rows scoped
    /// to it, two older unscoped rows filed into checking, a transfer pair, a rule, a suggestion and a review reason, a
    /// card bill, holdings, a possible duplicate, a pending miss and a merge-log copy, all keyed by the number.
    static func legacy() -> LedgerState {
        var state = LedgerBudgetAPI.demoState(now: Fixture.now, calendar: Fixture.calendar)
        state.accounts.append(Account(id: legacyAccount, name: "Account ••0123", institution: "Meadow", kind: .checking, balance: Money(1500), source: .fileImport))
        for (i, day) in days.enumerated() {
            state.transactions.append(row(legacyRow("F\(i + 1)"), legacyAccount, day: day, amounts[i], "MEADOW ROW \(i + 1)"))
        }
        state.transactions.append(row(unscopedRow("U1"), Ledger.checkingID, day: 2, -20, "OLD STATEMENT ONE"))
        state.transactions.append(row(unscopedRow("U2"), Ledger.checkingID, day: 4, -35, "OLD STATEMENT TWO"))
        // A transfer between the statement account and a checking row.
        let checking = state.transactions.first { $0.accountID == Ledger.checkingID && $0.source != .fileImport && $0.transferPeerID == nil }!
        let f3 = state.transactions.firstIndex { $0.id == legacyRow("F3") }!
        state.transactions[f3].transferPeerID = checking.id
        state.transactions[state.transactions.firstIndex { $0.id == checking.id }!].transferPeerID = legacyRow("F3")
        state.rules.append(BudgetRule(id: "rule-ofx", match: RuleMatch(merchantContains: "meadow", accountID: legacyAccount), categoryID: "dining"))
        state.suggestions[legacyRow("F2")] = [CategorySuggestion(categoryID: "groceries", confidence: 0.4)]
        state.reviewReasons[legacyRow("F2")] = "Not sure"
        state.cardBills[legacyAccount] = CardBill(accountID: legacyAccount, statementBalance: Money(100), updatedAt: Fixture.now)
        state.holdings[legacyAccount] = AccountHoldings(id: legacyAccount, holdings: [], total: .zero, fetchedAt: Fixture.now)
        state.possibleDuplicates[legacyRow("F4")] = [legacyRow("F5")]
        state.pendingMisses[legacyRow("F6")] = Fixture.now
        state.mergeLog.append(RowMergeRecord(id: "merge-1", kind: .skippedIncoming, at: Fixture.now, keptID: legacyRow("F6"), droppedID: legacyRow("D1"),
                                             dropped: row(legacyRow("D1"), legacyAccount, day: 15, -31.40, "MEADOW ROW 6")))
        // Balances that agree with the rows, as ingest leaves them.
        var ledger = Ledger(state: state, now: Fixture.now, calendar: Fixture.calendar)
        ledger.reanchor(legacyAccount)
        ledger.reanchor(Ledger.checkingID)
        return ledger.state
    }

    static func ledger(_ state: LedgerState = legacy()) -> Ledger { Ledger(state: state, now: Fixture.now, calendar: Fixture.calendar) }

    static func encoded(_ state: LedgerState) throws -> String { String(decoding: try JSONEncoder().encode(state), as: UTF8.self) }

    @Test("The audit counts the account, every OFX row and the rule; it needs no key and changes nothing")
    func auditCounts() {
        let ledger = Self.ledger()
        #expect(ledger.statementIDAudit() == StatementIDAudit(accounts: 1, rows: 8, rules: 1))
        #expect(ledger.state == Self.ledger().state)
        #expect(Self.ledger(LedgerBudgetAPI.demoState(now: Fixture.now, calendar: Fixture.calendar)).statementIDAudit().isClean)
    }

    @Test("Migration keeps every row and every balance")
    func keepsRowsAndBalances() {
        let before = Self.ledger()
        var after = before
        let done = after.hashStatementIDs(.test)
        #expect(done.report.accounts == 1 && done.report.rows == 8 && done.report.rules == 1 && done.report.collisions == 0)
        #expect(after.transactions.count == before.transactions.count)
        #expect(after.balances() == before.balances())
        for account in before.accounts {
            let id = done.accountMap[account.id] ?? account.id
            #expect(after.balance(of: id, through: Fixture.now) == before.balance(of: account.id, through: Fixture.now))
        }
        let renamed = try! #require(after.accounts.first { $0.id == done.accountMap[Self.legacyAccount] })
        #expect(renamed.id.hasPrefix("fileImport:stmt-h1-") && renamed.mask == "0123" && renamed.name == "Account ••0123")
        #expect(after.upgrades.contains(Ledger.statementIDsUpgrade))
    }

    @Test("After migration no id, key or reference holds the number")
    func noNumberLeft() throws {
        var ledger = Self.ledger()
        #expect(try Self.encoded(ledger.state).contains("9876543210"))
        let done = ledger.hashStatementIDs(.test)
        #expect(!(try Self.encoded(ledger.state).contains("9876543210")))
        #expect(ledger.statementIDAudit().isClean)
        // Every id-keyed field followed its row or account.
        let account = done.accountMap[Self.legacyAccount]!
        #expect(ledger.cardBills[account]?.accountID == account && ledger.holdings[account]?.id == account)
        let f2 = done.rowMap[Self.legacyRow("F2")]!
        #expect(ledger.suggestions[f2] != nil && ledger.reviewReasons[f2] == "Not sure")
        #expect(ledger.possibleDuplicates[done.rowMap[Self.legacyRow("F4")]!] == [done.rowMap[Self.legacyRow("F5")]!])
        #expect(ledger.pendingMisses[done.rowMap[Self.legacyRow("F6")]!] != nil)
        #expect(ledger.mergeLog.first?.keptID == done.rowMap[Self.legacyRow("F6")] && ledger.mergeLog.first?.dropped.accountID == account)
        #expect(ledger.mergeLog.first?.droppedID == ledger.mergeLog.first?.dropped.id)
        // Unscoped rows moved into the scoped form, on the account they were filed into.
        #expect(done.rowMap[Self.unscopedRow("U1")] == "fileImport:\(Ledger.checkingID):" + StatementIDs.test.rowExternalID(legacy: "ofx-\(Self.number)-U1"))
    }

    @Test("Transfer pairs stay symmetric and the rule still matches its rows")
    func pairsAndRule() {
        var ledger = Self.ledger()
        let done = ledger.hashStatementIDs(.test)
        let f3 = ledger.transactions.first { $0.id == done.rowMap[Self.legacyRow("F3")] }!
        let peer = ledger.transactions.first { $0.id == f3.transferPeerID }
        #expect(peer?.transferPeerID == f3.id)
        let rule = ledger.rules.first { $0.id == "rule-ofx" }!
        #expect(rule.match.accountID == done.accountMap[Self.legacyAccount])
        #expect(ledger.transactions.contains { $0.accountID == rule.match.accountID && $0.merchant.lowercased().contains("meadow") })
    }

    @Test("Running it twice changes nothing")
    func idempotent() {
        var ledger = Self.ledger()
        _ = ledger.hashStatementIDs(.test)
        let once = ledger.state
        let again = ledger.hashStatementIDs(.test)
        #expect(again.report.isEmpty && again.accountMap.isEmpty && again.rowMap.isEmpty)
        #expect(ledger.state == once)
    }

    /// The legacy rows as an OFX file would carry them today (ACCTID and FITID as 0.5.x read them).
    static func ofx(_ fitids: [(String, Int, Decimal, String)]) -> String {
        let rows = fitids.map { "<STMTTRN><TRNTYPE>DEBIT<DTPOSTED>202609\(String(format: "%02d", $0.1))<TRNAMT>\($0.2)<FITID>\($0.0)<NAME>\($0.3)" }
        return "OFXHEADER:100\n<OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><CURDEF>USD<BANKACCTFROM><ACCTID>\(number)</BANKACCTFROM><BANKTRANLIST>\n"
            + rows.joined(separator: "\n") + "\n</BANKTRANLIST><LEDGERBAL><BALAMT>1500.00</LEDGERBAL></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>"
    }

    @Test("A re-import of the original file after migration adds nothing: the parser and the migration make the same ids")
    func reimportAddsNothing() async throws {
        var ledger = Self.ledger()
        let done = ledger.hashStatementIDs(.test)
        let api = LedgerBudgetAPI(state: ledger.state, calendar: Fixture.calendar, clock: { Fixture.now }, chatModel: nil, decisions: DecisionRouting(),
                                  persistence: nil, deployment: DeploymentInfo(endpoint: "t", version: "t", sources: [.fileImport], institutions: []))
        let statement = Self.ofx(Self.days.indices.map { ("F\($0 + 1)", Self.days[$0], Self.amounts[$0], "MEADOW ROW \($0 + 1)") })
        let report = try await api.ingest(try FileImport.parse(statement, ids: .test), batchID: "again", into: done.accountMap[Self.legacyAccount])
        #expect(report.rowsAdded == 0 && report.rowsUpdated == 0)
        let old = Self.ofx([("U1", 2, -20, "OLD STATEMENT ONE"), ("U2", 4, -35, "OLD STATEMENT TWO")])
        #expect(try await api.ingest(try FileImport.parse(old, ids: .test), batchID: "again-2", into: Ledger.checkingID).rowsAdded == 0)
        #expect(await api.state.transactions.count == ledger.transactions.count)
    }

    @Test("Two legacy rows that map to one id merge, keeping the person's edits")
    func collisionsMerge() throws {
        var state = Self.legacy()
        // The same statement row twice: once from before ids were scoped, once after.
        var unscoped = Self.row(Self.unscopedRow("F7"), Self.legacyAccount, day: 20, -7, "MEADOW ROW 7")
        unscoped.categorization = Categorization(categoryID: "coffee", confidence: 1, tier: .user, needsReview: false)
        unscoped.note = "Team coffee"
        var scoped = Self.row(Self.legacyRow("F7"), Self.legacyAccount, day: 20, -7, "MEADOW ROW 7")
        scoped.tags = ["Work"]
        state.transactions += [scoped, unscoped]
        var ledger = Self.ledger(state)
        let rows = ledger.transactions.count
        let done = ledger.hashStatementIDs(.test)
        #expect(done.report.collisions == 1)
        #expect(ledger.transactions.count == rows - 1)
        let kept = try #require(ledger.transactions.first { $0.id == done.rowMap[Self.legacyRow("F7")] })
        #expect(kept.categorization?.tier == .user && kept.categorization?.categoryID == "coffee")
        #expect(kept.note == "Team coffee" && kept.tags == ["Work"])
        #expect(Set(ledger.transactions.map(\.id)).count == ledger.transactions.count)
    }

    @Test("A legacy account an older server wrote back is migrated again, folding into the account already there")
    func stalePodRevert() throws {
        var ledger = Self.ledger()
        let done = ledger.hashStatementIDs(.test)
        let newID = try #require(done.accountMap[Self.legacyAccount])
        // A 0.5.5 pod saves its whole `accounts` document, with the legacy id and without the new one.
        var reverted = ledger.state
        let legacyAccount = Self.legacy().accounts.first { $0.id == Self.legacyAccount }!
        reverted.accounts.removeAll { $0.id == newID }
        reverted.accounts.append(legacyAccount)
        reverted.openingBalances[Self.legacyAccount] = reverted.openingBalances.removeValue(forKey: newID) // its `openingBalances` too
        var stale = Self.ledger(reverted)
        #expect(stale.upgrades.contains(Ledger.statementIDsUpgrade))
        #expect(stale.statementIDAudit() == StatementIDAudit(accounts: 1, rows: 0, rules: 0))
        _ = stale.hashStatementIDs(.test)
        #expect(stale.statementIDAudit().isClean)
        #expect(stale.accounts.filter { $0.id == newID }.count == 1 && !stale.accounts.contains { $0.id == Self.legacyAccount })
        #expect(stale.balances() == ledger.balances())
        #expect(!(try Self.encoded(stale.state).contains("9876543210")))

        // Both written back: the legacy entry folds into the one already there.
        var both = ledger.state
        both.accounts.append(legacyAccount)
        var twice = Self.ledger(both)
        let merged = twice.hashStatementIDs(.test)
        #expect(merged.report.collisions == 1 && twice.accounts.filter { $0.id == newID }.count == 1)
        #expect(twice.statementIDAudit().isClean)
    }

    @Test("Every ledger field is classified as holding ids or not")
    func fieldCoverage() {
        // Fields holding an account or row id (as a value or a key). `renameIDs` must handle each one.
        let idBearing: Set<String> = ["accounts", "openingBalances", "transactions", "suggestions", "reviewReasons", "rules", "cardBills", "holdings",
                                      "possibleDuplicates", "mergeLog", "pendingMisses"]
        let idFree: Set<String> = ["categories", "monthlyTargets", "decisionPolicy", "merchantTargets", "monthlySavings", "merchantAliases",
                                   "forgottenMerchants", "upgrades", "recurringChoices", "assistantMemories", "manualAssets", "planScenarios",
                                   "recurringReviews"]
        #expect(idBearing.isDisjoint(with: idFree))
        #expect(Set(LedgerState.CodingKeys.allCases.map(\.rawValue)) == idBearing.union(idFree))
    }
}
