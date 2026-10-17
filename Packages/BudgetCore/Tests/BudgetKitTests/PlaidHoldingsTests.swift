import Foundation
import Testing
@testable import BudgetKit

/// A Plaid `/investments/holdings/get` answer, shaped like the docs' example. Everything is made up.
enum HoldingsJSON {
    static let response = #"""
    {"accounts": [
       {"account_id": "inv", "balances": {"current": 20000, "iso_currency_code": "USD"}, "name": "Brokerage", "type": "investment", "subtype": "brokerage"},
       {"account_id": "ira", "balances": {"current": 0, "iso_currency_code": "USD"}, "name": "IRA", "type": "investment", "subtype": "ira"},
       {"account_id": "chk", "balances": {"current": 900, "iso_currency_code": "USD"}, "name": "Checking", "type": "depository", "subtype": "checking"}
     ],
     "holdings": [
       {"account_id": "inv", "security_id": "sec-vti", "quantity": 12.5, "cost_basis": 1000, "institution_price": 248,
        "institution_price_as_of": "2026-10-14", "institution_value": 3100, "iso_currency_code": "USD", "unofficial_currency_code": null},
       {"account_id": "inv", "security_id": "sec-aapl", "quantity": 10, "cost_basis": null, "institution_price": 220,
        "institution_price_as_of": "2026-10-16", "institution_value": 2200, "iso_currency_code": "USD", "unofficial_currency_code": null},
       {"account_id": "inv", "security_id": "sec-cash", "quantity": 812.4, "cost_basis": 812.4, "institution_price": 1,
        "institution_price_as_of": null, "institution_value": 812.4, "iso_currency_code": "USD", "unofficial_currency_code": null},
       {"account_id": "inv", "security_id": "sec-btc", "quantity": 0.01, "cost_basis": 300, "institution_price": 60000,
        "institution_price_as_of": "2026-10-16", "institution_value": 600, "iso_currency_code": null, "unofficial_currency_code": "BTC"},
       {"account_id": "inv", "security_id": "sec-gone", "quantity": 1, "institution_value": 50, "iso_currency_code": "USD"},
       {"account_id": "inv", "security_id": "sec-vti", "quantity": 1, "institution_price": 248}
     ],
     "securities": [
       {"security_id": "sec-vti", "name": "Vanguard Total Stock Market ETF", "ticker_symbol": "VTI", "type": "etf", "is_cash_equivalent": false,
        "close_price": 250.5, "close_price_as_of": "2026-10-15", "iso_currency_code": "USD"},
       {"security_id": "sec-aapl", "name": "Apple Inc.", "ticker_symbol": "AAPL", "type": "equity", "is_cash_equivalent": false,
        "close_price": 219, "close_price_as_of": "2026-10-15", "iso_currency_code": "USD"},
       {"security_id": "sec-cash", "name": "U S Dollar", "ticker_symbol": null, "type": "cash", "is_cash_equivalent": true,
        "close_price": 1, "close_price_as_of": null, "iso_currency_code": "USD"},
       {"security_id": "sec-btc", "name": "Bitcoin", "ticker_symbol": "BTC", "type": "cryptocurrency", "is_cash_equivalent": false,
        "close_price": null, "iso_currency_code": null, "unofficial_currency_code": "BTC"}
     ],
     "item": {"item_id": "item-1"},
     "request_id": "req-holdings-1"}
    """#

    static func parsed() throws -> (holdings: [String: [SourceHolding]], requestID: String?) {
        try PlaidSource.parseHoldings(try JSONValue.parse(Data(response.utf8)))
    }

    static func holding(_ ticker: String) throws -> SourceHolding {
        try #require(try parsed().holdings["inv"]?.first { $0.symbol == ticker })
    }
}

@Suite("Plaid holdings")
struct PlaidHoldingsTests {
    @Test("Holdings are joined to the securities in the same response; an investment account with none comes back empty")
    func parseHoldingsJoinsSecurities() throws {
        let (holdings, requestID) = try HoldingsJSON.parsed()
        #expect(requestID == "req-holdings-1")
        // The empty IRA is there, so a sold-out account is cleared; checking isn't an investment account.
        #expect(Set(holdings.keys) == ["inv", "ira"] && holdings["ira"] == [])
        let inv = try #require(holdings["inv"])
        // The row with no value is dropped; a security the response doesn't list still keeps its value.
        #expect(inv.count == 5)
        let vti = try HoldingsJSON.holding("VTI")
        #expect(vti.description == "Vanguard Total Stock Market ETF" && vti.securityID == "sec-vti" && vti.type == "etf" && !vti.isCash)
        #expect(vti.marketValue == Money(3100))
        let unlisted = try #require(inv.first { $0.securityID == "sec-gone" })
        #expect(unlisted.description == "Holding" && unlisted.symbol == nil && unlisted.marketValue == Money(50))
    }

    @Test("Price is whichever of the broker's and the last close says it's newer (INV-007)")
    func priceTakesFresherTimestamp() throws {
        let day = { (s: String) in try #require(PlaidSource.day(s)) }
        // The close (Oct 15) is newer than the broker's price (Oct 14).
        let vti = try HoldingsJSON.holding("VTI")
        #expect(vti.price == Money(250.5))
        #expect(vti.priceAsOf == (try day("2026-10-15")))
        // The broker's (Oct 16) is newer than the close.
        let aapl = try HoldingsJSON.holding("AAPL")
        #expect(aapl.price == Money(220))
        #expect(aapl.priceAsOf == (try day("2026-10-16")))
        // Neither dated: the broker's, which matches the value.
        let cash = try #require(try HoldingsJSON.parsed().holdings["inv"]?.first { $0.securityID == "sec-cash" })
        #expect(cash.price == Money(1) && cash.priceAsOf == nil)
        // A broker's date-time counts, and beats a close on the same day.
        let fresher = #"{"holdings": [{"account_id": "a", "security_id": "s", "institution_price": 10, "institution_price_datetime": "2026-10-15T20:00:00Z", "institution_value": 10}], "securities": [{"security_id": "s", "close_price": 9, "close_price_as_of": "2026-10-15"}]}"#
        let one = try #require(try PlaidSource.parseHoldings(try JSONValue.parse(Data(fresher.utf8))).holdings["a"]?.first)
        #expect(one.price == Money(10))
    }

    @Test("Cash shows as cash: a cash-equivalent security, or one of type cash")
    func cashEquivalentFlagged() throws {
        let inv = try #require(try HoldingsJSON.parsed().holdings["inv"])
        #expect(inv.filter(\.isCash).map(\.securityID) == ["sec-cash"])
        let typed = #"{"holdings": [{"account_id": "a", "security_id": "s", "institution_value": 5}], "securities": [{"security_id": "s", "name": "Sweep", "type": "cash"}]}"#
        #expect(try PlaidSource.parseHoldings(try JSONValue.parse(Data(typed.utf8))).holdings["a"]?.first?.isCash == true)
    }

    @Test("Quantity is the decimal Plaid wrote, and cost basis is the whole position's, when the broker knows it")
    func quantityAndCostBasisParsed() throws {
        let vti = try HoldingsJSON.holding("VTI")
        #expect(vti.quantity == Decimal(string: "12.5") && vti.costBasis == Money(1000))
        let aapl = try HoldingsJSON.holding("AAPL")
        #expect(aapl.quantity == 10 && aapl.costBasis == nil)
        let btc = try HoldingsJSON.holding("BTC")
        #expect(btc.quantity == Decimal(string: "0.01"))
    }

    @Test("A position in another currency keeps its code; the ledger sets it aside, so it counts as not itemized")
    func nonUSDKeptForSetAside() throws {
        let btc = try HoldingsJSON.holding("BTC")
        #expect(btc.marketValue.currencyCode == "BTC" && btc.costBasis?.currencyCode == "BTC")
        var ledger = HoldingsFixture.ledger()
        // The brokerage and the empty IRA.
        #expect(ledger.applyHoldings(try HoldingsJSON.parsed().holdings, source: .plaid, at: EngineFixture.now) == 2)
        let stored = try #require(ledger.holdings["plaid:inv"])
        #expect(!stored.holdings.contains { $0.ticker == "BTC" })
        #expect(stored.total == Money(3100 + 2200 + 812.4 + 50))
        #expect(stored.holdings.allSatisfy { $0.value.currencyCode == "USD" })
    }

    @Test("Asking Plaid: the request carries the Item's token, and Plaid's error comes back with its code")
    func fetch() async throws {
        let ok = StatusTransport(["/investments/holdings/get": (200, HoldingsJSON.response)])
        let source = PlaidSource(environment: .sandbox, credentials: .init(clientID: "id", secret: "secret"), accessToken: "access-sandbox-1",
                                 institution: "Northwind", transport: ok)
        let (holdings, requestID) = try await source.holdingsReport()
        #expect(holdings["inv"]?.count == 5 && requestID == "req-holdings-1")
        #expect(ok.body(of: "/investments/holdings/get") == .object(["access_token": .string("access-sandbox-1"), "client_id": .string("id"), "secret": .string("secret")]))

        let refused = StatusTransport(["/investments/holdings/get": (400, #"{"error_type": "ITEM_ERROR", "error_code": "PRODUCT_NOT_READY", "error_message": "not yet", "request_id": "req-nr"}"#)])
        let waiting = PlaidSource(environment: .sandbox, credentials: .init(clientID: "id", secret: "secret"), accessToken: "access-sandbox-1",
                                  institution: "Northwind", transport: refused)
        do {
            _ = try await waiting.holdingsReport()
            Issue.record("expected Plaid's error")
        } catch let error as PlaidAPIError {
            #expect(error.errorCode == "PRODUCT_NOT_READY" && error.requestID == "req-nr")
        }
    }
}

/// The `Rows` accounts plus two Plaid brokerages (one at the same bank as savings) and an account a file brought.
enum HoldingsFixture {
    static let brokerage = Account(id: "plaid:inv", name: "Brokerage", institution: "Northwind", kind: .investment, balance: Money(8000), source: .plaid)
    static let ira = Account(id: "plaid:ira", name: "IRA", institution: "Northwind", kind: .investment, balance: Money(20_000), source: .plaid)
    static let checking = Account(id: "plaid:chk", name: "Checking", institution: "Northwind", kind: .checking, balance: Money(900), source: .plaid)

    static func state() -> LedgerState {
        var state = Rows.state([])
        state.accounts += [brokerage, ira, checking]
        return state
    }

    static func ledger() -> Ledger { Ledger(state: state(), now: EngineFixture.now, calendar: Fixture.calendar) }

    static func position(_ ticker: String, _ value: Decimal, security: String? = nil) -> SourceHolding {
        SourceHolding(symbol: ticker, description: ticker, marketValue: Money(value), securityID: security ?? "sec-\(ticker)")
    }
}

@Suite("Holdings in the ledger")
struct HoldingsLedgerTests {
    @Test("Only accounts the ledger holds as investments take positions")
    func applyHoldingsOnlyToInvestmentAccounts() {
        var ledger = HoldingsFixture.ledger()
        let stored = ledger.applyHoldings(["inv": [HoldingsFixture.position("VTI", 100)], "chk": [HoldingsFixture.position("X", 5)],
                                           "unknown": [HoldingsFixture.position("Y", 5)]], source: .plaid, at: EngineFixture.now)
        #expect(stored == 1)
        #expect(Set(ledger.holdings.keys) == ["plaid:inv"])
        // The same external id from another provider is another account.
        #expect(ledger.applyHoldings(["inv": [HoldingsFixture.position("VTI", 100)]], source: .simplefin, at: EngineFixture.now) == 0)
        // An account the person says isn't an investment takes none.
        ledger.accounts[ledger.accounts.firstIndex { $0.id == "plaid:inv" }!].kind = .savings
        #expect(ledger.applyHoldings(["inv": [HoldingsFixture.position("VTI", 100)]], source: .plaid, at: EngineFixture.now) == 0)
    }

    @Test("Each check replaces an account's positions whole, largest first, and leaves the other accounts alone")
    func holdingsReplacedPerAccount() throws {
        var ledger = HoldingsFixture.ledger()
        ledger.applyHoldings(["inv": [HoldingsFixture.position("A", 100), HoldingsFixture.position("B", 7_000), HoldingsFixture.position("C", 900)],
                              "ira": [HoldingsFixture.position("D", 20_000)]], source: .plaid, at: EngineFixture.now)
        #expect(ledger.holdings["plaid:inv"]?.holdings.map(\.ticker) == ["B", "C", "A"])
        let later = EngineFixture.now.addingTimeInterval(86_400)
        ledger.applyHoldings(["inv": [HoldingsFixture.position("A", 8_000)]], source: .plaid, at: later)
        let inv = try #require(ledger.holdings["plaid:inv"])
        #expect(inv.holdings.map(\.ticker) == ["A"] && inv.total == Money(8_000) && inv.fetchedAt == later)
        #expect(ledger.holdings["plaid:ira"]?.holdings.map(\.ticker) == ["D"])
        // Sold everything: an empty list clears it.
        ledger.applyHoldings(["inv": []], source: .plaid, at: later)
        #expect(ledger.holdings["plaid:inv"]?.holdings == [] && ledger.holdings["plaid:inv"]?.total == .zero)
        // Ids are stable across checks, carry no provider id, and stay apart for two lots of one security.
        let id = Ledger.accountHoldings(HoldingsFixture.brokerage, [HoldingsFixture.position("A", 1)], at: later).holdings[0].id
        #expect(id == Ledger.accountHoldings(HoldingsFixture.brokerage, [HoldingsFixture.position("A", 2)], at: later).holdings[0].id)
        #expect(!id.contains("sec-"))
        let lots = Ledger.accountHoldings(HoldingsFixture.brokerage, [HoldingsFixture.position("A", 1), HoldingsFixture.position("A", 2)], at: later)
        #expect(Set(lots.holdings.map(\.id)).count == 2)
    }

    @Test("Positions add up to the balance within what the broker didn't itemize (C6)")
    func unitemizedWhenTotalBelowBalance() throws {
        var ledger = HoldingsFixture.ledger()
        // Brokerage: balance 8,000; positions 6,500 → 1,500 not itemized, and total + unitemized is the balance.
        ledger.applyHoldings(["inv": [HoldingsFixture.position("A", 6_000), HoldingsFixture.position("B", 500)]], source: .plaid, at: EngineFixture.now)
        let inv = try #require(ledger.holdings["plaid:inv"])
        #expect(inv.unitemized == Money(1_500))
        #expect(inv.total + (inv.unitemized ?? .zero) == HoldingsFixture.brokerage.balance)
        // Within $1, or within 1% of the balance: rounding, not shown.
        #expect(Ledger.unitemized(balance: Money(8_000), total: Money(7_999.50)) == nil)
        #expect(Ledger.unitemized(balance: Money(20_000), total: Money(19_850)) == nil)
        #expect(Ledger.unitemized(balance: Money(50), total: Money(48.50)) == Money(1.50))
        // Positions worth more than the balance (a price newer than it): nothing claimed as unitemized.
        #expect(Ledger.unitemized(balance: Money(8_000), total: Money(8_400)) == nil)
    }

    @Test("A ledger saved before holdings loads with none")
    func oldLedgerDecodesWithoutHoldings() throws {
        let data = try JSONEncoder().encode(HoldingsFixture.state())
        guard case var .object(o) = try JSONValue.parse(data) else { Issue.record("not an object"); return }
        o["holdings"] = nil
        let old = try JSONDecoder().decode(LedgerState.self, from: try JSONEncoder().encode(JSONValue.object(o)))
        #expect(old.holdings.isEmpty && old.accounts.count == HoldingsFixture.state().accounts.count)
        // And a ledger with them keeps them through a save.
        var ledger = HoldingsFixture.ledger()
        ledger.applyHoldings(["inv": [HoldingsFixture.position("A", 6_000)]], source: .plaid, at: EngineFixture.now)
        let saved = try JSONDecoder().decode(LedgerState.self, from: try JSONEncoder().encode(ledger.state))
        #expect(saved.holdings == ledger.state.holdings)
    }

    @Test("The report: investment accounts by total, the oldest check as its date, and a no-longer-investment account left out")
    func report() async throws {
        let api = LedgerBudgetAPI(state: HoldingsFixture.state(), calendar: Fixture.calendar, clock: { EngineFixture.now }, chatModel: nil,
                                  decisions: DecisionRouting(), persistence: nil,
                                  deployment: DeploymentInfo(endpoint: "test", version: "t", sources: [.plaid], institutions: []))
        #expect(try await api.holdings() == .empty)
        #expect(await api.investmentAccountCount(source: .plaid, institution: "Northwind") == 2)
        #expect(await api.investmentAccountCount(source: .plaid, institution: "Harbor") == 0)
        let earlier = EngineFixture.now.addingTimeInterval(-3_600)
        #expect(try await api.applyHoldings(["inv": [HoldingsFixture.position("A", 6_000)]], source: .plaid, at: earlier) == 1)
        #expect(try await api.applyHoldings(["ira": [HoldingsFixture.position("B", 19_000)]], source: .plaid, at: EngineFixture.now) == 1)
        let report = try await api.holdings()
        #expect(report.accounts.map(\.id) == ["plaid:ira", "plaid:inv"] && report.asOf == earlier)
        #expect(await api.state.holdings.count == 2)
    }

    @Test("The demo shows two brokerages: one itemized to the cent, one with cash it doesn't list")
    func demoSeedsHoldings() async throws {
        let api = LedgerBudgetAPI(latency: .zero)
        let report = try await api.holdings()
        #expect(report.accounts.map(\.id) == ["northwind", "meadow-inv"])
        let accounts = try await api.overview().accounts
        for holdings in report.accounts {
            let balance = try #require(accounts.first { $0.id == holdings.id }?.balance)
            #expect(holdings.total + (holdings.unitemized ?? .zero) == balance)
        }
        let northwind = report.accounts[0], meadow = report.accounts[1]
        #expect(northwind.unitemized == nil && northwind.holdings.count == 6 && northwind.holdings.contains { $0.isCash })
        #expect(meadow.unitemized == Money(2_099.17))
        #expect(northwind.holdings.first?.ticker == "VTI" && northwind.holdings.first?.quantity == Decimal(string: "72.5"))
    }
}
