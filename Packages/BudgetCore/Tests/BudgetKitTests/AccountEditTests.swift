import Foundation
import Testing
@testable import BudgetKit

/// B3: the person corrects an account's kind (a SimpleFIN guess, say), gives it a nickname and its last digits, and
/// the next sync keeps all three.
@Suite("Account edits")
struct AccountEditTests {
    /// SimpleFIN names a card "Everyday Rewards", which says nothing of a card, so its kind is guessed as checking.
    static func simplefinSnapshot(name: String = "Everyday Rewards", mask: String? = nil) -> SourceSnapshot {
        SourceSnapshot(source: .simplefin, accounts: [
            SourceAccount(externalID: "sf-chk", institution: "Harbor Bank", institutionDomain: nil, name: "Total Checking", kind: .checking,
                          balance: Money(2000), availableBalance: nil, balanceDate: EngineFixture.now, transactions: [], holdings: []),
            SourceAccount(externalID: "sf-card", institution: "Harbor Bank", institutionDomain: nil, name: name, kind: .infer(fromName: name),
                          balance: Money(-500), availableBalance: nil, balanceDate: EngineFixture.now, transactions: [
                              SourceTransaction(externalID: "s1", posted: EngineFixture.day(2), amount: Money(-42), description: "CORNER MARKET"),
                          ], holdings: [], mask: mask),
        ], warnings: [])
    }
    static let cardID = Ledger.accountID(.simplefin, "sf-card")

    static func api(persistence: (any LedgerPersistence)? = nil) -> LedgerBudgetAPI {
        EngineFixture.api(persistence: persistence, decisions: DecisionRouting(local: StubDecisions([:])))
    }

    @Test("A SimpleFIN card named without a keyword becomes a card: its balance moves from cash to cards owed")
    func kindMovesBalance() async throws {
        let api = Self.api()
        _ = try await api.ingest(Self.simplefinSnapshot(), batchID: "sf-1")
        #expect(try await api.overview().accounts.first { $0.id == Self.cardID }?.kind == .checking)
        let before = try #require(try await api.overview().balances)
        #expect(before.cash == Money(1500) && before.cardsOwed == .zero)

        let result = try await api.updateAccount(id: Self.cardID, AccountChange(kind: .credit))
        #expect(result.account.kind == .credit && result.account.kindSetByPerson == true)
        #expect(result.warning == nil)    // owes 500: a card's balance is negative
        let after = try #require(try await api.overview().balances)
        #expect(after.cash == Money(2000))
        #expect(after.cardsOwed == Money(500))
        #expect(after.netWorth == before.netWorth)
    }

    @Test("The next sync keeps the person's kind, nickname and last digits")
    func syncKeepsEdits() async throws {
        let api = Self.api()
        _ = try await api.ingest(Self.simplefinSnapshot(), batchID: "sf-1")
        _ = try await api.updateAccount(id: Self.cardID, AccountChange(kind: .credit, nickname: "  Rewards card ", mask: "4321"))

        _ = try await api.ingest(Self.simplefinSnapshot(name: "EVERYDAY REWARDS", mask: "9999"), batchID: "sf-2")
        var account = try #require(try await api.overview().accounts.first { $0.id == Self.cardID })
        #expect(account.kind == .credit)
        #expect(account.nickname == "Rewards card")       // trimmed
        #expect(account.name == "EVERYDAY REWARDS")       // the bank's name keeps updating underneath
        #expect(account.mask == "4321" && account.maskSetByPerson == true)
        #expect(account.shortLabel == "Rewards card ••4321")

        // Cleared, the digits are the provider's again from the next sync; a cleared nickname gives back the bank's name.
        let cleared = try await api.updateAccount(id: Self.cardID, AccountChange(nickname: "", mask: ""))
        #expect(cleared.account.mask == nil && cleared.account.maskSetByPerson == nil && cleared.account.nickname == nil)
        _ = try await api.ingest(Self.simplefinSnapshot(name: "EVERYDAY REWARDS", mask: "9999"), batchID: "sf-3")
        account = try #require(try await api.overview().accounts.first { $0.id == Self.cardID })
        #expect(account.mask == "9999" && account.shortLabel == "EVERYDAY REWARDS ••9999")
        #expect(account.kind == .credit)
    }

    @Test("A nickname names the account in rule descriptions and the CSV export")
    func nicknameNamesTheAccount() throws {
        var ledger = Setup.ledger(Setup.state([Rows.row("rent", "chk", 3, -1800, "HARBOR PROPERTY MGMT", "rent", tier: .user)]))
        _ = try ledger.updateAccount(id: "chk", AccountChange(nickname: "Bills"))
        #expect(ledger.describe(RuleMatch(merchantContains: "harbor", accountID: "chk")).hasSuffix("Bills ••0909"))
        let csv = ledger.exportCSV(TransactionFilter())
        #expect(csv.contains("Bills ••0909"))
        #expect(!csv.contains("Total Checking"))
        // The subscriptions list and the sync-health line name it the same way (`displayName`).
        #expect(Ledger.fullName(ledger.state.accounts.first { $0.id == "chk" }!) == "Harbor Bills")
    }

    @Test("Making an account a card sends its money-in filed as Income back to review, not the person's own")
    func cardSendsIncomeToReview() throws {
        var state = Setup.state([
            Rows.row("pay", "chk", 2, 1042.89, "AUTOMATIC PAYMENT - THANK", "income", tier: .decisionModel),
            Rows.row("mine", "chk", 3, 20, "VENMO CASHBACK", "income", tier: .user),
            Rows.row("ruled", "chk", 4, 30, "EMPLOYER REIMB", "income", tier: .rule, decidedBy: "rule:rule-1"),
            Rows.row("hidden", "chk", 5, 15, "ODD CREDIT", "income", tier: .decisionModel, hidden: true),
            // Filed on another card after the one-time upgrade ran: this edit leaves it to the person.
            Rows.row("elsewhere", "card", 6, 12, "STATEMENT CREDIT", "income", tier: .merchantMemory),
        ], rules: [Setup.rule("rule-1", descriptor: "EMPLOYER REIMB", "income")])
        state.upgrades = [Ledger.cardIncomeUpgrade]
        var ledger = Setup.ledger(state)
        let untouched = ["mine", "ruled", "hidden", "elsewhere"].map { ledger.row($0) }

        let result = try ledger.updateAccount(id: "chk", AccountChange(kind: .credit))
        #expect(result.sentToReview == 1)
        let pay = try #require(ledger.row("pay")?.categorization)
        #expect(pay.categoryID != BudgetCategory.incomeID && pay.needsReview)
        #expect(ledger.reviewReasons["pay"]?.hasPrefix("It was filed as Income, but money coming in on a credit card isn't pay") == true)
        #expect(["mine", "ruled", "hidden", "elsewhere"].map { ledger.row($0) } == untouched)
        // 5,000 in a checking account made a card: said, never flipped.
        #expect(result.warning?.contains("positive") == true)
        #expect(result.account.balance == Money(5000))

        // Back to checking: nothing more goes to review, and there's nothing to warn about.
        let back = try ledger.updateAccount(id: "chk", AccountChange(kind: .checking))
        #expect(back.sentToReview == 0 && back.warning == nil)
    }

    @Test("A kind change pairs old matched transfers that were card-to-card before")
    func kindChangeRepairsTransfers() throws {
        var state = Setup.state([
            Rows.row("out", "card", 3, -200, "TRANSFER TO REWARDS", "transfer", tier: .model, decidedBy: "Matched transfer · Rewards"),
            Rows.row("in", "card2", 3, 200, "TRANSFER FROM GOLD", "transfer", tier: .model, decidedBy: "Matched transfer · Gold Card"),
        ])
        state.accounts.append(Account(id: "card2", name: "Rewards", institution: "Harbor", kind: .credit, balance: Money(-10), source: .simplefin))
        var ledger = Setup.ledger(state)
        #expect(ledger.row("out")?.transferPeerID == nil)   // card-to-card never pairs

        _ = try ledger.updateAccount(id: "card2", AccountChange(kind: .checking))
        #expect(ledger.row("out")?.transferPeerID == "in" && ledger.row("in")?.transferPeerID == "out")
    }

    @Test("Bad last digits and unknown accounts are refused")
    func refusals() async throws {
        var ledger = Setup.ledger(Setup.state())
        let before = ledger.state
        for mask in ["1", "123456", "12a4", "12 34", "١٢٣٤"] {
            #expect(throws: BudgetAPIError.rejected("Last digits are 2 to 5 numbers, like 0909.")) {
                try ledger.updateAccount(id: "chk", AccountChange(mask: mask))
            }
        }
        #expect(throws: BudgetAPIError.rejected("A nickname can be at most 60 characters.")) {
            try ledger.updateAccount(id: "chk", AccountChange(kind: .savings, nickname: String(repeating: "x", count: 61)))
        }
        #expect(throws: BudgetAPIError.notFound) { try ledger.updateAccount(id: "nope", AccountChange(nickname: "Bills")) }
        #expect(ledger.state == before)    // a refusal changes nothing, the kind in the same change included

        // Five digits (Amex) and two are fine; so is a 60-character nickname.
        #expect(try ledger.updateAccount(id: "card", AccountChange(mask: "31005")).account.mask == "31005")
        #expect(try ledger.updateAccount(id: "card", AccountChange(mask: "05")).account.mask == "05")
        #expect(try ledger.updateAccount(id: "card", AccountChange(nickname: String(repeating: "x", count: 60))).account.nickname?.count == 60)

        // Through the API: a refusal writes nothing, a change writes once.
        let persistence = RecordingPersistence()
        let api = Self.api(persistence: persistence)
        _ = try await api.ingest(Self.simplefinSnapshot(), batchID: "sf-1")
        let saves = await persistence.saves.count
        await #expect(throws: BudgetAPIError.notFound) { try await api.updateAccount(id: "nope", AccountChange(kind: .credit)) }
        await #expect(throws: BudgetAPIError.self) { try await api.updateAccount(id: Self.cardID, AccountChange(mask: "x")) }
        #expect(await persistence.saves.count == saves)
        _ = try await api.updateAccount(id: Self.cardID, AccountChange(nickname: "Rewards card"))
        #expect(await persistence.saves.count == saves + 1)
        #expect(await persistence.saves.last?.new.accounts.first { $0.id == Self.cardID }?.nickname == "Rewards card")
    }

    @Test("Old stored accounts and old apps decode without the new fields, and an empty change means nothing")
    func wireCompat() throws {
        let old = #"{"id":"a","name":"Checking","institution":"Harbor","kind":"checking","balance":{"minor":100,"currency":"USD"},"source":"plaid"}"#
        let account = try RemoteBudgetAPI.decoder.decode(Account.self, from: Data(old.utf8))
        #expect(account.nickname == nil && account.kindSetByPerson == nil && account.maskSetByPerson == nil && account.displayName == "Checking")
        #expect(try RemoteBudgetAPI.decoder.decode(AccountChange.self, from: Data("{}".utf8)) == AccountChange())
        var ledger = Setup.ledger(Setup.state())
        let before = ledger.state
        _ = try ledger.updateAccount(id: "chk", AccountChange())
        #expect(ledger.state == before)
    }
}
