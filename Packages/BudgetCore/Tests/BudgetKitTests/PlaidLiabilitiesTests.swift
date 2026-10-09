import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import BudgetKit

/// Answers each path with a status and body, and records what was sent. Nothing leaves the process.
final class StatusTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let routes: [String: (status: Int, body: String)]
    private(set) var requests: [URLRequest] = []

    init(_ routes: [String: (status: Int, body: String)]) { self.routes = routes }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = lock.withLock { () -> (Int, String) in
            requests.append(request)
            return routes[request.url!.path] ?? (404, #"{"error":"not found"}"#)
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func body(of path: String) -> JSONValue? {
        lock.withLock { requests.last { $0.url!.path == path }?.httpBody.flatMap { try? JSONValue.parse($0) } }
    }

    var paths: [String] { lock.withLock { requests.map { $0.url!.path } } }
}

@Suite("Plaid Liabilities (card bills)")
struct PlaidLiabilitiesTests {
    static let credentials = PlaidSource.Credentials(clientID: "cid", secret: "sec")

    /// The shape of Plaid's /liabilities/get example: one card with every field, one with most of them null, a mortgage.
    static let response = #"""
    {"accounts": [], "liabilities": {
      "credit": [
        {"account_id": "card-1", "aprs": [
            {"apr_percentage": 27.24, "apr_type": "cash_apr", "balance_subject_to_apr": 0, "interest_charge_amount": 0},
            {"apr_percentage": 21.99, "apr_type": "purchase_apr", "balance_subject_to_apr": 1562.32, "interest_charge_amount": 31.2}],
         "is_overdue": false, "last_payment_amount": 168.25, "last_payment_date": "2026-08-22",
         "last_statement_issue_date": "2026-09-01", "last_statement_balance": 1708.77,
         "minimum_payment_amount": 35, "next_payment_due_date": "2026-09-26"},
        {"account_id": "card-2", "aprs": [], "is_overdue": null, "last_payment_amount": null, "last_payment_date": null,
         "last_statement_issue_date": null, "last_statement_balance": null, "minimum_payment_amount": null, "next_payment_due_date": null}
      ],
      "mortgage": [{"account_id": "home-1", "next_monthly_payment": 2100}],
      "student": null
    }, "request_id": "req-liab-1"}
    """#

    static func source(_ transport: any HTTPTransport, environment: PlaidSource.Environment = .sandbox) -> PlaidSource {
        PlaidSource(environment: environment, credentials: credentials, accessToken: "access-test-1", institution: "Summit Card", transport: transport)
    }

    @Test("Parses each card's statement; null fields stay nil, APR is picked by type, loans are left out")
    func parse() async throws {
        let transport = StatusTransport(["/liabilities/get": (200, Self.response)])
        let (bills, requestID) = try await Self.source(transport).liabilities(accountIDs: ["card-1", "card-2"])
        #expect(requestID == "req-liab-1")
        #expect(bills.map(\.externalAccountID) == ["card-1", "card-2"])
        let card = bills[0]
        #expect(card.statementBalance == Money(1708.77))
        #expect(card.minimumPayment == Money(35))
        #expect(card.dueDate == PlaidSource.day("2026-09-26"))
        #expect(card.statementDate == PlaidSource.day("2026-09-01"))
        #expect(card.lastPaymentAmount == Money(168.25))
        #expect(card.isOverdue == false)
        #expect(card.purchaseAPR == 21.99)
        let sparse = bills[1]
        #expect(sparse.statementBalance == nil && sparse.dueDate == nil && sparse.isOverdue == nil && sparse.purchaseAPR == nil)
        guard case let .object(body)? = transport.body(of: "/liabilities/get") else { Issue.record("no body"); return }
        #expect(body["access_token"] == .string("access-test-1"))
        #expect(body["options"] == .object(["account_ids": .array([.string("card-1"), .string("card-2")])]))
        #expect(transport.requests.first?.url?.host == "sandbox.plaid.com")
    }

    @Test("Plaid's errors come back by code, with the request id", arguments: [
        ("ADDITIONAL_CONSENT_REQUIRED", "INVALID_INPUT", CardBillAccess.needsConsent),
        ("PRODUCTS_NOT_SUPPORTED", "ITEM_ERROR", .notSupported),
        ("INVALID_PRODUCT", "INVALID_INPUT", .notSupported),
        ("NO_LIABILITY_ACCOUNTS", "ITEM_ERROR", .noCreditAccounts),
        ("PRODUCT_NOT_READY", "ITEM_ERROR", .notReady),
        ("INSTITUTION_DOWN", "INSTITUTION_ERROR", .failed),
    ])
    func errors(code: String, type: String, access: CardBillAccess) async throws {
        let body = #"{"display_message": null, "error_code": "\#(code)", "error_message": "worded however Plaid likes", "error_type": "\#(type)", "request_id": "req-err-1"}"#
        let transport = StatusTransport(["/liabilities/get": (400, body)])
        do {
            _ = try await Self.source(transport).liabilities(accountIDs: ["card-1"])
            Issue.record("expected an error")
        } catch let error as PlaidAPIError {
            #expect(error.errorCode == code)
            #expect(error.errorType == type)
            #expect(error.requestID == "req-err-1")
            #expect(error.status == 400)
            #expect(CardBillAccess.from(errorCode: error.errorCode) == access)
        }
    }

    @Test("A body that isn't Plaid's error stays the transport's error")
    func otherErrors() async throws {
        let transport = StatusTransport(["/liabilities/get": (502, "Bad gateway")])
        await #expect(throws: SourceHTTPError.self) { try await Self.source(transport).liabilities(accountIDs: []) }
        #expect(PlaidAPIError(SourceHTTPError(status: 500, body: #"{"message": "no"}"#)) == nil)
    }

    @Test("Unknown access states read as failed, so they're asked again later")
    func accessDecoding() throws {
        #expect(try JSONDecoder().decode(CardBillAccess.self, from: Data(#""somethingNew""#.utf8)) == .failed)
        #expect(try JSONDecoder().decode(CardBillAccess.self, from: Data(#""needsConsent""#.utf8)) == .needsConsent)
    }

    @Test("New links consent to liabilities next to investments, never as a required product")
    func newLink() async throws {
        let transport = StatusTransport(["/link/token/create": (200, #"{"link_token": "link-sandbox-1"}"#)])
        _ = try await PlaidSource.linkToken(environment: .sandbox, credentials: Self.credentials, userID: "owner", investments: true, transport: transport)
        guard case let .object(body)? = transport.body(of: "/link/token/create") else { Issue.record("no body"); return }
        #expect(body["products"] == .array([.string("transactions")]))
        #expect(body["additional_consented_products"] == .array([.string("investments"), .string("liabilities")]))
        #expect(body["access_token"] == nil)
    }

    @Test("The card-bill grant is update mode on the same Item: its access token, no products, liabilities consent, the redirect kept")
    func grant() async throws {
        let transport = StatusTransport(["/link/token/create": (200, #"{"link_token": "link-sandbox-2"}"#)])
        _ = try await PlaidSource.linkToken(environment: .sandbox, credentials: Self.credentials, userID: "owner", investments: true,
                                            redirectURI: "https://budget.example.com/", accessToken: "access-test-1", grantLiabilities: true,
                                            transport: transport)
        guard case let .object(body)? = transport.body(of: "/link/token/create") else { Issue.record("no body"); return }
        #expect(body["access_token"] == .string("access-test-1"))
        #expect(body["products"] == .array([]))
        #expect(body["additional_consented_products"] == .array([.string("liabilities")]))
        #expect(body["redirect_uri"] == .string("https://budget.example.com/"))
        // Only Link is asked: no exchange, no removal.
        #expect(transport.paths == ["/link/token/create"])
    }

    @Test("A plain reconnect stays as it was: the access token alone")
    func reconnect() async throws {
        let transport = StatusTransport(["/link/token/create": (200, #"{"link_token": "link-sandbox-3"}"#)])
        _ = try await PlaidSource.linkToken(environment: .sandbox, credentials: Self.credentials, userID: "owner", investments: true,
                                            accessToken: "access-test-1", transport: transport)
        guard case let .object(body)? = transport.body(of: "/link/token/create") else { Issue.record("no body"); return }
        #expect(body["products"] == nil)
        #expect(body["additional_consented_products"] == nil)
    }
}
