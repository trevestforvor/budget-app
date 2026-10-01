import Foundation
import Testing
@testable import BudgetKit

/// Where income lives: pay lands in a cash account, card payments leave it. Those payments are
/// transfers, never negative income — the bug a description-less Meadow export exposed.
@Suite("Income and transfers")
struct IncomeTransferTests {
    static func api(_ decisions: DecisionRouting = DecisionRouting(), extra: [LedgerTransaction] = []) -> LedgerBudgetAPI {
        var state = LedgerState.empty
        state.decisionPolicy = DecisionPolicy(provider: .localDecide, autoAcceptPercent: 80, kinds: [.category])
        state.accounts = [
            Account(id: "cash", name: "Individual Cash Account", institution: "Meadow", kind: .checking, balance: Money(12345), source: .plaid, mask: "1111"),
            Account(id: "freedom", name: "Freedom Unlimited", institution: "Harbor", kind: .credit, balance: Money(-90), source: .plaid, mask: "0909"),
            Account(id: "gold", name: "Gold Card", institution: "Summit Card", kind: .credit, balance: Money(-24), source: .plaid, mask: "22222"),
        ]
        state.transactions = extra
        return LedgerBudgetAPI(state: state, calendar: Fixture.calendar, clock: { EngineFixture.now }, chatModel: nil, decisions: decisions,
                               persistence: nil, deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
    }

    static func row(_ id: String, _ account: String, _ day: Int, _ amount: Decimal, _ raw: String, category: String? = nil) -> LedgerTransaction {
        LedgerTransaction(id: id, accountID: account, postedAt: FileImport.day(2026, 8, day)!, merchant: raw.capitalized, rawDescription: raw,
                          amount: Money(amount), categorization: category.map { Categorization(categoryID: $0, confidence: 0.99, tier: .decisionModel, needsReview: false) },
                          isPending: false, source: .plaid, providerCategory: nil)
    }

    /// Meadow's Quicken export: an investment-style statement whose rows have no NAME or MEMO.
    static let qfx = """
    OFXHEADER:100
    <OFX><INVSTMTMSGSRSV1><INVSTMTTRNRS><INVSTMTRS><CURDEF>USD<INVACCTFROM><ACCTID>1X0001111</INVACCTFROM>
    <INVTRANLIST>
    <INVBANKTRAN><STMTTRN><TRNTYPE>CREDIT<DTPOSTED>20260815<TRNAMT>5000.00<FITID>a1</STMTTRN><SUBACCTFUND>CASH</INVBANKTRAN>
    <INVBANKTRAN><STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260818<TRNAMT>-1250.00<FITID>a2</STMTTRN><SUBACCTFUND>CASH</INVBANKTRAN>
    <INVBANKTRAN><STMTTRN><TRNTYPE>INT<DTPOSTED>20260831<TRNAMT>12.30<FITID>a3</STMTTRN><SUBACCTFUND>CASH</INVBANKTRAN>
    <INVBANKTRAN><STMTTRN><TRNTYPE>XFER<DTPOSTED>20260820<TRNAMT>-2000.00<FITID>a4</STMTTRN><SUBACCTFUND>CASH</INVBANKTRAN>
    <INVBANKTRAN><STMTTRN><TRNTYPE>DEBIT<DTPOSTED>20260822<TRNAMT>-45.00<FITID>a5</STMTTRN><SUBACCTFUND>CASH</INVBANKTRAN>
    </INVTRANLIST></INVSTMTRS></INVSTMTTRNRS></INVSTMTMSGSRSV1></OFX>
    """

    @Test("A description-less QFX gets names from its types; interest and transfers are settled by the statement")
    func typedRows() throws {
        let rows = try FileImport.parse(Self.qfx).accounts[0].transactions
        #expect(rows.map(\.description) == ["Deposit", "Withdrawal", "Interest", "Transfer", "Withdrawal"])
        #expect(rows[2].providerCategory == "INCOME_INTEREST_EARNED" && rows[3].providerCategory == "TRANSFER_OUT")
    }

    @Test("A withdrawal that pays a card is a transfer on both sides; a same-amount card refund isn't a payment")
    func pairsCardPayments() async throws {
        let api = Self.api(extra: [
            Self.row("harbor-pay", "freedom", 19, 1250, "AUTOMATIC PAYMENT - THANK", category: "income"), // mis-filed earlier
            Self.row("gold-refund", "gold", 23, 45, "SWEETGREEN NOMAD", category: "dining"),              // a refund, same amount as a withdrawal
        ])
        let report = try await api.ingest(try FileImport.parse(Self.qfx), batchID: "qfx", into: "cash")
        #expect(report.rowsAdded == 5)
        let rows = Dictionary(uniqueKeysWithValues: try await api.transactions(TransactionFilter(limit: 50)).map { ($0.rawDescription + "|\($0.amount.minorUnits)", $0) })
        #expect(rows["Withdrawal|-125000"]?.categorization?.categoryID == "transfer")
        #expect(rows["Withdrawal|-125000"]?.categorization?.decidedBy?.hasPrefix("Matched transfer") == true)
        #expect(rows["AUTOMATIC PAYMENT - THANK|125000"]?.categorization?.categoryID == "transfer") // the card side is corrected too
        #expect(rows["Interest|1230"]?.categorization?.categoryID == "income")
        #expect(rows["Transfer|-200000"]?.categorization?.categoryID == "transfer")
        #expect(rows["SWEETGREEN NOMAD|4500"]?.categorization?.categoryID == "dining")          // untouched
        #expect(rows["Withdrawal|-4500"]?.categorization?.categoryID != "transfer")
    }

    @Test("Money going out is never income, even when the model says so; money in and out are asked separately")
    func incomeOnlyComesIn() async throws {
        let model = StubDecisions(["DEPOSIT": ("income", 0.97), "WITHDRAWAL": ("income", 0.97)])
        let api = Self.api(DecisionRouting(local: model))
        _ = try await api.ingest(try FileImport.parse(Self.qfx), batchID: "qfx", into: "cash")
        let rows = try await api.transactions(TransactionFilter(limit: 50))
        let deposit = try #require(rows.first { $0.rawDescription == "Deposit" })
        #expect(deposit.categorization?.categoryID == "income" && deposit.categorization?.needsReview == false)
        for withdrawal in rows where withdrawal.rawDescription == "Withdrawal" {
            #expect(withdrawal.categorization?.categoryID != "income")
            #expect(withdrawal.categorization?.needsReview == true)
        }
        let review = try await api.reviewQueue()
        #expect(review.first { $0.transaction.rawDescription == "Withdrawal" }?.suggestions.first?.categoryID == "transfer")
        #expect(await model.calls == 2) // "Deposit" in and "Withdrawal" out; interest and the transfer needed no model
    }

    @Test("Generic descriptions teach merchant memory nothing")
    func noMemoryFromGenericRows() async throws {
        let api = Self.api(extra: [Self.row("old", "cash", 1, -300, "Withdrawal", category: "housing")])
        let memory = await api.state.transactions.isEmpty ? [:] : Ledger(state: await api.state, now: EngineFixture.now, calendar: Fixture.calendar).merchantMemory(excluding: [])
        #expect(memory["WITHDRAWAL"] == nil)
    }
}
