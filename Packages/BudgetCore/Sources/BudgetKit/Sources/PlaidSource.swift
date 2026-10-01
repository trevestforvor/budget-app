import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLSession/URLRequest on Linux
#endif

/// Plaid (https://plaid.com/docs/api/). Server-side only: the secret and access tokens never reach the phone.
///
/// Connect flow: server creates a Link token → phone opens Plaid Link with it → Link returns a
/// public token → server exchanges it for an access token (one per Item, i.e. per login).
public struct PlaidSource: TransactionSource {
    public enum Environment: String, Sendable {
        case sandbox, production
        var host: URL { URL(string: "https://\(rawValue).plaid.com")! }
    }

    public struct Credentials: Sendable {
        public var clientID: String
        public var secret: String
        public init(clientID: String, secret: String) { self.clientID = clientID; self.secret = secret }
    }

    public let environment: Environment
    public let credentials: Credentials
    /// The Item's access token (from `exchange`).
    public let accessToken: String
    public let institution: String
    private let transport: any HTTPTransport

    public init(environment: Environment, credentials: Credentials, accessToken: String, institution: String,
                transport: any HTTPTransport = URLSessionTransport()) {
        self.environment = environment
        self.credentials = credentials
        self.accessToken = accessToken
        self.institution = institution
        self.transport = transport
    }

    public var kind: SourceKind { .plaid }

    // MARK: Requests

    static func request(_ environment: Environment, _ path: String, _ body: [String: JSONValue], _ credentials: Credentials) throws -> URLRequest {
        var request = URLRequest(url: environment.host.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload = body
        payload["client_id"] = .string(credentials.clientID)
        payload["secret"] = .string(credentials.secret)
        request.httpBody = try JSONValue.object(payload).data()
        request.timeoutInterval = 60
        return request
    }

    /// `/link/token/create` — asks for transactions (with `daysRequested` of history, fixed at Item
    /// creation: max 730), plus investments when the institution has them.
    /// - Parameter redirectURI: the Universal Link registered in the Dashboard, required for OAuth banks on iOS.
    /// - Parameter accessToken: set to open Link in update mode for an existing Item (re-auth).
    public static func linkToken(environment: Environment, credentials: Credentials, userID: String, investments: Bool,
                                 daysRequested: Int = 730, redirectURI: String? = nil, accessToken: String? = nil,
                                 transport: any HTTPTransport = URLSessionTransport()) async throws -> String {
        var body: [String: JSONValue] = [
            "client_name": .string("Budget"), "language": .string("en"), "country_codes": .array([.string("US")]),
            "user": .object(["client_user_id": .string(userID)]),
        ]
        if let accessToken {
            body["access_token"] = .string(accessToken)
        } else {
            body["products"] = .array([.string("transactions")])
            body["transactions"] = .object(["days_requested": .number(Double(min(max(daysRequested, 1), 730)))])
            if investments { body["additional_consented_products"] = .array([.string("investments")]) }
        }
        if let redirectURI { body["redirect_uri"] = .string(redirectURI) }
        let json = try await transport.json(try request(environment, "link/token/create", body, credentials))
        guard case let .object(o) = json, case let .string(token)? = o["link_token"] else { throw DecisionError.malformed("no link_token") }
        return token
    }

    /// `/item/public_token/exchange` → (access token, item id). Store both server-side.
    public static func exchange(publicToken: String, environment: Environment, credentials: Credentials,
                                transport: any HTTPTransport = URLSessionTransport()) async throws -> (accessToken: String, itemID: String) {
        let json = try await transport.json(try request(environment, "item/public_token/exchange", ["public_token": .string(publicToken)], credentials))
        guard case let .object(o) = json, case let .string(token)? = o["access_token"], case let .string(item)? = o["item_id"] else {
            throw DecisionError.malformed("no access_token")
        }
        return (token, item)
    }

    /// `/item/remove` — revokes the access token at Plaid (the Item stops existing; Trial slots aren't returned).
    public static func removeItem(accessToken: String, environment: Environment, credentials: Credentials,
                                  transport: any HTTPTransport = URLSessionTransport()) async throws {
        _ = try await transport.json(try request(environment, "item/remove", ["access_token": .string(accessToken)], credentials))
    }

    // MARK: Sync

    public struct SyncPage: Sendable {
        public var added: [(accountID: String, transaction: SourceTransaction)]
        public var modified: [(accountID: String, transaction: SourceTransaction)]
        public var removed: [String]
        public var nextCursor: String
        public var hasMore: Bool
    }

    /// One page of `/transactions/sync`. Persist `nextCursor` only after all pages (`hasMore == false`) are applied.
    public func syncPage(cursor: String?, count: Int = 500) async throws -> SyncPage {
        var body: [String: JSONValue] = ["access_token": .string(accessToken), "count": .number(Double(count))]
        if let cursor { body["cursor"] = .string(cursor) }
        return try Self.parseSync(try await transport.json(try Self.request(environment, "transactions/sync", body, credentials)))
    }

    /// All pages from `cursor` to now.
    public func sync(from cursor: String?) async throws -> SyncPage {
        var page = try await syncPage(cursor: cursor)
        var all = page
        while page.hasMore {
            page = try await syncPage(cursor: page.nextCursor)
            all.added += page.added
            all.modified += page.modified
            all.removed += page.removed
            all.nextCursor = page.nextCursor
            all.hasMore = page.hasMore
        }
        return all
    }

    /// Incremental: everything since `cursor` (nil = full history), current balances and holdings.
    /// Persist `nextCursor` only after the snapshot is applied.
    public func snapshot(cursor: String?) async throws -> (snapshot: SourceSnapshot, nextCursor: String, removed: [String]) {
        let page = try await sync(from: cursor)
        let balances = try Self.parseAccounts(try await transport.json(
            try Self.request(environment, "accounts/balance/get", ["access_token": .string(accessToken)], credentials)), institution: institution)
        let holdings = (try? await self.holdings()) ?? [:]
        let changed = page.added + page.modified
        let accounts = balances.map { account -> SourceAccount in
            var a = account
            a.transactions = changed.filter { $0.accountID == account.externalID }.map(\.transaction)
            a.holdings = holdings[account.externalID] ?? []
            return a
        }
        return (SourceSnapshot(source: .plaid, accounts: accounts, warnings: []), page.nextCursor, page.removed)
    }

    public func fetch(since: Date, includePending: Bool = true) async throws -> SourceSnapshot {
        let page = try await sync(from: nil)
        let balances = try Self.parseAccounts(try await transport.json(
            try Self.request(environment, "accounts/balance/get", ["access_token": .string(accessToken)], credentials)), institution: institution)
        let holdings = (try? await self.holdings()) ?? [:]
        let accounts = balances.map { account -> SourceAccount in
            var a = account
            a.transactions = page.added.filter { $0.accountID == account.externalID && $0.transaction.posted >= since && (includePending || !$0.transaction.isPending) }
                .map(\.transaction)
            a.holdings = holdings[account.externalID] ?? []
            return a
        }
        return SourceSnapshot(source: .plaid, accounts: accounts, warnings: [])
    }

    /// `/investments/holdings/get`, grouped by account.
    public func holdings() async throws -> [String: [SourceHolding]] {
        try Self.parseHoldings(try await transport.json(
            try Self.request(environment, "investments/holdings/get", ["access_token": .string(accessToken)], credentials)))
    }

    // MARK: Parsing

    static func string(_ o: [String: JSONValue], _ key: String) -> String? { if case let .string(v)? = o[key] { v } else { nil } }
    static func number(_ o: [String: JSONValue], _ key: String) -> Double? { if case let .number(v)? = o[key] { v } else { nil } }

    static func money(_ value: Double, _ currency: String?) -> Money {
        Money(Decimal(string: String(format: "%.2f", value)) ?? 0, currencyCode: currency ?? "USD")
    }

    /// Plaid leaves `iso_currency_code` null exactly when an amount is in an unofficial currency (crypto, some national
    /// ones) and names it in `unofficial_currency_code`; that code is kept so ingest can set the amount aside.
    static func currency(_ o: [String: JSONValue]) -> String? {
        string(o, "iso_currency_code") ?? string(o, "unofficial_currency_code")
    }

    static func day(_ s: String) -> Date? {
        guard let m = s.wholeMatch(of: /(\d{4})-(\d{2})-(\d{2})/) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: Int(m.1), month: Int(m.2), day: Int(m.3), hour: 12))
    }

    /// Plaid amounts are positive when money leaves the account; the ledger is negative-out.
    static func transaction(_ value: JSONValue) -> (accountID: String, transaction: SourceTransaction)? {
        guard case let .object(o) = value, let id = string(o, "transaction_id"), let account = string(o, "account_id"),
              let amount = number(o, "amount"), let date = string(o, "date").flatMap(day) else { return nil }
        var category: String?
        if case let .object(pfc)? = o["personal_finance_category"] { category = string(pfc, "detailed") ?? string(pfc, "primary") }
        let pending: Bool = if case let .bool(p)? = o["pending"] { p } else { false }
        // A posted row arrives under a new id, naming the pending row it replaces (which Plaid lists as removed).
        let replaces = pending ? nil : string(o, "pending_transaction_id")
        return (account, SourceTransaction(externalID: id, posted: date, amount: money(-amount, currency(o)),
                                           description: string(o, "name") ?? string(o, "merchant_name") ?? "",
                                           payee: string(o, "merchant_name"), isPending: pending, providerCategory: category,
                                           replacesExternalID: replaces))
    }

    static func parseSync(_ json: JSONValue) throws -> SyncPage {
        guard case let .object(o) = json, let cursor = string(o, "next_cursor") else { throw DecisionError.malformed("no next_cursor") }
        func list(_ key: String) -> [JSONValue] { if case let .array(a)? = o[key] { a } else { [] } }
        let hasMore: Bool = if case let .bool(v)? = o["has_more"] { v } else { false }
        return SyncPage(added: list("added").compactMap(transaction), modified: list("modified").compactMap(transaction),
                        removed: list("removed").compactMap { if case let .object(r) = $0 { string(r, "transaction_id") } else { nil } },
                        nextCursor: cursor, hasMore: hasMore)
    }

    /// Credit and loan balances come back as amounts owed (positive); the ledger shows them negative.
    static func parseAccounts(_ json: JSONValue, institution: String) throws -> [SourceAccount] {
        guard case let .object(o) = json, case let .array(accounts)? = o["accounts"] else { throw DecisionError.malformed("no accounts") }
        return accounts.compactMap { value in
            guard case let .object(a) = value, let id = string(a, "account_id"), case let .object(b)? = a["balances"] else { return nil }
            let type = string(a, "type") ?? "depository"
            let subtype = string(a, "subtype") ?? ""
            let kind: AccountKind = switch type {
            case "credit", "loan": .credit
            case "investment", "brokerage": .investment
            default: subtype.contains("saving") || subtype == "money market" || subtype == "cd" ? .savings : .checking
            }
            let currency = Self.currency(b)
            let sign: Double = kind == .credit ? -1 : 1
            let current = number(b, "current") ?? 0
            return SourceAccount(externalID: id, institution: institution, institutionDomain: nil,
                                 name: displayName(a), kind: kind,
                                 balance: money(current * sign, currency),
                                 availableBalance: number(b, "available").map { money($0, currency) },
                                 balanceDate: .now, transactions: [], holdings: [], mask: string(a, "mask"))
        }
    }

    /// Chase names every card "CREDIT CARD"; the official name ("Chase Freedom Unlimited") tells them apart.
    static func displayName(_ a: [String: JSONValue]) -> String {
        let name = string(a, "name"), official = string(a, "official_name")
        let generic = ["credit card", "checking", "savings", "account", "card"]
        if let official, !official.isEmpty, name.map({ generic.contains($0.lowercased().trimmingCharacters(in: .whitespaces)) }) ?? true { return official }
        return name ?? official ?? "Account"
    }

    static func parseHoldings(_ json: JSONValue) throws -> [String: [SourceHolding]] {
        guard case let .object(o) = json, case let .array(holdings)? = o["holdings"] else { throw DecisionError.malformed("no holdings") }
        var securities: [String: (ticker: String?, name: String)] = [:]
        if case let .array(list)? = o["securities"] {
            for case let .object(s) in list {
                if let id = string(s, "security_id") { securities[id] = (string(s, "ticker_symbol"), string(s, "name") ?? "Security") }
            }
        }
        var out: [String: [SourceHolding]] = [:]
        for case let .object(h) in holdings {
            guard let account = string(h, "account_id"), let value = number(h, "institution_value") else { continue }
            let security = string(h, "security_id").flatMap { securities[$0] }
            out[account, default: []].append(SourceHolding(symbol: security?.ticker, description: security?.name ?? "Holding",
                                                          marketValue: money(value, string(h, "iso_currency_code"))))
        }
        return out
    }
}
