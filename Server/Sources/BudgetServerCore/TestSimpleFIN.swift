import BudgetKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A made-up SimpleFIN Bridge for a throwaway server (`ServerConfig.isThrowaway`: in memory, `BUDGET_ALLOW_DEMO=1`), so
/// the SimpleFIN path can be tried end to end with no SimpleFIN account and no network.
///
/// - The setup token `TestSimpleFIN.setupToken` (documented in docs/SERVER.md) claims here, in process, and works any
///   number of times. Its claim and access addresses are on a `.invalid` host, which never resolves, so nothing about it
///   can leave the machine even by mistake.
/// - Its pulls answer two banks with three accounts and a few weeks of rows, dated back from today.
/// - Only a throwaway server installs it (`transport(wrapping:config:)`); a server with a database refuses the token
///   before claiming (`refuseTestToken`), so it can never put made-up banks in a real ledger.
enum TestSimpleFIN {
    static let host = "simplefin-test.budget.invalid"
    /// `base64("https://simplefin-test.budget.invalid/claim/demo")`.
    static let setupToken = "aHR0cHM6Ly9zaW1wbGVmaW4tdGVzdC5idWRnZXQuaW52YWxpZC9jbGFpbS9kZW1v"
    static let accessURL = "https://test:test@\(host)/simplefin"

    /// Whether a setup token is this test bridge's.
    static func isTestToken(_ token: String) -> Bool {
        (try? SimpleFINSource.claimURL(fromSetupToken: token))?.host()?.lowercased() == host
    }

    /// Refuses the test token on any server that isn't a throwaway one, before anything is claimed or sent.
    static func refuseTestToken(_ token: String, throwaway: Bool) throws {
        guard !throwaway, isTestToken(token) else { return }
        throw BudgetAPIError.rejected("That's the test server's made-up SimpleFIN token. It works only on an in-memory test server (BUDGET_ALLOW_DEMO=1, no POSTGRES_HOST).")
    }

    /// The providers' transport: on a throwaway server, with this bridge answering its own host in front of it.
    static func transport(wrapping inner: any HTTPTransport, config: ServerConfig) -> any HTTPTransport {
        config.isThrowaway ? Bridge(inner: inner) : inner
    }

    /// Answers requests to `host`; everything else goes to `inner` unchanged.
    struct Bridge: HTTPTransport {
        let inner: any HTTPTransport

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            guard let url = request.url, url.host()?.lowercased() == TestSimpleFIN.host else { return try await inner.send(request) }
            let (status, body) = TestSimpleFIN.answer(method: request.httpMethod ?? "GET", url: url, now: Date())
            return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
    }

    struct Row { var daysAgo: Int; var amount: String; var description: String }
    struct Account { var id: String; var connID: String; var name: String; var balance: String; var rows: [Row] }

    static let banks = [("TEST-1", "Sample Credit Union"), ("TEST-2", "Sample Card Bank")]
    static let accounts: [Account] = [
        Account(id: "TEST-CHK", connID: "TEST-1", name: "Everyday Checking", balance: "2450.18", rows: [
            Row(daysAgo: 1, amount: "-4.75", description: "CORNER COFFEE"),
            Row(daysAgo: 3, amount: "-86.40", description: "NEIGHBORHOOD GROCERY"),
            Row(daysAgo: 6, amount: "-52.10", description: "CITY WATER UTILITY"),
            Row(daysAgo: 10, amount: "-500.00", description: "TRANSFER TO SAVINGS"),
            Row(daysAgo: 12, amount: "-300.00", description: "CARD PAYMENT"),
            Row(daysAgo: 14, amount: "2150.00", description: "PAYROLL DEPOSIT"),
            Row(daysAgo: 21, amount: "-1200.00", description: "RENT PAYMENT"),
            Row(daysAgo: 28, amount: "2150.00", description: "PAYROLL DEPOSIT"),
        ]),
        Account(id: "TEST-SAV", connID: "TEST-1", name: "Savings", balance: "8200.00", rows: [
            Row(daysAgo: 10, amount: "500.00", description: "TRANSFER FROM CHECKING"),
            Row(daysAgo: 30, amount: "1.62", description: "INTEREST PAID"),
        ]),
        Account(id: "TEST-CARD", connID: "TEST-2", name: "Rewards Card", balance: "-642.37", rows: [
            Row(daysAgo: 2, amount: "-38.20", description: "GAS STATION"),
            Row(daysAgo: 5, amount: "-15.99", description: "STREAMING SERVICE"),
            Row(daysAgo: 9, amount: "-64.03", description: "HARDWARE STORE"),
            Row(daysAgo: 12, amount: "300.00", description: "PAYMENT THANK YOU"),
            Row(daysAgo: 18, amount: "-27.50", description: "PIZZA PLACE"),
        ]),
    ]

    /// The bridge's answer to one request: the claim, the account set for a window, or 404.
    static func answer(method: String, url: URL, now: Date) -> (Int, String) {
        let path = url.path()
        if method == "POST", path == "/claim/demo" { return (200, accessURL) }
        guard method == "GET", path == "/simplefin/accounts" else { return (404, "Not found") }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let start = query.first { $0.name == "start-date" }?.value.flatMap(Double.init) ?? 0
        let end = query.first { $0.name == "end-date" }?.value.flatMap(Double.init)
        let only = Set(query.filter { $0.name == "account" }.compactMap(\.value))
        let balancesOnly = query.contains { $0.name == "balances-only" && $0.value == "1" }
        // Noon UTC, so a row's day is the same in every time zone a test server might run in.
        let today = (now.timeIntervalSince1970 / 86_400).rounded(.down) * 86_400 + 43_200
        var dayStyle = Date.ISO8601FormatStyle().year().month().day()
        dayStyle.timeZone = TimeZone(identifier: "UTC")!
        let accountJSON = accounts.filter { only.isEmpty || only.contains($0.id) }.map { account -> String in
            let rows = balancesOnly ? [] : account.rows.enumerated().compactMap { index, row -> String? in
                let posted = today - Double(row.daysAgo) * 86_400
                guard posted >= start, end.map({ posted < $0 }) ?? true else { return nil }
                let day = Date(timeIntervalSince1970: posted).formatted(dayStyle).replacingOccurrences(of: "-", with: "")
                return #"{"id": "\#(account.id)-\#(day)-\#(index)", "posted": \#(Int(posted)), "amount": "\#(row.amount)", "description": "\#(row.description)"}"#
            }
            return #"{"id": "\#(account.id)", "name": "\#(account.name)", "conn_id": "\#(account.connID)", "currency": "USD", "balance": "\#(account.balance)", "balance-date": \#(Int(now.timeIntervalSince1970)), "transactions": [\#(rows.joined(separator: ", "))]}"#
        }
        let connections = banks.map { #"{"conn_id": "\#($0.0)", "name": "\#($0.1)", "org_id": "\#($0.0)"}"# }
        return (200, #"{"errlist": [], "connections": [\#(connections.joined(separator: ", "))], "accounts": [\#(accountJSON.joined(separator: ", "))]}"#)
    }
}
