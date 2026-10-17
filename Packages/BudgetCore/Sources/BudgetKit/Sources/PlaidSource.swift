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
    let transport: any HTTPTransport

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
    /// creation: max 730), with consent for investments (when the institution has them) and liabilities (card bills),
    /// which are billed only once used. A Plaid account not enabled for Liabilities (INVALID_PRODUCT) links without it.
    /// - Parameter redirectURI: the Universal Link registered in the Dashboard, required for OAuth banks on iOS.
    /// - Parameter accessToken: set to open Link in update mode for an existing Item (re-auth).
    /// - Parameter grantLiabilities: with `accessToken`, update mode that asks the person to consent to liabilities on
    ///   the same Item (the card-bill grant). The Item and its access token stay as they are: nothing is exchanged after.
    ///   Only ever started by the person's own click.
    public static func linkToken(environment: Environment, credentials: Credentials, userID: String, investments: Bool,
                                 daysRequested: Int = 730, redirectURI: String? = nil, accessToken: String? = nil,
                                 grantLiabilities: Bool = false,
                                 transport: any HTTPTransport = URLSessionTransport()) async throws -> String {
        var body: [String: JSONValue] = [
            "client_name": .string("Budget"), "language": .string("en"), "country_codes": .array([.string("US")]),
            "user": .object(["client_user_id": .string(userID)]),
        ]
        if let accessToken {
            body["access_token"] = .string(accessToken)
            if grantLiabilities {
                body["products"] = .array([])
                body["additional_consented_products"] = .array([.string(liabilitiesProduct)])
            }
        } else {
            // Never in `products`: that list is a requirement every institution must meet, so it would hide banks.
            body["products"] = .array([.string("transactions")])
            body["transactions"] = .object(["days_requested": .number(Double(min(max(daysRequested, 1), 730)))])
            body["additional_consented_products"] = .array((investments ? ["investments"] : []).map(JSONValue.string) + [.string(liabilitiesProduct)])
        }
        if let redirectURI { body["redirect_uri"] = .string(redirectURI) }
        let json: JSONValue
        do {
            json = try await transport.json(try request(environment, "link/token/create", body, credentials))
        } catch let error as SourceHTTPError where accessToken == nil && PlaidAPIError(error)?.errorCode == "INVALID_PRODUCT" {
            // A Plaid account without Liabilities access refuses its consent: link the bank without card bills rather
            // than not at all (card bills then say "not supported").
            body["additional_consented_products"] = investments ? .array([.string("investments")]) : nil
            json = try await transport.json(try request(environment, "link/token/create", body, credentials))
        }
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

    /// How many times a pagination that Plaid changed under us starts over before the sync gives up (and tries later).
    public static let paginationRestarts = 3

    /// All pages from `cursor` to now. When Plaid's data changes mid-way (TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION),
    /// the pages so far are thrown away and the loop starts again from the cursor it began with, up to
    /// `paginationRestarts` times.
    public func sync(from cursor: String?) async throws -> SyncPage {
        var restarts = 0
        while true {
            do {
                return try await pages(from: cursor)
            } catch let error as SourceHTTPError
                where restarts < Self.paginationRestarts && PlaidAPIError(error)?.errorCode == "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION" {
                restarts += 1
            }
        }
    }

    private func pages(from cursor: String?) async throws -> SyncPage {
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

    /// Incremental: everything since `cursor` (nil = full history) and the accounts' balances, read as `balances` says.
    /// Holdings aren't part of it: they're fetched once a day per Item (HoldingsSync), never on every sync.
    /// Persist `nextCursor` only after the snapshot is applied.
    public func snapshot(cursor: String?, balances read: BalanceRead = .cached(asOf: nil), now: Date = .now) async throws -> Pull {
        let page = try await sync(from: cursor)
        let balances = try await accounts(read, now: now)
        let changed = page.added + page.modified
        let accounts = balances.accounts.map { account -> SourceAccount in
            var a = account
            a.transactions = changed.filter { $0.accountID == account.externalID }.map(\.transaction)
            return a
        }
        return Pull(snapshot: SourceSnapshot(source: .plaid, accounts: accounts, warnings: []), nextCursor: page.nextCursor,
                    removed: page.removed, liveBalance: balances.live, balanceFallback: balances.fallback)
    }

    public func fetch(since: Date, includePending: Bool = true) async throws -> SourceSnapshot {
        let page = try await sync(from: nil)
        let balances = try await accounts(.cached(asOf: nil))
        let accounts = balances.accounts.map { account -> SourceAccount in
            var a = account
            a.transactions = page.added.filter { $0.accountID == account.externalID && $0.transaction.posted >= since && (includePending || !$0.transaction.isPending) }
                .map(\.transaction)
            return a
        }
        return SourceSnapshot(source: .plaid, accounts: accounts, warnings: [])
    }

    /// What `snapshot` pulled.
    public struct Pull: Sendable {
        public var snapshot: SourceSnapshot
        /// Store it only after the snapshot is applied.
        public var nextCursor: String
        /// Transaction ids Plaid removed.
        public var removed: [String]
        /// The balances came from a live read at the bank (false: Plaid's cached ones).
        public var liveBalance: Bool
        /// Why a live read that was asked for gave way to the cached balances: Plaid's code and request id when it said.
        public var balanceFallback: PlaidAPIError?
    }

    // MARK: Balances

    /// How a sync reads balances.
    public enum BalanceRead: Sendable, Equatable {
        /// `/accounts/get`: the balances Plaid keeps, free, and refreshed about once a day on a Transactions Item. They're
        /// dated by Plaid's `last_updated_datetime` when it gives one, else by `asOf` (the newest time they're known to
        /// be from), else by the time of the read.
        case cached(asOf: Date?)
        /// `/accounts/balance/get`: a live read at the bank. It's slow (seconds, sometimes half a minute) and Plaid limits
        /// it per Item, so it's only for the person's own refresh, within the server's cap. When Plaid refuses it, the
        /// cached balances are read instead.
        case live
    }

    /// The Item's accounts and balances, read as `read` says. `live` says whether the live read is what came back.
    public func accounts(_ read: BalanceRead, now: Date = .now) async throws -> (accounts: [SourceAccount], live: Bool, fallback: PlaidAPIError?) {
        var asOf: Date?
        var fallback: PlaidAPIError?
        switch read {
        case .live:
            // Capital One (older connections) and Apple Card refuse a live read without a freshness floor; every other
            // bank ignores it. Older data than that comes back as an error, and the cached balances are read instead.
            let floor = now.addingTimeInterval(-86_400).formatted(.iso8601)
            let body: [String: JSONValue] = ["access_token": .string(accessToken),
                                             "options": .object(["min_last_updated_datetime": .string(floor)])]
            do {
                let json = try await transport.json(try Self.request(environment, "accounts/balance/get", body, credentials))
                return (try Self.parseAccounts(json, institution: institution, readAt: now), true, nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Any refusal (a rate limit, a bank that can't answer live, a stale floor): the cached read below still
                // answers, or fails for the Item's real reason (a sign-in, say) the way a sync would anyway.
                let http = error as? SourceHTTPError
                fallback = http.flatMap(PlaidAPIError.init) ?? PlaidAPIError(status: http?.status ?? 0)
            }
        case let .cached(date):
            asOf = date
        }
        let json = try await transport.json(try Self.request(environment, "accounts/get", ["access_token": .string(accessToken)], credentials))
        return (try Self.parseAccounts(json, institution: institution, readAt: asOf.map { min($0, now) } ?? now), false, fallback)
    }

    // MARK: Item

    /// What `/item/get` says about the Item: the ground truth for its live state.
    public struct Item: Hashable, Sendable {
        public var itemID: String?
        public var institutionID: String?
        /// `item.error`; nil while the Item is healthy.
        public var error: PlaidAPIError?
        /// When the bank's consent runs out (`consent_expiration_time`); nil at banks without an expiry.
        public var consentExpiresAt: Date?
        public var billedProducts: [String]
        public var availableProducts: [String]
        /// The webhook URL Plaid has for the Item.
        public var webhook: String?
        /// `status.transactions.last_successful_update`.
        public var transactionsUpdatedAt: Date?
        public var requestID: String?
    }

    /// `/item/get`. Plaid's errors (ITEM_NOT_FOUND above all) come back as `PlaidAPIError`.
    public func item() async throws -> Item {
        do {
            return try Self.parseItem(try await transport.json(
                try Self.request(environment, "item/get", ["access_token": .string(accessToken)], credentials)))
        } catch let error as SourceHTTPError {
            throw PlaidAPIError(error) ?? error
        }
    }

    static func parseItem(_ json: JSONValue) throws -> Item {
        guard case let .object(o) = json, case let .object(item)? = o["item"] else { throw DecisionError.malformed("no item") }
        func list(_ key: String) -> [String] {
            if case let .array(a)? = item[key] { a.compactMap { if case let .string(s) = $0 { s } else { nil } } } else { [] }
        }
        var error: PlaidAPIError?
        if case let .object(e)? = item["error"], string(e, "error_code") != nil || string(e, "error_type") != nil {
            error = PlaidAPIError(status: 200, errorType: string(e, "error_type"), errorCode: string(e, "error_code"),
                                  errorMessage: string(e, "error_message"), displayMessage: string(e, "display_message"),
                                  requestID: string(e, "request_id"))
        }
        var updated: Date?
        if case let .object(status)? = o["status"], case let .object(transactions)? = status["transactions"] {
            updated = string(transactions, "last_successful_update").flatMap(timestamp)
        }
        return Item(itemID: string(item, "item_id"), institutionID: string(item, "institution_id"), error: error,
                    consentExpiresAt: string(item, "consent_expiration_time").flatMap(timestamp), billedProducts: list("billed_products"),
                    availableProducts: list("available_products"), webhook: string(item, "webhook").flatMap { $0.isEmpty ? nil : $0 },
                    transactionsUpdatedAt: updated, requestID: string(o, "request_id"))
    }

    /// An ISO 8601 time, with or without fractional seconds ("2026-11-03T17:20:13Z", "…13.123Z").
    static func timestamp(_ s: String) -> Date? {
        (try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))) ?? (try? Date(s, strategy: .iso8601))
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

    /// Credit and loan balances come back as amounts owed (positive); the ledger shows them negative. A balance is dated
    /// by Plaid's `last_updated_datetime` when it gives one, else by `readAt`.
    static func parseAccounts(_ json: JSONValue, institution: String, readAt: Date = .now) throws -> [SourceAccount] {
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
            let updated = string(b, "last_updated_datetime").flatMap(timestamp)
            return SourceAccount(externalID: id, institution: institution, institutionDomain: nil,
                                 name: displayName(a), kind: kind,
                                 balance: money(current * sign, currency),
                                 availableBalance: number(b, "available").map { money($0, currency) },
                                 balanceDate: updated ?? readAt, transactions: [], holdings: [], mask: string(a, "mask"), providerType: type)
        }
    }

    /// Chase names every card "CREDIT CARD"; the official name ("Chase Freedom Unlimited") tells them apart.
    static func displayName(_ a: [String: JSONValue]) -> String {
        let name = string(a, "name"), official = string(a, "official_name")
        let generic = ["credit card", "checking", "savings", "account", "card"]
        if let official, !official.isEmpty, name.map({ generic.contains($0.lowercased().trimmingCharacters(in: .whitespaces)) }) ?? true { return official }
        return name ?? official ?? "Account"
    }
}
