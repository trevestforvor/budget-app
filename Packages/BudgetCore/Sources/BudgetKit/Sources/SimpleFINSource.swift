import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLSession/URLRequest on Linux
#endif

/// SimpleFIN Bridge (https://www.simplefin.org/protocol.html).
///
/// Setup: the person creates a setup token at the bridge; the server base64-decodes it into a
/// claim URL and POSTs to it once, receiving an access URL with credentials in its userinfo
/// (`https://user:pass@host/path`). The access URL is a secret: whoever pulls with it keeps it sealed at rest and never
/// logs or shows it (the server seals it with `BUDGET_TOKEN_KEY`).
public struct SimpleFINSource: TransactionSource {
    public let accessURL: URL
    private let transport: any HTTPTransport

    public init(accessURL: URL, transport: any HTTPTransport = URLSessionTransport()) {
        self.accessURL = accessURL
        self.transport = transport
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
    public static func claim(setupToken: String, transport: any HTTPTransport = URLSessionTransport()) async throws -> URL {
        var request = URLRequest(url: try claimURL(fromSetupToken: setupToken))
        request.httpMethod = "POST"
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else { throw SetupError.claimFailed(response.statusCode) }
        guard let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: string), url.user != nil, url.password != nil else { throw SetupError.invalidAccessURL }
        return url
    }

    // MARK: Fetch

    /// `GET {access}/accounts?start-date=&end-date=&account=…&pending=1`, Basic auth from the access URL's userinfo.
    /// `end` is exclusive; `accountIDs` narrows the pull to those accounts (none means all).
    func accountsRequest(since: Date, end: Date? = nil, accountIDs: [String] = [], includePending: Bool, balancesOnly: Bool = false) -> URLRequest {
        var components = URLComponents(url: accessURL.appending(path: "accounts"), resolvingAgainstBaseURL: false)!
        let user = components.user ?? "", password = components.password ?? ""
        components.user = nil
        components.password = nil
        var items = [URLQueryItem(name: "start-date", value: String(Int(since.timeIntervalSince1970)))]
        if let end { items.append(URLQueryItem(name: "end-date", value: String(Int(end.timeIntervalSince1970)))) }
        items += accountIDs.map { URLQueryItem(name: "account", value: $0) }
        if includePending { items.append(URLQueryItem(name: "pending", value: "1")) }
        if balancesOnly { items.append(URLQueryItem(name: "balances-only", value: "1")) }
        items.append(URLQueryItem(name: "version", value: "2"))
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.setValue("Basic " + Data("\(user):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        return request
    }

    /// One pull of one window. Pending rows are asked for only on the fresh pull: older windows have none.
    public func fetch(_ window: SimpleFINWindow, now: Date = Date()) async throws -> SimpleFINPull {
        let pending = window.purpose == .fresh
        let request = accountsRequest(since: window.start, end: window.end, accountIDs: window.accountIDs, includePending: pending)
        let (data, response) = try await transport.send(request)
        switch response.statusCode {
        case 200: return try Self.pull(data, window: window, requestedAt: now)
        case 403: throw SimpleFINError.revoked
        case 402: throw SimpleFINError.paymentRequired
        default: throw SimpleFINError.http(response.statusCode)
        }
    }

    public func fetch(since: Date, includePending: Bool = true) async throws -> SourceSnapshot {
        try await fetch(SimpleFINWindow(start: since, purpose: includePending ? .fresh : .backfill)).snapshot
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
        /// Bridge-specific fields; only `payee` is read, and only key names are ever reported.
        var extra: [String: JSONValue]?
        enum CodingKeys: String, CodingKey { case id, posted, amount, description, transactedAt = "transacted_at", pending, extra }
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
        var extra: [String: JSONValue]?
        enum CodingKeys: String, CodingKey {
            case id, name, org, currency, balance, transactions, extra
            case connID = "conn_id", availableBalance = "available-balance", balanceDate = "balance-date"
        }
    }

    static func money(_ string: String?, _ currency: String) -> Money? {
        guard let string, let amount = DecimalAmount(string: string) else { return nil }
        // Currencies are ISO 4217 codes, or a URL for custom currencies (points, gift cards) — those aren't money.
        return Money(minorUnits: amount.minorUnits, currencyCode: currency.count == 3 ? currency.uppercased() : "XXX")
    }

    /// Text from the bridge, made safe to store and show: control characters out, at most `limit` characters.
    public static func sanitize(_ text: String, limit: Int = 200) -> String {
        let kept = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces).prefix(limit))
    }

    /// The connection an account comes through. A v1 bridge names no connections, so its org stands in for one.
    static func connectionID(_ account: WireAccount) -> String {
        account.connID ?? "org:" + (account.org?.domain ?? account.org?.name ?? "unknown")
    }

    public static func parse(_ data: Data) throws -> SourceSnapshot {
        try pull(data, window: SimpleFINWindow(start: .distantPast, purpose: .fresh), requestedAt: Date()).snapshot
    }

    /// The pull as the server keeps it: the snapshot to ingest, the typed errlist, and what's needed to move each bank's
    /// window on.
    static func pull(_ data: Data, window: SimpleFINWindow, requestedAt: Date) throws -> SimpleFINPull {
        let set = try JSONDecoder().decode(AccountSet.self, from: data)
        var connections = (set.connections ?? []).map { SourceConnection(id: $0.connID, name: sanitize($0.name, limit: 80), orgURL: $0.orgURL) }
        var extraKeys: Set<String> = []
        var transactionCount = 0
        let named = Dictionary(connections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let accounts = set.accounts.map { a -> SourceAccount in
            let connectionID = connectionID(a)
            let connection = named[connectionID]
            let institution = connection?.name ?? a.org?.name ?? a.org?.domain ?? "Unknown institution"
            if connection == nil, !connections.contains(where: { $0.id == connectionID }) {
                connections.append(SourceConnection(id: connectionID, name: sanitize(institution, limit: 80), orgURL: a.org?.domain))
            }
            extraKeys.formUnion((a.extra ?? [:]).keys.map { sanitize($0, limit: 40) })
            let domain = connection?.orgURL ?? a.org?.domain
            let transactions = (a.transactions ?? []).compactMap { t -> SourceTransaction? in
                guard let amount = money(t.amount, a.currency) else { return nil }
                extraKeys.formUnion((t.extra ?? [:]).keys.map { sanitize($0, limit: 40) })
                // `memo` is free text that never names anything here; `payee`, when the bridge gives one, is the name.
                var payee: String?
                if case let .string(text) = t.extra?["payee"] {
                    let clean = sanitize(text, limit: 120)
                    payee = clean.isEmpty ? nil : clean
                }
                // `posted` is 0 for pending rows; fall back to when it was transacted.
                let when = t.posted > 0 ? t.posted : (t.transactedAt ?? 0)
                return SourceTransaction(externalID: t.id, posted: Date(timeIntervalSince1970: TimeInterval(when)), amount: amount,
                                         description: t.description, payee: payee, isPending: t.pending ?? (t.posted == 0))
            }
            transactionCount += transactions.count
            return SourceAccount(externalID: a.id, institution: institution, institutionDomain: domain, name: a.name,
                                 kind: .infer(fromName: a.name),
                                 balance: money(a.balance, a.currency) ?? .zero, availableBalance: money(a.availableBalance, a.currency),
                                 balanceDate: Date(timeIntervalSince1970: TimeInterval(a.balanceDate)),
                                 transactions: transactions, holdings: [], connectionID: connectionID,
                                 coveredFrom: window.start == .distantPast ? nil : window.start)
        }
        let problems = (set.errlist ?? []).map {
            SimpleFINProblem(code: sanitize($0.code, limit: 40), message: $0.msg.map { sanitize($0) }, connectionID: $0.connID, accountID: $0.accountID)
        }
        var accountProblems: [String: SourceAccountProblem] = [:]
        for problem in problems {
            if problem.code.hasPrefix("con.auth"), let connectionID = problem.connectionID {
                for account in accounts where account.connectionID == connectionID { accountProblems[account.externalID] = .needsSignIn(code: problem.code) }
            } else if problem.code.hasPrefix("act."), let accountID = problem.accountID, accountProblems[accountID] == nil {
                accountProblems[accountID] = .failed(code: problem.code)
            }
        }
        let warnings = problems.map { $0.message ?? $0.code } + (set.errlist == nil ? (set.errors ?? []).map { sanitize($0) } : [])
        let snapshot = SourceSnapshot(source: .simplefin, accounts: accounts, warnings: warnings, includesPending: window.purpose == .fresh,
                                      connections: connections, accountProblems: accountProblems)
        return SimpleFINPull(snapshot: snapshot, problems: problems, transactionCount: transactionCount, extraKeys: extraKeys,
                             requestedAt: requestedAt, window: window)
    }

    /// Connections the bridge says need the person to sign in again (`con.auth`).
    public static func connectionsNeedingAuth(_ data: Data) -> [String] {
        guard let pull = try? pull(data, window: SimpleFINWindow(start: .distantPast, purpose: .fresh), requestedAt: Date()) else { return [] }
        return pull.problems.filter { $0.code.hasPrefix("con.auth") }.compactMap(\.connectionID)
    }
}

/// What one request to the bridge brought.
public struct SimpleFINPull: Sendable {
    public var snapshot: SourceSnapshot
    /// The errlist, typed.
    public var problems: [SimpleFINProblem]
    public var transactionCount: Int
    /// The names of the bridge's `extra` fields seen (never their values), for a daily log line.
    public var extraKeys: Set<String>
    public var requestedAt: Date
    public var window: SimpleFINWindow

    /// The first problem with the whole link (`gen.auth`, `gen.api`), if any.
    public var linkProblem: SimpleFINProblem? { problems.first { $0.code.hasPrefix("gen.") } }
}

/// One errlist entry. The message is the bridge's, sanitized; the code is what decides anything.
public struct SimpleFINProblem: Hashable, Sendable {
    public var code: String
    public var message: String?
    public var connectionID: String?
    public var accountID: String?

    public init(code: String, message: String? = nil, connectionID: String? = nil, accountID: String? = nil) {
        self.code = code; self.message = message; self.connectionID = connectionID; self.accountID = accountID
    }

    /// `gen.auth` → revoked (the whole link), `gen.api` → the provider's side, `con.auth` → one bank's sign-in, and
    /// anything else (`act.failed`, `act.missingdata`, …) → transient.
    public var kind: LinkErrorKind {
        if code.hasPrefix("gen.auth") { return .revoked }
        if code.hasPrefix("gen.") { return .providerSetup }
        if code.hasPrefix("con.auth") { return .needsSignIn }
        return .transient
    }
}

/// How a pull from SimpleFIN failed, without free text to search later.
public enum SimpleFINError: LocalizedError, Equatable {
    /// 403, or `gen.auth`: SimpleFIN no longer accepts this access URL; only a new setup token fixes it.
    case revoked
    /// 402: the SimpleFIN subscription needs attention.
    case paymentRequired
    /// `gen.api`: something on SimpleFIN's side; only the code is kept.
    case provider(code: String)
    case http(Int)
    /// This server's own daily cap was reached; `nextAtText` says when the next pull can run, in the server's time zone.
    case budget(nextAt: Date, nextAtText: String)

    public var kind: LinkErrorKind {
        switch self {
        case .revoked: .revoked
        case .paymentRequired, .provider: .providerSetup
        case .http: .transient
        case .budget: .rateLimited
        }
    }

    /// The code kept on the link (`StoredLink.errorCode`).
    public var code: String {
        switch self {
        case .revoked: "http-403"
        case .paymentRequired: "http-402"
        case let .provider(code): code
        case let .http(status): "http-\(status)"
        case .budget: "budget"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .revoked: "SimpleFIN no longer accepts this server's access. Create a new setup token at https://beta-bridge.simplefin.org and paste it on the dashboard."
        case .paymentRequired: "SimpleFIN says the subscription needs attention. Renew it at https://beta-bridge.simplefin.org."
        case let .provider(code): "SimpleFIN couldn't answer (\(code)). The next sync tries again."
        case let .http(status): "SimpleFIN answered \(status). The next sync tries again."
        case let .budget(_, nextAtText):
            "SimpleFIN allows about 24 requests a day; this server stops at \(SimpleFINBudget.hardStopPerDay). The next pull can run at \(nextAtText)."
        }
    }
}
