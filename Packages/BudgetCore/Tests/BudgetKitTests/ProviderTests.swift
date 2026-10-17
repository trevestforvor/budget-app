import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BudgetKit

/// Answers by URL path and records what was sent.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: [String]]
    private(set) var requests: [URLRequest] = []

    /// Each path can have several bodies, returned in order (for pagination).
    init(_ routes: [String: [String]]) { self.routes = routes }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = lock.withLock { () -> (Int, String) in
            requests.append(request)
            let path = request.url!.path
            guard var bodies = routes[path], !bodies.isEmpty else { return (404, #"{"error":"not found"}"#) }
            let body = bodies.removeFirst()
            if !bodies.isEmpty { routes[path] = bodies }
            return (200, body)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func body(of path: String) -> JSONValue? {
        lock.withLock { requests.last { $0.url!.path == path }?.httpBody.flatMap { try? JSONValue.parse($0) } }
    }
}

@Suite("Plaid adapter")
struct PlaidTests {
    static let credentials = PlaidSource.Credentials(clientID: "cid", secret: "sec")

    // Shapes from Plaid's /transactions/sync, /accounts/balance/get and /investments/holdings/get examples.
    static let page1 = #"""
    {"added": [
      {"transaction_id": "t1", "account_id": "card", "amount": 28.34, "iso_currency_code": "USD", "date": "2026-09-20",
       "name": "DD *DOORDASH BURGERKING", "merchant_name": "DoorDash", "pending": false,
       "personal_finance_category": {"primary": "FOOD_AND_DRINK", "detailed": "FOOD_AND_DRINK_FAST_FOOD", "confidence_level": "VERY_HIGH"}},
      {"transaction_id": "t2", "account_id": "card", "amount": -500.00, "iso_currency_code": "USD", "date": "2026-09-21",
       "name": "PAYMENT THANK YOU", "pending": false}
     ], "modified": [], "removed": [], "next_cursor": "c1", "has_more": true}
    """#
    static let page2 = #"""
    {"added": [{"transaction_id": "t3", "account_id": "card", "amount": 12.5, "date": "2026-09-24", "name": "BLUE BOTTLE", "pending": true}],
     "modified": [], "removed": [{"transaction_id": "t0", "account_id": "card"}], "next_cursor": "c2", "has_more": false}
    """#
    static let balances = #"""
    {"accounts": [
      {"account_id": "card", "balances": {"available": 18000, "current": 1408.09, "iso_currency_code": "USD", "limit": 20000},
       "mask": "1001", "name": "Gold Card", "subtype": "credit card", "type": "credit"},
      {"account_id": "cash", "balances": {"available": 21000, "current": 21000, "iso_currency_code": "USD"},
       "name": "Cash Account", "subtype": "savings", "type": "depository"},
      {"account_id": "inv", "balances": {"current": 32418.77, "iso_currency_code": "USD"}, "name": "Automated Investing", "subtype": "brokerage", "type": "investment"}
    ]}
    """#
    static let holdings = #"""
    {"accounts": [], "holdings": [{"account_id": "inv", "security_id": "s1", "institution_value": 30000.5, "quantity": 100, "iso_currency_code": "USD"}],
     "securities": [{"security_id": "s1", "ticker_symbol": "VTI", "name": "Vanguard Total Stock Market ETF"}]}
    """#

    @Test("Sync pages until has_more is false; positive-out amounts are flipped")
    func sync() async throws {
        let transport = FakeTransport(["/transactions/sync": [Self.page1, Self.page2]])
        let plaid = PlaidSource(environment: .sandbox, credentials: Self.credentials, accessToken: "access-1", institution: "American Express", transport: transport)
        let result = try await plaid.sync(from: nil)
        #expect(result.nextCursor == "c2")
        #expect(result.removed == ["t0"])
        #expect(result.added.map(\.transaction.amount) == [Money(-28.34), Money(500), Money(-12.5)])
        let doordash = result.added[0].transaction
        #expect(doordash.payee == "DoorDash")
        #expect(doordash.providerCategory == "FOOD_AND_DRINK_FAST_FOOD")
        #expect(result.added[2].transaction.isPending)
        guard case let .object(body)? = transport.body(of: "/transactions/sync") else { Issue.record("no body"); return }
        #expect(body["cursor"] == .string("c1"))
        #expect(body["client_id"] == .string("cid"))
        #expect(body["access_token"] == .string("access-1"))
        #expect(transport.requests.first?.url?.host == "sandbox.plaid.com")
    }

    @Test("Balances: credit shows as owed (negative); holdings come from their own call, not the sync")
    func snapshot() async throws {
        let transport = FakeTransport(["/transactions/sync": [Self.page2], "/accounts/get": [Self.balances], "/investments/holdings/get": [Self.holdings]])
        let plaid = PlaidSource(environment: .production, credentials: Self.credentials, accessToken: "a", institution: "Meadow", transport: transport)
        let snapshot = try await plaid.fetch(since: PlaidSource.day("2026-09-01")!)
        let card = try #require(snapshot.accounts.first { $0.externalID == "card" })
        #expect(card.kind == .credit)
        #expect(card.balance == Money(-1408.09))
        #expect(card.transactions.map(\.externalID) == ["t3"])
        #expect(snapshot.accounts.first { $0.externalID == "cash" }?.kind == .savings)
        let inv = try #require(snapshot.accounts.first { $0.externalID == "inv" })
        #expect(inv.kind == .investment)
        #expect(inv.holdings.isEmpty && transport.requests.allSatisfy { $0.url!.path != "/investments/holdings/get" })
        let holdings = try await plaid.holdings()
        #expect(holdings["inv"]?.first?.symbol == "VTI")
        #expect(holdings["inv"]?.first?.marketValue == Money(30000.5))
    }

    @Test("Chase's generic \"CREDIT CARD\" gives way to the official name; the mask comes through")
    func genericNames() throws {
        let json = #"""
        {"accounts": [
          {"account_id": "a", "balances": {"current": 2377.9}, "mask": "0909", "name": "CREDIT CARD", "official_name": "Freedom Unlimited", "type": "credit"},
          {"account_id": "b", "balances": {"current": 10}, "mask": "2864", "name": "CREDIT CARD", "type": "credit"},
          {"account_id": "c", "balances": {"current": 10}, "name": "Gold Card", "official_name": "American Express Gold Card", "type": "credit"}
        ]}
        """#
        let accounts = try PlaidSource.parseAccounts(try JSONValue.parse(Data(json.utf8)), institution: "Chase")
        #expect(accounts.map(\.name) == ["Freedom Unlimited", "CREDIT CARD", "Gold Card"])
        #expect(accounts.map(\.mask) == ["0909", "2864", nil])
    }

    @Test("Link token and public-token exchange")
    func link() async throws {
        let transport = FakeTransport(["/link/token/create": [#"{"link_token": "link-sandbox-123", "expiration": "2026-09-26T00:00:00Z"}"#],
                                       "/item/public_token/exchange": [#"{"access_token": "access-sandbox-9", "item_id": "item-1"}"#]])
        let token = try await PlaidSource.linkToken(environment: .sandbox, credentials: Self.credentials, userID: "me", investments: true, transport: transport)
        #expect(token == "link-sandbox-123")
        guard case let .object(body)? = transport.body(of: "/link/token/create") else { Issue.record("no body"); return }
        // Consented, billed only once used: liabilities is what card bills read (PlaidLiabilitiesTests).
        #expect(body["additional_consented_products"] == .array([.string("investments"), .string("liabilities")]))
        #expect(body["transactions"] == .object(["days_requested": .number(730)])) // two years, fixed at Item creation
        let exchanged = try await PlaidSource.exchange(publicToken: "public-1", environment: .sandbox, credentials: Self.credentials, transport: transport)
        #expect(exchanged.accessToken == "access-sandbox-9")
        #expect(exchanged.itemID == "item-1")
    }

    @Test("Provider errors surface status and body")
    func errors() async {
        let plaid = PlaidSource(environment: .sandbox, credentials: Self.credentials, accessToken: "a", institution: "x", transport: FakeTransport([:]))
        await #expect(throws: SourceHTTPError.self) { try await plaid.syncPage(cursor: nil) }
    }
}

@Suite("Teller adapter")
struct TellerTests {
    // Shapes from Teller's Accounts, Balances and Transactions docs.
    static let accounts = #"""
    [{"id": "acc_chk", "enrollment_id": "enr_1", "name": "Total Checking", "type": "depository", "subtype": "checking",
      "currency": "USD", "last_four": "4321", "status": "open", "institution": {"id": "chase", "name": "Chase"},
      "links": {"self": "…", "balances": "https://api.teller.io/accounts/acc_chk/balances", "transactions": "https://api.teller.io/accounts/acc_chk/transactions"}},
     {"id": "acc_cc", "enrollment_id": "enr_1", "name": "Sapphire", "type": "credit", "subtype": "credit_card",
      "currency": "USD", "last_four": "9876", "status": "open", "institution": {"id": "chase", "name": "Chase"},
      "links": {"balances": "…", "transactions": "…"}}]
    """#
    static let checkingBalances = #"{"account_id": "acc_chk", "ledger": "18572.63", "available": "18400.00"}"#
    static let cardBalances = #"{"account_id": "acc_cc", "ledger": "612.40", "available": "9387.60"}"#
    static let checkingTransactions = #"""
    [{"id": "txn_1", "account_id": "acc_chk", "amount": "-79.99", "date": "2026-09-18", "description": "COMCAST XFINITY", "status": "posted",
      "type": "ach", "details": {"processing_status": "complete", "category": "utilities", "counterparty": {"name": "COMCAST", "type": "organization"}}},
     {"id": "txn_2", "account_id": "acc_chk", "amount": "3850.00", "date": "2026-09-15", "description": "ACME CORP PAYROLL", "status": "posted",
      "details": {"processing_status": "complete", "category": "income", "counterparty": {"name": null, "type": null}}},
     {"id": "txn_3", "account_id": "acc_chk", "amount": "-6.25", "date": "2026-09-25", "description": "BLUE BOTTLE", "status": "pending",
      "details": {"processing_status": "pending", "category": null, "counterparty": null}}]
    """#

    func source() -> (TellerSource, FakeTransport) {
        let transport = FakeTransport([
            "/accounts": [Self.accounts],
            "/accounts/acc_chk/balances": [Self.checkingBalances],
            "/accounts/acc_cc/balances": [Self.cardBalances],
            "/accounts/acc_chk/transactions": [Self.checkingTransactions],
            "/accounts/acc_cc/transactions": ["[]"],
        ])
        return (TellerSource(accessToken: "test_token_abc", transport: transport), transport)
    }

    @Test("Accounts, balances and signed transactions; token goes in Basic auth")
    func fetch() async throws {
        let (teller, transport) = source()
        let snapshot = try await teller.fetch(since: PlaidSource.day("2026-09-01")!)
        #expect(snapshot.source == .teller)
        let checking = try #require(snapshot.accounts.first)
        #expect(checking.institution == "Chase")
        #expect(checking.name == "Total Checking ••4321")
        #expect(checking.balance == Money(18572.63))
        #expect(checking.availableBalance == Money(18400))
        #expect(checking.transactions.map(\.amount) == [Money(-79.99), Money(3850), Money(-6.25)])
        #expect(checking.transactions[0].payee == "COMCAST")
        #expect(checking.transactions[0].providerCategory == "utilities")
        #expect(checking.transactions[2].isPending)
        let card = snapshot.accounts[1]
        #expect(card.kind == .credit)
        #expect(card.balance == Money(-612.40))
        let auth = transport.requests.first?.value(forHTTPHeaderField: "Authorization")
        #expect(auth == "Basic " + Data("test_token_abc:".utf8).base64EncodedString())
        #expect(transport.requests.contains { $0.url?.query == "start_date=2026-09-01" })
    }

    @Test("Excluding pending rows")
    func noPending() async throws {
        let (teller, _) = source()
        let snapshot = try await teller.fetch(since: PlaidSource.day("2026-09-01")!, includePending: false)
        #expect(snapshot.accounts.first?.transactions.count == 2)
    }
}
