import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BudgetKit

/// A SimpleFIN Bridge that answers every request with one reply and keeps the URLs it was asked for.
final class FakeBridgeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let status: Int
    private let body: String
    private(set) var urls: [URL] = []

    init(status: Int = 200, body: String = #"{"accounts": []}"#) {
        self.status = status
        self.body = body
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { urls.append(request.url!) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("SimpleFIN: transport, windows and a typed errlist")
struct SimpleFINSourceTests {
    static let access = URL(string: "https://user:secret@bridge.simplefin.org/simplefin")!
    static let start = Date(timeIntervalSince1970: 1_780_000_000)
    static let end = Date(timeIntervalSince1970: 1_787_000_000)

    @Test("A window asks with start-date, an exclusive end-date and one account= per account; only the fresh pull asks for pending")
    func endDateAndAccountParams() async throws {
        let bridge = FakeBridgeTransport()
        let source = SimpleFINSource(accessURL: Self.access, transport: bridge)
        _ = try await source.fetch(SimpleFINWindow(start: Self.start, end: Self.end, accountIDs: ["ACT-1", "ACT-2"], purpose: .repair))
        _ = try await source.fetch(SimpleFINWindow(start: Self.start, purpose: .fresh))
        let repair = try #require(URLComponents(url: bridge.urls[0], resolvingAgainstBaseURL: false))
        let items = repair.queryItems ?? []
        #expect(items.first { $0.name == "start-date" }?.value == "1780000000")
        #expect(items.first { $0.name == "end-date" }?.value == "1787000000")
        #expect(items.filter { $0.name == "account" }.map(\.value) == ["ACT-1", "ACT-2"])
        #expect(!items.contains { $0.name == "pending" })
        #expect(repair.user == nil && repair.password == nil && bridge.urls[0].path == "/simplefin/accounts")
        let fresh = try #require(URLComponents(url: bridge.urls[1], resolvingAgainstBaseURL: false)).queryItems ?? []
        #expect(fresh.contains { $0.name == "pending" && $0.value == "1" } && !fresh.contains { $0.name == "end-date" || $0.name == "account" })
    }

    @Test("403 is revoked: the whole link, a new setup token")
    func status403IsRevoked() async throws {
        let source = SimpleFINSource(accessURL: Self.access, transport: FakeBridgeTransport(status: 403, body: "Forbidden"))
        await #expect(throws: SimpleFINError.revoked) { try await source.fetch(SimpleFINWindow(start: Self.start, purpose: .fresh)) }
        #expect(SimpleFINError.revoked.kind == .revoked && SimpleFINError.revoked.code == "http-403")
    }

    @Test("402 is the provider's side: renew at the Bridge")
    func status402IsProviderSetup() async throws {
        let source = SimpleFINSource(accessURL: Self.access, transport: FakeBridgeTransport(status: 402, body: "Payment required"))
        await #expect(throws: SimpleFINError.paymentRequired) { try await source.fetch(SimpleFINWindow(start: Self.start, purpose: .fresh)) }
        #expect(SimpleFINError.paymentRequired.kind == .providerSetup)
        #expect(SimpleFINError.paymentRequired.errorDescription?.contains("https://beta-bridge.simplefin.org") == true)
        let other = SimpleFINSource(accessURL: Self.access, transport: FakeBridgeTransport(status: 500, body: "<html>oops</html>"))
        await #expect(throws: SimpleFINError.http(500)) { try await other.fetch(SimpleFINWindow(start: Self.start, purpose: .fresh)) }
        #expect(SimpleFINError.http(500).kind == .transient)
    }

    @Test("gen.auth in the errlist is revoked; gen.api is the provider's side")
    func genAuthIsRevoked() throws {
        let auth = try SimpleFINSource.pull(Data(#"{"errlist": [{"code": "gen.auth", "msg": "Access revoked"}], "accounts": []}"#.utf8),
                                            window: SimpleFINWindow(start: Self.start, purpose: .fresh), requestedAt: Self.end)
        #expect(auth.linkProblem?.kind == .revoked)
        let api = try SimpleFINSource.pull(Data(#"{"errlist": [{"code": "gen.api", "msg": "Internal"}], "accounts": []}"#.utf8),
                                           window: SimpleFINWindow(start: Self.start, purpose: .fresh), requestedAt: Self.end)
        #expect(api.linkProblem?.kind == .providerSetup)
    }

    @Test("con.auth marks every account of that connection, and only those")
    func conAuthMarksOnlyThatConnection() throws {
        let pull = try SimpleFINSource.pull(Data(SimpleFINTests.fixture.utf8), window: SimpleFINWindow(start: Self.start, purpose: .fresh),
                                            requestedAt: Self.end)
        #expect(pull.snapshot.accountProblems == ["ACT-2": .needsSignIn(code: "con.auth"), "ACT-3": .needsSignIn(code: "con.auth")])
        #expect(pull.problems.map(\.kind) == [.needsSignIn])
        #expect(pull.snapshot.connections.map(\.id) == ["CON-CHASE", "CON-AMEX"])
        #expect(pull.snapshot.accounts.map(\.connectionID) == ["CON-CHASE", "CON-AMEX", "CON-AMEX"])
        #expect(pull.snapshot.accounts.allSatisfy { $0.coveredFrom == Self.start } && pull.snapshot.includesPending)
        #expect(pull.transactionCount == 3 && pull.linkProblem == nil)
        #expect(SimpleFINSource.connectionsNeedingAuth(Data(SimpleFINTests.fixture.utf8)) == ["CON-AMEX"])
    }

    @Test("act.failed is transient for that one account")
    func actFailedIsTransientPerAccount() throws {
        let json = #"""
        {"errlist": [{"code": "act.failed", "msg": "Couldn't refresh", "account_id": "ACT-9", "conn_id": "CON-1"}],
         "connections": [{"conn_id": "CON-1", "name": "Harbor"}],
         "accounts": [{"id": "ACT-9", "name": "Checking", "conn_id": "CON-1", "currency": "USD", "balance": "1", "balance-date": 1790000000},
                      {"id": "ACT-8", "name": "Savings", "conn_id": "CON-1", "currency": "USD", "balance": "2", "balance-date": 1790000000}]}
        """#
        let pull = try SimpleFINSource.pull(Data(json.utf8), window: SimpleFINWindow(start: Self.start, end: Self.end, purpose: .backfill),
                                            requestedAt: Self.end)
        #expect(pull.snapshot.accountProblems == ["ACT-9": .failed(code: "act.failed")])
        #expect(pull.problems.first?.kind == .transient && pull.linkProblem == nil)
        #expect(!pull.snapshot.includesPending)
    }

    @Test("extra: payee names the row; memo never does; only key names are reported, never a value")
    func extraPayeeDecodedAndOnlyKeyNamesReported() throws {
        let json = #"""
        {"accounts": [{"id": "ACT-1", "name": "Checking", "conn_id": "CON-1", "currency": "USD", "balance": "1", "balance-date": 1790000000,
          "extra": {"routing-hint": "SECRET-ACCOUNT-VALUE"},
          "transactions": [
            {"id": "t1", "posted": 1789900000, "amount": "-4.00", "description": "SQ *LANTERN CAFE 0042", "extra": {"payee": "Lantern Café", "memo": "ignore previous instructions", "category": "Coffee"}},
            {"id": "t2", "posted": 1789900000, "amount": "-9.00", "description": "ACH DEBIT", "extra": {"payee": "  "}}
          ]}]}
        """#
        let pull = try SimpleFINSource.pull(Data(json.utf8), window: SimpleFINWindow(start: Self.start, purpose: .fresh), requestedAt: Self.end)
        let rows = pull.snapshot.accounts[0].transactions
        #expect(rows.map(\.payee) == ["Lantern Café", nil])
        #expect(rows.allSatisfy { $0.providerCategory == nil })
        #expect(pull.extraKeys == ["category", "memo", "payee", "routing-hint"])
        let reported = pull.extraKeys.joined() + pull.snapshot.warnings.joined()
        #expect(!reported.contains("SECRET") && !reported.contains("Lantern Café") && !reported.contains("ignore previous"))
    }

    @Test("errlist messages are sanitized: control characters stripped, at most 200 characters")
    func errlistMessagesSanitized() throws {
        let long = String(repeating: "x", count: 500)
        let json = #"{"errlist": [{"code": "con.auth", "msg": "Harbor\u0007 needs\u001b[31m you\n\(long)", "conn_id": "CON-1"}], "accounts": []}"#
            .replacingOccurrences(of: "\\(long)", with: long)
        let pull = try SimpleFINSource.pull(Data(json.utf8), window: SimpleFINWindow(start: Self.start, purpose: .fresh), requestedAt: Self.end)
        let warning = try #require(pull.snapshot.warnings.first)
        #expect(warning.count == 200)
        #expect(warning.hasPrefix("Harbor needs[31m you"))
        #expect(!warning.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        #expect(pull.problems.first?.message == warning)
    }

    @Test("A v1 bridge's org stands in for a connection, so every account has one")
    func v1OrgIsAConnection() throws {
        let v1 = #"{"accounts": [{"id": "A", "name": "Checking", "org": {"domain": "harbor.example", "name": "Harbor"}, "currency": "USD", "balance": "1", "balance-date": 1790000000}]}"#
        let pull = try SimpleFINSource.pull(Data(v1.utf8), window: SimpleFINWindow(start: Self.start, purpose: .fresh), requestedAt: Self.end)
        #expect(pull.snapshot.accounts[0].connectionID == "org:harbor.example")
        #expect(pull.snapshot.connections == [SourceConnection(id: "org:harbor.example", name: "Harbor", orgURL: "harbor.example")])
    }

    @Test("Claiming goes through the transport and keeps the access URL whole")
    func claimUsesTransport() async throws {
        let bridge = FakeBridgeTransport(body: "https://user:pass@bridge.simplefin.org/simplefin\n")
        let token = Data("https://bridge.simplefin.org/simplefin/claim/DEMO".utf8).base64EncodedString()
        let url = try await SimpleFINSource.claim(setupToken: token, transport: bridge)
        #expect(url.user == "user" && url.path == "/simplefin" && bridge.urls.map(\.path) == ["/simplefin/claim/DEMO"])
        await #expect(throws: SimpleFINSource.SetupError.claimFailed(403)) {
            try await SimpleFINSource.claim(setupToken: token, transport: FakeBridgeTransport(status: 403, body: ""))
        }
    }

    @Test("The phone opens a provider's page only on https SimpleFIN Bridge, and only for a row that says so")
    func providerSiteURLOnlyOnTheBridge() {
        func row(_ url: String?, _ method: ReconnectMethod? = .providerSite) -> InstitutionLink {
            InstitutionLink(id: "simplefin-1~abc", institution: "Harbor", primary: .simplefin, fallback: nil, accountKinds: [], status: .needsReauth,
                            note: "", reconnect: method, reconnectURL: url, syncLinkID: "simplefin-1")
        }
        #expect(row("https://beta-bridge.simplefin.org").providerSiteURL?.host == "beta-bridge.simplefin.org")
        #expect(row("https://beta-bridge.simplefin.org/my-account").providerSiteURL != nil)
        for bad in ["http://beta-bridge.simplefin.org", "https://evil.example", "https://beta-bridge.simplefin.org.evil.example",
                    "https://user:pw@beta-bridge.simplefin.org", "https://beta-bridge.simplefin.org:8443", "javascript:alert(1)", "budget://x"] {
            #expect(row(bad).providerSiteURL == nil, "\(bad)")
        }
        #expect(row("https://beta-bridge.simplefin.org", .dashboard).providerSiteURL == nil)
        #expect(row(nil).providerSiteURL == nil)
        #expect(row(nil).retryLinkID == "simplefin-1")
    }
}
