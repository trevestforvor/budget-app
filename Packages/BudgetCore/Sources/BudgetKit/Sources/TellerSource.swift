import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLSession/URLRequest on Linux
#endif

/// Teller (https://teller.io/docs/api). Direct bank APIs; requests need the application's
/// client certificate (mTLS) plus the enrollment's access token as the Basic-auth username.
///
/// Connect flow: the phone opens Teller Connect with the application id; it returns an access
/// token for the enrollment, which the phone hands to the server once and forgets.
public struct TellerSource: TransactionSource {
    public static let baseURL = URL(string: "https://api.teller.io")!

    public let accessToken: String
    private let transport: any HTTPTransport

    /// - Parameter transport: must present the Teller client certificate —
    ///   `URLSessionTransport.mutualTLS(ClientCertificateDelegate(pkcs12:password:))` on Apple platforms.
    public init(accessToken: String, transport: any HTTPTransport) {
        self.accessToken = accessToken
        self.transport = transport
    }

    public var kind: SourceKind { .teller }

    func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Basic " + Data("\(accessToken):".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60 // the first transactions call on a large account can be slow
        return request
    }

    public func fetch(since: Date, includePending: Bool = true) async throws -> SourceSnapshot {
        let accountsJSON = try await transport.json(request("accounts"))
        guard case let .array(list) = accountsJSON else { throw DecisionError.malformed("accounts") }
        var accounts: [SourceAccount] = []
        var warnings: [String] = []
        for case let .object(a) in list {
            guard var account = Self.account(a) else { continue }
            if case let .object(links)? = a["links"], links["balances"] != nil {
                if case let .object(b) = try await transport.json(request("accounts/\(account.externalID)/balances")) {
                    (account.balance, account.availableBalance) = Self.balances(b, kind: account.kind, currency: account.balance.currencyCode)
                }
            }
            do {
                let json = try await transport.json(request("accounts/\(account.externalID)/transactions",
                                                            query: [URLQueryItem(name: "start_date", value: Self.isoDay(since))]))
                if case let .array(rows) = json {
                    account.transactions = rows.compactMap(Self.transaction).filter { includePending || !$0.isPending }
                }
            } catch {
                warnings.append("\(account.institution) \(account.name): transactions unavailable (\(error.localizedDescription))")
            }
            accounts.append(account)
        }
        return SourceSnapshot(source: .teller, accounts: accounts, warnings: warnings)
    }

    // MARK: Parsing

    static func string(_ o: [String: JSONValue], _ key: String) -> String? { if case let .string(v)? = o[key] { v } else { nil } }

    static func account(_ a: [String: JSONValue]) -> SourceAccount? {
        guard let id = string(a, "id"), let name = string(a, "name") else { return nil }
        var institution = "Unknown institution"
        if case let .object(i)? = a["institution"], let n = string(i, "name") { institution = n }
        let kind: AccountKind = switch (string(a, "type"), string(a, "subtype")) {
        case ("credit", _): .credit
        case (_, "savings"?), (_, "money_market"?), (_, "certificate_of_deposit"?), (_, "treasury"?): .savings
        default: .checking
        }
        let currency = string(a, "currency") ?? "USD"
        let display = string(a, "last_four").map { "\(name) ••\($0)" } ?? name
        return SourceAccount(externalID: id, institution: institution, institutionDomain: nil, name: display, kind: kind,
                             balance: Money(minorUnits: 0, currencyCode: currency), availableBalance: nil, balanceDate: .now,
                             transactions: [], holdings: [], mask: string(a, "last_four"))
    }

    /// `{ledger, available}` as strings. Credit ledger balances are amounts owed; shown negative.
    static func balances(_ b: [String: JSONValue], kind: AccountKind, currency: String) -> (Money, Money?) {
        func money(_ key: String) -> Money? {
            guard let s = string(b, key), let d = DecimalAmount(string: s) else { return nil }
            return Money(minorUnits: kind == .credit ? -Swift.abs(d.minorUnits) : d.minorUnits, currencyCode: currency)
        }
        return (money("ledger") ?? Money(minorUnits: 0, currencyCode: currency), money("available"))
    }

    /// Teller amounts are signed from the account holder's view: negative is money out.
    static func transaction(_ value: JSONValue) -> SourceTransaction? {
        guard case let .object(t) = value, let id = string(t, "id"), let amountText = string(t, "amount"),
              let amount = DecimalAmount(string: amountText), let date = string(t, "date").flatMap(PlaidSource.day) else { return nil }
        var payee: String?
        var category: String?
        if case let .object(details)? = t["details"] {
            category = string(details, "category")
            if case let .object(counterparty)? = details["counterparty"] { payee = string(counterparty, "name") }
        }
        return SourceTransaction(externalID: id, posted: date, amount: Money(minorUnits: amount.minorUnits),
                                 description: string(t, "description") ?? "", payee: payee,
                                 isPending: string(t, "status") == "pending", providerCategory: category)
    }

    static func isoDay(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "UTC")!).year().month().day())
    }
}
