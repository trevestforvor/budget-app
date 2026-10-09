import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking // URLRequest on Linux
#endif

// Card bills from Plaid Liabilities (`/liabilities/get`): each credit card's statement balance, minimum payment, due
// date and last payment. Billed per Item once used, so the server calls it only when the person turns card bills on,
// only on Items with a credit card, and at most once a day per Item (`SyncService`). It never removes, replaces or
// re-links an Item: an Item linked before liabilities was consented answers ADDITIONAL_CONSENT_REQUIRED, and the fix
// is the person's own click on the dashboard's "Grant card-bill access" (update mode, same Item, same access token).

/// One credit card's statement as `/liabilities/get` reports it. Every field may be missing at some institution.
public struct SourceCardBill: Hashable, Sendable {
    /// The provider's account id (Plaid `account_id`).
    public var externalAccountID: String
    /// Owed on the latest statement, as a positive amount.
    public var statementBalance: Money?
    public var statementDate: Date?
    public var minimumPayment: Money?
    public var dueDate: Date?
    public var isOverdue: Bool?
    public var lastPaymentAmount: Money?
    public var lastPaymentDate: Date?
    /// The purchase APR, percent.
    public var purchaseAPR: Double?

    public init(externalAccountID: String, statementBalance: Money? = nil, statementDate: Date? = nil, minimumPayment: Money? = nil,
                dueDate: Date? = nil, isOverdue: Bool? = nil, lastPaymentAmount: Money? = nil, lastPaymentDate: Date? = nil,
                purchaseAPR: Double? = nil) {
        self.externalAccountID = externalAccountID; self.statementBalance = statementBalance; self.statementDate = statementDate
        self.minimumPayment = minimumPayment; self.dueDate = dueDate; self.isOverdue = isOverdue
        self.lastPaymentAmount = lastPaymentAmount; self.lastPaymentDate = lastPaymentDate; self.purchaseAPR = purchaseAPR
    }
}

/// A Plaid API error, read from its JSON body. Code branches on `errorType` and `errorCode`, never on the message,
/// which Plaid may reword. `requestID` is what Plaid support asks for; it's safe to log (a token never is).
public struct PlaidAPIError: LocalizedError, Hashable, Sendable {
    public var status: Int
    public var errorType: String?
    public var errorCode: String?
    public var errorMessage: String?
    public var displayMessage: String?
    public var requestID: String?

    public init(status: Int, errorType: String? = nil, errorCode: String? = nil, errorMessage: String? = nil,
                displayMessage: String? = nil, requestID: String? = nil) {
        self.status = status; self.errorType = errorType; self.errorCode = errorCode; self.errorMessage = errorMessage
        self.displayMessage = displayMessage; self.requestID = requestID
    }

    /// Plaid's error body (`error_type`, `error_code`, `error_message`, `display_message`, `request_id`); nil when the
    /// body isn't one.
    public init?(_ error: SourceHTTPError) {
        guard case let .object(o)? = try? JSONValue.parse(Data(error.body.utf8)) else { return nil }
        let code = PlaidSource.string(o, "error_code"), type = PlaidSource.string(o, "error_type")
        guard code != nil || type != nil else { return nil }
        self.init(status: error.status, errorType: type, errorCode: code, errorMessage: PlaidSource.string(o, "error_message"),
                  displayMessage: PlaidSource.string(o, "display_message"), requestID: PlaidSource.string(o, "request_id"))
    }

    public var errorDescription: String? {
        "Plaid: \(errorMessage ?? "error \(status)")" + (errorCode.map { " (\($0))" } ?? "")
    }
}

/// Whether an Item gives card bills, as the last `/liabilities/get` said. Each "not available" answer is a state of
/// the Item, not a failed sync: the transactions sync goes on either way.
public enum CardBillAccess: String, Hashable, Codable, Sendable, CaseIterable {
    /// Card bills came back.
    case ok
    /// The Item was linked before liabilities was consented (ADDITIONAL_CONSENT_REQUIRED): the person can grant it
    /// from the dashboard.
    case needsConsent
    /// The institution doesn't offer liabilities, or this Plaid account isn't enabled for it (PRODUCTS_NOT_SUPPORTED,
    /// INVALID_PRODUCT).
    case notSupported
    /// No credit card on the Item (NO_LIABILITY_ACCOUNTS, or none among its accounts, so it wasn't asked).
    case noCreditAccounts
    /// Plaid is still gathering it (PRODUCT_NOT_READY); asked again on a later day.
    case notReady
    /// Anything else; asked again on a later day.
    case failed

    /// What an error code means for card bills. Codes not listed are `.failed`.
    public static func from(errorCode: String?) -> CardBillAccess {
        switch errorCode {
        case "ADDITIONAL_CONSENT_REQUIRED": .needsConsent
        case "PRODUCTS_NOT_SUPPORTED", "INVALID_PRODUCT": .notSupported
        case "NO_LIABILITY_ACCOUNTS": .noCreditAccounts
        case "PRODUCT_NOT_READY": .notReady
        default: .failed
        }
    }

    /// A state a later version adds decodes as `.failed` (asked again later), instead of failing the link's load.
    public init(from decoder: any Decoder) throws {
        self = CardBillAccess(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .failed
    }
}

extension PlaidSource {
    /// The product name Plaid uses for card bills.
    public static let liabilitiesProduct = "liabilities"

    /// The Item's credit cards in a snapshot (Plaid type "credit"; loans aren't card bills). Card bills are asked for
    /// only when there's one: a depository-only Item would answer NO_LIABILITY_ACCOUNTS.
    public static func cardAccountIDs(_ snapshot: SourceSnapshot) -> [String] {
        snapshot.accounts.filter { $0.providerType == "credit" }.map(\.externalID)
    }

    /// `/liabilities/get` for `accountIDs` (the Item's credit cards): each card's statement, by Plaid account id, with the
    /// response's `request_id`. Plaid's errors come back as `PlaidAPIError`, so callers branch on the code.
    public func liabilities(accountIDs: [String]) async throws -> (bills: [SourceCardBill], requestID: String?) {
        var body: [String: JSONValue] = ["access_token": .string(accessToken)]
        if !accountIDs.isEmpty { body["options"] = .object(["account_ids": .array(accountIDs.map(JSONValue.string))]) }
        do {
            return try Self.parseLiabilities(try await transport.json(try Self.request(environment, "liabilities/get", body, credentials)))
        } catch let error as SourceHTTPError {
            throw PlaidAPIError(error) ?? error
        }
    }

    /// `liabilities.credit[]`. Mortgages and student loans aren't card bills and are left out. Any field may be null;
    /// APRs are a list picked by type, never by position.
    static func parseLiabilities(_ json: JSONValue) throws -> (bills: [SourceCardBill], requestID: String?) {
        guard case let .object(o) = json, case let .object(liabilities)? = o["liabilities"] else { throw DecisionError.malformed("no liabilities") }
        var bills: [SourceCardBill] = []
        if case let .array(credit)? = liabilities["credit"] {
            for case let .object(card) in credit {
                guard let id = string(card, "account_id") else { continue }
                func amount(_ key: String) -> Money? { number(card, key).map { money($0, "USD") } }
                var apr: Double?
                if case let .array(aprs)? = card["aprs"] {
                    for case let .object(a) in aprs where string(a, "apr_type") == "purchase_apr" { apr = number(a, "apr_percentage") }
                }
                let overdue: Bool? = if case let .bool(v)? = card["is_overdue"] { v } else { nil }
                bills.append(SourceCardBill(
                    externalAccountID: id, statementBalance: amount("last_statement_balance"),
                    statementDate: string(card, "last_statement_issue_date").flatMap(day), minimumPayment: amount("minimum_payment_amount"),
                    dueDate: string(card, "next_payment_due_date").flatMap(day), isOverdue: overdue,
                    lastPaymentAmount: amount("last_payment_amount"), lastPaymentDate: string(card, "last_payment_date").flatMap(day),
                    purchaseAPR: apr))
            }
        }
        return (bills, string(o, "request_id"))
    }
}
