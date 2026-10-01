import Foundation
import Testing
@testable import BudgetKit

@Suite("SimpleFIN adapter")
struct SimpleFINTests {
    /// Shape from the SimpleFIN v2 protocol's Account Set / Connection / Error examples.
    static let fixture = #"""
    {
      "errlist": [{"code": "con.auth", "msg": "Authentication failed for American Express", "conn_id": "CON-AMEX"}],
      "connections": [
        {"conn_id": "CON-CHASE", "name": "Chase", "org_id": "ORG-1", "org_url": "https://chase.com", "sfin_url": "https://sfin.example"},
        {"conn_id": "CON-AMEX", "name": "American Express", "org_id": "ORG-2", "sfin_url": "https://sfin.example"}
      ],
      "accounts": [
        {
          "id": "ACT-1", "name": "Total Checking", "conn_id": "CON-CHASE", "currency": "USD",
          "balance": "6200.45", "available-balance": "6150.00", "balance-date": 1790000000,
          "transactions": [
            {"id": "t1", "posted": 1789900000, "amount": "-23.50", "description": "SQ *CASA TACO 0423"},
            {"id": "t2", "posted": 0, "transacted_at": 1789990000, "amount": "-5.25", "description": "BLUE BOTTLE", "pending": true},
            {"id": "t3", "posted": 1789800000, "amount": "3850.00", "description": "ACME CORP PAYROLL PPD"}
          ],
          "extra": {"account-open-date": 978360153}
        },
        {
          "id": "ACT-2", "name": "Gold Card", "conn_id": "CON-AMEX", "currency": "USD",
          "balance": "-1741.62", "balance-date": 1790000000
        },
        {
          "id": "ACT-3", "name": "Airline Miles", "conn_id": "CON-AMEX", "currency": "https://points.example/miles",
          "balance": "42000", "balance-date": 1790000000
        }
      ]
    }
    """#

    @Test("Parses v2 accounts, connections, pending rows and errlist")
    func parse() throws {
        let data = Data(Self.fixture.utf8)
        let snapshot = try SimpleFINSource.parse(data)
        #expect(snapshot.warnings == ["Authentication failed for American Express"])
        #expect(SimpleFINSource.connectionsNeedingAuth(data) == ["CON-AMEX"])
        let checking = try #require(snapshot.accounts.first)
        #expect(checking.institution == "Chase")
        #expect(checking.institutionDomain == "https://chase.com")
        #expect(checking.kind == .checking)
        #expect(checking.balance == Money(6200.45))
        #expect(checking.availableBalance == Money(6150))
        #expect(checking.transactions.map(\.amount) == [Money(-23.5), Money(-5.25), Money(3850)])
        let pending = checking.transactions[1]
        #expect(pending.isPending)
        #expect(pending.posted == Date(timeIntervalSince1970: 1_789_990_000))
        let card = snapshot.accounts[1]
        #expect(card.institution == "American Express")
        #expect(card.kind == .credit)
        #expect(card.transactions.isEmpty)
        #expect(snapshot.accounts[2].balance.currencyCode == "XXX") // custom currency, not money
    }

    @Test("v1 responses with an org object still parse")
    func v1() throws {
        let v1 = #"{"errors": ["Heads up"], "accounts": [{"org": {"domain": "schwab.com", "name": "Charles Schwab"}, "id": "A", "name": "Individual Brokerage", "currency": "USD", "balance": "48210.10", "balance-date": 1790000000}]}"#
        let snapshot = try SimpleFINSource.parse(Data(v1.utf8))
        #expect(snapshot.warnings == ["Heads up"])
        #expect(snapshot.accounts.first?.institution == "Charles Schwab")
        #expect(snapshot.accounts.first?.kind == .investment)
    }

    @Test("Setup token decodes to an https claim URL; junk is rejected")
    func setupToken() throws {
        let token = Data("https://bridge.simplefin.org/simplefin/claim/DEMO123".utf8).base64EncodedString()
        #expect(try SimpleFINSource.claimURL(fromSetupToken: token).absoluteString == "https://bridge.simplefin.org/simplefin/claim/DEMO123")
        #expect(throws: SimpleFINSource.SetupError.invalidToken) { try SimpleFINSource.claimURL(fromSetupToken: "not-a-token!") }
        let http = Data("http://insecure.example/claim".utf8).base64EncodedString()
        #expect(throws: SimpleFINSource.SetupError.invalidToken) { try SimpleFINSource.claimURL(fromSetupToken: http) }
    }

    @Test("Accounts request moves credentials from the URL into Basic auth")
    func request() {
        let source = SimpleFINSource(accessURL: URL(string: "https://user:secret@bridge.simplefin.org/simplefin")!)
        let request = source.accountsRequest(since: Date(timeIntervalSince1970: 1_780_000_000), includePending: true)
        #expect(request.url?.absoluteString == "https://bridge.simplefin.org/simplefin/accounts?start-date=1780000000&pending=1&version=2")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("user:secret".utf8).base64EncodedString())
    }

    @Test("Account kinds are inferred from names", arguments: [
        ("Total Checking", AccountKind.checking), ("Meadow Cash Account", .savings), ("Amex Gold Card", .credit),
        ("Individual Brokerage", .investment), ("Roth IRA", .investment), ("Automated Investing", .investment),
    ])
    func inference(name: String, kind: AccountKind) {
        #expect(AccountKind.infer(fromName: name) == kind)
    }
}

@Suite("Cross-source deduplication")
struct DedupTests {
    let day: TimeInterval = 86_400
    let base = Date(timeIntervalSince1970: 1_789_900_000)

    func key(_ account: String, _ offsetDays: Double, _ amount: Decimal, _ text: String) -> Deduplicator.Key {
        Deduplicator.Key(account: account, date: base.addingTimeInterval(offsetDays * day), amount: Money(amount), description: text)
    }

    @Test("Same purchase from two providers, different descriptors, a day apart")
    func duplicate() {
        #expect(Deduplicator.isDuplicate(key("amex", 0, -23.50, "SQ *CASA TACO 0423"), key("amex", 1, -23.50, "Casa Taco")))
        #expect(Deduplicator.isDuplicate(key("chase", 0, -79.99, "COMCAST XFINITY"), key("chase", 2, -79.99, "Comcast Xfinity Internet")))
    }

    @Test("Different amount, account, merchant or a far date are not duplicates")
    func distinct() {
        let a = key("amex", 0, -23.50, "Casa Taco")
        #expect(!Deduplicator.isDuplicate(a, key("amex", 0, -23.51, "Casa Taco")))
        #expect(!Deduplicator.isDuplicate(a, key("chase", 0, -23.50, "Casa Taco")))
        #expect(!Deduplicator.isDuplicate(a, key("amex", 0, -23.50, "Blue Bottle Coffee")))
        #expect(!Deduplicator.isDuplicate(a, key("amex", 5, -23.50, "Casa Taco")))
    }

    @Test("unique() drops incoming rows already in the ledger and repeats within the batch")
    func unique() {
        let existing = [key("amex", 0, -23.50, "Casa Taco")]
        let incoming = [key("amex", 1, -23.50, "SQ *CASA TACO"), key("amex", 1, -12, "Hearth"), key("amex", 1, -12, "HEARTH BAKERY")]
        let kept = Deduplicator.unique(incoming, against: existing) { $0 }
        #expect(kept.map(\.description) == ["Hearth"])
    }
}
