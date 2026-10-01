import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLSession/URLRequest on Linux
#endif

/// SimpleFIN Bridge (https://www.simplefin.org/protocol.html).
///
/// Setup: the person creates a setup token at the bridge; the server base64-decodes it into a
/// claim URL and POSTs to it once, receiving an access URL with credentials in its userinfo
/// (`https://user:pass@host/path`). The access URL is a secret: store it server-side only.
public struct SimpleFINSource: TransactionSource {
    public let accessURL: URL
    private let session: URLSession

    public init(accessURL: URL, session: URLSession = .shared) {
        self.accessURL = accessURL
        self.session = session
    }

    public var kind: SourceKind { .simplefin }

    // MARK: Setup

    public enum SetupError: LocalizedError, Equatable {
        case invalidToken
        case claimFailed(Int)
        case invalidAccessURL

        public var errorDescription: String? {
            switch self {
            case .invalidToken: "That isn't a SimpleFIN setup token."
            case let .claimFailed(status): "The bridge refused the setup token (\(status)). Tokens can only be claimed once."
            case .invalidAccessURL: "The bridge returned an unusable access URL."
            }
        }
    }

    /// Setup token → claim URL.
    public static func claimURL(fromSetupToken token: String) throws -> URL {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let padded = trimmed + String(repeating: "=", count: (4 - trimmed.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), let string = String(data: data, encoding: .utf8),
              let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https" else {
            throw SetupError.invalidToken
        }
        return url
    }

    /// Claims a setup token once and returns the access URL.
    public static func claim(setupToken: String, session: URLSession = .shared) async throws -> URL {
        var request = URLRequest(url: try claimURL(fromSetupToken: setupToken))
        request.httpMethod = "POST"
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw SetupError.claimFailed(status) }
        guard let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: string), url.user != nil, url.password != nil else { throw SetupError.invalidAccessURL }
        return url
    }

    // MARK: Fetch

    /// `GET {access}/accounts?start-date=&pending=1`, Basic auth from the access URL's userinfo.
    func accountsRequest(since: Date, includePending: Bool, balancesOnly: Bool = false) -> URLRequest {
        var components = URLComponents(url: accessURL.appending(path: "accounts"), resolvingAgainstBaseURL: false)!
        let user = components.user ?? "", password = components.password ?? ""
        components.user = nil
        components.password = nil
        var items = [URLQueryItem(name: "start-date", value: String(Int(since.timeIntervalSince1970)))]
        if includePending { items.append(URLQueryItem(name: "pending", value: "1")) }
        if balancesOnly { items.append(URLQueryItem(name: "balances-only", value: "1")) }
        items.append(URLQueryItem(name: "version", value: "2"))
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.setValue("Basic " + Data("\(user):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        return request
    }

    public func fetch(since: Date, includePending: Bool = true) async throws -> SourceSnapshot {
        let (data, response) = try await session.data(for: accountsRequest(since: since, includePending: includePending))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw BudgetAPIError.server(status: status, message: status == 403 ? "SimpleFIN access was revoked; create a new setup token." : nil)
        }
        return try Self.parse(data)
    }

    // MARK: Wire format (protocol v2.0.0-draft; v1's `org` object is still accepted)

    struct AccountSet: Decodable {
        var errlist: [WireError]?
        /// Deprecated in v2: plain strings for display.
        var errors: [String]?
        var connections: [WireConnection]?
        var accounts: [WireAccount]
    }

    /// `{code: "con.auth" | "act.failed" | …, msg, conn_id?, account_id?}`
    struct WireError: Decodable {
        var code: String
        var msg: String?
        var connID: String?
        var accountID: String?
        enum CodingKeys: String, CodingKey { case code, msg, connID = "conn_id", accountID = "account_id" }
    }

    struct WireConnection: Decodable {
        var connID: String
        var name: String
        var orgID: String?
        var orgURL: String?
        enum CodingKeys: String, CodingKey { case connID = "conn_id", name, orgID = "org_id", orgURL = "org_url" }
    }

    /// v1 only.
    struct WireOrg: Decodable {
        var domain: String?
        var name: String?
    }

    struct WireTransaction: Decodable {
        var id: String
        var posted: Int64
        var amount: String
        var description: String
        var transactedAt: Int64?
        var pending: Bool?
        enum CodingKeys: String, CodingKey { case id, posted, amount, description, transactedAt = "transacted_at", pending }
    }

    struct WireAccount: Decodable {
        var id: String
        var name: String
        var connID: String?
        var org: WireOrg?
        var currency: String
        var balance: String
        var availableBalance: String?
        var balanceDate: Int64
        var transactions: [WireTransaction]?
        enum CodingKeys: String, CodingKey {
            case id, name, org, currency, balance, transactions
            case connID = "conn_id", availableBalance = "available-balance", balanceDate = "balance-date"
        }
    }

    static func money(_ string: String?, _ currency: String) -> Money? {
        guard let string, let amount = DecimalAmount(string: string) else { return nil }
        // Currencies are ISO 4217 codes, or a URL for custom currencies (points, gift cards) — those aren't money.
        return Money(minorUnits: amount.minorUnits, currencyCode: currency.count == 3 ? currency.uppercased() : "XXX")
    }

    public static func parse(_ data: Data) throws -> SourceSnapshot {
        let set = try JSONDecoder().decode(AccountSet.self, from: data)
        let connections = Dictionary((set.connections ?? []).map { ($0.connID, $0) }, uniquingKeysWith: { a, _ in a })
        let accounts = set.accounts.map { a -> SourceAccount in
            let connection = a.connID.flatMap { connections[$0] }
            let institution = connection?.name ?? a.org?.name ?? a.org?.domain ?? "Unknown institution"
            let domain = connection?.orgURL ?? a.org?.domain
            let transactions = (a.transactions ?? []).compactMap { t -> SourceTransaction? in
                guard let amount = money(t.amount, a.currency) else { return nil }
                // `posted` is 0 for pending rows; fall back to when it was transacted.
                let when = t.posted > 0 ? t.posted : (t.transactedAt ?? 0)
                return SourceTransaction(externalID: t.id, posted: Date(timeIntervalSince1970: TimeInterval(when)), amount: amount,
                                         description: t.description, isPending: t.pending ?? (t.posted == 0))
            }
            return SourceAccount(externalID: a.id, institution: institution, institutionDomain: domain, name: a.name,
                                 kind: .infer(fromName: a.name),
                                 balance: money(a.balance, a.currency) ?? .zero, availableBalance: money(a.availableBalance, a.currency),
                                 balanceDate: Date(timeIntervalSince1970: TimeInterval(a.balanceDate)),
                                 transactions: transactions, holdings: [])
        }
        let warnings = (set.errlist ?? []).map { $0.msg ?? $0.code } + (set.errlist == nil ? (set.errors ?? []) : [])
        return SourceSnapshot(source: .simplefin, accounts: accounts, warnings: warnings)
    }

    /// Connections the bridge says need the person to sign in again (`con.auth`).
    public static func connectionsNeedingAuth(_ data: Data) -> [String] {
        guard let set = try? JSONDecoder().decode(AccountSet.self, from: data) else { return [] }
        return (set.errlist ?? []).filter { $0.code.hasPrefix("con.auth") }.compactMap(\.connID)
    }
}
