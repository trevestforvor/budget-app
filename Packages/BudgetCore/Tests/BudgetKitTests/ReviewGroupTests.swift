import Foundation
import Testing
@testable import BudgetKit

/// Review decisions (groups of rows one answer files) and the demo's Activity examples that exercise them.
@Suite("Review groups")
struct ReviewGroupTests {
    private func item(_ id: String, account: String, raw: String, amount: Decimal, merchant: String? = nil, guess: String = "transfer") -> ReviewItem {
        let row = LedgerTransaction(id: id, accountID: account, postedAt: Fixture.now, merchant: merchant ?? raw, rawDescription: raw,
                                    amount: Money(amount), categorization: Categorization(categoryID: guess, confidence: 0.4, tier: .model, needsReview: true),
                                    isPending: false, source: .plaid)
        return ReviewItem(transaction: row, suggestions: [], reason: "Low confidence.")
    }

    @Test("A group is one account, one descriptor, one direction; the biggest decision (rows, then money) comes first")
    func grouping() {
        let items = [
            item("a", account: "chk", raw: "SQ *CASA TACO 0423", amount: -23.5, merchant: "Casa Taco", guess: "dining"),
            item("b", account: "sav", raw: "Withdrawal", amount: -1200),
            item("c", account: "chk", raw: "Withdrawal", amount: -80),         // another account: its own decision
            item("d", account: "sav", raw: "Withdrawal", amount: 300),         // money in: its own decision
            item("e", account: "sav", raw: "WITHDRAWAL", amount: -450),        // same descriptor as memory reads it
            item("f", account: "chk", raw: "SQ *CASA TACO 0611", amount: -18, merchant: "Casa Taco", guess: "dining"),
        ]
        let groups = ReviewGroup.groups(items)
        #expect(groups.map(\.transactionIDs) == [["b", "e"], ["a", "f"], ["d"], ["c"]])
        let withdrawals = groups[0]
        #expect(withdrawals.isGeneric && !groups[1].isGeneric)
        #expect(withdrawals.total == Money(-1650))
        #expect(withdrawals.bestGuess == "transfer")
        #expect(withdrawals.scopedRule == RuleMatch(descriptorContains: "Withdrawal", direction: .moneyOut, accountID: "sav"))
        // A merchant's rule reads the descriptor as memory does, so next month's code is caught too.
        #expect(groups[1].scopedRule == RuleMatch(descriptorContains: "CASA TACO", direction: .moneyOut))
        #expect(groups[2].scopedRule.direction == .moneyIn)
        #expect(Set(groups.map(\.id)).count == groups.count)
    }

    @Test("The demo has a withdrawal group, a hidden row with a note, rows the model filed under one name, and account digits")
    func demoExamples() throws {
        let ledger = Fixture.ledger()
        let groups = ReviewGroup.groups(ledger.reviewItems)
        #expect(ledger.reviewItems.count == 11 && groups.count == 8)
        let withdrawals = try #require(groups.first)
        #expect(withdrawals.count == 4 && withdrawals.isGeneric
                && withdrawals.key == ReviewGroup.Key(accountID: "sav", descriptor: "WITHDRAWAL", isOutflow: true, merchant: "WITHDRAWAL"))
        #expect(withdrawals.first.reason.contains("doesn't name a merchant"))

        let hidden = ledger.query(TransactionFilter(visibility: .notCounted)).filter(\.isHidden)
        #expect(hidden.count == 1 && hidden[0].note != nil)
        // Five in all: three recent rows (Activity's examples) and the first Olive Grill and Uniqlo rows, the answers
        // merchant memory learned from the model (Settings' examples) — every one under the demo model's name.
        let modelFiled = ledger.query(TransactionFilter(modelFiledOnly: true))
        #expect(modelFiled.count == 5)
        #expect(modelFiled.allSatisfy { $0.categorization?.decidedBy == Ledger.demoDecisionModelLabel })
        #expect(Set(modelFiled.map(\.rawDescription)) == ["BLUEBIRD COFFEE #12", "WALGREENS #4412", "LYFT *RIDE SUN 8PM", "OLIVE GRILL MAIN", "UNIQLO USA"])
        // One set of digits per account, none shared.
        #expect(ledger.accounts.allSatisfy { $0.mask?.count == 4 })
        #expect(Set(ledger.accounts.compactMap(\.mask)).count == ledger.accounts.count)
    }

    @Test("Filing a group files exactly its rows, and the scoped rule reaches only that account's withdrawals")
    func fileGroupWithRule() throws {
        var ledger = Fixture.ledger()
        let withdrawals = try #require(ReviewGroup.groups(ledger.reviewItems).first)
        let preview = try ledger.preview(.createBudgetRule(CreateBudgetRule(match: withdrawals.scopedRule, categoryID: "transfer", applyToExisting: false)))
        #expect(preview.matchCount == 4)

        let result = try ledger.perform(.editTransactions(EditTransactions(transactionIDs: withdrawals.transactionIDs, categoryID: "transfer")))
        #expect(result.affectedTransactions == 4 && result.undo != nil)
        #expect(ReviewGroup.groups(ledger.reviewItems).count == 7)
        #expect(!ledger.reviewItems.contains { withdrawals.contains($0.id) })
    }
}
