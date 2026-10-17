import Foundation
import Testing
@testable import BudgetKit

@Suite("Holdings as read")
struct HoldingsReadTests {
    static func api(_ state: LedgerState) -> LedgerBudgetAPI {
        LedgerBudgetAPI(state: state, calendar: Fixture.calendar, clock: { EngineFixture.now }, chatModel: nil,
                        decisions: DecisionRouting(), persistence: nil,
                        deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
    }

    @Test("What the broker didn't itemize follows today's balance, not the balance at the check")
    func unitemizedFollowsTheBalance() async throws {
        let api = Self.api(HoldingsFixture.state())
        try await api.applyHoldings(["inv": [HoldingsFixture.position("VTI", 6_000)]], source: .plaid, at: EngineFixture.now)
        #expect(try await api.holdings().accounts.first { $0.id == "plaid:inv" }?.unitemized == Money(2_000))

        // A sync moves the balance before the next holdings check.
        var state = await api.state
        state.accounts = state.accounts.map { account in
            var account = account
            if account.id == "plaid:inv" { account.balance = Money(8_500) }
            return account
        }
        let synced = Self.api(state)
        let brokerage = try #require(try await synced.holdings().accounts.first { $0.id == "plaid:inv" })
        #expect(brokerage.unitemized == Money(2_500) && brokerage.total + Money(2_500) == Money(8_500))
        // Down to the positions' worth: nothing left to explain.
        state.accounts = state.accounts.map { account in
            var account = account
            if account.id == "plaid:inv" { account.balance = Money(6_000) }
            return account
        }
        #expect(try await Self.api(state).holdings().accounts.first { $0.id == "plaid:inv" }?.unitemized == nil)
    }

    @Test("A foreign currency held as cash has its close priced in dollars (INV-007)")
    func foreignCashCloseInDollars() throws {
        let json = #"""
        {"accounts": [{"account_id": "inv", "type": "investment"}],
         "holdings": [{"account_id": "inv", "security_id": "sec-eur", "quantity": 100, "institution_value": 100, "iso_currency_code": "EUR"},
                      {"account_id": "inv", "security_id": "sec-sap", "quantity": 1, "institution_value": 180, "iso_currency_code": "EUR"}],
         "securities": [{"security_id": "sec-eur", "name": "Euro", "type": "cash", "is_cash_equivalent": true,
                         "close_price": 1.08, "close_price_as_of": "2026-10-15", "iso_currency_code": "EUR"},
                        {"security_id": "sec-sap", "name": "SAP SE", "ticker_symbol": "SAP", "type": "equity",
                         "close_price": 180, "close_price_as_of": "2026-10-15", "iso_currency_code": "EUR"}]}
        """#
        let inv = try #require(try PlaidSource.parseHoldings(try JSONValue.parse(Data(json.utf8))).holdings["inv"])
        let euro = try #require(inv.first { $0.description == "Euro" })
        #expect(euro.price == Money(1.08, currencyCode: "USD") && euro.marketValue.currencyCode == "EUR")
        // A stock in another currency keeps its own.
        #expect(inv.first { $0.symbol == "SAP" }?.price?.currencyCode == "EUR")
    }

    @Test("A holding's id follows its ticker, so Plaid rotating the security id doesn't change it (INV-008)")
    func holdingIDSurvivesSecurityRotation() {
        let before = Ledger.accountHoldings(HoldingsFixture.brokerage, [HoldingsFixture.position("VTI", 100, security: "sec-old")], at: EngineFixture.now)
        let after = Ledger.accountHoldings(HoldingsFixture.brokerage, [HoldingsFixture.position("VTI", 100, security: "sec-new")], at: EngineFixture.now)
        #expect(before.holdings.map(\.id) == after.holdings.map(\.id))
    }
}
